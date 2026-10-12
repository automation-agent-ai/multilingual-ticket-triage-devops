# ──────────────────────────────────────────────────────────────────────────────
# Multilingual Ticket Triage API — Production Dockerfile
#
# Build:   docker build -t ticket-triage-api:latest .
# Run:     docker run -p 8000:8000 -e OLLAMA_BASE_URL=http://host.docker.internal:11434 \
#                     -v $(pwd)/data:/app/data:ro \
#                     -v hf-model-cache:/home/appuser/.cache/huggingface \
#                     ticket-triage-api:latest
#
# Notes:
#  - torch is installed from the PyTorch CPU wheel index (no CUDA) to keep the
#    image lean (~3 GB vs ~8 GB).  The embedding model runs on CPU in the
#    container.
#  - Data (DuckDB, LanceDB) and the HuggingFace model cache are always
#    provided via volumes at runtime.  The image itself contains no datasets,
#    databases, model weights, or secrets.
#  - The application runs as non-root user "appuser" (UID 1000).
# ──────────────────────────────────────────────────────────────────────────────

# ── Stage 1: dependency builder ───────────────────────────────────────────────
# A separate build stage keeps the final image free of build tools and
# pip caches.
FROM python:3.12-slim AS builder

# System build dependencies needed by some C extensions.
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# ── Layer 1: PyTorch CPU wheel (large; cached separately for faster rebuilds) ─
# torch 2.3.1+cpu → 2.10.0+cpu: fixes CVE-2025-32434 (CRITICAL) +
# GHSA-63cw-57p8-fm3p (HIGH — RCE via untrusted checkpoints, patched in 2.10.0)
# deserialization in torch.load()).  CPU-only wheel from the PyTorch index.
# Isolated in its own layer so a requirements update does not re-download PyTorch.
COPY requirements-docker.txt .
RUN pip install --no-cache-dir --upgrade pip \
 && pip install --no-cache-dir \
        "torch==2.10.0+cpu" \
        --index-url https://download.pytorch.org/whl/cpu

# ── Layer 2: remaining Python dependencies ────────────────────────────────────
# requirements-docker.txt now contains torch==2.10.0+cpu as an explicit pin,
# which prevents pip's resolver from upgrading torch to the latest CUDA release
# (triggered by sentence-transformers' torch>=1.11.0 constraint).
# The --extra-index-url is required so pip can locate the +cpu wheel; without
# it torch==2.10.0+cpu is not found on PyPI and the install fails.
RUN pip install --no-cache-dir \
        --extra-index-url https://download.pytorch.org/whl/cpu \
        -r requirements-docker.txt

# ── Stage 2: runtime image ────────────────────────────────────────────────────
FROM python:3.12-slim AS runtime

# Minimal system runtime dependencies.
RUN apt-get update && apt-get install -y --no-install-recommends \
        libgomp1 \
        curl \
    && rm -rf /var/lib/apt/lists/*

# Non-root user for production security.
# UID/GID 1000 matches the typical first user on Linux/WSL2 hosts, which
# simplifies bind-mount permissions for the HuggingFace model cache.
RUN groupadd --gid 1000 appgroup \
 && useradd  --uid 1000 --gid appgroup --shell /bin/bash --create-home appuser

WORKDIR /app

# Copy the entire site-packages tree from the builder stage.
COPY --from=builder /usr/local/lib/python3.12/site-packages \
                    /usr/local/lib/python3.12/site-packages
COPY --from=builder /usr/local/bin /usr/local/bin

# ── Application code ──────────────────────────────────────────────────────────
# Only the source packages required to run the API.
# Datasets, databases, model weights, secrets are never bundled.
COPY --chown=appuser:appgroup api/        ./api/
COPY --chown=appuser:appgroup src/        ./src/
COPY --chown=appuser:appgroup config.yaml ./config.yaml
COPY --chown=appuser:appgroup config-aws.yaml ./config-aws.yaml

# ── Runtime directories ───────────────────────────────────────────────────────
# data/    — DuckDB and LanceDB mount point (provided as volume at runtime).
# outputs/ — Writable directory for result files.
# HuggingFace cache inside appuser home so the non-root user can write to it.
RUN mkdir -p /app/data /app/outputs \
 && chown -R appuser:appgroup /app

# ── Remove pip and setuptools from the runtime image ─────────────────────────
# The runtime container never needs to install packages.  Removing these tools
# eliminates:
#   • setuptools CVE-2025-47273 (HIGH — path traversal in PackageIndex)
#   • msgpack GHSA-6v7p-g79w-8964 (HIGH — OOB read/crash in pip's vendored
#     msgpack, bundled inside pip/_vendor/msgpack)
# The pip executables and dist-info directories are also removed to prevent
# accidental re-introduction of the packages.
RUN find /usr/local/lib/python3.12/site-packages -maxdepth 1 \
        \( -name "pip*" -o -name "setuptools*" \) \
        -exec rm -rf {} + 2>/dev/null || true \
 && find /usr/local/bin -name "pip*" -delete 2>/dev/null || true

# ── Environment defaults ──────────────────────────────────────────────────────
# All of these are overridden at runtime via environment variables or compose
# files.  OLLAMA_BASE_URL is intentionally left at the container default;
# the compose files set host.docker.internal.
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    CONFIG_PATH=/app/config.yaml \
    OLLAMA_BASE_URL=http://localhost:11434 \
    INFERENCE_CONCURRENCY=1 \
    HOST=0.0.0.0 \
    PORT=8000 \
    HF_HOME=/home/appuser/.cache/huggingface \
    TRANSFORMERS_CACHE=/home/appuser/.cache/huggingface/hub

# ── Port ──────────────────────────────────────────────────────────────────────
EXPOSE 8000

# ── Switch to non-root ────────────────────────────────────────────────────────
USER appuser

# ── Health check ──────────────────────────────────────────────────────────────
# Short interval during development; PROD compose overrides these values.
HEALTHCHECK --interval=30s --timeout=10s --start-period=90s --retries=3 \
    CMD curl -f http://localhost:${PORT}/health || exit 1

# ── Startup command ───────────────────────────────────────────────────────────
# Invokes api/server.py which calls uvicorn with HOST/PORT from environment.
CMD ["python", "-m", "api.server"]
