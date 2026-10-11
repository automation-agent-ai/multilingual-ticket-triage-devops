# Sprint S06 — Terraform Infrastructure as Code

## Purpose

This Terraform module provisions the foundational Kubernetes resources required
by Sprint S07 (Prometheus + Grafana monitoring).  It targets the **local
docker-desktop cluster only** and manages exactly five resources inside the
dedicated `triage-monitoring` namespace.

It does **not** deploy Prometheus, Grafana, or any application workloads.
It does **not** touch the existing `triage-dev` or `triage-prod` namespaces.

---

## Architecture

```
docker-desktop cluster
└── triage-monitoring  (kubernetes_namespace_v1)
    ├── prometheus-data PVC  1 Gi ReadWriteOnce  (kubernetes_persistent_volume_claim_v1)
    ├── grafana-data    PVC  1 Gi ReadWriteOnce  (kubernetes_persistent_volume_claim_v1)
    ├── triage-prometheus    ServiceAccount      (kubernetes_service_account_v1)
    └── triage-grafana       ServiceAccount      (kubernetes_service_account_v1)
```

## What Terraform manages

| Terraform resource | Kubernetes kind | Name |
|---|---|---|
| `kubernetes_namespace_v1.triage_monitoring` | Namespace | `triage-monitoring` |
| `kubernetes_persistent_volume_claim_v1.prometheus_data` | PersistentVolumeClaim | `prometheus-data` |
| `kubernetes_persistent_volume_claim_v1.grafana_data` | PersistentVolumeClaim | `grafana-data` |
| `kubernetes_service_account_v1.triage_prometheus` | ServiceAccount | `triage-prometheus` |
| `kubernetes_service_account_v1.triage_grafana` | ServiceAccount | `triage-grafana` |

**Terraform does NOT manage** the `triage-dev` and `triage-prod` namespaces,
their Deployments, Services, or any Kustomize-owned resources.

---

## How the Kubernetes provider connects to docker-desktop

The `kubernetes` provider reads the standard kubeconfig at `~/.kube/config` and
uses the explicitly configured context `docker-desktop`.  The context is set via
the `kube_context` variable (default `docker-desktop`) so a remote Hetzner or
cloud context can never be accidentally targeted.

```hcl
provider "kubernetes" {
  config_path    = "~/.kube/config"
  config_context = "docker-desktop"
}
```

---

## Prerequisites

- Terraform ≥ 1.5.0 (`terraform version`)
- `kubectl` pointing at the docker-desktop cluster
- Docker Desktop running with Kubernetes enabled
- WSL2 kubeconfig at `~/.kube/config` with the `docker-desktop` context

---

## Standard workflow

```bash
# Format
terraform -chdir=terraform fmt -recursive

# Initialise (downloads hashicorp/kubernetes ~> 2.35)
terraform -chdir=terraform init

# Validate HCL syntax
terraform -chdir=terraform validate

# Preview changes
terraform -chdir=terraform plan -out=s06.tfplan

# Apply ONLY after reviewing the plan output
terraform -chdir=terraform apply s06.tfplan
```

---

## Verification

```bash
# Namespace
kubectl --context docker-desktop get namespace triage-monitoring

# PVCs and ServiceAccounts
kubectl --context docker-desktop -n triage-monitoring get pvc,serviceaccounts

# Labels set by Terraform
kubectl --context docker-desktop get namespace triage-monitoring \
  --show-labels
```

### Expected PVC status

Both PVCs will show `Pending` immediately after apply.  This is **correct
behaviour** — not a failure.  The `standard` StorageClass on docker-desktop
uses `volumeBindingMode: WaitForFirstConsumer`, meaning the underlying volume is
provisioned only when a Pod mounts the claim.  Sprint S07's Prometheus and
Grafana Pods will trigger binding.

---

## Terraform state and security

This module uses **local state** (`terraform.tfstate`) for simplicity in a
school project context.

> ⚠️ **Production note:** Local state must be backed up manually and contains
> sensitive resource metadata.  A real production deployment must use a secured
> remote backend (Terraform Cloud, S3 with encryption and locking, etc.) and
> must never commit state to version control.

The following entries are added to `.gitignore`:

```
.terraform/
*.tfstate
*.tfstate.*
crash.log
crash.*.log
*.tfplan
*.tfvars
!terraform/terraform.tfvars.example
```

The `.terraform.lock.hcl` file **is** committed to pin the exact provider
version (`hashicorp/kubernetes v2.38.0`).

---

## Reproducibility

To reproduce the entire monitoring namespace from scratch on any machine:

```bash
git checkout feat/s06-terraform   # or main after merge
terraform -chdir=terraform init
terraform -chdir=terraform apply -auto-approve
```

All five resources will be created in deterministic order because Terraform
resolves the implicit dependency graph (namespace → PVCs, ServiceAccounts).

---

## Idempotency

After a successful apply, a second `terraform plan` produces:

```
No changes. Your infrastructure matches the configuration.
```

Terraform reconciles live cluster state against the configuration on every run
and applies only the minimal delta.

---

## Sprint S07 integration

Sprint S07 will deploy Prometheus and Grafana into the `triage-monitoring`
namespace and **must reuse** the following Terraform-managed resources:

| Resource type | Exact name | Used by |
|---|---|---|
| Namespace | `triage-monitoring` | All S07 workloads |
| PVC | `prometheus-data` | Prometheus `volumeMounts` |
| PVC | `grafana-data` | Grafana `volumeMounts` |
| ServiceAccount | `triage-prometheus` | Prometheus Pod `serviceAccountName` |
| ServiceAccount | `triage-grafana` | Grafana Pod `serviceAccountName` |

Sprint S07 Helm charts or Kustomize overlays must reference these names
directly rather than creating their own namespace or PVCs.  This prevents
Helm from taking ownership of Terraform-managed resources.

**Important:** Sprint S07 ClusterRole/ClusterRoleBinding manifests must bind
to `triage-prometheus` and `triage-grafana` ServiceAccounts (namespace
`triage-monitoring`) for API scraping permissions.

---

## Safe cleanup (after all sprints are complete)

```bash
# Remove all five Terraform-managed resources
terraform -chdir=terraform destroy

# Verify
kubectl --context docker-desktop get namespace triage-monitoring
# Expected: Error from server (NotFound)
```

> **Never run `terraform destroy` during an active sprint.**  All monitoring
> data will be lost when the PVCs are deleted.

---

## Terraform vs Kustomize ownership

| Namespace | Managed by | Resources |
|---|---|---|
| `triage-dev` | Kustomize (`k8s/overlays/dev`) | Deployment, Service, ConfigMap, … |
| `triage-prod` | Kustomize (`k8s/overlays/prod`) | Deployment, Service, ConfigMap, … |
| `triage-monitoring` | **Terraform** (`terraform/`) | Namespace, PVCs, ServiceAccounts |

Terraform owns the `triage-monitoring` namespace and its bootstrap resources.
Kustomize (Sprint S07) will add Deployments and Services into that namespace
but must not recreate the namespace or the PVCs.

---

## Limitations

- **Local cluster only.** This module targets docker-desktop and cannot be
  used directly against a remote Hetzner k3s cluster without updating the
  provider context and storage class.
- **Single-node storage.** `rancher.io/local-path` PVCs are bound to the single
  `desktop-control-plane` node.  Data does not survive node deletion or cluster
  reset.
- **No remote state.** Local `.tfstate` must be backed up manually.
- **No TLS or secrets management.** Monitoring credentials are outside this
  module's scope.
- **Cluster recreation.** Only the five resources defined in this module are
  reproducible by Terraform.  The cluster itself (Docker Desktop Kubernetes)
  must be recreated through Docker Desktop settings.
