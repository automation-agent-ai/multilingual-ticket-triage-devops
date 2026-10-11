# Multilingual Ticket Triage — DevOps Graduation Project (Liora)

A local, auditable AI triage agent for multilingual customer-support tickets,
packaged as a FastAPI service and deployed to a local Kubernetes cluster with
full CI/CD, infrastructure-as-code, observability, security hardening, and
disaster recovery.

---

## Project Status

| Sprint | Area | Status |
|---|---|---|
| S02–S04 | FastAPI application, Docker DEV/PROD, Kubernetes DEV/PROD | ✅ Complete |
| S05 | GitHub Actions CI: 744 tests, Trivy gate, GHCR publish | ✅ Complete |
| S06 | Terraform: 5 monitoring-support resources applied | ✅ Complete |
| S07 | Prometheus + Grafana: DEV scrape UP, 8 dashboard panels, 3 alert rules | ✅ Complete |
| S08 | Security audit: 5 controls verified, residual risks documented | ✅ Complete |
| S09 | Disaster recovery: 118 MB backup, 42 SHA-256 verified files, nginx rollback | ✅ Complete |
| S10 | Final documentation | ✅ Complete |

**Current branch:** `feat/s06-terraform`  
**Kubernetes context:** `docker-desktop` (kind, local)

---

## Application Overview

The system classifies multilingual insurance support tickets into a **topic** (5 categories),
an **urgency level** (Low / Medium / High), and a **next action** (6 deterministic actions)
using a multi-step agentic pipeline:

```
POST /triage (subject + body)
    → multilingual-e5-large embedding
    → LanceDB top-k neighbor retrieval (3,206 reference vectors)
    → weighted neighbor vote (predicted queue, priority)
    → Ollama LLM (llama3.2:3b) → Pydantic LLMAnalysis
    → deterministic validator
    → optional conditional reviewer (granite4.1:8b, disabled by default)
    → deterministic router → next_action
    → simulated action executor
    → TriageResult (topic, urgency, next_action, confidence, flags)
```

Prediction uses `subject` and `body` only. Ground-truth labels (`queue`, `priority`, `answer`)
are never used during inference — only for post-prediction evaluation.

---

## Controlled A/B Evaluation (200 tickets, llama3.2:3b, seed 42)

| Configuration | Urgency Acc | Urgency F1 | Topic Acc | Topic F1 | Human Rev. | sec/ticket |
|---|---|---|---|---|---|---|
| Reviewer OFF | 55.5% | 55.4% | 59.5% | 56.0% | 42.0% | 2.90 |
| granite4.1:8b ON | 57.0% | 56.0% | 60.0% | 56.0% | 38.0% | 3.60 |

See [`outputs/curated_leaderboard.md`](outputs/curated_leaderboard.md) and
[`docs/MODEL_EVALUATION.md`](docs/MODEL_EVALUATION.md) for the full 7-run leaderboard.

---

## Quick Start

```bash
# 1. Create and activate virtual environment
python -m venv .venv && source .venv/bin/activate   # Linux/macOS
# .\.venv\Scripts\Activate.ps1                       # Windows

# 2. Install dependencies
pip install -r requirements.txt

# 3. Start Ollama and pull models
ollama serve
ollama pull llama3.2:3b

# 4. Download dataset (Kaggle)
kaggle datasets download -d tobiasbueck/multilingual-customer-support-tickets -p data --unzip

# 5. Build the index (first run)
# In config.yaml: set runtime.rebuild_duckdb: true, runtime.rebuild_lancedb: true
python main.py

# 6. Interactive demo
python cli.py
```

> **Note:** The raw dataset CSV, DuckDB database, and LanceDB vector index are
> excluded from this repository. See [Fresh-clone setup](#fresh-clone-setup) below.

---

## CLI Menu

```
0.  Exit
1.  Triage a ticket          (random eval ticket or specific ticket_id; reviewer OFF/ON)
2.  Run batch evaluation      (configurable limit; reviewer OFF/ON)
3.  Compare reviewer OFF vs ON
4.  Inspect evaluation results
      1. Curated evaluation   (7 configured runs grouped by methodology)
      2. Full experiment history
      3. Run details
      4. Confusion matrix
      5. Ticket prediction details
5.  Run leakage audit
6.  Show runtime configuration
```

---

## Running Tests

```bash
# Fast tests — no Ollama, no LanceDB, no DuckDB required (~25 s, 744 tests)
pytest tests/ -m "not slow" -q

# All tests (requires Ollama + dataset)
pytest tests/ -q
```

---

## Documentation

| Document | Description |
|---|---|
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | Full architecture with Mermaid diagram, component ownership, DEV/PROD separation |
| [`docs/LIORA_COMPLIANCE.md`](docs/LIORA_COMPLIANCE.md) | Compliance matrix: every requirement → implementation, evidence, command, status, limitations |
| [`docs/DEMO_GUIDE.md`](docs/DEMO_GUIDE.md) | Reproducible demo script: GitHub Actions, kubectl, triage request, Prometheus, Grafana, Terraform, DR |
| [`docs/EXPLAIN_THE_ARCHITECTURE.md`](docs/EXPLAIN_THE_ARCHITECTURE.md) | Oral-examination guide: what each component does, why it exists, how they interact |
| [`docs/technical_solution.md`](docs/technical_solution.md) | Full AI pipeline design: ontology, leakage boundary, evaluation methodology |
| [`docs/MODEL_EVALUATION.md`](docs/MODEL_EVALUATION.md) | 7-run curated leaderboard with controlled A/B results |
| [`docs/PROJECT_ARCHITECTURE.md`](docs/PROJECT_ARCHITECTURE.md) | Module responsibilities and data-flow reference |
| [`docs/CICD.md`](docs/CICD.md) | CI/CD pipeline stages, Kubernetes overlays, connectivity limitation |
| [`docs/MONITORING.md`](docs/MONITORING.md) | Prometheus + Grafana deployment, metrics, alert rules, verification results |
| [`docs/SECURITY.md`](docs/SECURITY.md) | 5 verified security controls, residual vulnerabilities, recommendations |
| [`docs/DISASTER_RECOVERY.md`](docs/DISASTER_RECOVERY.md) | DR scripts, backup contents, test results, RTO/RPO targets |
| [`docs/RUNBOOK.md`](docs/RUNBOOK.md) | Operational runbook: startup, batch runs, evaluation, Ollama model management |

---

## Infrastructure

### Docker
- `Dockerfile` — multi-stage build; non-root user `appuser` (UID 1000); `pip`/`setuptools` removed from runtime layer
- `docker-compose.dev.yml` / `docker-compose.prod.yml` — local Docker compose configurations

### Kubernetes (kind / docker-desktop)
- `k8s/base/` — shared Deployment + Service (security context, probes, read-only data mount)
- `k8s/overlays/dev/` — DEV overlay: namespace `triage-dev`, image `ticket-triage-api:s07-metrics`
- `k8s/overlays/prod/` — PROD overlay: namespace `triage-prod`, image `ticket-triage-api:latest`
- `k8s/ci-overlays/` — CI overlays used by deploy workflows (GHCR image, `IfNotPresent`)

### Terraform
- `terraform/` — provisions 5 monitoring-support resources: `triage-monitoring` namespace, 2 PVCs (Prometheus + Grafana), 2 ServiceAccounts

### Monitoring
- `monitoring/prometheus/` — Prometheus v3.1.0 deployment, scrape config, 3 alert rules
- `monitoring/grafana/` — Grafana v11.4.0 deployment, provisioned datasource + 8-panel dashboard

### CI/CD
- `.github/workflows/ci.yml` — test → build → Trivy scan → GHCR push
- `.github/workflows/deploy-dev.yml` — DEV deploy (dry-run; `kubectl apply` disabled)
- `.github/workflows/deploy-prod.yml` — PROD deploy (manual + approval gate; dry-run)

### Disaster Recovery
- `scripts/dr/backup.sh` — timestamped backup (DuckDB + LanceDB + manifests + Terraform state)
- `scripts/dr/verify.sh` — SHA-256 integrity verification
- `scripts/dr/restore-test.sh` — isolated restore test with row-count validation
- `scripts/dr/rollback-test.sh` — Kubernetes rollback test in isolated namespace

---

## Known Limitations

| Limitation | Details |
|---|---|
| CI `kubectl apply` disabled | No automated cluster deployment; GitHub runners cannot reach local kind cluster |
| PROD has no `/metrics` | PROD runs older `ticket-triage-api:latest` image; not scraped by Prometheus |
| `s07-metrics` image is local only | Not published to GHCR; DEV uses a locally built image |
| Terraform state is local | `terraform.tfstate` on disk; not backed up to remote backend |
| Prometheus snapshot not available | Snapshot API requires `--web.enable-admin-api` (not enabled); `--web.enable-lifecycle` enables reload/quit only |
| No Alertmanager | Alert rules visible in Prometheus UI; no notifications sent |
| DR rollback on nginx only | Application rollback procedure documented but not live-tested against AI pods |
| No automated backup schedule | `backup.sh` must be triggered manually |
| 54 unfixed HIGH OS CVEs | OS-layer CVEs in `python:3.12-slim` base image; no upstream patch at scan time |

---

## Fresh-Clone Setup

The following are excluded from this repository:
- Full raw dataset CSV (`data/dataset-*.csv`)
- DuckDB database (`data/tickets.duckdb`)
- LanceDB vector index (`data/lancedb/`)
- Ollama models (pull with `ollama pull llama3.2:3b`)
- Python virtual environment (`.venv/`)
- HuggingFace model cache (`.cache/`)
- Terraform state (`terraform/terraform.tfstate`)

Static output artifacts are committed:
- `outputs/curated_leaderboard.csv` / `.md` — curated 7-run KPI table
- `outputs/triage_results.csv` — representative 20-ticket sample
- `outputs/triage_trace.jsonl` — representative decision trace

Run IDs in `config.yaml` under `leaderboard` refer to the submitted local experiment history
and will not exist in a freshly rebuilt database. After rebuilding, regenerate leaderboard files:

```bash
python scripts/export_curated_leaderboard.py
```

---

## Dataset Attribution

**Multilingual Customer Support Tickets** by Tobias Bueck  
[kaggle.com/datasets/tobiasbueck/multilingual-customer-support-tickets](https://www.kaggle.com/datasets/tobiasbueck/multilingual-customer-support-tickets)

The raw dataset CSV is not included in this repository.
