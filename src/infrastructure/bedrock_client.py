"""
Amazon Bedrock Runtime client for the Converse API.

BedrockClient:
  - Sends a text prompt to bedrock-runtime converse().
  - Uses the default AWS credential chain (EC2 instance role). No keys are
    read from config or the environment by this class.
  - Returns the model's text, with a markdown fence removed when the model
    wrapped an otherwise valid JSON object.
  - Does not parse or validate the schema. The caller still runs
    LLMAnalysis.model_validate_json and the existing retry/fallback path.
"""

from __future__ import annotations

import json
import logging

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError, ConnectTimeoutError, ReadTimeoutError

logger = logging.getLogger(__name__)

# Reinforces the analyzer/reviewer prompt. Nova Micro has no Ollama-style
# format=json switch, and a short system instruction keeps the full
# LLMAnalysis object intact instead of a topic/urgency fragment.
_SYSTEM_PROMPT = (
    "You are a JSON API. Return one JSON object and nothing else. "
    "Do not use markdown or code fences. Do not add commentary. "
    "Include every field the user requested. "
    "For ticket triage those fields are topic, urgency, missing_info, "
    "missing_fields, confidence, and short_note. "
    "Use the exact enum strings from the user message. "
    "missing_info must be a JSON boolean. "
    "missing_fields must be a JSON array of strings. "
    "confidence must be a number from 0.0 to 1.0. "
    "short_note must be a short plain-text string."
)


class BedrockClient:
    """
    Wraps the Amazon Bedrock Runtime Converse API.

    The caller is responsible for parsing and validating the returned string.
    generate_json matches OllamaClient: it returns text and raises on
    transport or API failure. Malformed JSON is returned as text so the
    analyzer can retry.
    """

    def __init__(
        self,
        model_id: str,
        region: str,
        temperature: float,
        timeout_seconds: int,
        max_tokens: int = 1024,
        connect_timeout_seconds: int = 10,
        top_p: float | None = None,
    ) -> None:
        if not model_id:
            raise ValueError("Bedrock model_id is required")
        if timeout_seconds <= 0:
            raise ValueError("timeout_seconds must be positive")
        if max_tokens <= 0:
            raise ValueError("max_tokens must be positive")
        if connect_timeout_seconds <= 0:
            raise ValueError("connect_timeout_seconds must be positive")

        self.model_id = model_id
        self.region = region
        self.temperature = float(temperature)
        self.timeout_seconds = int(timeout_seconds)
        self.max_tokens = int(max_tokens)
        self.connect_timeout_seconds = int(connect_timeout_seconds)
        self.top_p = None if top_p is None else float(top_p)

        # max_attempts is the total number of tries, including the first.
        # Validation retries stay in the analyzer; this client does not hide
        # a timeout behind extra Bedrock calls.
        sdk_config = Config(
            connect_timeout=self.connect_timeout_seconds,
            read_timeout=self.timeout_seconds,
            retries={"max_attempts": 1, "mode": "standard"},
        )
        self._runtime = boto3.client(
            "bedrock-runtime",
            region_name=region,
            config=sdk_config,
        )
        logger.debug(
            "Initialized BedrockClient model=%s region=%s",
            self.model_id,
            self.region,
        )

    def generate_json(self, prompt: str) -> tuple[str, dict]:
        """
        Send prompt to Bedrock and return the model's response text and metadata.

        Returns:
            (text, metadata_dict) where metadata_dict contains:
                - input_tokens: int | None
                - output_tokens: int | None  
                - latency_ms: int | None
                - model_id: str
                - region: str
                - invoked: bool (True if successful)

        Raises botocore.exceptions.ClientError on Bedrock API errors.
        Raises botocore.exceptions.ReadTimeoutError if the read times out.
        Raises botocore.exceptions.ConnectTimeoutError if the connection times out.
        Raises ValueError if the response contains no text.
        """
        inference_config: dict = {
            "temperature": self.temperature,
            "maxTokens": self.max_tokens,
        }
        if self.top_p is not None:
            inference_config["topP"] = self.top_p

        try:
            response = self._runtime.converse(
                modelId=self.model_id,
                system=[{"text": _SYSTEM_PROMPT}],
                messages=[
                    {
                        "role": "user",
                        "content": [{"text": prompt}],
                    }
                ],
                inferenceConfig=inference_config,
            )
        except (ClientError, ConnectTimeoutError, ReadTimeoutError):
            raise

        text = _extract_text(response)
        if not text.strip():
            raise ValueError("Bedrock response did not contain text")
        
        # Extract inference metadata from response
        metadata = _extract_metadata(response, self.model_id, self.region)
        
        return _coerce_json_text(text), metadata


def _extract_text(response: dict) -> str:
    """Concatenate text blocks from a Converse API response."""
    try:
        content = response["output"]["message"]["content"]
    except (KeyError, TypeError) as exc:
        raise ValueError("Bedrock response did not contain text") from exc
    parts: list[str] = []
    for block in content:
        if isinstance(block, dict) and "text" in block and block["text"] is not None:
            parts.append(str(block["text"]))
    return "".join(parts)


def _strip_markdown_fence(text: str) -> str:
    """Remove a single leading/trailing markdown code fence, if present."""
    stripped = text.strip()
    if not stripped.startswith("```"):
        return stripped
    lines = stripped.splitlines()
    if lines and lines[0].startswith("```"):
        lines = lines[1:]
    if lines and lines[-1].strip() == "```":
        lines = lines[:-1]
    return "\n".join(lines).strip()


def _is_json_value(text: str) -> bool:
    try:
        json.loads(text)
    except (json.JSONDecodeError, ValueError):
        return False
    return True


def _first_json_object(text: str) -> str | None:
    """Return the first balanced {...} object, or None if there is none."""
    start = text.find("{")
    if start < 0:
        return None
    depth = 0
    in_string = False
    escape = False
    for index in range(start, len(text)):
        char = text[index]
        if in_string:
            if escape:
                escape = False
            elif char == "\\":
                escape = True
            elif char == '"':
                in_string = False
            continue
        if char == '"':
            in_string = True
        elif char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return text[start : index + 1]
    return None


def _coerce_json_text(text: str) -> str:
    """
    Return model text that json.loads can read when the payload is valid.

    A fence or a short preamble is removed only when the remaining text is
    valid JSON. Anything else is returned unchanged so Pydantic still rejects
    it and the analyzer retry runs.
    """
    candidate = text.strip().lstrip("\ufeff")
    fenced = _strip_markdown_fence(candidate)
    for blob in (fenced, candidate):
        if blob and _is_json_value(blob):
            return blob
    extracted = _first_json_object(fenced)
    if extracted is not None and _is_json_value(extracted):
        return extracted
    return text


def _extract_metadata(response: dict, model_id: str, region: str) -> dict:
    """
    Extract inference metadata from Bedrock Converse API response.
    
    Returns dict with keys: input_tokens, output_tokens, latency_ms, 
    model_id, region, invoked. All values are defensive - missing fields
    become None rather than raising exceptions.
    
    Args:
        response: The full boto3 converse() response dict
        model_id: The model/inference profile ID used
        region: The AWS region used
        
    Returns:
        dict with inference metadata
    """
    metadata = {
        "input_tokens": None,
        "output_tokens": None,
        "latency_ms": None,
        "model_id": model_id,
        "region": region,
        "invoked": True,  # If we reached here, the call succeeded
    }
    
    # Extract token usage
    try:
        usage = response.get("usage", {})
        if "inputTokens" in usage:
            metadata["input_tokens"] = int(usage["inputTokens"])
        if "outputTokens" in usage:
            metadata["output_tokens"] = int(usage["outputTokens"])
    except (KeyError, TypeError, ValueError) as e:
        logger.debug(f"Could not extract usage from Bedrock response: {e}")
    
    # Extract latency metrics
    try:
        metrics = response.get("metrics", {})
        if "latencyMs" in metrics:
            metadata["latency_ms"] = int(metrics["latencyMs"])
    except (KeyError, TypeError, ValueError) as e:
        logger.debug(f"Could not extract metrics from Bedrock response: {e}")
    
    return metadata
