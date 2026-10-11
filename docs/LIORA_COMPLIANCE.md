# Liora Compliance Matrix — Multilingual Ticket Triage DevOps

**Project:** Liora graduation project  
**Date:** 2026-10-11  
**Sprint:** S10 — Final documentation  
**Branch:** `feat/s06-terraform`

This document maps every implemented Liora requirement to its implementation artifact,
verification command, current status, and any remaining limitation.

---

## 1. Application — FastAPI Ticket Triage Agent

| Requirement | Implementation | Evidence File | Verification Command | Status | Limitation |
|---|---|---|---|---|---|
| FastAPI REST service with `/health`, `/ready`, `/triage` | `api/app.py` | `api/app.py` | `curl http://localhost:18000/health` | ✅ Verified | — |
| Multilingual AI pipeline (E5 + Ollama LLM) | `src/application/agent.py`, `src/infrastructure/` | `docs/technical_solution.md` | `curl -X POST http://localhost:18000/triage -H 'Content-Type: application/json' -d @api/example_request.json` | ✅ Verified (DEV live) | Ollama runs on Windows host; not containerized |
| LanceDB vector retrieval (top-k cosine) | `src/infrastructure/lancedb_ticket_store.py` | `docs/PROJECT_ARCHITECTURE.md §8` | CLI option 1 → triage a ticket | ✅ Verified | — |
| DuckDB structured storage (5 tables) | `src/infrastructure/duckdb_repository.py` | `docs/PROJECT_ARCHITECTURE.md §8` | DuckDB backup row counts in `docs/DISASTER_RECOVERY.md` | ✅ Verified | `data/tickets.duckdb` excluded from Git |
| Deterministic validator + router | `src/application/validator.py`, `src/application/router.py` | `docs/technical_solution.md §8` | Unit tests: `pytest tests/test_validator.py tests/test_router.py -q` | ✅ Verified | — |
| Conditional reviewer (optional second-pass LLM) | `src/application/reviewer.py` | `docs/technical_solution.md §7` | CLI option 3 (reviewer ON vs OFF) | ✅ Verified | Disabled by default (`reviewer.enabled: false`) |
| Prometheus metrics endpoint `/metrics` | `api/prom_metrics.py` | `docs/MONITORING.md` | `curl http://localhost:18000/metrics` | ✅ Verified (DEV only) | PROD image does not expose `/metrics` |
| 744 unit tests passing | `tests/` (26 test files) | CI log | `pytest tests/ -m "not slow" -q` | ✅ 744 passed | — |

---

## 2. Docker — Containerisation

| Requirement | Implementation | Evidence File | Verification Command | Status | Limitation |
|---|---|---|---|---|---|
| Multi-stage Dockerfile (builder + runtime) | `Dockerfile` | `Dockerfile` | `docker build -t ticket-triage-api:latest .` | ✅ Verified | — |
| Non-root user `appuser` (UID 1000) | `Dockerfile` lines 52–60, 120 | `docs/SECURITY.md §2 Control 1` | `docker run --rm ticket-triage-api:latest whoami` → `appuser` | ✅ Verified | — |
| `pip`/`setuptools` removed from runtime layer | `Dockerfile` lines 98–101 | `docs/SECURITY.md §2 Control 2` | `docker run --rm ticket-triage-api:latest pip --version` → error | ✅ Verified | — |
| `.dockerignore` excludes secrets + credentials | `.dockerignore` lines 52–62 | `docs/SECURITY.md §2 Control 3b` | `cat .dockerignore \| grep -E 'env\|key\|kaggle'` | ✅ Verified | — |
| DEV docker-compose | `docker-compose.dev.yml` | `docker-compose.dev.yml` | `docker compose -f docker-compose.dev.yml config` | ✅ Verified | — |
| PROD docker-compose | `docker-compose.prod.yml` | `docker-compose.prod.yml` | `docker compose -f docker-compose.prod.yml config` | ✅ Verified | — |

---

## 3. Kubernetes — Local DEV and PROD Deployment

| Requirement | Implementation | Evidence File | Verification Command | Status | Limitation |
|---|---|---|---|---|---|
| DEV deployment (triage-dev namespace) | `k8s/overlays/dev/` | `k8s/overlays/dev/kustomization.yaml` | `kubectl get pods -n triage-dev` | ✅ Running (1/1) | Uses locally built `s07-metrics` image |
| PROD deployment (triage-prod namespace) | `k8s/overlays/prod/` | `k8s/overlays/prod/kustomization.yaml` | `kubectl get pods -n triage-prod` | ✅ Running (1/1) | Uses older `latest` image; no `/metrics` |
| Non-root, no privilege escalation, dropped capabilities | `k8s/base/deployment.yaml` lines 20–60 | `docs/SECURITY.md §2 Control 1` | `kubectl get pod -n triage-dev -o jsonpath='{.items[0].spec.securityContext}'` | ✅ Verified | `readOnlyRootFilesystem: false` (Python `__pycache__`) |
| App-data read-only volume mount | `k8s/base/deployment.yaml` line 74 | `docs/SECURITY.md §2 Control 3c` | `kubectl get pod -n triage-dev -o json \| python3 -c "..."` → `readOnly=True` | ✅ Verified | — |
| Liveness + readiness + startup probes | `k8s/base/deployment.yaml` lines 82–116 | `k8s/base/deployment.yaml` | `kubectl describe pod -n triage-dev \| grep -A4 'Liveness\|Readiness\|Startup'` | ✅ Implemented | — |
| Namespace isolation (3 namespaces) | `k8s/overlays/*/namespace.yaml`, `terraform/main.tf` | `docs/SECURITY.md §2 Control 4` | `kubectl get namespaces \| grep triage` | ✅ Verified | No NetworkPolicy — pods not network-isolated |
| Dedicated monitoring ServiceAccounts | `terraform/main.tf` lines 91–120 | `docs/SECURITY.md §2 Control 4` | `kubectl get sa -n triage-monitoring` | ✅ Verified (Terraform) | Application namespaces use `default` SA |
| Kustomize overlays (base + dev + prod) | `k8s/base/`, `k8s/overlays/` | `k8s/README.md` | `kubectl kustomize k8s/overlays/dev` | ✅ Verified | — |

---

## 4. CI/CD — GitHub Actions

| Requirement | Implementation | Evidence File | Verification Command | Status | Limitation |
|---|---|---|---|---|---|
| CI: pytest gate (744 tests, `-m "not slow"`) | `.github/workflows/ci.yml` job `test` | `.github/workflows/ci.yml` lines 50–90 | See Actions log: `pytest tests/ -m "not slow" -v --tb=short` | ✅ Verified (CI) | — |
| CI: Docker build | `.github/workflows/ci.yml` job `build-scan-push` | `.github/workflows/ci.yml` lines 155–165 | CI Actions log | ✅ Verified (CI) | — |
| CI: Trivy CRITICAL/HIGH blocking gate (`exit-code: 1`, `ignore-unfixed: true`) | `.github/workflows/ci.yml` lines 194–206 | `.github/workflows/ci.yml` | CI Actions log — Trivy step | ✅ Verified (CI) | 54 unfixed HIGH OS CVEs remain; `ignore-unfixed` keeps gate passing |
| CI: SARIF upload to GitHub Security tab | `.github/workflows/ci.yml` lines 208–214 | `.github/workflows/ci.yml` | GitHub repo → Security → Code scanning | ✅ Verified (CI) | — |
| CI: GHCR push (gated on Trivy pass, main only) | `.github/workflows/ci.yml` lines 220–233 | `.github/workflows/ci.yml` | `docker pull ghcr.io/automation-agent-ai/multilingual-ticket-triage-devops:latest` | ✅ Verified (CI) | — |
| CI: minimum permissions (`contents: read` default) | `.github/workflows/ci.yml` lines 29–31 | `docs/SECURITY.md §2 Control 5` | `cat .github/workflows/ci.yml \| grep -A2 'permissions'` | ✅ Implemented | — |
| Deploy-DEV workflow (real apply — self-hosted runner) | `.github/workflows/deploy-dev.yml` | `k8s/runner/rbac.yaml`, `scripts/install-runner.sh` | GitHub Actions → Deploy DEV → Run workflow | ✅ Implemented (runner pending approval) | Self-hosted runner not yet registered — see docs/CICD.md §6 |
| Deploy-PROD workflow (manual + approval gate) | `.github/workflows/deploy-prod.yml` | `.github/workflows/deploy-prod.yml` | GitHub Actions UI → Deploy PROD → Run workflow | ✅ Dry-run verified | PROD remains dry-run by design; cluster unchanged |
| Immutable image tag `sha-<40-char-sha>` | `.github/workflows/ci.yml` lines 130–141 | `.github/workflows/ci.yml` | `docker pull ghcr.io/…:sha-<sha>` | ✅ Verified (CI) | — |

---

## 5. Terraform — Infrastructure as Code

| Requirement | Implementation | Evidence File | Verification Command | Status | Limitation |
|---|---|---|---|---|---|
| Terraform provisions monitoring namespace | `terraform/main.tf` resource `kubernetes_namespace_v1.triage_monitoring` | `terraform/main.tf` | `terraform -chdir=terraform show \| grep triage-monitoring` | ✅ Applied (5 resources) | Local state only (`terraform.tfstate`) |
| Terraform provisions Prometheus PVC (1Gi) | `terraform/main.tf` resource `kubernetes_persistent_volume_claim_v1.prometheus_data` | `terraform/main.tf` | `kubectl get pvc -n triage-monitoring` | ✅ Bound | `rancher.io/local-path` — tied to single node |
| Terraform provisions Grafana PVC (1Gi) | `terraform/main.tf` resource `kubernetes_persistent_volume_claim_v1.grafana_data` | `terraform/main.tf` | `kubectl get pvc -n triage-monitoring` | ✅ Bound | Same local-path limitation |
| Terraform provisions ServiceAccounts | `terraform/main.tf` resources `triage_prometheus`, `triage_grafana` | `terraform/main.tf` | `kubectl get sa -n triage-monitoring` | ✅ Verified | — |
| `terraform plan` shows no changes after apply | `terraform/s06.tfplan` | `docs/MONITORING.md §Terraform dependencies` | `terraform -chdir=terraform plan` → `No changes.` | ✅ Verified | — |
| Terraform state excluded from Git | `.gitignore` lines 64–68 | `.gitignore` | `git status -- terraform/terraform.tfstate` → untracked | ✅ Verified | State is backed up in `backups/<TIMESTAMP>/terraform/` |

---

## 6. Monitoring — Prometheus + Grafana

| Requirement | Implementation | Evidence File | Verification Command | Status | Limitation |
|---|---|---|---|---|---|
| Prometheus deployed to `triage-monitoring` | `monitoring/prometheus/deployment.yaml` | `docs/MONITORING.md` | `kubectl get pod -n triage-monitoring -l app.kubernetes.io/name=prometheus` | ✅ Running (1/1) | — |
| Grafana deployed to `triage-monitoring` | `monitoring/grafana/deployment.yaml` | `docs/MONITORING.md` | `kubectl get pod -n triage-monitoring -l app.kubernetes.io/name=grafana` | ✅ Running (1/1) | — |
| DEV scrape target UP | `monitoring/prometheus/configmap.yaml` | `docs/MONITORING.md §Prometheus scrape targets` | `curl http://localhost:19090/api/v1/targets` → `state: up` | ✅ Verified | PROD not scraped; PROD image has no `/metrics` |
| 6 application metrics exported | `api/prom_metrics.py` | `docs/MONITORING.md §Application metrics` | `curl http://localhost:18000/metrics \| grep -E 'triage_\|http_\|agent_ready'` | ✅ Verified (DEV) | — |
| 3 alert rules (loaded, inactive when healthy) | `monitoring/prometheus/alert-rules-configmap.yaml` | `docs/MONITORING.md §Alert rules` | `curl http://localhost:19090/api/v1/rules` → 3 rules, state=inactive | ✅ Verified | No Alertmanager; no notification routing |
| 8-panel Grafana dashboard | `monitoring/grafana/dashboard-configmap.yaml` | `docs/MONITORING.md §Dashboard` | `http://localhost:13000/d/triage-overview` | ✅ Verified | — |
| Grafana datasource connected to Prometheus | `monitoring/grafana/datasource-configmap.yaml` | `docs/MONITORING.md §Verify datasource health` | `curl -u admin:<pw> http://localhost:13000/api/datasources/uid/triage-prometheus/health` | ✅ `{"status":"OK"}` | — |
| Grafana credentials via K8s Secret | `monitoring/grafana/deployment.yaml` lines 44–59 | `docs/SECURITY.md §2 Control 3d` | `kubectl get secret grafana-credentials -n triage-monitoring` | ✅ Verified | etcd not encrypted at rest (local kind cluster) |

---

## 7. Security — DevSecOps Controls

| Requirement | Implementation | Evidence File | Verification Command | Status | Limitation |
|---|---|---|---|---|---|
| Control 1: Non-root container | `Dockerfile` line 120, `k8s/base/deployment.yaml` lines 20–25 | `docs/SECURITY.md §2 Control 1` | `kubectl get pod -n triage-dev -o jsonpath='{.items[0].spec.securityContext}'` | ✅ Verified | — |
| Control 2: Trivy scan gate (8 CVEs remediated) | `.github/workflows/ci.yml`, `requirements-docker.txt` | `docs/SECURITY.md §2 Control 2` | CI Actions log — Trivy step | ✅ Verified | 54 unfixed HIGH OS CVEs — no upstream patch |
| Control 3: Secrets not in Git or image | `.gitignore`, `.dockerignore` | `docs/SECURITY.md §2 Control 3` | `git log --all -- '*.env' '*.tfstate' 'kaggle.json'` → empty | ✅ Verified | — |
| Control 4: Namespace isolation + dedicated SAs | `terraform/main.tf`, `k8s/overlays/*/namespace.yaml` | `docs/SECURITY.md §2 Control 4` | `kubectl get namespaces \| grep triage` | ✅ Verified | No NetworkPolicy |
| Control 5: CI minimum permissions + PROD gate | `.github/workflows/ci.yml`, `.github/workflows/deploy-prod.yml` | `docs/SECURITY.md §2 Control 5` | `cat .github/workflows/ci.yml \| grep -B1 -A3 'permissions'` | ✅ Verified | — |
| 54 unfixed HIGH OS CVEs documented | `docs/SECURITY.md §3.1` | `docs/SECURITY.md §3.1` | CI Actions log — Trivy diagnostic table scan | ✅ Documented | Mitigation: weekly rebuild schedule recommended |

---

## 8. Disaster Recovery

| Requirement | Implementation | Evidence File | Verification Command | Status | Limitation |
|---|---|---|---|---|---|
| Timestamped backup script | `scripts/dr/backup.sh` | `docs/DISASTER_RECOVERY.md §Actual Test Results` | `bash scripts/dr/backup.sh` | ✅ Verified — 118 MB, 42 files | Backup directory is local; off-machine copy not automated |
| SHA-256 integrity verification | `scripts/dr/verify.sh` | `docs/DISASTER_RECOVERY.md §Integrity Verification` | `bash scripts/dr/verify.sh backups/20261011T105508Z` | ✅ Verified — all 42 files pass | — |
| Isolated restore test (DuckDB + LanceDB) | `scripts/dr/restore-test.sh` | `docs/DISASTER_RECOVERY.md §Isolated Restore Test` | `bash scripts/dr/restore-test.sh backups/20261011T105508Z` | ✅ Verified — row counts match | — |
| Kubernetes rollback test | `scripts/dr/rollback-test.sh` | `docs/DISASTER_RECOVERY.md §Kubernetes Rollback Procedure` | `bash scripts/dr/rollback-test.sh` | ✅ Verified (isolated namespace, nginx) | Demonstrated on nginx, not the AI application; existing workloads unmodified |
| Prometheus TSDB snapshot | Requires `--web.enable-admin-api` (not currently enabled) | `docs/DISASTER_RECOVERY.md §Monitoring Data Limitations` | N/A — admin API not enabled | ⚠ Not implemented | `--web.enable-lifecycle` present enables reload/quit only; snapshot API requires a separate `--web.enable-admin-api` flag |
| Terraform state backup | Included in `scripts/dr/backup.sh` | `docs/DISASTER_RECOVERY.md §Terraform State Handling` | `ls backups/20261011T105508Z/terraform/terraform.tfstate` | ✅ Verified | Remote backend not configured |
| RTO ≤ 30 min (data restore) | `restore-test.sh` | `docs/DISASTER_RECOVERY.md §RTO/RPO` | See measured times | ✅ Measured < 5 s | Ollama re-pull ~5 min if host cache lost |
| RPO ≤ 24 h | `backup.sh` | `docs/DISASTER_RECOVERY.md §RTO/RPO` | `bash scripts/dr/backup.sh` (< 10 s runtime) | ✅ Script available | Automated schedule (cron/CI trigger) not yet configured |

---

## 9. Summary Status

| Sprint | Area | Status |
|---|---|---|
| S02–S04 | FastAPI application, Docker, local Kubernetes | ✅ Complete |
| S05 | GitHub Actions CI (tests, build, Trivy, GHCR) | ✅ Complete |
| S05b | Dependency remediation (8 CVEs) | ✅ Complete |
| S06 | Terraform monitoring infrastructure (5 resources) | ✅ Complete |
| S07 | Prometheus + Grafana (DEV scrape, 8 panels, 3 alerts) | ✅ Complete |
| S08 | Security audit (5 controls verified) | ✅ Complete |
| S09 | Disaster recovery (backup + restore + rollback) | ✅ Complete |
| S10 | Final documentation | ✅ This document |
| S05c | CD activation (self-hosted runner + RBAC) | ✅ Configured — runner pending approval |

### Remaining gaps (documented, not blocking)

- Self-hosted runner not yet registered — awaiting explicit approval (see docs/CICD.md §6)
- DEV `kubectl apply` via GitHub Actions pending runner registration
- PROD image lacks `/metrics` — PROD not monitored
- `s07-metrics` image local only — not in GHCR
- No Alertmanager / notification routing
- No NetworkPolicy objects
- No automated backup schedule
- Prometheus snapshot requires `--web.enable-admin-api` (not enabled; `--web.enable-lifecycle` enables reload/quit only)
- Terraform state local only (no remote backend)
