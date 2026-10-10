"""
Production server entry point for the Ticket Triage API.

Usage:
    python -m api.server

Environment variables:
    CONFIG_PATH           — Path to config.yaml (default: config.yaml)
    OLLAMA_BASE_URL       — Ollama API base URL (default: http://localhost:11434)
    INFERENCE_CONCURRENCY — Max concurrent inference requests (default: 1)
    HOST                  — Server host (default: 0.0.0.0)
    PORT                  — Server port (default: 8000)

Example:
    OLLAMA_BASE_URL=http://192.168.1.100:11434 python -m api.server
"""

import os
import sys

if __name__ == "__main__":
    import uvicorn

    # Server configuration from environment
    host = os.environ.get("HOST", "0.0.0.0")
    port = int(os.environ.get("PORT", "8000"))
    reload = os.environ.get("RELOAD", "false").lower() == "true"

    print("=" * 80)
    print("Multilingual Ticket Triage API")
    print("=" * 80)
    print(f"Configuration:")
    print(f"  CONFIG_PATH:           {os.environ.get('CONFIG_PATH', 'config.yaml')}")
    print(f"  OLLAMA_BASE_URL:       {os.environ.get('OLLAMA_BASE_URL', 'http://localhost:11434')}")
    print(f"  INFERENCE_CONCURRENCY: {os.environ.get('INFERENCE_CONCURRENCY', '1')}")
    print(f"  HOST:                  {host}")
    print(f"  PORT:                  {port}")
    print(f"  RELOAD:                {reload}")
    print("=" * 80)
    print()
    print("Starting server...")
    print()

    uvicorn.run(
        "api.app:app",
        host=host,
        port=port,
        reload=reload,
        log_level="info",
    )
