# AWS Monitoring Stack - Demo Runbook

**Date**: October 12, 2026  
**Pre-Defense**: October 13, 2026  
**Cluster**: AWS k3s (m6i.xlarge, 4 vCPU, 16 GiB RAM)  
**Namespace**: `triage-monitoring`  

---

## Overview

Lightweight Prometheus + Grafana monitoring stack deployed on AWS k3s to monitor DEV and PROD environments of the Multilingual Ticket Triage application.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    AWS k3s Cluster                       │
│                                                          │
│  ┌────────────────┐  ┌────────────────┐                │
│  │  triage-dev    │  │  triage-prod   │                │
│  │  /metrics:8000 │  │  /metrics:8000 │                │
│  └────────┬───────┘  └────────┬───────┘                │
│           │                    │                         │
│           │   scrape (30s)     │                         │
│           └──────────┬─────────┘                         │
│                      │                                   │
│           ┌──────────▼──────────┐                        │
│           │    Prometheus       │                        │
│           │    :9090            │                        │
│           │    10Gi storage     │                        │
│           │    7d retention     │                        │
│           └──────────┬──────────┘                        │
│                      │                                   │
│                      │ datasource                        │
│                      │                                   │
│           ┌──────────▼──────────┐                        │
│           │     Grafana         │                        │
│           │     :3000           │                        │
│           │     2Gi storage     │                        │
│           └─────────────────────┘                        │
│                                                          │
└─────────────────────────────────────────────────────────┘
```

## Quick Status Check

### 1. Verify All Components

```bash
# Check monitoring namespace
kubectl get all -n triage-monitoring

# Expected output:
# - prometheus pod: 1/1 Running
# - grafana pod: 1/1 Running
# - Services: prometheus:9090, grafana:3000
# - PVCs: prometheus-data (10Gi), grafana-data (2Gi) both Bound
```

### 2. Verify DEV and PROD Applications

```bash
# Check application health
kubectl get pods -n triage-dev
kubectl get pods -n triage-prod

# Both should show: 1/1 Running, no recent restarts
```

### 3. Check Resource Usage

```bash
# Node resources
kubectl top node

# Monitoring pod resources
kubectl top pods -n triage-monitoring

# Expected:
# - Node: ~110-120m CPU (3%), ~3.7-3.9Gi memory (23-24%)
# - Prometheus: ~0-5m CPU, ~20-50Mi memory
# - Grafana: ~1-2m CPU, ~60-80Mi memory
```

## Prometheus Verification

### Access Prometheus UI

```bash
# Start port-forward (run in background or separate terminal)
kubectl port-forward -n triage-monitoring svc/prometheus 9090:9090
```

Open: http://localhost:9090

### Check Targets

Navigate to: **Status > Targets**

Expected targets (all UP):
- `prometheus` - Self-monitoring
- `ticket-triage-dev` - DEV application
- `ticket-triage-prod` - PROD application

### Sample Queries

#### Request Rate by Environment
```promql
sum(rate(http_requests_total{route="/triage"}[5m])) by (environment)
```

#### Success Rate
```promql
sum(rate(http_requests_total{status_code="200"}[5m])) by (job) / 
sum(rate(http_requests_total[5m])) by (job)
```

#### Memory Usage
```promql
process_resident_memory_bytes{job=~"ticket-triage.*"}
```

#### P95 Latency
```promql
histogram_quantile(0.95, 
  rate(http_request_duration_seconds_bucket{route="/triage"}[5m])
)
```

## Grafana Verification

### Access Grafana UI

```bash
# Start port-forward (run in background or separate terminal)
kubectl port-forward -n triage-monitoring svc/grafana 3000:3000
```

Open: http://localhost:3000

**Login Credentials**:
- Username: `admin`
- Password: [Set in k8s/aws-monitoring/grafana/secret.yaml - use secure password]

### Navigate to Dashboard

1. Click **Dashboards** in the left sidebar
2. Select **Ticket Triage — AWS DEV vs PROD**

### Dashboard Panels

The dashboard displays 11 panels comparing DEV and PROD:

1. **DEV Availability** - Target health (UP/DOWN)
2. **PROD Availability** - Target health (UP/DOWN)
3. **DEV Total Requests** - Cumulative request count
4. **PROD Total Requests** - Cumulative request count
5. **HTTP Request Rate** - Requests per second (DEV vs PROD)
6. **HTTP Error Rates** - 4xx and 5xx responses
7. **Response Latency p50** - Median response time
8. **Response Latency p95** - 95th percentile response time
9. **Process Memory** - Resident memory usage
10. **Process CPU** - CPU utilization rate
11. **Prometheus Scrape Health** - All targets status

## Live Demo: Generate Observable Traffic

### Submit Test Tickets

#### DEV Environment
```bash
kubectl exec -n triage-dev deploy/ticket-triage -- \
  curl -s -X POST http://localhost:8000/triage \
  -H "Content-Type: application/json" \
  -d '{
    "ticket_id": "DEMO-DEV-001",
    "subject": "Test Request for Demo",
    "body": "This ticket demonstrates metrics collection in DEV environment"
  }' | python3 -m json.tool
```

#### PROD Environment
```bash
kubectl exec -n triage-prod deploy/ticket-triage -- \
  curl -s -X POST http://localhost:8000/triage \
  -H "Content-Type: application/json" \
  -d '{
    "ticket_id": "DEMO-PROD-001",
    "subject": "Production Monitoring Verification",
    "body": "This ticket verifies production monitoring and alerting"
  }' | python3 -m json.tool
```

### Observe Metrics in Real-Time

**In Prometheus** (http://localhost:9090):
```promql
# Total triage requests by environment
http_requests_total{route="/triage",status_code="200"}
```

**In Grafana Dashboard**:
- **DEV Total Requests** and **PROD Total Requests** should increment
- **HTTP Request Rate** chart shows new request spikes
- **Response Latency** panels update with request processing time

Wait 30 seconds for scrape interval, then refresh Grafana dashboard.

## Deployment Summary

### Resources Created

| Resource Type | Name | Specifications |
|--------------|------|----------------|
| Namespace | triage-monitoring | Isolated monitoring namespace |
| PVC | prometheus-data | 10Gi, local-path storage |
| PVC | grafana-data | 2Gi, local-path storage |
| ServiceAccount | triage-prometheus | Prometheus identity |
| ServiceAccount | triage-grafana | Grafana identity |
| Secret | grafana-credentials | Admin credentials |
| ConfigMap | prometheus-config | Scrape configuration |
| ConfigMap | prometheus-rules | Alert rules |
| ConfigMap | grafana-datasources | Prometheus datasource |
| ConfigMap | grafana-dashboards | DEV vs PROD dashboard |
| Deployment | prometheus | 1 replica, 200m CPU, 512Mi memory |
| Deployment | grafana | 1 replica, 100m CPU, 256Mi memory |
| Service | prometheus | ClusterIP:9090 |
| Service | grafana | ClusterIP:3000 |

### Current Metrics (as of deployment)

**Scrape Targets**: 3 (all UP)
- prometheus (self-monitoring)
- ticket-triage-dev
- ticket-triage-prod

**Request Counters**:
- DEV: 10+ successful requests
- PROD: 4+ successful requests

**Latency**:
- DEV p95: ~0.945s
- PROD p95: ~0.925s

**Memory Usage**:
- DEV: ~2.6 GB
- PROD: ~2.4 GB

**Monitoring Resources**:
- Prometheus: 0-5m CPU, 19-50 MB memory
- Grafana: 1-2m CPU, 65-80 MB memory
- Total monitoring overhead: ~300m CPU requests, ~768Mi memory requests

### Security Features

- ✅ All services are ClusterIP only (no external exposure)
- ✅ Access requires `kubectl port-forward`
- ✅ Grafana credentials stored in Kubernetes Secret
- ✅ No anonymous access enabled
- ✅ Non-root containers with dropped capabilities
- ✅ Read-only root filesystems where possible
- ✅ Resource limits prevent resource exhaustion

## Deployment Commands Reference

### Initial Deployment

```bash
# Navigate to manifests directory
cd /home/ubuntu/workspaces/multilingual-ticket-triage-devops/k8s/aws-monitoring

# Create namespace
kubectl apply -f namespace.yaml

# Deploy all resources
kubectl apply -k .

# Wait for pods to be ready
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=prometheus -n triage-monitoring --timeout=120s
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=grafana -n triage-monitoring --timeout=120s
```

### Update Dashboard

```bash
# Edit dashboard JSON
vi k8s/aws-monitoring/grafana/dashboard-configmap.yaml

# Rebuild ConfigMap with updated dashboard
cd k8s/aws-monitoring/grafana
cat triage-comparison.json | sed 's/^/    /' > dashboard-configmap.yaml

# Apply changes
kubectl apply -f dashboard-configmap.yaml

# Restart Grafana to pick up changes
kubectl rollout restart deployment/grafana -n triage-monitoring
```

### Scale Down/Up

```bash
# Scale down (preserve data)
kubectl scale deployment/prometheus --replicas=0 -n triage-monitoring
kubectl scale deployment/grafana --replicas=0 -n triage-monitoring

# Scale back up
kubectl scale deployment/prometheus --replicas=1 -n triage-monitoring
kubectl scale deployment/grafana --replicas=1 -n triage-monitoring
```

## Troubleshooting

### Pods Not Ready

```bash
# Check pod status
kubectl describe pod -n triage-monitoring <pod-name>

# Check logs
kubectl logs -n triage-monitoring <pod-name>

# Common issues:
# - Image pull errors: Check image name and availability
# - PVC binding: Check storage class and provisioner
# - Resource limits: Check node capacity
```

### Targets Down in Prometheus

```bash
# Verify application is running
kubectl get pods -n triage-dev
kubectl get pods -n triage-prod

# Test metrics endpoint directly
kubectl exec -n triage-dev deploy/ticket-triage -- curl http://localhost:8000/metrics

# Check DNS resolution
kubectl exec -n triage-monitoring deploy/prometheus -- \
  nslookup ticket-triage.triage-dev.svc.cluster.local

# Check Prometheus logs
kubectl logs -n triage-monitoring deploy/prometheus | grep -i error
```

### Grafana Dashboard Not Showing Data

```bash
# Verify datasource connection
kubectl exec -n triage-monitoring deploy/grafana -- \
  curl -s http://localhost:3000/api/datasources | python3 -m json.tool

# Test Prometheus query from Grafana pod
kubectl exec -n triage-monitoring deploy/grafana -- \
  curl -s http://prometheus.triage-monitoring.svc.cluster.local:9090/api/v1/query?query=up

# Check Grafana logs
kubectl logs -n triage-monitoring deploy/grafana | tail -50
```

### High Resource Usage

```bash
# Check actual usage
kubectl top pods -n triage-monitoring
kubectl top node

# Adjust retention if needed (edit deployment)
kubectl edit deployment/prometheus -n triage-monitoring
# Change: --storage.tsdb.retention.time=7d to --storage.tsdb.retention.time=3d

# Reduce scrape frequency (edit ConfigMap)
kubectl edit configmap/prometheus-config -n triage-monitoring
# Change: scrape_interval: 30s to scrape_interval: 60s
```

## Validation Checklist for Demo

- [ ] Monitoring namespace exists and all pods are Running
- [ ] Prometheus has 3 targets UP (prometheus, dev, prod)
- [ ] Grafana login works with credentials
- [ ] Dashboard loads and displays data
- [ ] DEV and PROD applications still healthy with no restarts
- [ ] Submit test ticket to DEV and observe metrics update
- [ ] Submit test ticket to PROD and observe metrics update
- [ ] Request counters increase in dashboard
- [ ] Latency metrics show realistic values (0.5-1.5s)
- [ ] Memory and CPU metrics display correctly
- [ ] No errors in pod logs
- [ ] Total cluster CPU < 5%, memory < 30%
- [ ] Monitoring overhead < 10% of node resources

## Key Demo Talking Points

1. **Lightweight Stack**: Only ~300m CPU and ~768Mi memory requested
2. **Production-Ready**: Non-root containers, resource limits, security contexts
3. **Real-Time Monitoring**: 30-second scrape interval for near real-time data
4. **DEV vs PROD Comparison**: Single dashboard for environment comparison
5. **7-Day Retention**: Sufficient for development and debugging
6. **No External Exposure**: ClusterIP services, port-forward access only
7. **Persistent Storage**: Data survives pod restarts
8. **Alert Rules**: Basic alerting for target down and high error rate
9. **Observable Metrics**: Request rate, latency percentiles, error rate, resource usage
10. **Zero Application Impact**: No changes to DEV/PROD applications required

## Follow-Up Improvements

### Post-Demo Enhancements
- [ ] Add Alertmanager for active alerting
- [ ] Configure Slack/email notifications
- [ ] Add custom recording rules for aggregations
- [ ] Implement Grafana Loki for log aggregation
- [ ] Add kube-state-metrics for cluster-level metrics
- [ ] Configure Prometheus remote storage for long-term retention
- [ ] Create additional dashboards for AWS/k3s metrics
- [ ] Implement Prometheus ServiceMonitor CRDs
- [ ] Add Grafana authentication integration (OAuth, LDAP)
- [ ] Deploy node-exporter for host-level metrics

### Terraform Migration
- [ ] Install Terraform on AWS instance
- [ ] Initialize Terraform configuration
- [ ] Import existing resources to Terraform state
- [ ] Enable remote state backend (S3 + DynamoDB)
- [ ] Implement CI/CD for infrastructure changes

---

**Note**: This monitoring stack was deployed on October 12, 2026, for the DevOps pre-defense. All components are operational and demo-ready.
