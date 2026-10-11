# Demo Guide — Multilingual Ticket Triage DevOps

**Project:** Liora graduation project  
**Date:** 2026-10-11  
**Branch:** `feat/s06-terraform`  
**Cluster context:** `docker-desktop` (kind)

---

## Prerequisites

Before starting, verify the following:

```bash
# Kubernetes cluster is running and all pods are ready
kubectl --context docker-desktop get pods -A | grep triage

# Expected output (all 1/1 Running):
# triage-dev         ticket-triage-<hash>   1/1     Running
# triage-prod        ticket-triage-<hash>   1/1     Running
# triage-monitoring  grafana-<hash>         1/1     Running
# triage-monitoring  prometheus-<hash>      1/1     Running
```

```bash
# Open four port-forward terminals and leave them running:

# Terminal 1 — DEV API
kubectl --context docker-desktop port-forward svc/ticket-triage 18000:8000 -n triage-dev

# Terminal 2 — Prometheus
kubectl --context docker-desktop port-forward svc/prometheus 19090:9090 -n triage-monitoring

# Terminal 3 — Grafana
kubectl --context docker-desktop port-forward svc/grafana 13000:3000 -n triage-monitoring
```

---

## Demo Step 1 — GitHub Actions (CI/CD)

**What to show:** The CI pipeline runs tests, builds the Docker image, runs a Trivy security scan, and publishes to GHCR.

Navigate to the GitHub repository → **Actions** tab → **CI — Test · Build · Scan · Publish**.

Point out:
- Job **Python Tests**: `pytest tests/ -m "not slow"` — 744 tests, ~25 seconds
- Job **Build · Scan · Push**:
  - Trivy diagnostic table scan (non-blocking, shows CVE details in log)
  - Trivy blocking scan: `CRITICAL,HIGH`, `exit-code: 1`, `ignore-unfixed: true`
  - GHCR push gated on `steps.trivy.outcome == 'success'`
  - Immutable tag: `sha-<40-char-sha>`

Navigate to the **Security** tab → **Code scanning** to show the SARIF upload.

**S05c update — CD gap resolved (runner pending approval):**
The `deploy-dev` workflow has been updated with a real `kubectl apply` step.
It runs on a **self-hosted runner** (`triage-dev-deployer` label) co-located
on the WSL2 host, which can reach `127.0.0.1:50060` (kind cluster API).

The runner uses a dedicated `cicd-deployer` Kubernetes ServiceAccount with a
**least-privilege Role scoped to triage-dev only** (no cluster-admin, no
cross-namespace access, no secret reads).

The runner is **not yet registered** — the host owner must approve installation
(see `docs/CICD.md §6`).  Once registered, the full CD pipeline including
`kubectl apply`, rollout verification, and smoke-test is active.

The `deploy-prod` workflow **remains a dry-run by design** — PROD is never
modified by automation.

---

## Demo Step 2 — Kubernetes Workloads

```bash
# Show all four pods running
kubectl --context docker-desktop get pods -A -l 'app in (ticket-triage)' --show-labels
kubectl --context docker-desktop get pods -n triage-monitoring

# Show the DEV image tag (s07-metrics = instrumented with /metrics)
kubectl --context docker-desktop get deployment ticket-triage -n triage-dev \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
# → ticket-triage-api:s07-metrics

# Show the PROD image tag (latest = older, no /metrics)
kubectl --context docker-desktop get deployment ticket-triage -n triage-prod \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
# → ticket-triage-api:latest

# Show security context (non-root, privilege escalation denied, capabilities dropped)
kubectl --context docker-desktop get pod -n triage-dev \
  -o jsonpath='{.items[0].spec.securityContext}' | python3 -m json.tool

# Show the DEV health endpoints
curl -s http://localhost:18000/health
# → {"status":"ok"}

curl -s http://localhost:18000/ready
# → {"ready":true,"agent_initialized":true}
```

---

## Demo Step 3 — Real Triage Request (AI Pipeline End-to-End)

```bash
# POST a billing ticket through the full AI pipeline
curl -s -X POST http://localhost:18000/triage \
  -H 'Content-Type: application/json' \
  -d '{
    "ticket_id": "demo-001",
    "subject": "Double charge on my invoice",
    "body": "I was charged twice for my insurance premium this month. Please refund the duplicate payment immediately."
  }' | python3 -m json.tool
```

Expected response fields:
- `topic`: `"Billing / Payment"`
- `urgency`: `"High"` or `"Medium"`
- `next_action`: `"forward_to_billing_team"` or `"escalate_to_human_supervisor"`
- `confidence`: floating-point value (e.g. `0.99`)
- `missing_info`: `false`
- `action_result.action_status`: `"simulated"`

**What to explain:** The pipeline embed the ticket using `intfloat/multilingual-e5-large`, retrieves the 5 most similar historical tickets from LanceDB (3,206 reference vectors), passes the ticket + neighbor context to `llama3.2:3b` via Ollama, validates the output deterministically, and routes to an action via business rules. The action executor is simulated — no real external system is called.

---

## Demo Step 4 — Prometheus Metrics

```bash
# Verify scrape targets (DEV should be state=up)
curl -s http://localhost:19090/api/v1/targets | python3 -c "
import sys, json
d = json.load(sys.stdin)
for tg in d['data']['activeTargets']:
    print(tg['labels'].get('job'), tg['health'], tg['lastScrape'][:19])
"
# Expected:
# prometheus   up   2026-10-11T...
# ticket-triage-dev   up   2026-10-11T...

# Show real application metrics
curl -s http://localhost:19090/api/v1/query?query=triage_requests_total
curl -s http://localhost:19090/api/v1/query?query=agent_ready

# Verify alert rules are loaded (all inactive = system healthy)
curl -s http://localhost:19090/api/v1/rules | python3 -c "
import sys, json
d = json.load(sys.stdin)
for g in d['data']['groups']:
    for r in g['rules']:
        print(r['name'], '—', r.get('state','n/a'))
"
# Expected:
# TicketTriageDevDown — inactive
# TicketTriageHighErrorRate — inactive
# TicketTriageFailuresDetected — inactive
```

Open `http://localhost:19090/targets` in a browser to show the Targets page visually.

**Key limitation to state:** PROD is not scraped. The PROD pod runs `ticket-triage-api:latest` which was built before the `/metrics` endpoint was added. The `s07-metrics` image used in DEV is locally built and has not been published to GHCR.

---

## Demo Step 5 — Grafana Dashboard

1. Open `http://localhost:13000` → log in with `admin` / (password set in `grafana-credentials` K8s Secret)
2. Navigate to **Dashboards → Ticket Triage → Ticket Triage — Overview**

Point out the 8 panels:
1. **DEV Availability** (`up` stat — green)
2. **Agent Ready** (`agent_ready` — green)
3. **Triage Requests total** (stat with sparkline)
4. **Triage Failures total** (stat, red if > 0)
5. **HTTP Request Throughput** (time-series, per route)
6. **HTTP 5xx Error Rate** (time-series)
7. **HTTP Latency p50/p95/p99 for `/triage`** (time-series)
8. **Triage Processing Duration p50/p95** (time-series)

```bash
# Verify datasource health from CLI
curl -s -u admin:<password> \
  http://localhost:13000/api/datasources/uid/triage-prometheus/health \
  | python3 -m json.tool
# Expected: {"status":"OK","message":"Successfully queried the Prometheus API."}
```

---

## Demo Step 6 — Terraform Plan

```bash
# Show the 5 Terraform-managed resources and confirm no changes needed
terraform -chdir=terraform plan

# Expected last line:
# No changes. Your infrastructure matches the configuration.

# Show the resources currently managed
terraform -chdir=terraform show | grep -E 'resource|name\s*='
```

The 5 resources managed by Terraform:
- `kubernetes_namespace_v1.triage_monitoring` → namespace `triage-monitoring`
- `kubernetes_persistent_volume_claim_v1.prometheus_data` → PVC `prometheus-data` (1Gi)
- `kubernetes_persistent_volume_claim_v1.grafana_data` → PVC `grafana-data` (1Gi)
- `kubernetes_service_account_v1.triage_prometheus` → SA `triage-prometheus`
- `kubernetes_service_account_v1.triage_grafana` → SA `triage-grafana`

**What to explain:** Terraform manages the monitoring *infrastructure* (namespace, storage, identity). The application deployments and ConfigMaps are managed by Kustomize. This separation means Terraform can be destroyed/recreated without affecting the application namespaces.

---

## Demo Step 7 — Disaster Recovery Verification

```bash
# Show the latest backup exists
ls -lh backups/20261011T105508Z/

# Verify SHA-256 integrity of all 42 backup files
bash scripts/dr/verify.sh backups/20261011T105508Z
# Expected: RESULT: ALL CHECKS PASSED

# Show backup metadata
cat backups/20261011T105508Z/BACKUP_META.txt
# Expected: timestamp, sources, lancedb_rows_at_backup: 3206

# Show DuckDB row counts in the backup
python3 - <<'EOF'
import duckdb, os
base = "backups/20261011T105508Z/duckdb"
for f in sorted(os.listdir(base)):
    if f.endswith(".parquet"):
        count = duckdb.sql(f"SELECT count(*) FROM read_parquet('{base}/{f}')").fetchone()[0]
        print(f"{f}: {count} rows")
EOF
# Expected:
# historical_tickets.parquet: 4000 rows
# triage_confusion_matrix.parquet: 1461 rows
# triage_metrics.parquet: 1533 rows
# triage_predictions.parquet: 4676 rows
# triage_runs.parquet: 59 rows
```

**Key limitation to state:** The rollback procedure was demonstrated on an isolated nginx deployment in the `triage-dr-test` namespace (see `docs/DISASTER_RECOVERY.md`). The existing DEV, PROD, and monitoring workloads were not modified during the test. Prometheus/Grafana metrics history is ephemeral — a Prometheus TSDB snapshot requires `--web.enable-admin-api` (not currently enabled; the present `--web.enable-lifecycle` flag enables config-reload and graceful-quit only).

---

## Demo Order Summary

| Step | What it shows | Duration |
|---|---|---|
| 1 | GitHub Actions — CI stages, Trivy gate, GHCR publish | ~3 min |
| 2 | kubectl — 4 pods running, security context, health endpoints | ~2 min |
| 3 | POST /triage — end-to-end AI pipeline (live result) | ~1–3 min |
| 4 | Prometheus — targets page, real metrics, alert rules | ~2 min |
| 5 | Grafana — 8-panel dashboard, datasource health | ~2 min |
| 6 | terraform plan — 5 resources, no changes | ~1 min |
| 7 | DR verify — 42 SHA-256 checksums, Parquet row counts | ~2 min |
| **Total** | | **~13–16 min** |
