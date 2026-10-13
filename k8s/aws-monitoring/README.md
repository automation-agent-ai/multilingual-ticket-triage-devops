# AWS Monitoring Stack - Kubernetes Deployment

Production-ready Prometheus + Grafana monitoring for the Multilingual Ticket Triage application on AWS k3s.

## Quick Start

### Deploy

```bash
# Apply all resources
kubectl apply -k .

# Wait for readiness
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=prometheus -n triage-monitoring --timeout=120s
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=grafana -n triage-monitoring --timeout=120s

# Verify deployment
kubectl get all -n triage-monitoring
```

### Access

**Prometheus**:
```bash
kubectl port-forward -n triage-monitoring svc/prometheus 9090:9090
# Open http://localhost:9090
```

**Grafana**:
```bash
kubectl port-forward -n triage-monitoring svc/grafana 3000:3000
# Open http://localhost:3000
# Login: admin / [password from grafana-credentials secret]
```

## Structure

```
aws-monitoring/
├── namespace.yaml                              # Namespace definition
├── prometheus/
│   ├── pvc.yaml                               # 10Gi persistent storage
│   ├── serviceaccount.yaml                    # RBAC identity
│   ├── configmap.yaml                         # Scrape configuration
│   ├── alert-rules-configmap.yaml             # Alert definitions
│   ├── deployment.yaml                        # Prometheus server
│   └── service.yaml                           # ClusterIP service
├── grafana/
│   ├── pvc.yaml                               # 2Gi persistent storage
│   ├── serviceaccount.yaml                    # RBAC identity
│   ├── secret.yaml                            # Admin credentials
│   ├── datasource-configmap.yaml              # Prometheus connection
│   ├── dashboard-provider-configmap.yaml      # Dashboard provisioning
│   ├── dashboard-configmap.yaml               # DEV vs PROD dashboard
│   ├── triage-comparison.json                 # Dashboard source
│   ├── deployment.yaml                        # Grafana server
│   └── service.yaml                           # ClusterIP service
└── kustomization.yaml                         # Kustomize orchestration
```

## Monitored Targets

- **ticket-triage-dev**: `ticket-triage.triage-dev.svc.cluster.local:8000/metrics`
- **ticket-triage-prod**: `ticket-triage.triage-prod.svc.cluster.local:8000/metrics`

## Dashboard Metrics

The pre-configured **Ticket Triage — AWS DEV vs PROD** dashboard tracks:

1. Target availability (UP/DOWN status)
2. HTTP request rate (req/s)
3. Error rates (4xx, 5xx)
4. Response latency (p50, p95)
5. Process memory usage
6. Process CPU usage
7. Prometheus scrape health

## Resource Allocation

| Component | CPU Request | Memory Request | CPU Limit | Memory Limit |
|-----------|-------------|----------------|-----------|--------------|
| Prometheus | 200m | 512Mi | 1000m | 1Gi |
| Grafana | 100m | 256Mi | 500m | 512Mi |
| **Total** | **300m** | **768Mi** | **1500m** | **1.5Gi** |

## Configuration

### Update Scrape Targets

Edit `prometheus/configmap.yaml`:

```yaml
scrape_configs:
  - job_name: 'new-target'
    static_configs:
      - targets: ['service.namespace.svc.cluster.local:9090']
```

Apply changes:
```bash
kubectl apply -f prometheus/configmap.yaml
kubectl rollout restart deployment/prometheus -n triage-monitoring
```

### Update Dashboard

1. Edit `grafana/triage-comparison.json`
2. Rebuild ConfigMap:
   ```bash
   cd grafana
   cat > dashboard-configmap.yaml << 'EOF'
   apiVersion: v1
   kind: ConfigMap
   metadata:
     name: grafana-dashboards
     namespace: triage-monitoring
   data:
     triage-comparison.json: |
   EOF
   cat triage-comparison.json | sed 's/^/    /' >> dashboard-configmap.yaml
   ```
3. Apply:
   ```bash
   kubectl apply -f dashboard-configmap.yaml
   kubectl rollout restart deployment/grafana -n triage-monitoring
   ```

### Change Retention Period

Edit `prometheus/deployment.yaml`:

```yaml
args:
  - --storage.tsdb.retention.time=14d  # Change from 7d to 14d
```

Apply:
```bash
kubectl apply -f prometheus/deployment.yaml
```

## Security

- **No external exposure**: ClusterIP services only
- **Secure credentials**: Stored in Kubernetes Secret
- **Non-root containers**: UID 65534 (Prometheus), UID 472 (Grafana)
- **Capability dropping**: ALL capabilities dropped
- **Resource limits**: Prevents resource exhaustion
- **No anonymous access**: Authentication required

## Troubleshooting

### Check Logs

```bash
kubectl logs -n triage-monitoring deploy/prometheus
kubectl logs -n triage-monitoring deploy/grafana
```

### Verify Targets

```bash
kubectl exec -n triage-monitoring deploy/prometheus -- \
  wget -qO- http://localhost:9090/api/v1/targets | python3 -m json.tool
```

### Test Metrics Endpoint

```bash
kubectl exec -n triage-dev deploy/ticket-triage -- \
  curl http://localhost:8000/metrics
```

### Check DNS

```bash
kubectl exec -n triage-monitoring deploy/prometheus -- \
  nslookup ticket-triage.triage-dev.svc.cluster.local
```

## Maintenance

### Backup Data

```bash
# Prometheus
kubectl exec -n triage-monitoring deploy/prometheus -- tar czf /tmp/prometheus-backup.tar.gz /prometheus
kubectl cp triage-monitoring/prometheus-xxx:/tmp/prometheus-backup.tar.gz ./prometheus-backup.tar.gz

# Grafana
kubectl exec -n triage-monitoring deploy/grafana -- tar czf /tmp/grafana-backup.tar.gz /var/lib/grafana
kubectl cp triage-monitoring/grafana-xxx:/tmp/grafana-backup.tar.gz ./grafana-backup.tar.gz
```

### Update Images

```bash
# Edit deployments to use new image versions
kubectl set image deployment/prometheus prometheus=prom/prometheus:v3.2.0 -n triage-monitoring
kubectl set image deployment/grafana grafana=grafana/grafana:11.5.0 -n triage-monitoring
```

## Cleanup

**WARNING**: This will delete all monitoring data!

```bash
kubectl delete -k .
```

To preserve data:
1. Back up PVCs first (see Maintenance section)
2. Then run cleanup

## Related Documentation

- [Monitoring Demo Runbook](../../docs/MONITORING_DEMO_RUNBOOK.md)
- [AWS Migration Plan](../../docs/AWS_MIGRATION_PLAN.md)
- [Architecture Documentation](../../docs/ARCHITECTURE.md)

## Support

For issues or questions:
1. Check pod logs: `kubectl logs -n triage-monitoring <pod-name>`
2. Check events: `kubectl get events -n triage-monitoring --sort-by='.lastTimestamp'`
3. Verify metrics: Direct curl to application `/metrics` endpoint
4. Review Prometheus targets: http://localhost:9090/targets (via port-forward)
