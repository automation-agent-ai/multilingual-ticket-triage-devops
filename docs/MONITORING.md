# Sprint S07 — Prometheus & Grafana Monitoring

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  namespace: triage-monitoring  (Terraform-managed)              │
│                                                                  │
│  ┌─────────────────┐    scrape /metrics    ┌────────────────┐  │
│  │  Prometheus      │◄──────────────────── │ ticket-triage  │  │
│  │  :9090          │                       │ (triage-dev)   │  │
│  │  PVC: 1Gi       │                       │ :8000          │  │
│  └────────┬────────┘                       └────────────────┘  │
│           │ data source                                          │
│  ┌────────▼────────┐                                            │
│  │  Grafana         │                                            │
│  │  :3000          │                                            │
│  │  PVC: 1Gi       │                                            │
│  └─────────────────┘                                            │
└─────────────────────────────────────────────────────────────────┘
```

### Resource ownership

| Resource | Kind | Owner |
|---|---|---|
| `triage-monitoring` | Namespace | **Terraform (S06)** |
| `prometheus-data` | PVC | **Terraform (S06)** |
| `grafana-data` | PVC | **Terraform (S06)** |
| `triage-prometheus` | ServiceAccount | **Terraform (S06)** |
| `triage-grafana` | ServiceAccount | **Terraform (S06)** |
| `prometheus` | Deployment | **Kustomize (S07)** |
| `grafana` | Deployment | **Kustomize (S07)** |
| ConfigMaps, Services | Various | **Kustomize (S07)** |

---

## Kubernetes resources

### Prometheus

| Resource | Name |
|---|---|
| Deployment | `prometheus` |
| Service | `prometheus` (ClusterIP :9090) |
| ConfigMap | `prometheus-config` (scrape config) |
| ConfigMap | `prometheus-rules` (alert rules) |
| PVC | `prometheus-data` 1Gi (Terraform) |
| ServiceAccount | `triage-prometheus` (Terraform) |

### Grafana

| Resource | Name |
|---|---|
| Deployment | `grafana` |
| Service | `grafana` (ClusterIP :3000) |
| ConfigMap | `grafana-datasources` |
| ConfigMap | `grafana-dashboard-provider` |
| ConfigMap | `grafana-dashboards` |
| Secret | `grafana-credentials` (kubectl-created, not in git) |
| PVC | `grafana-data` 1Gi (Terraform) |
| ServiceAccount | `triage-grafana` (Terraform) |

---

## Terraform dependencies

This sprint reuses the following resources provisioned by Sprint S06 Terraform:

```bash
# Verify Terraform-managed resources still exist and are managed
terraform -chdir=terraform plan
# Expected: No changes. Your infrastructure matches the configuration.
```

Do NOT re-create or import these resources via Kustomize or Helm.

---

## Application metrics (`api/prom_metrics.py`)

### HTTP metrics

| Metric | Type | Labels | Description |
|---|---|---|---|
| `http_requests_total` | Counter | `method`, `route`, `status_code` | Total HTTP requests by route template and status |
| `http_request_duration_seconds` | Histogram | `method`, `route` | HTTP request duration in seconds |

### Triage metrics

| Metric | Type | Labels | Description |
|---|---|---|---|
| `triage_requests_total` | Counter | — | Total POST /triage calls |
| `triage_failures_total` | Counter | — | Total POST /triage that returned 5xx |
| `triage_duration_seconds` | Histogram | — | End-to-end triage pipeline duration |
| `agent_ready` | Gauge | — | 1=agent initialized, 0=startup failed |

**Safety**: `/metrics` scrapes are excluded from HTTP counters. Labels use only
templated route paths, HTTP methods, and numeric status codes — never ticket IDs,
customer names, email addresses, or any user-supplied strings.

---

## Deployment commands

### Prerequisites

Terraform-managed resources must exist (Sprint S06):
```bash
terraform -chdir=terraform plan
# → No changes.
```

### Deploy monitoring stack

```bash
# Create Grafana credentials secret (once per cluster)
kubectl --context docker-desktop create secret generic grafana-credentials \
  -n triage-monitoring \
  --from-literal=admin-user=admin \
  --from-literal=admin-password=<CHOOSE_A_STRONG_PASSWORD>

# Apply monitoring stack
kubectl --context docker-desktop apply -k monitoring/

# Wait for rollout
kubectl --context docker-desktop rollout status deployment/prometheus -n triage-monitoring
kubectl --context docker-desktop rollout status deployment/grafana -n triage-monitoring
```

### Update DEV to s07-metrics image

```bash
# Load image into the kind node containerd (required for imagePullPolicy: Never)
docker build -t ticket-triage-api:s07-metrics .
docker save ticket-triage-api:s07-metrics | \
  docker exec -i desktop-control-plane ctr -n k8s.io images import -

# Apply DEV overlay (kustomization.yaml already references s07-metrics tag)
kubectl --context docker-desktop apply -k k8s/overlays/dev/
kubectl --context docker-desktop rollout status deployment/ticket-triage -n triage-dev
```

---

## Port-forward commands

Run these in separate terminal tabs and leave them running:

```bash
# Prometheus — http://localhost:19090
kubectl --context docker-desktop port-forward svc/prometheus 19090:9090 -n triage-monitoring

# Grafana — http://localhost:13000
kubectl --context docker-desktop port-forward svc/grafana 13000:3000 -n triage-monitoring

# DEV API (optional)
kubectl --context docker-desktop port-forward svc/ticket-triage 18000:8000 -n triage-dev
```

---

## Prometheus scrape targets

| Job | Target | Metrics path | Notes |
|---|---|---|---|
| `prometheus` | `localhost:9090` | `/metrics` | Self-monitoring |
| `ticket-triage-dev` | `ticket-triage.triage-dev.svc.cluster.local:8000` | `/metrics` | DEV instrumented (s07-metrics image) |

**PROD**: Not scraped yet. The `triage-prod` namespace still runs `ticket-triage-api:latest`
which does not expose `/metrics`. Uncomment the PROD scrape block in
`monitoring/prometheus/configmap.yaml` after updating the PROD image.

### Verify scrape status

```bash
# Via Prometheus API
curl http://localhost:19090/api/v1/targets | python3 -m json.tool

# Via Prometheus UI
open http://localhost:19090/targets
```

---

## Alert rules

File: `monitoring/prometheus/alert-rules-configmap.yaml`

| Alert | Condition | Duration | Severity |
|---|---|---|---|
| `TicketTriageDevDown` | `up{job="ticket-triage-dev"} == 0` | 2m | critical |
| `TicketTriageHighErrorRate` | >10% of requests return 5xx | 2m | warning |
| `TicketTriageFailuresDetected` | `triage_failures_total` rate > 0 | 2m | warning |

**Note**: These alerts fire in Prometheus (visible at `http://localhost:19090/alerts`).
No notification channel (PagerDuty, Slack, email) is configured — this is a
local school project. A real production deployment would add an Alertmanager with
routing rules.

```bash
# Verify rules are loaded
curl http://localhost:19090/api/v1/rules | python3 -c "
import sys, json; d = json.load(sys.stdin)
for g in d['data']['groups']:
    for r in g['rules']:
        print(r['name'], r.get('state','n/a'))
"
```

---

## Grafana datasource and dashboard

### Datasource

- **Name**: Prometheus
- **UID**: `triage-prometheus`
- **URL**: `http://prometheus.triage-monitoring.svc.cluster.local:9090`
- **Type**: provisioned from ConfigMap `grafana-datasources` (cannot be deleted via UI)

### Dashboard: "Ticket Triage — Overview"

- **UID**: `triage-overview`
- **Folder**: Ticket Triage
- **Panels**:
  1. DEV Availability (`up` stat, green/red)
  2. Agent Ready (`agent_ready` stat, green/red)
  3. Triage Requests total (stat with sparkline)
  4. Triage Failures total (stat, red if >0)
  5. HTTP Request Throughput (time-series, per route)
  6. HTTP 5xx Error Rate (time-series)
  7. HTTP Latency p50/p95/p99 for `/triage` (time-series)
  8. Triage Processing Duration p50/p95 (time-series)

Access: `http://localhost:13000` → login with `admin` / (password set in secret)

### Verify datasource health

```bash
curl -s -u admin:<password> \
  http://localhost:13000/api/datasources/uid/triage-prometheus/health | python3 -m json.tool
# Expected: {"status":"OK","message":"Successfully queried the Prometheus API."}
```

---

## Storage setup

Both PVCs are provisioned by Terraform (Sprint S06) using the `standard`
StorageClass (`rancher.io/local-path`, `WaitForFirstConsumer`).

They were `Pending` after `terraform apply` and transitioned to `Bound` when
the Prometheus and Grafana Pods were scheduled in Sprint S07.

```bash
kubectl --context docker-desktop -n triage-monitoring get pvc
# NAME               STATUS   VOLUME                                     CAPACITY
# grafana-data       Bound    pvc-...                                    1Gi
# prometheus-data    Bound    pvc-...                                    1Gi
```

---

## Verification results (Sprint S07 — 2026-10-11)

| Check | Result |
|---|---|
| Prometheus Pod Running/Ready | ✅ 1/1 |
| Grafana Pod Running/Ready | ✅ 1/1 |
| PVC prometheus-data | ✅ Bound |
| PVC grafana-data | ✅ Bound |
| Prometheus `/-/ready` | ✅ 200 OK |
| Grafana `/api/health` | ✅ OK, v11.4.0 |
| Prometheus datasource connected | ✅ "Successfully queried the Prometheus API." |
| Dashboard provisioned | ✅ "Ticket Triage — Overview" |
| DEV scrape target | ✅ state=up |
| `triage_requests_total` in Prometheus | ✅ value=1 (after E2E test) |
| `agent_ready` in Prometheus | ✅ value=1 |
| Alert rules loaded | ✅ 3 rules, state=inactive (healthy) |
| DEV `/health` | ✅ 200 `{"status":"ok"}` |
| DEV `/ready` | ✅ 200 `{"ready":true}` |
| DEV `/triage` E2E (billing ticket) | ✅ 200, confidence=0.99, next_action=forward_to_billing_team |
| PROD pod status | ✅ 1/1 Running, unchanged |
| Unit tests | ✅ 744 passed |

---

## Known limitations

1. **PROD metrics not available**: `triage-prod` runs `ticket-triage-api:latest`
   (no `/metrics`). Update PROD image to `s07-metrics` and uncomment the PROD
   scrape block in `prometheus/configmap.yaml` to enable PROD monitoring.

2. **No Alertmanager**: Alert rules fire in Prometheus UI only. No notifications
   are sent. Add Alertmanager + routing rules for production use.

3. **Local Terraform state**: `terraform/terraform.tfstate` is on disk; not backed
   up. A remote backend is required for production.

4. **Single-node storage**: `rancher.io/local-path` volumes are tied to the
   `desktop-control-plane` node. Data does not survive a cluster reset.

5. **PROD approval pending**: PROD was NOT updated during this sprint. See
   section "Approving PROD update" below.

---

## Approving PROD update

After stakeholder approval, run:

```bash
# Load image into kind node
docker save ticket-triage-api:s07-metrics | \
  docker exec -i desktop-control-plane ctr -n k8s.io images import -

# Update PROD kustomization to reference s07-metrics
# (edit k8s/overlays/prod/kustomization.yaml: newTag: s07-metrics)

# Deploy PROD
kubectl --context docker-desktop apply -k k8s/overlays/prod/
kubectl --context docker-desktop rollout status deployment/ticket-triage -n triage-prod

# Verify PROD metrics endpoint
kubectl --context docker-desktop port-forward svc/ticket-triage 18001:8000 -n triage-prod
curl http://localhost:18001/metrics

# Uncomment PROD scrape target in monitoring/prometheus/configmap.yaml
# and re-apply the monitoring stack
kubectl --context docker-desktop apply -k monitoring/
```

---

## Screenshots to capture for Liora

1. **Prometheus Targets page** — `http://localhost:19090/targets`
   - Shows `ticket-triage-dev` as UP
2. **Prometheus Alerts page** — `http://localhost:19090/alerts`
   - Shows 3 rules, all Inactive (system healthy)
3. **Grafana Dashboard** — `http://localhost:13000/d/triage-overview`
   - Shows DEV Availability=UP, Agent Ready=READY, triage counts
4. **Grafana Datasource** — Settings → Data sources → Prometheus → Test
   - "Data source is working"
5. **kubectl get pods** output showing all 4 pods Running/Ready across all namespaces

---

## Safe cleanup (all sprints complete)

```bash
# Remove monitoring Kustomize resources
kubectl --context docker-desktop delete -k monitoring/

# Remove Grafana secret
kubectl --context docker-desktop delete secret grafana-credentials -n triage-monitoring

# Remove Terraform-managed infrastructure (namespace, PVCs, SAs)
terraform -chdir=terraform destroy

# Restore DEV to latest image
# (edit k8s/overlays/dev/kustomization.yaml: newTag: latest)
kubectl --context docker-desktop apply -k k8s/overlays/dev/
```
