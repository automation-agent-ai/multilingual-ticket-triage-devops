# AWS Monitoring Deployment Log

**Date**: October 12, 2026, 21:13 UTC  
**Operator**: Cursor AI Agent  
**Cluster**: AWS k3s (ip-172-31-43-47)  
**Duration**: ~3 minutes  

## Pre-Deployment State

**Cluster Info**:
- Node: m6i.xlarge (4 vCPU, 16 GiB RAM)
- k3s version: v1.36.5+k3s1
- Storage class: local-path
- CPU usage: 104m (2%)
- Memory usage: 3542Mi (22%)

**Existing Applications**:
- triage-dev: 1/1 Running, 500m CPU / 2Gi memory requests
- triage-prod: 1/1 Running, 500m CPU / 2Gi memory requests
- Total app requests: 1000m CPU, 4Gi memory

**Available Resources**:
- CPU: ~3000m available
- Memory: ~12Gi available

## Deployment Steps

### 1. Created Kubernetes Manifests (21:13:45)

Generated production-ready Kubernetes YAML:
- namespace.yaml
- prometheus/: 7 files (PVC, ServiceAccount, ConfigMaps, Deployment, Service)
- grafana/: 8 files (PVC, ServiceAccount, Secret, ConfigMaps, Deployment, Service)
- kustomization.yaml

**Terraform Alternative**: Also created Terraform configuration in `terraform/aws-monitoring/` for future use (Terraform not installed on AWS system).

### 2. Applied Resources (21:14:12)

```bash
kubectl apply -f namespace.yaml
kubectl apply -k .
```

**Results**:
- Namespace created: triage-monitoring
- ServiceAccounts created: 2
- ConfigMaps created: 5
- Secret created: 1
- Services created: 2
- PVCs created: 2
- Deployments created: 2

### 3. PVC Provisioning (21:14:13 - 21:14:17)

**prometheus-data**: 
- Size: 10Gi
- Volume: pvc-6ea56722-08e8-45d6-b8c3-4f2c9ba8d04d
- Provisioned in: 4 seconds

**grafana-data**:
- Size: 2Gi
- Volume: pvc-80733fa6-3e83-4f96-8665-66be1e8d0f40
- Provisioned in: 4 seconds

### 4. Image Pull (21:14:17 - 21:14:21)

**Prometheus**:
- Image: prom/prometheus:v3.1.0
- Size: 116.8 MB
- Pull time: 3.7 seconds

**Grafana**:
- Image: grafana/grafana:11.4.0
- Size: 132.8 MB
- Pull time: 4.8 seconds

### 5. Container Start (21:14:21 - 21:14:22)

Both containers started successfully within 1 second of image pull completion.

### 6. Readiness Checks (21:14:22 - 21:14:38)

**Prometheus**:
- Initial delay: 10 seconds
- Ready at: 21:14:32 (10 seconds after start)

**Grafana**:
- Initial delay: 15 seconds
- Ready at: 21:14:38 (16 seconds after start)

### 7. Scrape Verification (21:14:40)

**Prometheus Targets**:
- prometheus: UP (self-monitoring)
- ticket-triage-dev: UP (scraped successfully)
- ticket-triage-prod: UP (scraped successfully)

First successful scrapes within 2 seconds of readiness.

## Post-Deployment State

**Monitoring Resources**:
- Prometheus: 0m CPU, 19Mi memory
- Grafana: 1m CPU, 65Mi memory
- Total: 1m CPU, 84Mi memory actual usage

**Cluster State**:
- CPU usage: 114m (2%) - increased by 10m
- Memory usage: 3729Mi (23%) - increased by 187Mi
- No application restarts
- All pods healthy

**Metrics Collected**:
- DEV successful requests: 10
- PROD successful requests: 4
- DEV p95 latency: 0.945s
- PROD p95 latency: 0.925s
- DEV memory: 2616 MB
- PROD memory: 2364 MB

## Services

**Prometheus**:
- ClusterIP: 10.43.197.20
- Port: 9090
- Endpoint: 10.42.0.15:9090

**Grafana**:
- ClusterIP: 10.43.163.173
- Port: 3000
- Endpoint: 10.42.0.16:3000

## Dashboard

**Name**: Ticket Triage — AWS DEV vs PROD  
**UID**: triage-aws-comparison  
**Panels**: 11  
**Refresh**: 30s  

**Metrics Displayed**:
1. DEV/PROD availability
2. Total request counts
3. Request rate comparison
4. Error rate comparison
5. Latency percentiles (p50, p95)
6. Memory usage
7. CPU usage
8. Scrape health

## Configuration

**Prometheus**:
- Scrape interval: 30s
- Retention: 7 days
- External labels: cluster=aws-k3s, region=us-east-1

**Grafana**:
- Admin user: admin
- Password: [Set via secret.yaml - use secure password in production]
- Anonymous access: disabled
- Analytics: disabled

## Security

✅ Non-root containers  
✅ Dropped capabilities  
✅ Resource limits enforced  
✅ Credentials in Secret  
✅ ClusterIP services only  
✅ No external exposure  

## Validation Tests

### Test 1: Submit Ticket to DEV
- Request: POST /triage (MON-001)
- Response: 200 OK
- Latency: ~0.8s
- Metric update: Confirmed in Prometheus

### Test 2: Submit Ticket to PROD
- Request: POST /triage (MON-002)
- Response: 200 OK
- Latency: ~0.9s
- Metric update: Confirmed in Prometheus

### Test 3: Prometheus Query
```promql
sum(http_requests_total{route="/triage",status_code="200"}) by (job)
```
Results:
- ticket-triage-dev: 10 requests
- ticket-triage-prod: 4 requests

### Test 4: Dashboard Verification
- All panels loading data: ✅
- DEV vs PROD comparison: ✅
- Real-time updates (30s): ✅
- Grafana login: ✅

## Issues Encountered

**None**. Deployment completed without errors or warnings.

## Performance Impact

**On Applications**:
- No restarts
- No performance degradation
- Metrics endpoint adds <1ms overhead per request

**On Cluster**:
- CPU overhead: ~10m (0.25% of total capacity)
- Memory overhead: ~187Mi (1.2% of total capacity)
- Network: 2 HTTP requests per 30 seconds per target

## Files Created

**Kubernetes Manifests** (`k8s/aws-monitoring/`):
- 1 namespace file
- 7 Prometheus files
- 8 Grafana files
- 1 kustomization file
- 1 README
- 1 deployment log (this file)

**Terraform Configuration** (`terraform/aws-monitoring/`):
- versions.tf
- providers.tf
- variables.tf
- main.tf
- outputs.tf
- terraform.tfvars
- .gitignore
- README.md
- dashboards/triage-comparison.json

**Documentation** (`docs/`):
- MONITORING_DEMO_RUNBOOK.md

**Total**: 28 new files

## Git Status

**Branch**: Not committed (awaiting approval)  
**Changes**: 28 new files  
**Size**: ~45 KB  

## Access Commands

**Prometheus**:
```bash
kubectl port-forward -n triage-monitoring svc/prometheus 9090:9090
```

**Grafana**:
```bash
kubectl port-forward -n triage-monitoring svc/grafana 3000:3000
```

## Rollback Plan

If needed, rollback is straightforward:

```bash
# Delete monitoring stack
kubectl delete -k /home/ubuntu/workspaces/multilingual-ticket-triage-devops/k8s/aws-monitoring

# Verify applications unaffected
kubectl get pods -n triage-dev
kubectl get pods -n triage-prod
```

**Time to rollback**: ~10 seconds  
**Data loss**: Monitoring data only (applications unaffected)  

## Next Steps

1. ✅ Deployment complete and verified
2. ✅ Documentation created
3. ⏳ Demo preparation for October 13, 2026
4. ⏳ Optional: Install Terraform for infrastructure-as-code management
5. ⏳ Optional: Configure Alertmanager for active alerting
6. ⏳ Optional: Add Loki for log aggregation

## Sign-Off

**Deployment Status**: ✅ SUCCESS  
**Application Impact**: ✅ NONE  
**Demo Ready**: ✅ YES  
**Documentation**: ✅ COMPLETE  

All monitoring components operational and ready for pre-defense demonstration.
