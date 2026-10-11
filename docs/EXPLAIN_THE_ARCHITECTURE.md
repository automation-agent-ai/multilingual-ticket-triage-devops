# Explain the Architecture — Oral Examination Guide

**Project:** Liora — Multilingual Ticket Triage DevOps  
**Date:** 2026-10-11

This document gives technically correct, concise explanations of every major component:
what it does, why it exists, and how it interacts with everything else.

---

## 1. The Application — FastAPI Ticket Triage Agent

### What it does
The application takes a customer-support ticket (a subject line and a body text) and automatically classifies it into a **topic** (one of five insurance categories), an **urgency level** (Low / Medium / High), and a **next action** (one of six fixed actions). The output is a structured JSON response.

### Why it exists
Manual triage of high-volume multilingual support tickets is slow and inconsistent. An automated agent can pre-classify tickets in under 5 seconds per ticket, freeing human agents to focus on complex or high-urgency cases.

### How it works (step by step)
1. **Preprocessing**: the subject and body are normalised and combined into a representation text.
2. **Embedding**: `intfloat/multilingual-e5-large` converts the text into a 1024-dimensional vector. This model supports 100+ languages, so a French or German ticket is handled the same as an English one.
3. **Retrieval**: the vector is used to search LanceDB — a local vector database — for the 5 most similar historical tickets (cosine similarity). These are called "neighbors".
4. **Weighted vote**: the neighbors' labels are aggregated by a weighted vote to predict the most likely queue and priority.
5. **LLM analysis**: the ticket text, the assignment ontology, and the neighbor context are sent to `llama3.2:3b` via Ollama. The LLM returns a structured JSON response (topic, urgency, confidence, missing info, short note), which is validated against a strict Pydantic schema.
6. **Validation**: a deterministic Python validator checks confidence thresholds, missing-information flags, and whether the LLM and kNN predictions agree. This step uses no LLM — it is pure rule-based Python.
7. **Optional reviewer**: if the validator raises trigger flags (e.g. low confidence or disagreement), an optional second LLM (`granite4.1:8b`) reviews the first analysis and may revise it. This is disabled by default.
8. **Routing**: a deterministic router maps the validator result to a final `next_action` using explicit Python business rules. The LLM never decides the final action.
9. **Action executor**: a simulated executor records what *would* happen (e.g. "forward to billing team"). No real external system is called.
10. **Response**: the full structured result is returned to the caller and optionally persisted to DuckDB and JSONL.

### Why the design is split this way
The LLM handles open-ended reasoning (what is this ticket about?). The validator and router are deterministic Python — so the system is auditable: you can always explain exactly why a ticket was routed a specific way, without relying on a black-box model.

---

## 2. Docker — Containerisation

### What it does
Docker packages the FastAPI application and all its Python dependencies into a reproducible, portable container image.

### Why it exists
Without Docker, the application only runs on a machine with the exact Python environment configured. With Docker, the image is identical on every machine and in every deployment environment.

### How it works
The `Dockerfile` uses a **multi-stage build**:
- **Builder stage**: installs Python dependencies into a separate layer (keeps the final image smaller by excluding build tools).
- **Runtime stage**: copies only the installed packages and application code; removes `pip` and `setuptools` so the running container cannot install new packages.
- The container runs as `appuser` (UID 1000), not root — this limits the blast radius if the container is compromised.
- `.dockerignore` prevents secrets, dataset files, and model weights from ever entering the build context.

---

## 3. Kubernetes — Local DEV and PROD

### What it does
Kubernetes orchestrates the running containers — it starts them, restarts them if they crash, routes traffic to healthy pods, and provides health probes.

### Why it exists
In production, you need more than `docker run`. Kubernetes gives you automatic restarts, rolling deployments, rollback capability, namespace isolation, and a declarative configuration that can be version-controlled.

### How it is structured
The project uses **Kustomize** to manage overlays. There is a `base` directory with the shared Deployment and Service, and separate `overlays/dev` and `overlays/prod` directories that patch environment-specific values (image tag, namespace, ConfigMap).

**DEV** (`triage-dev` namespace): runs `ticket-triage-api:s07-metrics` — a locally built image that includes the Prometheus `/metrics` endpoint.  
**PROD** (`triage-prod` namespace): runs `ticket-triage-api:latest` — an older locally built image that does not include `/metrics`.

Three health probes are configured:
- **Startup probe** (on `/health`): allows up to 5 minutes for the embedding model to load.
- **Liveness probe** (on `/health`): restarts the pod if the server process becomes unresponsive.
- **Readiness probe** (on `/ready`): prevents traffic from reaching the pod until the AI agent (embedding model + LanceDB + LLM client) has fully initialised.

The application data (DuckDB + LanceDB) is mounted as a **read-only `hostPath` volume** so the container cannot overwrite production data.

---

## 4. GitHub Actions — CI/CD Pipeline

### What it does
GitHub Actions automatically runs tests, builds the Docker image, scans it for vulnerabilities, and publishes it to the container registry whenever code is pushed to `main`.

### Why it exists
Manual testing and deployment is error-prone and slow. CI enforces that no broken code reaches the registry and that every published image has passed a security scan.

### How it works (three jobs)
1. **test**: installs CPU-only PyTorch and project dependencies, then runs `pytest tests/ -m "not slow"` — 744 tests in ~25 seconds. If any test fails, the pipeline stops.
2. **build-scan-push** (depends on `test`):
   - Builds the Docker image locally.
   - **Trivy diagnostic scan** (non-blocking): lists all found CVEs in the Actions log.
   - **Trivy blocking scan** (`exit-code: 1`): fails the pipeline if any CRITICAL or HIGH vulnerability with an available fix is found. The `ignore-unfixed: true` setting skips OS-layer CVEs for which no patch exists yet.
   - **GHCR push**: only if Trivy passed, only on push to `main`. Tagged `sha-<40-char-sha>` (immutable) and `latest`.

3. **deploy-dev / deploy-prod** (separate workflow files):
   - Render the Kubernetes manifests with `kubectl kustomize` (validates YAML).
   - `kubectl apply` is **disabled** (`if: false`) because GitHub-hosted runners run on Azure and have no network route to the local kind cluster.

### The 54 unfixed OS CVEs
The Trivy diagnostic scan finds 54 HIGH-severity CVEs in the `python:3.12-slim` base image for which Debian has not yet released a fix. The blocking gate uses `ignore-unfixed: true`, so these do not block CI. They are a documented residual risk. A weekly rebuild schedule would inherit fixes as Debian releases them.

---

## 5. Terraform — Infrastructure as Code

### What it does
Terraform provisions the five Kubernetes resources that the monitoring stack needs: the `triage-monitoring` namespace, two PersistentVolumeClaims (one for Prometheus data, one for Grafana data), and two ServiceAccounts (one for Prometheus, one for Grafana).

### Why it exists
These resources are *infrastructure* — they are long-lived and shared across sprints. Managing them with Terraform (rather than plain `kubectl apply`) means their state is tracked, changes are previewed with `terraform plan`, and they can be safely destroyed and recreated.

### How it works
Terraform uses the **Kubernetes provider** to create resources in the cluster. The state is recorded in `terraform.tfstate` (local file, excluded from Git). After the initial `terraform apply` (which created 5 resources), subsequent `terraform plan` commands return `No changes. Your infrastructure matches the configuration.`

The PVCs use the `rancher.io/local-path` StorageClass which has `volumeBindingMode: WaitForFirstConsumer` — the PVCs stay `Pending` until a Pod mounts them. This is expected and correct.

### What Terraform does NOT manage
Terraform does not manage the application deployments (`triage-dev`, `triage-prod`) or any of the Prometheus/Grafana ConfigMaps and Deployments — those are managed by Kustomize (`monitoring/`).

---

## 6. Prometheus + Grafana — Monitoring

### What Prometheus does
Prometheus is a time-series database and scraper. Every 30 seconds it sends an HTTP GET to `/metrics` on the DEV API pod and stores the returned metrics. It also evaluates alert rules.

### What Grafana does
Grafana reads from Prometheus and displays the data as visual dashboards. The "Ticket Triage — Overview" dashboard has 8 panels including availability status, request counts, error rates, latency percentiles (p50/p95/p99), and triage pipeline duration.

### Why they exist
Without monitoring you cannot tell whether the service is healthy, how many tickets are being processed, or whether error rates are rising. Prometheus provides the data; Grafana makes it visible.

### How the metrics reach Prometheus
The FastAPI app exposes six application metrics at `/metrics`:
- `http_requests_total` (counter, per route + status code)
- `http_request_duration_seconds` (histogram)
- `triage_requests_total` (counter)
- `triage_failures_total` (counter)
- `triage_duration_seconds` (histogram)
- `agent_ready` (gauge: 1 = agent initialised, 0 = startup failed)

Prometheus scrapes this endpoint using a `scrape_config` in `monitoring/prometheus/configmap.yaml`.

### The three alert rules
1. `TicketTriageDevDown` — fires if the DEV scrape target has been down for 2 minutes (severity: critical).
2. `TicketTriageHighErrorRate` — fires if more than 10% of requests return 5xx for 2 minutes (severity: warning).
3. `TicketTriageFailuresDetected` — fires if the `triage_failures_total` rate is above zero for 2 minutes (severity: warning).

All three are currently `inactive` because the system is healthy. There is no Alertmanager configured — alerts are visible in the Prometheus UI only.

### Important limitations
- **PROD is not monitored**: the PROD image (`ticket-triage-api:latest`) was built before the `/metrics` endpoint was added. Updating PROD requires replacing the image and uncommenting the PROD scrape block.
- **`s07-metrics` image is local only**: it was built locally and not published to GHCR.
- **Prometheus flag**: the deployment uses `--web.enable-lifecycle` which enables `POST /-/reload` and `POST /-/quit`. The snapshot API (`POST /api/v1/admin/tsdb/snapshot`) requires a separate `--web.enable-admin-api` flag, which is not currently enabled. This means live TSDB snapshots are not available.

---

## 7. Security — Five Verified Controls

### Control 1 — Non-root execution
Every container (FastAPI, Prometheus, Grafana) runs as a non-root user. The FastAPI container runs as `appuser` (UID 1000). Kubernetes enforces this with `runAsNonRoot: true` at the pod level. If an attacker exploits a vulnerability in the application, they are confined to the permissions of a non-root user inside the container.

### Control 2 — Trivy vulnerability scanning
Trivy scans the Docker image on every CI build. Any CRITICAL or HIGH vulnerability with an available fix causes the build to fail and the image is not pushed to GHCR. Results are uploaded to GitHub Security as SARIF. Eight CVEs were remediated before this gate was introduced.

### Control 3 — Secrets never in Git or image
`.gitignore` excludes `.env`, `*.tfstate`, `kaggle.json` and credential files. `.dockerignore` excludes the same. This has been verified: `git log --all -- '*.env' '*.tfstate'` returns empty.

### Control 4 — Namespace isolation + dedicated ServiceAccounts
The three namespaces (`triage-dev`, `triage-prod`, `triage-monitoring`) provide workload isolation. Prometheus and Grafana use dedicated ServiceAccounts provisioned by Terraform; the application pods use the `default` ServiceAccount with no additional permissions bound to it.

### Control 5 — CI minimum permissions + PROD approval gate
The CI workflow defaults to `contents: read`. GHCR push requires `packages: write` and is conditioned on push-to-main + Trivy pass. The PROD deploy workflow is manual-only, requires the exact input string `DEPLOY`, and is gated by a GitHub Environment approval (a required reviewer must approve in the GitHub UI before the workflow proceeds).

### Residual risks (documented, not fixed)
- 54 unfixed HIGH OS CVEs in the base image (no upstream patch available)
- No Kubernetes NetworkPolicy (pods not network-isolated from each other)
- `readOnlyRootFilesystem: false` (Python writes `__pycache__` — a known trade-off)
- Grafana credentials stored in unencrypted etcd (acceptable for local kind cluster)

---

## 8. Disaster Recovery

### What it does
The DR system creates timestamped backups of all critical application state and can verify and restore them in isolation.

### What is backed up
- **DuckDB**: opened read-only, all 5 tables exported to Parquet (schema-portable) plus the raw `.duckdb` file. Row counts: 4,000 tickets, 4,676 predictions, 59 runs.
- **LanceDB**: full directory copy of the vector store (3,206 embeddings, ~82 MB).
- **Kubernetes manifests**: version-controlled `k8s/` tree plus live running deployment YAMLs.
- **Terraform state**: `terraform.tfstate` (excluded from Git but included in DR backup).
- **SHA-256 manifest**: every file's checksum is recorded in `MANIFEST.sha256` for integrity verification.

Total backup size: 118 MB, 42 files. Backup runtime: < 10 seconds.

### What is NOT backed up (documented gaps)
- Prometheus TSDB (live metrics history) — snapshot API requires `--web.enable-admin-api`, not currently enabled
- Ollama model weights (~2 GB, Windows host `~/.ollama/`) — re-pulled on demand
- HuggingFace model weights — re-downloaded automatically

### The rollback test
A rollback was demonstrated in an isolated `triage-dr-test` namespace using nginx: nginx v1.24.0 was deployed, updated to v1.25.4, then rolled back to v1.24.0 using `kubectl rollout undo`. The test verified the rollback completed successfully and that the existing DEV, PROD, and monitoring workloads were unmodified. The application's `kubectl rollout undo` procedure is documented but was not executed against the live AI application pods.

### RTO / RPO
- **RPO ≤ 24 hours**: backup script runs in < 10 seconds; daily scheduling is documented but not yet automated.
- **RTO ≤ 30 min** (data restore): measured at < 5 seconds (file copy + verification).
- **RTO ≤ 5 min** (Kubernetes rollback): measured at ~30 seconds (`kubectl rollout undo` + pod ready).

---

## 9. How All Components Interact

```
Developer pushes code to GitHub
    → GitHub Actions: test (744 tests) → build → Trivy scan → push to GHCR
    → deploy workflows: render manifests (dry-run) — kubectl apply disabled

Developer manually loads image into kind node:
    docker build -t ticket-triage-api:s07-metrics .
    docker save … | ctr import …
    kubectl apply -k k8s/overlays/dev/

Kubernetes starts DEV pod:
    Startup probe → /health (waits for uvicorn)
    Readiness probe → /ready (waits for agent init: E5 model + LanceDB + Ollama client)

Client sends POST /triage:
    FastAPI → E5 embedding → LanceDB search → Ollama LLM → validator → router → executor
    → JSON response

Prometheus scrapes /metrics every 30s:
    → stores triage_requests_total, http_request_duration_seconds, agent_ready, etc.
    → evaluates 3 alert rules (all inactive when healthy)

Grafana queries Prometheus:
    → renders 8-panel dashboard at http://localhost:13000

Terraform manages the monitoring namespace, PVCs, and ServiceAccounts:
    → Kustomize manages Prometheus/Grafana Deployments and ConfigMaps on top

DR backup runs (manual):
    → reads DuckDB read-only, copies LanceDB, snapshots k8s manifests + Terraform state
    → writes MANIFEST.sha256 for integrity verification
```

---

## 10. Key Numbers to Know

| Item | Value |
|---|---|
| Unit tests passing | 744 |
| LanceDB reference vectors | 3,206 |
| DuckDB ticket rows | 4,000 |
| DuckDB prediction rows | 4,676 |
| DuckDB run rows | 59 |
| Embedding dimensions | 1,024 (E5-large) |
| Default LLM (analyzer) | `llama3.2:3b` via Ollama |
| Configured reviewer LLM | `granite4.1:8b` (disabled by default) |
| Prometheus metrics exported | 6 application metrics |
| Grafana dashboard panels | 8 |
| Alert rules | 3 |
| Terraform resources | 5 |
| DR backup size | 118 MB, 42 files |
| Unfixed HIGH OS CVEs | 54 (no upstream patch) |
| CVEs remediated (S05b) | 8 |
| DEV triage latency (avg) | ~2.9 s/ticket (reviewer OFF), ~3.6 s (reviewer ON) |
| Urgency accuracy (controlled A/B, reviewer ON) | 57.0% |
| Topic proxy accuracy (controlled A/B, reviewer ON) | 60.0% |
