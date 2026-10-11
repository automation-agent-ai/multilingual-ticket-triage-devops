"""
Prometheus instrumentation for the Ticket Triage FastAPI application.

Exposes lightweight HTTP and triage-specific metrics.

Safety rules enforced here:
- /metrics requests are NEVER counted as application requests.
- Labels use only low-cardinality, safe values (method, route template, status code).
- No ticket IDs, customer names, email addresses, or user-supplied strings appear
  in any label.
- AI classification logic is not modified.
"""

import time

from prometheus_client import (
    CONTENT_TYPE_LATEST,
    Counter,
    Gauge,
    Histogram,
    generate_latest,
)
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request

# Re-export for use in app.py without re-importing prometheus_client there.
__all__ = [
    "PrometheusMiddleware",
    "AGENT_READY",
    "TRIAGE_REQUESTS_TOTAL",
    "TRIAGE_FAILURES_TOTAL",
    "TRIAGE_DURATION_SECONDS",
    "generate_latest",
    "CONTENT_TYPE_LATEST",
]

# ── HTTP metrics ───────────────────────────────────────────────────────────────

HTTP_REQUESTS_TOTAL = Counter(
    "http_requests_total",
    "Total HTTP requests counted by method, route template and response status.",
    ["method", "route", "status_code"],
)

HTTP_REQUEST_DURATION_SECONDS = Histogram(
    "http_request_duration_seconds",
    "HTTP request duration in seconds by method and route template.",
    ["method", "route"],
    buckets=[0.01, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0, 30.0],
)

# ── Triage-specific metrics ────────────────────────────────────────────────────

TRIAGE_REQUESTS_TOTAL = Counter(
    "triage_requests_total",
    "Total ticket triage requests received.",
)

TRIAGE_FAILURES_TOTAL = Counter(
    "triage_failures_total",
    "Total ticket triage requests that resulted in a 5xx error.",
)

TRIAGE_DURATION_SECONDS = Histogram(
    "triage_duration_seconds",
    "Ticket triage end-to-end processing duration in seconds (includes LLM call).",
    buckets=[0.5, 1.0, 2.0, 5.0, 10.0, 30.0, 60.0, 120.0],
)

# ── Readiness gauge ────────────────────────────────────────────────────────────

AGENT_READY = Gauge(
    "agent_ready",
    "1 if the triage agent is initialized and ready to serve, 0 otherwise.",
)


# ── ASGI Middleware ────────────────────────────────────────────────────────────


class PrometheusMiddleware(BaseHTTPMiddleware):
    """
    ASGI middleware that records HTTP metrics for every request.

    Paths in EXCLUDED_PATHS are passed through without recording metrics so
    that Prometheus scrapes do not inflate the request count or latency
    histograms.
    """

    EXCLUDED_PATHS: frozenset[str] = frozenset({"/metrics"})

    async def dispatch(self, request: Request, call_next):  # type: ignore[override]
        path: str = request.url.path

        if path in self.EXCLUDED_PATHS:
            return await call_next(request)

        method: str = request.method
        start: float = time.perf_counter()

        response = await call_next(request)

        duration: float = time.perf_counter() - start

        # Resolve the FastAPI route template (e.g. "/triage") after routing has
        # occurred so we never record raw, user-supplied URL segments as labels.
        scope_route = request.scope.get("route")
        route: str = (
            getattr(scope_route, "path", path) if scope_route is not None else path
        )

        status_code: str = str(response.status_code)

        HTTP_REQUESTS_TOTAL.labels(
            method=method, route=route, status_code=status_code
        ).inc()
        HTTP_REQUEST_DURATION_SECONDS.labels(method=method, route=route).observe(
            duration
        )

        return response
