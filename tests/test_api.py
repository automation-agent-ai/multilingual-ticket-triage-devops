"""
Deterministic API tests with a fake agent.

Tests the FastAPI application endpoints without loading AI models or
connecting to external services. Uses a fake TicketTriageAgent that
returns canned responses for predictable testing.
"""

import pytest
from fastapi.testclient import TestClient

from src.domain.enums import NextAction, Topic, Urgency
from src.domain.models import (
    ActionExecutionResult,
    LLMAnalysis,
    NeighborPrediction,
    TicketInput,
    TriageResult,
    ValidationResult,
)


# ─── Fake Agent ───────────────────────────────────────────────────────────────


class FakeTicketTriageAgent:
    """
    Fake agent that returns canned responses for testing.

    Does not load models, connect to LanceDB, or call Ollama. Always returns
    a predictable TriageResult based on ticket_id patterns.
    """

    def process_ticket(self, ticket: TicketInput) -> TriageResult:
        """
        Return a canned TriageResult based on ticket_id.

        Rules:
          - ticket_id contains "billing" → BILLING + MEDIUM + FORWARD_BILLING
          - ticket_id contains "technical" → TECHNICAL + HIGH + FORWARD_TECHNICAL
          - otherwise → POLICY + LOW + SEND_FAQ
        """
        ticket_id_lower = ticket.ticket_id.lower()

        if "billing" in ticket_id_lower:
            topic = Topic.BILLING
            urgency = Urgency.MEDIUM
            next_action = NextAction.FORWARD_BILLING
            short_note = "Fake billing issue detected"
        elif "technical" in ticket_id_lower:
            topic = Topic.TECHNICAL
            urgency = Urgency.HIGH
            next_action = NextAction.FORWARD_TECHNICAL
            short_note = "Fake technical issue detected"
        else:
            topic = Topic.POLICY
            urgency = Urgency.LOW
            next_action = NextAction.SEND_FAQ
            short_note = "Fake policy question detected"

        action_result = ActionExecutionResult(
            selected_action=next_action,
            action_status="success",
            action_note=f"Fake action: {next_action.value}",
            target="fake_target",
        )

        return TriageResult(
            ticket_id=ticket.ticket_id,
            text_snippet=ticket.text_snippet,
            topic=topic,
            urgency=urgency,
            next_action=next_action,
            confidence=0.95,
            missing_info=False,
            missing_fields=[],
            requires_human_review=False,
            short_note=short_note,
            action_result=action_result,
        )


# ─── Pytest Fixtures ──────────────────────────────────────────────────────────


@pytest.fixture
def fake_agent():
    """Return a fake agent for testing."""
    return FakeTicketTriageAgent()


@pytest.fixture
def test_client(fake_agent, monkeypatch):
    """
    Return a TestClient with the fake agent injected.

    Patches the global _agent and _agent_ready variables so the API uses
    the fake agent instead of loading real models.
    """
    import asyncio
    
    # Import app and patch global state before creating TestClient
    import api.app as app_module
    from api.app import app

    # Patch global state to use fake agent
    monkeypatch.setattr(app_module, "_agent", fake_agent)
    monkeypatch.setattr(app_module, "_agent_ready", True)
    monkeypatch.setattr(app_module, "_inference_semaphore", asyncio.Semaphore(1))

    # Create a new test client
    # Use raise_server_exceptions=False to see real error responses
    return TestClient(app, raise_server_exceptions=False)


# ─── Health Endpoint Tests ────────────────────────────────────────────────────


def test_health_returns_200(test_client):
    """Test that GET /health returns HTTP 200."""
    response = test_client.get("/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


# ─── Readiness Endpoint Tests ─────────────────────────────────────────────────


def test_ready_returns_true_when_agent_initialized(test_client):
    """Test that GET /ready returns ready=true when agent is initialized."""
    response = test_client.get("/ready")
    assert response.status_code == 200
    data = response.json()
    assert data["ready"] is True
    assert data["agent_initialized"] is True


def test_ready_returns_false_when_agent_not_initialized(monkeypatch):
    """Test that GET /ready returns ready=false when agent is not initialized."""
    from api import app as app_module
    from api.app import app

    # Patch global state to simulate uninitialized agent
    monkeypatch.setattr(app_module, "_agent", None)
    monkeypatch.setattr(app_module, "_agent_ready", False)

    client = TestClient(app)
    response = client.get("/ready")
    assert response.status_code == 200
    data = response.json()
    assert data["ready"] is False
    assert data["agent_initialized"] is False


# ─── Triage Endpoint Tests ────────────────────────────────────────────────────


def test_triage_returns_200_with_valid_request(test_client):
    """Test that POST /triage returns HTTP 200 with valid request."""
    request_body = {
        "ticket_id": "test-123",
        "subject": "Policy question",
        "body": "I have a question about my policy coverage.",
    }
    response = test_client.post("/triage", json=request_body)
    assert response.status_code == 200


def test_triage_processes_billing_ticket(test_client):
    """Test that POST /triage correctly processes a billing ticket."""
    request_body = {
        "ticket_id": "billing-456",
        "subject": "Billing question",
        "body": "I was charged twice for my premium.",
    }
    response = test_client.post("/triage", json=request_body)
    assert response.status_code == 200

    data = response.json()
    assert data["ticket_id"] == "billing-456"
    assert data["topic"] == "Billing / Payment"
    assert data["urgency"] == "Medium"
    assert data["next_action"] == "forward_to_billing_team"
    assert data["confidence"] == 0.95
    assert data["missing_info"] is False
    assert data["requires_human_review"] is False
    assert data["short_note"] == "Fake billing issue detected"


def test_triage_processes_technical_ticket(test_client):
    """Test that POST /triage correctly processes a technical ticket."""
    request_body = {
        "ticket_id": "technical-789",
        "subject": "Cannot log in",
        "body": "I keep getting an error when trying to access my account online.",
    }
    response = test_client.post("/triage", json=request_body)
    assert response.status_code == 200

    data = response.json()
    assert data["ticket_id"] == "technical-789"
    assert data["topic"] == "Technical / Online Access"
    assert data["urgency"] == "High"
    assert data["next_action"] == "forward_to_technical_support"
    assert data["confidence"] == 0.95
    assert data["short_note"] == "Fake technical issue detected"


def test_triage_processes_policy_ticket(test_client):
    """Test that POST /triage correctly processes a policy ticket."""
    request_body = {
        "ticket_id": "policy-999",
        "subject": "Coverage question",
        "body": "Does my policy cover flood damage?",
    }
    response = test_client.post("/triage", json=request_body)
    assert response.status_code == 200

    data = response.json()
    assert data["ticket_id"] == "policy-999"
    assert data["topic"] == "Policy / Contract"
    assert data["urgency"] == "Low"
    assert data["next_action"] == "send_standard_faq_or_self_service_link"
    assert data["short_note"] == "Fake policy question detected"


def test_triage_validates_required_fields(test_client):
    """Test that POST /triage validates required fields."""
    # Missing ticket_id
    response = test_client.post(
        "/triage",
        json={"subject": "Test", "body": "Test"},
    )
    assert response.status_code == 422

    # Missing subject
    response = test_client.post(
        "/triage",
        json={"ticket_id": "test-123", "body": "Test"},
    )
    assert response.status_code == 422

    # Missing body
    response = test_client.post(
        "/triage",
        json={"ticket_id": "test-123", "subject": "Test"},
    )
    assert response.status_code == 422


def test_triage_returns_503_when_agent_not_initialized(monkeypatch):
    """Test that POST /triage returns HTTP 503 when agent is not initialized."""
    from api import app as app_module
    from api.app import app

    # Patch global state to simulate uninitialized agent
    monkeypatch.setattr(app_module, "_agent", None)
    monkeypatch.setattr(app_module, "_agent_ready", False)

    client = TestClient(app)
    request_body = {
        "ticket_id": "test-123",
        "subject": "Test",
        "body": "Test",
    }
    response = client.post("/triage", json=request_body)
    assert response.status_code == 503
    assert "Agent not initialized" in response.json()["detail"]


def test_triage_includes_action_result(test_client):
    """Test that POST /triage includes action_result in response."""
    request_body = {
        "ticket_id": "test-123",
        "subject": "Test",
        "body": "Test",
    }
    response = test_client.post("/triage", json=request_body)
    assert response.status_code == 200

    data = response.json()
    assert data["action_result"] is not None
    assert data["action_result"]["selected_action"] == "send_standard_faq_or_self_service_link"
    assert data["action_result"]["action_status"] == "success"
    assert data["action_result"]["target"] == "fake_target"


def test_triage_response_structure(test_client):
    """Test that POST /triage response has all required fields."""
    request_body = {
        "ticket_id": "test-123",
        "subject": "Test",
        "body": "Test",
    }
    response = test_client.post("/triage", json=request_body)
    assert response.status_code == 200

    data = response.json()
    required_fields = [
        "ticket_id",
        "text_snippet",
        "topic",
        "urgency",
        "next_action",
        "confidence",
        "missing_info",
        "missing_fields",
        "requires_human_review",
        "short_note",
        "action_result",
    ]
    for field in required_fields:
        assert field in data, f"Missing required field: {field}"


# ─── Integration Tests ────────────────────────────────────────────────────────


def test_multiple_concurrent_requests(test_client):
    """Test that multiple requests can be processed sequentially."""
    requests = [
        {"ticket_id": f"test-{i}", "subject": f"Test {i}", "body": f"Body {i}"}
        for i in range(5)
    ]

    for req in requests:
        response = test_client.post("/triage", json=req)
        assert response.status_code == 200
        assert response.json()["ticket_id"] == req["ticket_id"]


def test_preprocessing_applied(test_client):
    """Test that preprocessing is applied to input text."""
    request_body = {
        "ticket_id": "test-html",
        "subject": "Test <b>HTML</b>",
        "body": "Body with   multiple   spaces and <script>tags</script>",
    }
    response = test_client.post("/triage", json=request_body)
    assert response.status_code == 200

    # Preprocessing should produce a text_snippet
    data = response.json()
    assert len(data["text_snippet"]) > 0
