# Multilingual Ticket Triage — Cloud-Native DevOps Platform

An intelligent, multilingual AI triage agent for customer-support tickets, deployed as a cloud-native platform on AWS with verified **DEV** CI/CD (GitHub Actions → OIDC → SSM → k3s), Amazon Bedrock integration, infrastructure-as-code modules, Prometheus/Grafana on AWS k3s, and backup automation (local DR validation documented; full AWS restore not end-to-end tested).

---

## Project Overview

**Architecture:** Python/FastAPI microservice → Docker container → GitHub Actions CI/CD → AWS EC2 → k3s Kubernetes → Amazon Bedrock (Nova Micro) inference

**Deployment:** AWS eu-west-1 (production DEV environment) + local WSL/kind cluster (historical development)

**Repository:** [automation-agent-ai/multilingual-ticket-triage-devops](https://github.com/automation-agent-ai/multilingual-ticket-triage-devops)  
**Current branch:** `main` ([PR #4 merged](https://github.com/automation-agent-ai/multilingual-ticket-triage-devops/pull/4) on 2026-10-26)

---

## Project Status

| Phase | Area | Status |
|---|---|---|
| **Foundation** | FastAPI application, Docker, Kubernetes DEV/PROD namespaces | ✅ Complete |
| **CI/CD** | GitHub Actions: pytest, Trivy security gate, GHCR publish | ✅ Complete ([run 40256672282](https://github.com/automation-agent-ai/multilingual-ticket-triage-devops/actions/runs/40256672282)) |
| **AWS Migration** | Amazon Bedrock Nova Micro provider, config-aws.yaml, boto3 client | ✅ Complete ([PR #4](https://github.com/automation-agent-ai/multilingual-ticket-triage-devops/pull/4)) |
| **AWS CI/CD (DEV)** | GitHub OIDC → IAM → SSM → `triage-dev` | ✅ **Verified** ([run 40256053016](https://github.com/automation-agent-ai/multilingual-ticket-triage-devops/actions/runs/40256053016)) |
| **AWS CI/CD (PROD)** | `aws-prod-promote.yml` / workflow PROD jobs | 📝 **Not verified** — manual promotion prepared; `aws-prod` reviewer protection incomplete |
| **AWS `triage-prod` workload** | Existing deployment on k3s | ✅ **Healthy** (`/health` OK) — **not** deployed by verified automated PROD promotion |
| **Infrastructure** | Terraform (AWS OIDC, IAM, S3 backup, monitoring modules) | 📝 **Modules in repo** — live AWS IAM/OIDC not fully reproduced via `terraform apply` |
| **Monitoring (AWS k3s)** | Prometheus + Grafana in `triage-monitoring` | ✅ **Deployed** — scrapes DEV/PROD `/metrics` (targets UP); dashboards/alerts differ from WSL docs |
| **Security** | Trivy CRITICAL/HIGH gate, RBAC, OIDC, SSM | ✅ Verified on CI paths |
| **Backup/DR** | Restic + offsite copy automation; `scripts/dr/` locally | 📝 **Local restore tests** documented — **not** full AWS DR restoration |

**AWS DEV image (verified deploy):** `ghcr.io/automation-agent-ai/multilingual-ticket-triage-devops:aws-sha-091525522acc6875d97ac9dcc1f34231f5d015ef`  
**Main-branch CI** ([run 40256672282](https://github.com/automation-agent-ai/multilingual-ticket-triage-devops/actions/runs/40256672282)) builds/scans/pushes to GHCR — **does not** trigger AWS SSM deployment.  
**Kubernetes context:** AWS k3s (`triage-dev`, `triage-prod`, `triage-monitoring`) + WSL kind (`docker-desktop`, historical)

---

## Application Overview

The system classifies multilingual insurance support tickets into a **topic** (5 categories),
an **urgency level** (Low / Medium / High), and a **next action** (6 deterministic actions)
using a multi-step agentic pipeline:

```
POST /triage (subject + body)
    → multilingual-e5-large embedding (HuggingFace)
    → LanceDB top-k neighbor retrieval (3,206 reference vectors)
    → weighted neighbor vote (predicted queue, priority)
    → LLM provider (pluggable):
        • Amazon Bedrock (eu.amazon.nova-micro-v1:0) — AWS DEV/PROD
        • Ollama (llama3.2:3b) — local development
    → Pydantic validation (LLMAnalysis schema)
    → deterministic validator
    → optional conditional reviewer (disabled by default)
    → deterministic router → next_action
    → simulated action executor
    → TriageResult (topic, urgency, next_action, confidence, inference_metadata)
```

**Key features:**
- Prediction uses `subject` and `body` only (ground-truth labels never exposed to inference)
- Pluggable LLM provider architecture (`src/infrastructure/llm_provider.py`)
- Real-time inference metadata: provider, model, tokens, latency, invocation count
- EC2 instance IAM role authentication (no credentials in code or config)

---

## Controlled A/B Evaluation (200 tickets, llama3.2:3b, seed 42)

| Configuration | Urgency Acc | Urgency F1 | Topic Acc | Topic F1 | Human Rev. | sec/ticket |
|---|---|---|---|---|---|---|
| Reviewer OFF | 55.5% | 55.4% | 59.5% | 56.0% | 42.0% | 2.90 |
| granite4.1:8b ON | 57.0% | 56.0% | 60.0% | 56.0% | 38.0% | 3.60 |

See [`outputs/curated_leaderboard.md`](outputs/curated_leaderboard.md) and
[`docs/MODEL_EVALUATION.md`](docs/MODEL_EVALUATION.md) for the full 7-run leaderboard.

---

## Quick Start (Local Development with Ollama)

> **Note:** This requires external dataset download, Ollama installation, and model caching (~4GB). The application does **not** run immediately after git clone. AWS Bedrock deployment requires IAM role configuration (see [`docs/AWS_CICD.md`](docs/AWS_CICD.md)).

```bash
# 1. Clone and navigate
git clone https://github.com/automation-agent-ai/multilingual-ticket-triage-devops.git
cd multilingual-ticket-triage-devops

# 2. Create and activate virtual environment
python -m venv .venv && source .venv/bin/activate   # Linux/macOS
# .\.venv\Scripts\Activate.ps1                       # Windows

# 3. Install dependencies
pip install -r requirements.txt

# 4. Start Ollama and pull models (separate terminal)
ollama serve
ollama pull llama3.2:3b

# 5. Download dataset (requires Kaggle API credentials)
kaggle datasets download -d tobiasbueck/multilingual-customer-support-tickets -p data --unzip

# 6. Build the index (first run only, ~5 minutes)
# In config.yaml: set runtime.rebuild_duckdb: true, runtime.rebuild_lancedb: true
python main.py

# 7. Interactive demo
python cli.py
```

> **Data exclusions:** The raw dataset CSV, DuckDB database, and LanceDB vector index are excluded from this repository. See [Fresh-clone setup](#fresh-clone-setup) below.

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

## Reviewer Navigation Guide

This repository contains a complete cloud-native DevOps implementation. For defense/examination:

**Start here:**
- [`README.md`](README.md) — this file (project overview, architecture, setup)
- [`docs/DEMO_GUIDE.md`](docs/DEMO_GUIDE.md) — live AWS demo script for defense presentation
- [`docs/AWS_CICD.md`](docs/AWS_CICD.md) — complete AWS deployment architecture and CI/CD pipeline

**Source code:**
- `src/` — application modules (agent, analyzer, validator, router, action executor)
- `src/infrastructure/` — LLM providers (Bedrock, Ollama), embedding model, CSV loader, repositories
- `api/app.py` — FastAPI service with `/triage`, `/health`, `/ready`, `/metrics` endpoints
- `tests/` — 789 pytest tests (including 20 Bedrock client tests, all mocked boto3)

**Infrastructure:**
- `k8s/base/` + `k8s/overlays/{dev,prod,aws-dev,aws-prod}/` — Kubernetes manifests
- `.github/workflows/` — CI/CD pipelines (5 workflows: CI, WSL deploy, AWS CI/CD, AWS PROD promote)
- `terraform/` + `infra/terraform/` — IaC modules (monitoring, AWS OIDC/IAM, S3 backup bucket)
- `Dockerfile` — multi-stage container build

**Operations:**
- `ops/backup/` — Restic backup automation (systemd units, scripts, S3 offsite copy)
- `monitoring/` + `k8s/aws-monitoring/` — Prometheus + Grafana stack
- `scripts/dr/` — disaster recovery validation scripts

**Evidence & documentation:**
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — system architecture with Mermaid diagrams
- [`docs/LIORA_COMPLIANCE.md`](docs/LIORA_COMPLIANCE.md) — requirements compliance matrix
- [`outputs/curated_leaderboard.md`](outputs/curated_leaderboard.md) — controlled A/B evaluation results
- Root `*_REPORT.md` / `*_SUMMARY.txt` — phase completion reports (AWS consolidation, CI/CD)

**GitHub Actions evidence:**
- [PR #4](https://github.com/automation-agent-ai/multilingual-ticket-triage-devops/pull/4) — AWS Bedrock migration (23 commits, merged 2026-10-26)
- [Main CI run 40256672282](https://github.com/automation-agent-ai/multilingual-ticket-triage-devops/actions/runs/40256672282) — pytest ✅, Trivy ✅, GHCR push ✅
- [AWS CI run 40256053016](https://github.com/automation-agent-ai/multilingual-ticket-triage-devops/actions/runs/40256053016) — AWS DEV deploy ✅ via SSM

---

## Running Tests

```bash
# Fast tests — no Ollama, no LanceDB, no DuckDB required (~30 s, 781 tests including Bedrock mocks)
pytest tests/ -m "not slow" -q

# All tests (requires Ollama + dataset; 789 tests total)
pytest tests/ -q
```

**CI evidence:**
- **Main CI:** [run 40256672282](https://github.com/automation-agent-ai/multilingual-ticket-triage-devops/actions/runs/40256672282) — pytest 781 passed
- **AWS CI:** [run 40256053016](https://github.com/automation-agent-ai/multilingual-ticket-triage-devops/actions/runs/40256053016) — pytest 781 passed, Trivy PASSED, DEV deployed

---

## Documentation

| Document | Description |
|---|---|
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | Full architecture with Mermaid diagram, component ownership, DEV/PROD separation |
| [`docs/LIORA_COMPLIANCE.md`](docs/LIORA_COMPLIANCE.md) | Compliance matrix: every requirement → implementation, evidence, command, status, limitations |
| [`docs/DEMO_GUIDE.md`](docs/DEMO_GUIDE.md) | Live AWS demo script: health checks, CI evidence, Kubernetes status, monitoring, backup |
| [`docs/AWS_CICD.md`](docs/AWS_CICD.md) | AWS CI/CD pipeline architecture: GitHub OIDC → IAM → SSM → k3s deployment |
| [`docs/CICD.md`](docs/CICD.md) | WSL/kind CI/CD pipeline (historical local development environment) |
| [`docs/EXPLAIN_THE_ARCHITECTURE.md`](docs/EXPLAIN_THE_ARCHITECTURE.md) | Oral-examination guide: what each component does, why it exists, how they interact |
| [`docs/technical_solution.md`](docs/technical_solution.md) | Full AI pipeline design: ontology, leakage boundary, evaluation methodology |
| [`docs/MODEL_EVALUATION.md`](docs/MODEL_EVALUATION.md) | 7-run curated leaderboard with controlled A/B results |
| [`docs/PROJECT_ARCHITECTURE.md`](docs/PROJECT_ARCHITECTURE.md) | Module responsibilities and data-flow reference |
| [`docs/MONITORING.md`](docs/MONITORING.md) | Prometheus + Grafana deployment, metrics, alert rules, verification results |
| [`docs/SECURITY.md`](docs/SECURITY.md) | 5 verified security controls, residual vulnerabilities, recommendations |
| [`docs/DISASTER_RECOVERY.md`](docs/DISASTER_RECOVERY.md) | DR scripts, backup contents, test results, RTO/RPO targets |
| [`docs/RUNBOOK.md`](docs/RUNBOOK.md) | Operational runbook: startup, batch runs, evaluation, Ollama model management |

---

## Infrastructure

### Docker
- `Dockerfile` — multi-stage build; non-root user `appuser` (UID 1000); `pip`/`setuptools` removed from runtime layer
- `docker-compose.dev.yml` / `docker-compose.prod.yml` — local Docker compose configurations (development only)

### Kubernetes
**AWS k3s (production DEV):**
- `k8s/overlays/aws-dev/` — DEV overlay: namespace `triage-dev`, GHCR image with AWS Bedrock
- `k8s/overlays/aws-prod/` — PROD overlay: namespace `triage-prod` (manual promotion only)
- **DEV:** deployed via `aws-ci-cd.yml` on `feat/aws-bedrock-migration` (verified); **not** on every `main` push
- **PROD:** workload running separately; automated promotion workflow **not** verified end-to-end

**WSL kind (historical development):**
- `k8s/overlays/dev/` — local DEV: `docker-desktop` context, local images
- `k8s/overlays/prod/` — local PROD: dry-run only
- `k8s/ci-overlays/` — WSL CI overlays (self-hosted runner required)

**Shared:**
- `k8s/base/` — base Deployment + Service (security context, probes, read-only data mount)
- `k8s/aws-monitoring/` — Prometheus + Grafana for AWS k3s

### Terraform
**Prepared modules (not yet applied to live AWS):**
- `terraform/` — monitoring-support resources (namespace, PVCs, ServiceAccounts) for local kind
- `infra/terraform/aws-infra/` — AWS OIDC provider, IAM roles (github-actions-aws-deployer), SSM configuration
- `infra/terraform/aws-restic/` — S3 backup bucket with versioning and lifecycle policies

### Monitoring
- **AWS k3s (live):** `triage-monitoring` namespace — Prometheus + Grafana deployments and ClusterIP services; scrapes `ticket-triage-dev` and `ticket-triage-prod` `/metrics`
- **Repo manifests:** `monitoring/` (WSL/kind reference), `k8s/aws-monitoring/` (AWS-oriented Kustomize)

### CI/CD
**AWS pipelines (active):**
- `.github/workflows/aws-ci-cd.yml` — complete CI/CD: test → build → scan → deploy DEV (triggers on `feat/aws-bedrock-migration`)
- `.github/workflows/aws-prod-promote.yml` — manual PROD promotion with approval gate (prepared, not yet executed)

**WSL pipelines (historical):**
- `.github/workflows/ci.yml` — test → build → Trivy scan → GHCR push (triggers on `main`)
- `.github/workflows/deploy-dev.yml` — DEV deploy via self-hosted runner (requires runner registration)
- `.github/workflows/deploy-prod.yml` — PROD deploy with approval gate (dry-run only)

### Disaster Recovery
- `ops/backup/scripts/restic-backup.sh` — encrypted Restic backup to local EBS
- `ops/backup/scripts/restic-offsite-copy.sh` — offsite copy to Hetzner S3 (REST protocol)
- `ops/backup/systemd/` — systemd timer units for automated backup scheduling
- `scripts/dr/` — backup validation and restore testing scripts

---

## Known Limitations

| Area | Limitation | Details |
|---|---|---|
| **AWS PROD promotion** | Not verified | `triage-prod` pod healthy on older image; `aws-prod-promote.yml` / PROD CI jobs **not** executed successfully; `aws-prod` approval gate incomplete |
| **AWS CI trigger** | Feature branch only | `aws-ci-cd.yml` triggers on `feat/aws-bedrock-migration` push; **`main` push does not deploy AWS** |
| **Terraform state** | Not applied to AWS | Terraform modules prepared but not yet applied; IAM/OIDC configured manually via AWS Console/CLI |
| **WSL deploy** | Self-hosted runner required | `deploy-dev.yml` needs `triage-dev-deployer` runner on WSL host; not registered in this environment |
| **Disaster recovery** | Restore not live-tested on AWS | Backup/restore validated locally; full AWS restoration from Hetzner S3 documented but not executed |
| **GHCR package** | Visibility unknown | Repository is public; GHCR package visibility requires `read:packages` scope to verify anonymous access |
| **Image pin drift** | Git vs runtime mismatch | `k8s/overlays/aws-dev/kustomization.yaml` on main: `bbe590a3…`, deployed: `09152552…` |
| **Monitoring scope** | Metrics vs dashboards | AWS Prometheus scrapes app `/metrics`; Grafana dashboard coverage may differ from WSL `docs/MONITORING.md` |
| **OS CVEs** | 54 unfixed HIGH | OS-layer CVEs in `python:3.12-slim` base image; Trivy ignores unfixed to keep gate passing |
| **Local dataset required** | Not in git | Fresh clone needs Kaggle credentials + dataset download + index rebuild (~5-10 minutes) |

---

## Fresh-Clone Setup

**Excluded from this repository (by design):**
- Full raw dataset CSV (`data/dataset-*.csv`) — 82 MB, requires Kaggle download
- DuckDB database (`data/tickets.duckdb`) — rebuilt from CSV
- LanceDB vector index (`data/lancedb/`) — rebuilt from DuckDB + embedding model
- Ollama models — pull with `ollama pull llama3.2:3b` (~2 GB)
- HuggingFace model cache (`.cache/`) — downloaded on first run (~1.5 GB for multilingual-e5-large)
- Python virtual environment (`.venv/`) — created per environment
- Terraform state (`terraform/terraform.tfstate`) — local state only

**Included static artifacts:**
- `outputs/curated_leaderboard.csv` / `.md` — 7-run controlled A/B evaluation summary
- `outputs/triage_results.csv` — 20-ticket representative sample with predictions
- `outputs/triage_trace.jsonl` — decision trace with LLM prompts and responses
- `config.yaml` / `config-aws.yaml` — application configuration (Ollama vs Bedrock provider)

**Evaluation history:** Run IDs in `config.yaml` under `leaderboard.curated_runs` refer to a local experiment history built during development. After rebuilding the database in a fresh clone, these run IDs will not exist. Regenerate leaderboard files with:

```bash
python scripts/export_curated_leaderboard.py
```

**AWS deployment:** Requires IAM role with Bedrock permissions and SSM access. See [`docs/AWS_CICD.md`](docs/AWS_CICD.md) and [`docs/AWS_IAM_SETUP.md`](docs/AWS_IAM_SETUP.md).

---

## Dataset Attribution

**Multilingual Customer Support Tickets** by Tobias Bueck  
[kaggle.com/datasets/tobiasbueck/multilingual-customer-support-tickets](https://www.kaggle.com/datasets/tobiasbueck/multilingual-customer-support-tickets)

The raw dataset CSV is not included in this repository.
