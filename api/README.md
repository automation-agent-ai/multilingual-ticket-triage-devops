# Ticket Triage API

Minimal production-oriented FastAPI application for the multilingual Ticket Triage Agent.

## Architecture

The API exposes the existing `TicketTriageAgent` through HTTP endpoints without modifying the core agent implementation. All analyzer, validator, reviewer, router, and retrieval logic remains unchanged.

**Key design decisions:**
- Expensive dependencies (embedding model, LLM client, vector store) are initialized once at startup
- Inference concurrency is bounded by a semaphore to prevent resource exhaustion
- Unavailable inference backends return HTTP 503 without exposing internal exception details
- Preprocessing is applied consistently with the batch mode pipeline

## Endpoints

### `GET /health`
Liveness probe. Always returns HTTP 200 to indicate the server process is running.

**Response:**
```json
{
  "status": "ok"
}
```

### `GET /ready`
Readiness probe. Returns `ready=true` only if the agent initialized successfully at startup.

**Response:**
```json
{
  "ready": true,
  "agent_initialized": true
}
```

### `POST /triage`
Process one ticket through the full triage pipeline.

**Request:**
```json
{
  "ticket_id": "TKT-12345",
  "subject": "Cannot access my account",
  "body": "I keep getting an error when trying to log in to my account online."
}
```

**Response (HTTP 200):**
```json
{
  "ticket_id": "TKT-12345",
  "text_snippet": "Cannot access my account\n\nI keep getting an error when trying to log in to my account online.",
  "topic": "Technical / Online Access",
  "urgency": "High",
  "next_action": "forward_to_technical_support",
  "confidence": 0.92,
  "missing_info": false,
  "missing_fields": [],
  "requires_human_review": false,
  "short_note": "User unable to access account - login error",
  "action_result": {
    "selected_action": "forward_to_technical_support",
    "action_status": "success",
    "action_note": "Forwarded to technical support team",
    "target": "technical_support_queue"
  }
}
```

**Error Response (HTTP 503):**
```json
{
  "detail": "Inference backend unavailable. Please try again later."
}
```

## Configuration

Configuration is read from `config.yaml` by default. Override with environment variables:

| Variable | Description | Default |
|----------|-------------|---------|
| `CONFIG_PATH` | Path to config.yaml | `config.yaml` |
| `OLLAMA_BASE_URL` | Ollama API base URL | `http://localhost:11434` |
| `INFERENCE_CONCURRENCY` | Max concurrent inference requests | `1` |
| `HOST` | Server host | `0.0.0.0` |
| `PORT` | Server port | `8000` |
| `RELOAD` | Enable auto-reload for development | `false` |

## Installation

1. Activate the virtual environment:
   ```bash
   source .venv/bin/activate  # Linux/macOS
   # or
   .venv\Scripts\activate     # Windows
   ```

2. Install dependencies (if not already installed):
   ```bash
   pip install -r requirements.txt
   ```

## Usage

### Starting the server

**Production mode:**
```bash
python -m api.server
```

**With custom configuration:**
```bash
CONFIG_PATH=config.yaml \
OLLAMA_BASE_URL=http://192.168.1.100:11434 \
INFERENCE_CONCURRENCY=2 \
python -m api.server
```

**Development mode with auto-reload:**
```bash
RELOAD=true python -m api.server
```

**Alternative: Direct uvicorn invocation:**
```bash
uvicorn api.app:app --host 0.0.0.0 --port 8000
```

### Testing the API

**Run unit tests:**
```bash
pytest tests/test_api.py -v
```

**Manual testing with curl:**
```bash
# Health check
curl http://localhost:8000/health

# Readiness check
curl http://localhost:8000/ready

# Triage a ticket
curl -X POST http://localhost:8000/triage \
  -H "Content-Type: application/json" \
  -d '{
    "ticket_id": "TKT-001",
    "subject": "Cannot access my account",
    "body": "I keep getting an error when trying to log in."
  }'
```

**Interactive API documentation:**

Once the server is running, visit:
- Swagger UI: http://localhost:8000/docs
- ReDoc: http://localhost:8000/redoc

## Prerequisites

Before starting the API, ensure:

1. **LanceDB index exists**: The vector store must be built first. If `data/lancedb/` does not exist, run:
   ```bash
   # Set rebuild_lancedb: true in config.yaml, then:
   python main.py
   ```

2. **Ollama is running**: Start the Ollama service with the required model:
   ```bash
   ollama serve
   # In another terminal:
   ollama pull llama3.2:3b  # or your configured model
   ```

3. **Configuration is valid**: Verify `config.yaml` paths and model names are correct.

## Deployment

### Docker (recommended)

Create a `Dockerfile`:
```dockerfile
FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

ENV CONFIG_PATH=config.yaml
ENV OLLAMA_BASE_URL=http://ollama:11434
ENV INFERENCE_CONCURRENCY=1
ENV HOST=0.0.0.0
ENV PORT=8000

CMD ["python", "-m", "api.server"]
```

Build and run:
```bash
docker build -t ticket-triage-api .
docker run -p 8000:8000 \
  -e OLLAMA_BASE_URL=http://host.docker.internal:11434 \
  ticket-triage-api
```

### Kubernetes

Example deployment manifest:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ticket-triage-api
spec:
  replicas: 2
  selector:
    matchLabels:
      app: ticket-triage-api
  template:
    metadata:
      labels:
        app: ticket-triage-api
    spec:
      containers:
      - name: api
        image: ticket-triage-api:latest
        ports:
        - containerPort: 8000
        env:
        - name: OLLAMA_BASE_URL
          value: "http://ollama-service:11434"
        - name: INFERENCE_CONCURRENCY
          value: "1"
        livenessProbe:
          httpGet:
            path: /health
            port: 8000
          initialDelaySeconds: 10
          periodSeconds: 30
        readinessProbe:
          httpGet:
            path: /ready
            port: 8000
          initialDelaySeconds: 30
          periodSeconds: 10
```

## Concurrency and Performance

- **Inference concurrency** is limited to 1 by default to ensure predictable behavior on single-GPU environments
- Increase `INFERENCE_CONCURRENCY` if you have sufficient GPU memory and want to handle multiple concurrent requests
- The embedding model and vector store are thread-safe and reused across all requests
- Consider deploying multiple API replicas behind a load balancer for higher throughput

## Troubleshooting

**API returns 503 on all /triage requests:**
- Check `/ready` endpoint to see if agent initialized successfully
- Verify Ollama is running: `curl http://localhost:11434/api/tags`
- Check server logs for initialization errors
- Ensure LanceDB index exists in `data/lancedb/`

**Tests fail with import errors:**
- Install test dependencies: `pip install httpx2 pytest`
- Verify virtual environment is activated

**Agent initialization is slow:**
- The embedding model loads at startup and can take 30-60 seconds on CPU
- Consider using a smaller model or GPU acceleration for faster startup
- Startup time is acceptable in production as it happens once per deployment

## Development

### Adding new endpoints

1. Define request/response models in `api/app.py`
2. Add endpoint handler with `@app.get()` or `@app.post()` decorator
3. Add tests in `tests/test_api.py`

### Running tests in watch mode

```bash
pytest tests/test_api.py -v --tb=short -x
```

### Code quality

```bash
# Format code
black api/ tests/test_api.py

# Type checking
mypy api/

# Linting
ruff check api/
```

## License

Same as the parent project.
