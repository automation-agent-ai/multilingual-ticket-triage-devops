# AWS Monitoring Infrastructure

This Terraform configuration deploys a Prometheus + Grafana monitoring stack on the AWS k3s cluster for the Multilingual Ticket Triage application.

## Architecture

- **Namespace**: `triage-monitoring`
- **Components**:
  - Prometheus v3.1.0 (time-series database)
  - Grafana v11.4.0 (visualization)
  - Persistent storage for both components
  - DEV and PROD scrape targets

## Resources Deployed

1. **Namespace**: `triage-monitoring`
2. **PersistentVolumeClaims**: 
   - `prometheus-data` (10Gi)
   - `grafana-data` (2Gi)
3. **ServiceAccounts**: 
   - `triage-prometheus`
   - `triage-grafana`
4. **Secrets**: 
   - `grafana-credentials` (admin credentials)
5. **ConfigMaps**:
   - `prometheus-config` (scrape targets)
   - `prometheus-rules` (alert rules)
   - `grafana-datasources` (Prometheus connection)
   - `grafana-dashboard-provider` (dashboard provisioning)
   - `grafana-dashboards` (DEV vs PROD dashboard)
6. **Deployments**:
   - `prometheus` (200m CPU, 512Mi memory requests)
   - `grafana` (100m CPU, 256Mi memory requests)
7. **Services**:
   - `prometheus` (ClusterIP:9090)
   - `grafana` (ClusterIP:3000)

## Prerequisites

- AWS k3s cluster running and accessible
- `kubectl` context set to `default` (AWS cluster)
- Terraform >= 1.9
- Applications deployed in `triage-dev` and `triage-prod` namespaces
- Applications exposing `/metrics` endpoint on port 8000

## Deployment

### 1. Initialize Terraform

```bash
cd terraform/aws-monitoring
terraform init
```

### 2. Review Configuration

Edit `terraform.tfvars` to customize:
- Grafana admin password (recommended)
- Storage sizes
- Retention period

### 3. Plan and Apply

```bash
terraform fmt
terraform validate
terraform plan
terraform apply
```

### 4. Verify Deployment

```bash
# Check namespace and pods
kubectl get all -n triage-monitoring

# Wait for pods to be Ready
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=prometheus -n triage-monitoring --timeout=300s
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=grafana -n triage-monitoring --timeout=300s
```

## Access

### Prometheus

```bash
kubectl port-forward -n triage-monitoring svc/prometheus 9090:9090
```

Then open: http://localhost:9090

### Grafana

```bash
kubectl port-forward -n triage-monitoring svc/grafana 3000:3000
```

Then open: http://localhost:3000

- **Username**: `admin` (or as configured in terraform.tfvars)
- **Password**: Check `terraform.tfvars`

## Dashboard

The pre-configured dashboard "Ticket Triage — AWS DEV vs PROD" includes:

1. **Availability**: DEV and PROD target health
2. **Request Rate**: HTTP requests per second by environment
3. **Error Rate**: 4xx and 5xx responses
4. **Latency**: p50 and p95 response times
5. **Resources**: Memory and CPU usage
6. **Scrape Health**: Prometheus target status

## Monitoring Targets

- **DEV**: `ticket-triage.triage-dev.svc.cluster.local:8000/metrics`
- **PROD**: `ticket-triage.triage-prod.svc.cluster.local:8000/metrics`

Both targets are labeled with `environment` and `app` labels for filtering.

## Resource Usage

Expected steady-state resource consumption:

- **Prometheus**: ~200-500MB memory, 0.1-0.3 CPU cores
- **Grafana**: ~100-200MB memory, 0.05-0.1 CPU cores
- **Storage**: ~1-2GB for 7 days of metrics

## Security

- All services are ClusterIP only (no external exposure)
- Access requires `kubectl port-forward` or internal cluster access
- Grafana admin credentials stored in Kubernetes Secret
- No anonymous access enabled
- Non-root containers with dropped capabilities

## Maintenance

### Update Dashboard

Edit `dashboards/triage-comparison.json` and run:

```bash
terraform apply
```

### Change Retention

Edit `terraform.tfvars`:

```hcl
prometheus_retention = "14d"
```

Then apply:

```bash
terraform apply
```

### Backup Data

```bash
# Prometheus data
kubectl cp triage-monitoring/prometheus-xxx:/prometheus ./prometheus-backup

# Grafana data
kubectl cp triage-monitoring/grafana-xxx:/var/lib/grafana ./grafana-backup
```

## Troubleshooting

### Pods Not Ready

```bash
kubectl describe pod -n triage-monitoring <pod-name>
kubectl logs -n triage-monitoring <pod-name>
```

### Targets Down

Check Prometheus targets at http://localhost:9090/targets (via port-forward)

Common issues:
- Application not exposing metrics
- Service name resolution
- Network policies blocking traffic

### PVC Not Binding

k3s uses `WaitForFirstConsumer` binding mode - PVCs will remain Pending until a pod mounts them. This is expected behavior.

## Cleanup

**WARNING**: This will delete all monitoring data!

```bash
terraform destroy
```

To preserve data before cleanup:
1. Back up PVCs (see Maintenance section)
2. Export Grafana dashboards
3. Then run destroy

## Integration with CI/CD

This Terraform configuration can be integrated into CI/CD pipelines:

```bash
# In CI pipeline
cd terraform/aws-monitoring
terraform init -backend-config="key=monitoring/terraform.tfstate"
terraform plan -out=tfplan
terraform apply tfplan
```

## State Management

Current configuration uses local state file (`.tfstate`). For production:

1. Configure S3 backend in `versions.tf`
2. Enable state locking with DynamoDB
3. Never commit state files to git

## Support

For issues or questions:
- Check pod logs: `kubectl logs -n triage-monitoring <pod>`
- Check events: `kubectl get events -n triage-monitoring`
- Verify metrics: `kubectl exec -n triage-dev deploy/ticket-triage -- curl http://localhost:8000/metrics`
