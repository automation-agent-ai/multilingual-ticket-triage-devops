"""
FastAPI application for the multilingual Ticket Triage Agent.

Provides three endpoints:
  - GET /health  — liveness probe (always returns 200)
  - GET /ready   — readiness probe (checks if agent is initialized)
  - POST /triage — process one ticket and return structured triage result

Initialization:
  Agent dependencies (embedding model, LLM client, vector store) are loaded
  once at application startup, not for every request.

Concurrency:
  Inference is bounded by a semaphore to prevent resource exhaustion. The
  initial concurrency limit is 1 to ensure predictable behavior on single-GPU
  or constrained environments.

Error handling:
  Unavailable inference backends (Ollama connection errors, timeouts) are
  caught and return HTTP 503 without exposing internal exception details.
"""

import asyncio
import contextlib
import logging
import os
import time
import traceback
from typing import Any

import yaml
from fastapi import FastAPI, HTTPException, Request, status
from fastapi.responses import JSONResponse, PlainTextResponse
from pydantic import BaseModel, Field

from api.prom_metrics import (
    AGENT_READY,
    CONTENT_TYPE_LATEST,
    TRIAGE_DURATION_SECONDS,
    TRIAGE_FAILURES_TOTAL,
    TRIAGE_REQUESTS_TOTAL,
    PrometheusMiddleware,
    generate_latest,
)

from src.application.agent import TicketTriageAgent
from src.application.preprocessing import (
    build_raw_text,
    build_representation_text,
    make_text_snippet,
    normalize_text,
)
from src.domain.models import TicketInput, TriageResult

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
)
logger = logging.getLogger(__name__)

# Global application state
_agent: TicketTriageAgent | None = None
_agent_ready: bool = False
_inference_semaphore: asyncio.Semaphore | None = None

# Configuration
CONFIG_PATH = os.environ.get("CONFIG_PATH", "config.yaml")
OLLAMA_BASE_URL = os.environ.get("OLLAMA_BASE_URL", "http://localhost:11434")
INFERENCE_CONCURRENCY = int(os.environ.get("INFERENCE_CONCURRENCY", "1"))


# ─── Request/Response Models ──────────────────────────────────────────────────


class TicketTriageRequest(BaseModel):
    """
    HTTP request body for POST /triage.

    Only subject and body are required as inference input. All derived text
    fields are computed during preprocessing.
    """

    ticket_id: str = Field(..., description="Unique ticket identifier")
    subject: str = Field(..., description="Ticket subject line")
    body: str = Field(..., description="Ticket body or description")


class TicketTriageResponse(BaseModel):
    """
    HTTP response body for POST /triage.

    Returns the complete TriageResult with topic, urgency, next_action,
    confidence, flags, and action execution result.
    """

    ticket_id: str
    text_snippet: str
    topic: str
    urgency: str
    next_action: str
    confidence: float
    missing_info: bool
    missing_fields: list[str]
    requires_human_review: bool
    short_note: str
    action_result: dict[str, Any] | None = None


class HealthResponse(BaseModel):
    """Health check response."""

    status: str = "ok"


class ReadinessResponse(BaseModel):
    """Readiness check response."""

    ready: bool
    agent_initialized: bool


# ─── FastAPI Application ──────────────────────────────────────────────────────

app = FastAPI(
    title="Multilingual Ticket Triage API",
    description="Production-oriented FastAPI application for the Ticket Triage Agent",
    version="1.0.0",
)

# Register Prometheus ASGI middleware — must be added after app creation.
# /metrics requests are explicitly excluded from all HTTP counters.
app.add_middleware(PrometheusMiddleware)


# ─── Lifecycle Management ─────────────────────────────────────────────────────


@app.on_event("startup")
async def startup_event() -> None:
    """
    Initialize agent dependencies at application startup.

    This runs once when the server starts, not for every request. If
    initialization fails, the server will start but /ready will return
    ready=false and /triage will return HTTP 503.
    """
    global _agent, _agent_ready, _inference_semaphore

    logger.info("Starting Ticket Triage API...")
    logger.info(f"Config path: {CONFIG_PATH}")
    logger.info(f"Ollama base URL: {OLLAMA_BASE_URL}")
    logger.info(f"Inference concurrency: {INFERENCE_CONCURRENCY}")

    # Initialize inference semaphore for bounded concurrency
    _inference_semaphore = asyncio.Semaphore(INFERENCE_CONCURRENCY)

    # Attempt to initialize the agent
    try:
        _agent = _initialize_agent()
        _agent_ready = True
        AGENT_READY.set(1)
        logger.info("Agent initialized successfully")
    except Exception as exc:
        logger.error(f"Failed to initialize agent: {exc}")
        logger.error(traceback.format_exc())
        _agent_ready = False
        AGENT_READY.set(0)


@app.on_event("shutdown")
async def shutdown_event() -> None:
    """Clean up resources at application shutdown."""
    logger.info("Shutting down Ticket Triage API...")


# ─── Dependency Injection ─────────────────────────────────────────────────────


def get_agent() -> TicketTriageAgent:
    """
    Retrieve the initialized agent or raise HTTP 503 if unavailable.

    This dependency is injected into /triage to ensure the agent is ready
    before processing requests.
    """
    if not _agent_ready or _agent is None:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Agent not initialized. Check server logs and readiness endpoint.",
        )
    return _agent


# ─── Agent Initialization ─────────────────────────────────────────────────────


def _initialize_agent() -> TicketTriageAgent:
    """
    Build the TicketTriageAgent from config.yaml.

    This function is called once at application startup. It loads the
    embedding model, LLM client, vector store, and all pipeline components,
    then constructs and returns the agent.

    Raises:
        Exception: If any dependency fails to load (config, model, vector store, etc.)
    """
    from src.application.action_executor import ActionExecutor
    from src.application.analyzer import LocalLLMAnalyzer
    from src.application.neighbor_retriever import NeighborRetriever
    from src.application.reviewer import ConditionalLLMReviewer
    from src.application.router import TriageRouter
    from src.application.validator import TriageValidator
    from src.infrastructure.embedding_model import EmbeddingModel
    from src.infrastructure.lancedb_ticket_store import LanceDBTicketStore
    from src.infrastructure.llm_client import OllamaClient

    logger.info(f"Loading configuration from {CONFIG_PATH}")
    with open(CONFIG_PATH, "r", encoding="utf-8") as f:
        cfg = yaml.safe_load(f)

    # Override Ollama base URL from environment variable if set
    llm_cfg = cfg["llm"]
    if OLLAMA_BASE_URL != "http://localhost:11434":
        llm_cfg["base_url"] = OLLAMA_BASE_URL
        logger.info(f"Overriding LLM base_url to {OLLAMA_BASE_URL}")

    vs_cfg = cfg["vector_store"]
    ret_cfg = cfg["retrieval"]
    thresholds = cfg.get("thresholds", {})
    emb_cfg = cfg["embedding"]

    # Load embedding model
    logger.info(f"Loading embedding model: {emb_cfg['model_name']}")
    embedding_model = EmbeddingModel(
        model_name=emb_cfg["model_name"],
        device=emb_cfg.get("device", "auto"),
        normalize_embeddings=emb_cfg.get("normalize_embeddings", True),
    )
    logger.info(f"  device        : {embedding_model.device}")
    logger.info(f"  embedding dim : {embedding_model.get_dimension()}")

    # Initialize LLM client
    logger.info(f"Initializing LLM client: {llm_cfg['model_name']}")
    llm_client = OllamaClient(
        base_url=llm_cfg["base_url"],
        model_name=llm_cfg["model_name"],
        temperature=llm_cfg.get("temperature", 0.1),
        timeout_seconds=llm_cfg.get("timeout_seconds", 120),
    )

    # Initialize vector store
    logger.info(f"Connecting to LanceDB: {vs_cfg['path']}/{vs_cfg['table_name']}")
    store = LanceDBTicketStore(path=vs_cfg["path"], table_name=vs_cfg["table_name"])
    logger.info(f"  table count: {store.count()}")

    # Build pipeline components
    retriever = NeighborRetriever(
        embedding_model=embedding_model,
        ticket_store=store,
        top_k=ret_cfg.get("top_k", 5),
    )

    analyzer = LocalLLMAnalyzer(
        llm_client=llm_client,
        max_retries=llm_cfg.get("max_retries", 1),
        debug=False,
    )

    validator = TriageValidator(
        min_llm_confidence=thresholds.get("low_confidence", 0.60),
        min_neighbor_confidence=0.50,
        high_confidence_threshold=0.80,
    )

    router = TriageRouter()
    executor = ActionExecutor()

    # Build optional reviewer
    reviewer = None
    reviewer_cfg = cfg.get("reviewer", {})
    if reviewer_cfg.get("enabled", False):
        logger.info(f"Initializing reviewer: {reviewer_cfg['model_name']}")
        reviewer_client = OllamaClient(
            base_url=reviewer_cfg.get("base_url", llm_cfg["base_url"]),
            model_name=reviewer_cfg["model_name"],
            temperature=reviewer_cfg.get("temperature", 0.1),
            timeout_seconds=llm_cfg.get("timeout_seconds", 120),
        )
        reviewer = ConditionalLLMReviewer(
            llm_client=reviewer_client,
            trigger_flags=reviewer_cfg.get("trigger_flags", []),
            max_retries=reviewer_cfg.get("max_retries", 1),
            model_name=reviewer_cfg["model_name"],
            disagreement_confidence_ceiling=reviewer_cfg.get(
                "disagreement_confidence_ceiling", 0.85
            ),
            urgency_disagreement_confidence_ceiling=reviewer_cfg.get(
                "urgency_disagreement_confidence_ceiling", 0.90
            ),
        )

    # Construct and return agent
    agent = TicketTriageAgent(
        neighbor_retriever=retriever,
        analyzer=analyzer,
        validator=validator,
        router=router,
        action_executor=executor,
        reviewer=reviewer,
    )

    logger.info("Agent construction complete")
    return agent


# ─── Preprocessing Helpers ────────────────────────────────────────────────────


def _build_ticket_input(req: TicketTriageRequest) -> TicketInput:
    """
    Convert HTTP request to TicketInput with all derived text fields.

    Applies the same preprocessing pipeline used in main.py to ensure
    consistency between batch and API modes.
    """
    raw_text = build_raw_text(req.subject, req.body)
    cleaned_text = normalize_text(raw_text)
    representation_text = build_representation_text(req.subject, req.body)
    text_snippet = make_text_snippet(raw_text)

    return TicketInput(
        ticket_id=req.ticket_id,
        subject=req.subject,
        body=req.body,
        raw_text=raw_text,
        cleaned_text=cleaned_text,
        representation_text=representation_text,
        text_snippet=text_snippet,
    )


def _triage_result_to_response(result: TriageResult) -> TicketTriageResponse:
    """
    Convert TriageResult to HTTP response body.

    Extracts enum values as strings and serializes action_result to dict.
    """
    action_result_dict = None
    if result.action_result is not None:
        action_result_dict = {
            "selected_action": result.action_result.selected_action.value,
            "action_status": result.action_result.action_status,
            "action_note": result.action_result.action_note,
            "target": result.action_result.target,
        }

    return TicketTriageResponse(
        ticket_id=result.ticket_id,
        text_snippet=result.text_snippet,
        topic=result.topic.value,
        urgency=result.urgency.value,
        next_action=result.next_action.value,
        confidence=result.confidence,
        missing_info=result.missing_info,
        missing_fields=result.missing_fields,
        requires_human_review=result.requires_human_review,
        short_note=result.short_note,
        action_result=action_result_dict,
    )


# ─── HTTP Endpoints ───────────────────────────────────────────────────────────


@app.get(
    "/metrics",
    tags=["Monitoring"],
    include_in_schema=True,
    summary="Prometheus metrics",
    response_class=PlainTextResponse,
)
async def metrics() -> PlainTextResponse:
    """
    Expose Prometheus metrics in the text/plain exposition format.

    Scraped by Prometheus every 30 s. This request is excluded from the HTTP
    request counter so it does not skew throughput or latency statistics.
    """
    return PlainTextResponse(generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.get("/health", response_model=HealthResponse, tags=["Health"])
async def health() -> HealthResponse:
    """
    Liveness probe.

    Always returns HTTP 200 to indicate the server process is running.
    Does not check agent readiness or external dependencies.
    """
    return HealthResponse(status="ok")


@app.get("/ready", response_model=ReadinessResponse, tags=["Health"])
async def ready() -> ReadinessResponse:
    """
    Readiness probe.

    Returns ready=true only if the agent initialized successfully at startup.
    Use this endpoint for Kubernetes readiness checks or load balancer health.
    """
    return ReadinessResponse(ready=_agent_ready, agent_initialized=_agent_ready)


@app.post(
    "/triage",
    response_model=TicketTriageResponse,
    status_code=status.HTTP_200_OK,
    tags=["Triage"],
)
async def triage(req: TicketTriageRequest) -> TicketTriageResponse:
    """
    Process one ticket through the full triage pipeline.

    Applies preprocessing, retrieves neighbors, calls the LLM analyzer,
    validates the output, routes to a next action, and executes the action.

    Concurrency is bounded by INFERENCE_CONCURRENCY to prevent resource
    exhaustion. If the inference backend is unavailable, returns HTTP 503.

    Args:
        req: Ticket input with ticket_id, subject, and body.

    Returns:
        Structured triage result with topic, urgency, next_action, confidence,
        flags, and action execution details.

    Raises:
        HTTPException: 503 if agent not initialized or inference backend unavailable.
    """
    agent = get_agent()

    # Enforce bounded concurrency
    if _inference_semaphore is None:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Inference semaphore not initialized",
        )

    async with _inference_semaphore:
        TRIAGE_REQUESTS_TOTAL.inc()
        triage_start = time.perf_counter()
        try:
            # Build TicketInput with preprocessing
            ticket_input = _build_ticket_input(req)

            # Run agent in thread pool to avoid blocking event loop
            loop = asyncio.get_event_loop()
            result = await loop.run_in_executor(
                None, agent.process_ticket, ticket_input
            )

            # Convert to HTTP response
            return _triage_result_to_response(result)

        except Exception as exc:
            # Log full traceback internally but return generic error to client
            logger.error(f"Triage failed for ticket {req.ticket_id}: {exc}")
            logger.error(traceback.format_exc())

            TRIAGE_FAILURES_TOTAL.inc()

            # Return 503 for inference backend errors (Ollama connection, timeout)
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="Inference backend unavailable. Please try again later.",
            )
        finally:
            TRIAGE_DURATION_SECONDS.observe(time.perf_counter() - triage_start)


# ─── Exception Handlers ───────────────────────────────────────────────────────


@app.exception_handler(HTTPException)
async def http_exception_handler(request: Request, exc: HTTPException) -> JSONResponse:
    """Handle HTTPException with consistent JSON response."""
    return JSONResponse(
        status_code=exc.status_code,
        content={"detail": exc.detail},
    )


@app.exception_handler(Exception)
async def generic_exception_handler(request: Request, exc: Exception) -> JSONResponse:
    """
    Handle unexpected exceptions without exposing internal details.

    Logs full traceback internally but returns generic error to client.
    """
    logger.error(f"Unhandled exception: {exc}")
    logger.error(traceback.format_exc())
    return JSONResponse(
        status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
        content={"detail": "Internal server error. Please contact support."},
    )
