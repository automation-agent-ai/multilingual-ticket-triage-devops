"""
Unit tests for BedrockClient and LLM provider selection.

boto3 is mocked. These tests do not call Amazon Bedrock.
"""

import json
from unittest.mock import MagicMock, patch

import pytest
import yaml
from botocore.exceptions import ClientError, ReadTimeoutError
from pydantic import ValidationError

from src.application.analyzer import LocalLLMAnalyzer
from src.domain.enums import Topic, Urgency
from src.domain.models import LLMAnalysis, NeighborEvidence, NeighborPrediction, TicketInput
from src.infrastructure.bedrock_client import BedrockClient
from src.infrastructure.llm_client import OllamaClient
from src.infrastructure.llm_provider import create_llm_client, create_reviewer_client

FULL_JSON = json.dumps({
    "topic": "Technical / Online Access",
    "urgency": "High",
    "missing_info": False,
    "missing_fields": [],
    "confidence": 0.86,
    "short_note": "Customer reports a login access issue on the portal.",
})

TOPIC_URGENCY_ONLY = json.dumps({
    "topic": "Technical / Online Access",
    "urgency": "High",
})


def _converse_response(text: str) -> dict:
    return {
        "output": {
            "message": {
                "role": "assistant",
                "content": [{"text": text}],
            }
        },
        "stopReason": "end_turn",
        "usage": {"inputTokens": 20, "outputTokens": 40},
    }


def _converse_response_with_metrics(text: str, latency_ms: int = 850) -> dict:
    """Converse response with latencyMs included in metrics."""
    response = _converse_response(text)
    response["metrics"] = {"latencyMs": latency_ms}
    return response


@pytest.fixture
def mock_runtime():
    with patch("src.infrastructure.bedrock_client.boto3.client") as mock_client:
        runtime = MagicMock()
        mock_client.return_value = runtime
        yield runtime, mock_client


def _client(**overrides) -> BedrockClient:
    settings = {
        "model_id": "eu.amazon.nova-micro-v1:0",
        "region": "eu-west-1",
        "temperature": 0.1,
        "timeout_seconds": 120,
        "max_tokens": 1024,
        "connect_timeout_seconds": 10,
    }
    settings.update(overrides)
    return BedrockClient(**settings)


def _ticket() -> TicketInput:
    return TicketInput(
        ticket_id="T001",
        subject="Cannot login to the customer portal",
        body="I have been trying to log in for three days.",
        raw_text="Cannot login",
        cleaned_text="Cannot login",
        representation_text="Subject: Cannot login\n\nBody: login",
        text_snippet="Cannot login",
    )


def _prediction() -> NeighborPrediction:
    neighbor = NeighborEvidence(
        ticket_id="REF001",
        distance=0.15,
        similarity=0.87,
        actual_queue="Technical Support",
        actual_priority="high",
        actual_type="Incident",
        actual_tags=["Login"],
        proxy_topic="Technical / Online Access",
        proxy_urgency="High",
        text_snippet="User cannot access the portal.",
    )
    return NeighborPrediction(
        predicted_queue="Technical Support",
        queue_confidence=0.80,
        predicted_priority="high",
        priority_confidence=0.75,
        predicted_proxy_topic="Technical / Online Access",
        proxy_topic_confidence=0.78,
        predicted_tags=["Login"],
        neighbors=[neighbor],
    )


# ─── Valid Converse output ────────────────────────────────────────────────────

def test_generate_json_returns_full_schema_text(mock_runtime):
    runtime, mock_client = mock_runtime
    runtime.converse.return_value = _converse_response(FULL_JSON)
    client = _client()

    result, metadata = client.generate_json("classify this ticket")

    # Verify the text response
    analysis = LLMAnalysis.model_validate_json(result)
    assert analysis.topic == Topic.TECHNICAL
    assert analysis.urgency == Urgency.HIGH
    assert analysis.missing_info is False
    assert analysis.missing_fields == []
    assert analysis.confidence == pytest.approx(0.86)
    assert analysis.short_note.startswith("Customer reports")

    # Verify the metadata
    assert metadata["model_id"] == "eu.amazon.nova-micro-v1:0"
    assert metadata["region"] == "eu-west-1"
    assert metadata["invoked"] is True
    assert metadata["input_tokens"] == 20
    assert metadata["output_tokens"] == 40
    assert metadata["latency_ms"] is None  # Not in mock response

    mock_client.assert_called_once()
    assert mock_client.call_args.args == ("bedrock-runtime",)
    kwargs = mock_client.call_args.kwargs
    assert kwargs["region_name"] == "eu-west-1"
    assert "aws_access_key_id" not in kwargs
    assert "aws_secret_access_key" not in kwargs
    assert "aws_session_token" not in kwargs

    call = runtime.converse.call_args.kwargs
    assert call["modelId"] == "eu.amazon.nova-micro-v1:0"
    assert call["messages"][0]["content"][0]["text"] == "classify this ticket"
    assert "missing_fields" in call["system"][0]["text"]
    assert "short_note" in call["system"][0]["text"]
    assert call["inferenceConfig"]["temperature"] == pytest.approx(0.1)
    assert call["inferenceConfig"]["maxTokens"] == 1024
    assert "topP" not in call["inferenceConfig"]
    assert kwargs["config"].read_timeout == 120
    assert kwargs["config"].connect_timeout == 10
    assert kwargs["config"].retries["max_attempts"] == 1


def test_generate_json_strips_markdown_fence(mock_runtime):
    runtime, _ = mock_runtime
    runtime.converse.return_value = _converse_response(
        "```json\n" + FULL_JSON + "\n```"
    )
    result, metadata = _client().generate_json("prompt")
    analysis = LLMAnalysis.model_validate_json(result)
    assert analysis.topic == Topic.TECHNICAL
    assert analysis.missing_info is False
    assert metadata["invoked"] is True


def test_generate_json_extracts_object_from_preamble(mock_runtime):
    runtime, _ = mock_runtime
    runtime.converse.return_value = _converse_response(
        "Here is the triage decision:\n" + FULL_JSON
    )
    result, metadata = _client().generate_json("prompt")
    assert LLMAnalysis.model_validate_json(result).urgency == Urgency.HIGH
    assert metadata["invoked"] is True


def test_metadata_includes_latency_when_present(mock_runtime):
    """Test that latencyMs is extracted from Bedrock metrics when available."""
    runtime, _ = mock_runtime
    runtime.converse.return_value = _converse_response_with_metrics(FULL_JSON, latency_ms=920)
    result, metadata = _client().generate_json("prompt")
    
    assert metadata["invoked"] is True
    assert metadata["input_tokens"] == 20
    assert metadata["output_tokens"] == 40
    assert metadata["latency_ms"] == 920
    assert metadata["model_id"] == "eu.amazon.nova-micro-v1:0"
    assert metadata["region"] == "eu-west-1"


def test_metadata_handles_missing_metrics_gracefully(mock_runtime):
    """Test that missing metrics fields don't cause failures."""
    runtime, _ = mock_runtime
    response = _converse_response(FULL_JSON)
    # Explicitly remove usage to simulate edge case
    del response["usage"]
    runtime.converse.return_value = response
    result, metadata = _client().generate_json("prompt")
    
    assert metadata["invoked"] is True
    assert metadata["input_tokens"] is None
    assert metadata["output_tokens"] is None
    assert metadata["latency_ms"] is None


def test_topic_and_urgency_only_still_fails_schema(mock_runtime):
    """Partial JSON is returned, and the existing schema still rejects it."""
    runtime, _ = mock_runtime
    runtime.converse.return_value = _converse_response(TOPIC_URGENCY_ONLY)
    result, metadata = _client().generate_json("prompt")
    assert "topic" in result
    assert metadata["invoked"] is True
    with pytest.raises(ValidationError):
        LLMAnalysis.model_validate_json(result)


def test_analyzer_retries_malformed_bedrock_json_then_accepts_full_schema(mock_runtime):
    runtime, _ = mock_runtime
    runtime.converse.side_effect = [
        _converse_response("this is not valid json {"),
        _converse_response(FULL_JSON),
    ]
    analyzer = LocalLLMAnalyzer(llm_client=_client(), max_retries=1)
    result, metadata = analyzer.analyze(_ticket(), _prediction())

    assert result.topic == Topic.TECHNICAL
    assert result.confidence == pytest.approx(0.86)
    assert runtime.converse.call_count == 2
    assert metadata["invocation_count"] == 2
    # Check that tokens are summed (2 calls with 20/40 each)
    assert metadata["input_tokens"] == 40
    assert metadata["output_tokens"] == 80


def test_analyzer_fallback_when_bedrock_never_satisfies_schema(mock_runtime):
    runtime, _ = mock_runtime
    runtime.converse.return_value = _converse_response(TOPIC_URGENCY_ONLY)
    analyzer = LocalLLMAnalyzer(llm_client=_client(), max_retries=1)
    result, metadata = analyzer.analyze(_ticket(), _prediction())

    assert result.topic == Topic.OTHER
    assert result.confidence == pytest.approx(0.0)
    assert "valid_structured_llm_output" in result.missing_fields
    assert runtime.converse.call_count == 2
    assert metadata["invocation_count"] == 2


# ─── Malformed JSON, API errors, timeouts ─────────────────────────────────────

def test_malformed_json_is_returned_unchanged(mock_runtime):
    runtime, _ = mock_runtime
    raw = "this is not valid json {"
    runtime.converse.return_value = _converse_response(raw)
    result, metadata = _client().generate_json("prompt")
    assert result == raw
    assert metadata["invoked"] is True


def test_generate_json_raises_client_error(mock_runtime):
    runtime, _ = mock_runtime
    runtime.converse.side_effect = ClientError(
        {"Error": {"Code": "AccessDeniedException", "Message": "denied"}},
        "Converse",
    )
    with pytest.raises(ClientError) as exc_info:
        _client().generate_json("prompt")
    assert exc_info.value.response["Error"]["Code"] == "AccessDeniedException"


def test_generate_json_raises_read_timeout(mock_runtime):
    runtime, _ = mock_runtime
    runtime.converse.side_effect = ReadTimeoutError(endpoint_url="https://bedrock")
    with pytest.raises(ReadTimeoutError):
        _client(timeout_seconds=5, connect_timeout_seconds=2).generate_json("prompt")


def test_empty_response_raises_value_error(mock_runtime):
    runtime, _ = mock_runtime
    runtime.converse.return_value = _converse_response("   ")
    with pytest.raises(ValueError, match="did not contain text"):
        _client().generate_json("prompt")


def test_custom_generation_settings_are_forwarded(mock_runtime):
    runtime, mock_client = mock_runtime
    runtime.converse.return_value = _converse_response(FULL_JSON)
    result, metadata = _client(temperature=0.4, max_tokens=256, top_p=0.8, timeout_seconds=45).generate_json("p")

    inference = runtime.converse.call_args.kwargs["inferenceConfig"]
    assert inference["temperature"] == pytest.approx(0.4)
    assert inference["maxTokens"] == 256
    assert inference["topP"] == pytest.approx(0.8)
    config = mock_client.call_args.kwargs["config"]
    assert config.read_timeout == 45
    assert metadata["invoked"] is True


# ─── Provider selection ───────────────────────────────────────────────────────

def test_missing_provider_defaults_to_ollama():
    client = create_llm_client({
        "base_url": "http://localhost:11434",
        "model_name": "llama3.2:3b",
        "temperature": 0.1,
        "timeout_seconds": 30,
    })
    assert isinstance(client, OllamaClient)
    assert client.model_name == "llama3.2:3b"
    assert client.base_url == "http://localhost:11434"


def test_explicit_bedrock_provider_uses_inference_profile(mock_runtime):
    runtime, _ = mock_runtime
    client = create_llm_client({
        "provider": "Bedrock",
        "model_name": "eu.amazon.nova-micro-v1:0",
        "region": "eu-west-1",
        "temperature": 0.1,
        "timeout_seconds": 90,
        "max_tokens": 512,
    })
    assert isinstance(client, BedrockClient)
    assert client.model_id == "eu.amazon.nova-micro-v1:0"
    assert client.region == "eu-west-1"
    assert client.timeout_seconds == 90
    assert client.max_tokens == 512
    runtime.converse.return_value = _converse_response(FULL_JSON)
    result, metadata = client.generate_json("prompt")
    assert runtime.converse.call_args.kwargs["modelId"] == "eu.amazon.nova-micro-v1:0"
    assert metadata["model_id"] == "eu.amazon.nova-micro-v1:0"


def test_inference_profile_overrides_model_name(mock_runtime):
    _runtime, _ = mock_runtime
    client = create_llm_client({
        "provider": "bedrock",
        "model_name": "amazon.nova-micro-v1:0",
        "inference_profile": "eu.amazon.nova-micro-v1:0",
        "region": "eu-west-1",
    })
    assert client.model_id == "eu.amazon.nova-micro-v1:0"


def test_unknown_provider_raises():
    with pytest.raises(ValueError, match="Unsupported LLM provider"):
        create_llm_client({
            "provider": "openai",
            "model_name": "gpt",
            "base_url": "http://localhost",
        })


def test_reviewer_inherits_bedrock_provider(mock_runtime):
    _runtime, _ = mock_runtime
    client = create_reviewer_client(
        {
            "provider": "bedrock",
            "model_name": "eu.amazon.nova-micro-v1:0",
            "region": "eu-west-1",
            "timeout_seconds": 30,
        },
        {"model_name": "eu.amazon.nova-micro-v1:0", "temperature": 0.2},
    )
    assert isinstance(client, BedrockClient)
    assert client.model_id == "eu.amazon.nova-micro-v1:0"
    assert client.temperature == pytest.approx(0.2)
    assert client.timeout_seconds == 30


def test_reviewer_can_stay_on_ollama_when_explicit():
    client = create_reviewer_client(
        {
            "provider": "bedrock",
            "model_name": "eu.amazon.nova-micro-v1:0",
            "region": "eu-west-1",
        },
        {
            "provider": "ollama",
            "model_name": "granite4.1:8b",
            "base_url": "http://localhost:11434/",
            "temperature": 0.1,
        },
    )
    assert isinstance(client, OllamaClient)
    assert client.model_name == "granite4.1:8b"
    assert client.base_url == "http://localhost:11434"


def test_default_config_remains_ollama():
    with open("config.yaml", encoding="utf-8") as handle:
        cfg = yaml.safe_load(handle)
    assert cfg["llm"]["provider"] == "ollama"
    assert "eu.amazon.nova" not in cfg["llm"]["model_name"]


def test_aws_config_selects_bedrock_without_secrets():
    with open("config-aws.yaml", encoding="utf-8") as handle:
        text = handle.read()
        cfg = yaml.safe_load(text)
    assert cfg["llm"]["provider"] == "bedrock"
    assert cfg["llm"]["model_name"] == "eu.amazon.nova-micro-v1:0"
    assert cfg["llm"]["region"] == "eu-west-1"
    assert cfg["reviewer"]["provider"] == "bedrock"
    assert cfg["runtime"]["rebuild_lancedb"] is False
    assert cfg["runtime"]["rebuild_duckdb"] is False
    lowered = text.lower()
    for secret in ("aws_access_key", "aws_secret", "aws_session_token", "akia"):
        assert secret not in lowered


def test_build_agent_uses_bedrock_client_when_configured(mock_runtime, tmp_path):
    import main as app_main

    _runtime, _ = mock_runtime
    cfg = {
        "llm": {
            "provider": "bedrock",
            "model_name": "eu.amazon.nova-micro-v1:0",
            "region": "eu-west-1",
            "temperature": 0.1,
            "timeout_seconds": 60,
            "max_retries": 1,
        },
        "vector_store": {"path": str(tmp_path / "lancedb"), "table_name": "ticket_embeddings"},
        "retrieval": {"top_k": 5},
        "thresholds": {"low_confidence": 0.60},
        "reviewer": {
            "enabled": True,
            "provider": "bedrock",
            "model_name": "eu.amazon.nova-micro-v1:0",
            "region": "eu-west-1",
            "temperature": 0.1,
            "max_retries": 1,
            "trigger_flags": ["low_llm_confidence"],
        },
    }
    agent = app_main._build_agent(cfg, MagicMock())
    assert isinstance(agent.analyzer.llm_client, BedrockClient)
    assert isinstance(agent.reviewer.llm_client, BedrockClient)
    assert agent.analyzer.llm_client.model_id == "eu.amazon.nova-micro-v1:0"
    assert agent.reviewer.model_name == "eu.amazon.nova-micro-v1:0"
