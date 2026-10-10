# Kubernetes Deployment Guide — Multilingual Ticket Triage API

Sprint S04 · Liora DevOps · Context: `docker-desktop` (kind)

---

## Table of Contents

1. [Architecture](#1-architecture)
2. [Prerequisites](#2-prerequisites)
3. [Cluster setup](#3-cluster-setup)
4. [Image loading](#4-image-loading)
5. [Storage provisioning](#5-storage-provisioning)
6. [DEV deployment](#6-dev-deployment)
7. [PROD deployment](#7-prod-deployment)
8. [ConfigMaps and environment variables](#8-configmaps-and-environment-variables)
9. [Services](#9-services)
10. [Health probes](#10-health-probes)
11. [Port-forwarding](#11-port-forwarding)
12. [End-to-end tests](#12-end-to-end-tests)
13. [Resource limits](#13-resource-limits)
14. [Security controls](#14-security-controls)
15. [Common failures and troubleshooting](#15-common-failures-and-troubleshooting)
16. [Rollback](#16-rollback)
17. [Cleanup](#17-cleanup)
18. [Hetzner k3s migration notes](#18-hetzner-k3s-migration-notes)

---

## 1. Architecture

### Component overview

```
Windows Host
├── Ollama (port 11434)          ← LLM inference backend
└── WSL Ubuntu
    ├── Docker Desktop (kind cluster)
    │   └── desktop-control-plane (Docker container = k8s node)
    │       ├── /data/hf-cache/               ← staged HF model cache (2.2 GB)
    │       ├── /data/app-data-dev/            ← DEV: DuckDB + LanceDB copy
    │       └── /data/app-data-prod/           ← PROD: DuckDB + LanceDB copy
    └── Kubernetes namespaces
        ├── triage-dev
        │   ├── Deployment/ticket-triage       ← 1 replica, RELOAD=true
        │   ├── Service/ticket-triage          ← ClusterIP :8000
        │   └── ConfigMap/ticket-triage-config ← DEV env vars
        └── triage-prod
            ├── Deployment/ticket-triage       ← 1 replica, RELOAD=false
            ├── Service/ticket-triage          ← ClusterIP :8000
            └── ConfigMap/ticket-triage-config ← PROD env vars
```

### Kustomize structure

```
k8s/
├── base/                    ← shared deployment + service templates
│   ├── kustomization.yaml
│   ├── deployment.yaml
│   └── service.yaml
├── overlays/
│   ├── dev/                 ← triage-dev namespace overlay
│   │   ├── kustomization.yaml
│   │   ├── namespace.yaml
│   │   ├── configmap.yaml
│   │   └── patches/
│   │       └── deployment.yaml   ← DEV resource limits + volume paths
│   └── prod/                ← triage-prod namespace overlay
│       ├── kustomization.yaml
│       ├── namespace.yaml
│       ├── configmap.yaml
│       └── patches/
│           └── deployment.yaml   ← PROD resource limits + volume paths
└── README.md
```

### Ollama connectivity

Ollama runs on the Windows host and is reached from Kubernetes Pods via
`host.docker.internal`, which Docker Desktop's embedded DNS resolves to
`192.168.65.254`. This hostname is confirmed reachable from Pods running
inside the kind node — verified with a test pod during Stage A inspection.

No `hostAliases` or special network configuration is required.

---

## 2. Prerequisites

| Tool | Version | Notes |
|------|---------|-------|
| Docker Desktop | 4.94.0+ | provides the kind cluster |
| kubectl | 1.36.1+ | bundled with Docker Desktop |
| kustomize | built-in | via `kubectl kustomize` |
| Ollama | any | running on Windows host at port 11434 |

Verify:

```bash
kubectl version --client
kubectl config get-contexts
kubectl config current-context   # must show: docker-desktop
```

---

## 3. Cluster setup

The Kubernetes cluster is provided by Docker Desktop (kind-based).
The node `desktop-control-plane` must be Ready before deploying.

```bash
kubectl --context docker-desktop get nodes
# Expected:
# NAME                    STATUS   ROLES           AGE   VERSION
# desktop-control-plane   Ready    control-plane   ...   v1.36.1
```

**Safety check** — always verify context before any write operation:

```bash
kubectl config current-context
# Must print: docker-desktop
```

Do **not** reset the cluster or install additional cluster managers.

---

## 4. Image loading

The Docker image `ticket-triage-api:latest` is **not** automatically available
to the kind node's containerd store when built with `docker build`. The kind
node uses its own isolated containerd registry.

### Load the image (required once per cluster reset)

```bash
docker save ticket-triage-api:latest \
  | docker exec -i desktop-control-plane ctr -n k8s.io images import -
```

This streams the image (~562 MB compressed) directly into the kind node's
containerd store. The operation takes approximately 30–60 seconds.

### Verify

```bash
docker exec desktop-control-plane ctr -n k8s.io images ls | grep ticket-triage
# Expected output contains: docker.io/library/ticket-triage-api:latest
```

### Why `imagePullPolicy: Never`

All Kubernetes manifests set `imagePullPolicy: Never`. This instructs the
kubelet to use only the locally imported image and never contact an external
registry. If the image is missing from containerd, the Pod will fail with
`ErrImageNeverPull` — a clear signal to re-run the import command above.

---

## 5. Storage provisioning

The kind node (a Docker container) does not mount the WSL filesystem.
All runtime data must be staged into the kind node's local filesystem.

Three directories are used:

| Node path | Contents | Size |
|-----------|----------|------|
| `/data/hf-cache/` | HuggingFace model cache (`intfloat/multilingual-e5-large`) | ~2.2 GB |
| `/data/app-data-dev/` | DEV copy of `data/` (LanceDB + DuckDB) | ~107 MB |
| `/data/app-data-prod/` | PROD copy of `data/` (LanceDB + DuckDB) | ~107 MB |

### Provision storage (required once per cluster reset)

```bash
# 1. Create directories inside the kind node
docker exec desktop-control-plane \
  mkdir -p /data/hf-cache /data/app-data-dev /data/app-data-prod

# 2. Copy HuggingFace model cache (2.2 GB — ~10 seconds on SSD)
docker cp ~/.cache/huggingface/hub/. desktop-control-plane:/data/hf-cache/

# 3. Copy application data for DEV
docker cp ./data/. desktop-control-plane:/data/app-data-dev/

# 4. Copy application data for PROD
docker cp ./data/. desktop-control-plane:/data/app-data-prod/

# 5. Fix ownership to match the container user appuser (UID 1000)
docker exec desktop-control-plane \
  chown -R 1000:1000 /data/hf-cache /data/app-data-dev /data/app-data-prod
```

### Key constraints

- **Never** use WSL paths directly as `hostPath` volumes in kind. WSL paths are
  not visible inside the kind Docker container.
- **Never** rebuild the LanceDB index or overwrite the original `data/` directory.
- The HF cache is shared between DEV and PROD (read-only model weights only).
- DEV and PROD each have their own data copy to ensure isolation.
- Data is mounted read-only (`readOnly: true`) in both environments.

---

## 6. DEV deployment

**Verify context first:**

```bash
kubectl config current-context   # must be: docker-desktop
```

**Deploy:**

```bash
kubectl kustomize k8s/overlays/dev \
  | kubectl --context docker-desktop apply -f -
```

**Watch pods come up:**

```bash
kubectl --context docker-desktop get pods -n triage-dev -w
# Expect 0/1 → 1/1 within ~2 minutes (embedding model load time)
```

**DEV-specific settings:**

| Setting | Value |
|---------|-------|
| Namespace | `triage-dev` |
| RELOAD | `true` (uvicorn WatchFiles reloader enabled) |
| Memory limit | 6 Gi |
| CPU limit | 2000m |
| Data path | `/data/app-data-dev` |

---

## 7. PROD deployment

**Verify context first:**

```bash
kubectl config current-context   # must be: docker-desktop
```

**Deploy:**

```bash
kubectl kustomize k8s/overlays/prod \
  | kubectl --context docker-desktop apply -f -
```

**Watch pods come up:**

```bash
kubectl --context docker-desktop get pods -n triage-prod -w
```

**PROD-specific settings:**

| Setting | Value |
|---------|-------|
| Namespace | `triage-prod` |
| RELOAD | `false` (single stable uvicorn process) |
| Memory limit | 5 Gi |
| CPU limit | 2000m |
| Data path | `/data/app-data-prod` |

---

## 8. ConfigMaps and environment variables

Each environment has its own `ConfigMap/ticket-triage-config` in its namespace.
The Deployment uses `envFrom: configMapRef` to load all keys as environment
variables.

| Variable | DEV | PROD |
|----------|-----|------|
| `OLLAMA_BASE_URL` | `http://host.docker.internal:11434` | same |
| `CONFIG_PATH` | `/app/config.yaml` | same |
| `HOST` | `0.0.0.0` | same |
| `PORT` | `8000` | same |
| `RELOAD` | `true` | `false` |
| `INFERENCE_CONCURRENCY` | `1` | `1` |
| `HF_HOME` | `/home/appuser/.cache/huggingface` | same |
| `TRANSFORMERS_CACHE` | `/home/appuser/.cache/huggingface/hub` | same |
| `TOKENIZERS_PARALLELISM` | `false` | same |
| `PYTHONUNBUFFERED` | `1` | same |
| `ENVIRONMENT` | `dev` | `prod` |

To inspect a running ConfigMap:

```bash
kubectl --context docker-desktop get configmap ticket-triage-config \
  -n triage-dev -o yaml
```

To update a value without redeploying:

```bash
kubectl --context docker-desktop edit configmap ticket-triage-config -n triage-dev
# Then restart the pod to pick up new values:
kubectl --context docker-desktop rollout restart deployment/ticket-triage -n triage-dev
```

---

## 9. Services

Both environments expose a ClusterIP Service on port 8000.
ClusterIP Services are not directly reachable from outside the cluster;
use port-forwarding for local access (see §11).

```bash
kubectl --context docker-desktop get svc -n triage-dev
kubectl --context docker-desktop get svc -n triage-prod
```

Expected output (IPs will differ):

```
NAME            TYPE        CLUSTER-IP    EXTERNAL-IP   PORT(S)    AGE
ticket-triage   ClusterIP   10.96.28.36   <none>        8000/TCP   ...
```

Verify Service endpoints resolve to a running Pod:

```bash
kubectl --context docker-desktop get endpoints -n triage-dev
kubectl --context docker-desktop get endpoints -n triage-prod
```

---

## 10. Health probes

Three probes are configured per Pod:

### startupProbe — `/health`

Allows up to **5 minutes** for cold start (15s initial delay + 30 × 10s).
Covers the embedding model load time (~2 minutes observed in kind).
The pod enters the readiness gate only after startupProbe succeeds.

### livenessProbe — `/health`

Fires every 30s after startup. Restarts the pod if the server process hangs.
`/health` always returns `{"status": "ok"}` — it does not check Ollama.

### readinessProbe — `/ready`

Fires every 10s. Returns traffic to the Pod only when the agent is fully
initialized: embedding model loaded, LanceDB connected, LLM client ready.
`/ready` returns `{"ready": true, "agent_initialized": true}` when live.

---

## 11. Port-forwarding

Use ports 18080 (DEV) and 18081 (PROD) to avoid conflicts with existing
Docker Compose services on ports 8000/8001.

```bash
# Start DEV forwarding (background)
kubectl --context docker-desktop \
  port-forward -n triage-dev svc/ticket-triage 18080:8000 &

# Start PROD forwarding (background)
kubectl --context docker-desktop \
  port-forward -n triage-prod svc/ticket-triage 18081:8000 &
```

Kill port-forwarding when done:

```bash
pkill -f "kubectl.*port-forward.*18080"
pkill -f "kubectl.*port-forward.*18081"
```

---

## 12. End-to-end tests

Run after port-forwarding is active (§11).

### Health

```bash
curl http://localhost:18080/health   # DEV → {"status":"ok"}
curl http://localhost:18081/health   # PROD → {"status":"ok"}
```

### Readiness

```bash
curl http://localhost:18080/ready    # DEV → {"ready":true,"agent_initialized":true}
curl http://localhost:18081/ready    # PROD → {"ready":true,"agent_initialized":true}
```

### Inference (real ticket triage)

```bash
# DEV
curl -s -X POST http://localhost:18080/triage \
  -H "Content-Type: application/json" \
  -d @api/example_request.json | python3 -m json.tool

# PROD
curl -s -X POST http://localhost:18081/triage \
  -H "Content-Type: application/json" \
  -d @api/example_request.json | python3 -m json.tool
```

**Verified result (Sprint S04):**

```json
{
    "ticket_id": "TKT-DEMO-001",
    "text_snippet": "Cannot access my online account\n\nI've been trying to log in...",
    "topic": "Technical / Online Access",
    "urgency": "High",
    "next_action": "escalate_to_human_supervisor",
    "confidence": 0.8,
    "missing_info": false,
    "missing_fields": [],
    "requires_human_review": true,
    "short_note": "Customer is experiencing login issues...",
    "action_result": {
        "selected_action": "escalate_to_human_supervisor",
        "action_status": "simulated_success",
        "action_note": "Simulated action: escalate ticket to a human supervisor.",
        "target": "human_supervisor_queue"
    }
}
```

### View pod logs

```bash
kubectl --context docker-desktop logs -n triage-dev -l app=ticket-triage --tail=50
kubectl --context docker-desktop logs -n triage-prod -l app=ticket-triage --tail=50
```

---

## 13. Resource limits

| Resource | DEV request | DEV limit | PROD request | PROD limit |
|----------|-------------|-----------|--------------|------------|
| CPU | 500m | 2000m | 500m | 2000m |
| Memory | 2 Gi | 6 Gi | 2 Gi | 5 Gi |

**Observed memory usage:** The `intfloat/multilingual-e5-large` model uses
approximately 2–3 GB RSS after loading. Both Pods running simultaneously
require roughly 4–6 GB total memory. The kind node has 24 GB available;
this workload uses approximately 25% of node capacity.

No OOMKilled events were observed during Sprint S04 testing.

Metrics server is not installed in this kind cluster; use `kubectl top`
after installing `metrics-server` if resource monitoring is required.

---

## 14. Security controls

The following baseline Kubernetes security controls are applied:

| Control | Setting |
|---------|---------|
| Run as non-root | `runAsNonRoot: true` |
| User ID | `runAsUser: 1000` (matches image `appuser`) |
| Group ID | `runAsGroup: 1000` |
| FS Group | `fsGroup: 1000` (volume permission inheritance) |
| Privilege escalation | `allowPrivilegeEscalation: false` |
| Linux capabilities | `drop: [ALL]` |
| Read-only root FS | `false` (Python `__pycache__` writes at import time) |
| Data volumes | Mounted `readOnly: true` |
| Image pull policy | `Never` (no remote registry access) |
| Docker socket | Not mounted |
| Secrets | Not used (no sensitive credentials required) |

### Why `readOnlyRootFilesystem: false`

Python writes `__pycache__` bytecode into source directories at import time.
Setting `readOnlyRootFilesystem: true` causes import failures. All application
data is provided via dedicated volume mounts; the root filesystem is otherwise
not writable by the application logic.

---

## 15. Common failures and troubleshooting

### Pod stuck at `0/1 Running` (not ready)

The embedding model takes ~2 minutes to load. This is normal.
Check probe progress:

```bash
kubectl --context docker-desktop describe pod -n triage-dev -l app=ticket-triage
```

Look for `Startup probe failed` events. If they exceed `failureThreshold: 30`
(5 minutes total), the pod will be restarted.

### `ErrImageNeverPull`

The image is not in the kind node's containerd store.
Re-run the image loading step:

```bash
docker save ticket-triage-api:latest \
  | docker exec -i desktop-control-plane ctr -n k8s.io images import -
```

### `MountVolume.SetUp failed: hostPath ... not found`

The staging directories were not created or the cluster was reset.
Re-run the full storage provisioning commands in §5.

### Agent fails with `LanceDB table not found`

The `data/lancedb/` directory was not staged or was staged incorrectly.
Verify:

```bash
docker exec desktop-control-plane ls -la /data/app-data-dev/lancedb/
docker exec desktop-control-plane ls -la /data/app-data-prod/lancedb/
```

### Ollama connection refused (HTTP 503 on `/triage`)

Verify Ollama is running on the Windows host and listening on port 11434.
Test from inside a temporary Pod:

```bash
kubectl --context docker-desktop run ollama-test \
  --image=curlimages/curl:latest --restart=Never --rm -i \
  --command -- curl -s --max-time 5 http://host.docker.internal:11434/api/tags
```

### Port-forward drops

Port-forward connections are not persistent. If the connection drops, restart:

```bash
kubectl --context docker-desktop \
  port-forward -n triage-dev svc/ticket-triage 18080:8000 &
```

### OOMKilled

If memory limits are too tight, increase them in the overlay patch and reapply.
Check events:

```bash
kubectl --context docker-desktop get events -n triage-dev --sort-by='.lastTimestamp'
```

---

## 16. Rollback

Kubernetes maintains a revision history. Roll back to the previous deployment
revision with:

```bash
# DEV rollback
kubectl --context docker-desktop rollout undo deployment/ticket-triage -n triage-dev

# PROD rollback
kubectl --context docker-desktop rollout undo deployment/ticket-triage -n triage-prod
```

View rollout history:

```bash
kubectl --context docker-desktop rollout history deployment/ticket-triage -n triage-dev
kubectl --context docker-desktop rollout history deployment/ticket-triage -n triage-prod
```

Roll back to a specific revision:

```bash
kubectl --context docker-desktop rollout undo deployment/ticket-triage \
  -n triage-prod --to-revision=2
```

Verify rollout status:

```bash
kubectl --context docker-desktop rollout status deployment/ticket-triage -n triage-dev
```

---

## 17. Cleanup

Remove **only** the application-specific resources. Do not delete system
namespaces or unrelated resources.

```bash
# Remove DEV environment
kubectl --context docker-desktop delete namespace triage-dev

# Remove PROD environment
kubectl --context docker-desktop delete namespace triage-prod

# Remove staged data from kind node (optional — safe to leave)
docker exec desktop-control-plane rm -rf /data/hf-cache /data/app-data-dev /data/app-data-prod
```

Deleting a namespace removes all resources within it (pods, services,
configmaps, deployments, replicasets).

To redeploy from scratch after cleanup, repeat §4, §5, §6, and §7.

---

## 18. Hetzner k3s migration notes

The following changes would be required to migrate from the local kind cluster
to a Hetzner k3s deployment. **Do not implement these in Sprint S04.**

### Image registry

Local `imagePullPolicy: Never` cannot be used on a remote node.
Replace with a registry push:

```bash
docker tag ticket-triage-api:latest registry.example.com/ticket-triage-api:latest
docker push registry.example.com/ticket-triage-api:latest
```

Update all `image:` references and change `imagePullPolicy` to `IfNotPresent`
or `Always`. Add `imagePullSecrets` if the registry requires authentication.

### Storage

`hostPath` volumes are not portable. Replace with:

- **PersistentVolumeClaims** backed by Hetzner Block Storage or NFS
- Or use an init container to download the model at Pod startup from object
  storage (S3-compatible)

The HF cache and application data must be pre-loaded or pulled from a
persistent store accessible to the k3s node(s).

### Ollama

`host.docker.internal` does not exist on Hetzner nodes.
Options:
- Deploy Ollama as a Kubernetes Deployment in the same cluster
- Use a Hetzner server's internal IP or a Kubernetes Service DNS name
- Use an external Ollama endpoint with a real DNS hostname

### Networking

Change `ClusterIP` Services to `LoadBalancer` or configure an Ingress controller
(e.g., Traefik, which ships with k3s) with TLS termination.

### Secrets

Use Kubernetes Secrets or an external secrets manager (Vault, Sealed Secrets)
for any API tokens or credentials introduced at that stage.

### Namespaces

The `triage-dev` and `triage-prod` namespace structure transfers directly.
Only the resource classes and storage backends change.

---

## Quick reference — redeployment commands

```bash
# 0. Verify context (ALWAYS first)
kubectl config current-context   # must be: docker-desktop

# 1. Load image into kind node (if cluster was reset)
docker save ticket-triage-api:latest \
  | docker exec -i desktop-control-plane ctr -n k8s.io images import -

# 2. Provision storage (if cluster was reset)
docker exec desktop-control-plane \
  mkdir -p /data/hf-cache /data/app-data-dev /data/app-data-prod
docker cp ~/.cache/huggingface/hub/. desktop-control-plane:/data/hf-cache/
docker cp ./data/. desktop-control-plane:/data/app-data-dev/
docker cp ./data/. desktop-control-plane:/data/app-data-prod/
docker exec desktop-control-plane \
  chown -R 1000:1000 /data/hf-cache /data/app-data-dev /data/app-data-prod

# 3. Deploy DEV
kubectl kustomize k8s/overlays/dev \
  | kubectl --context docker-desktop apply -f -

# 4. Deploy PROD
kubectl kustomize k8s/overlays/prod \
  | kubectl --context docker-desktop apply -f -

# 5. Wait for pods to be ready (~2 minutes)
kubectl --context docker-desktop get pods -n triage-dev -w
kubectl --context docker-desktop get pods -n triage-prod -w

# 6. Port-forward
kubectl --context docker-desktop \
  port-forward -n triage-dev svc/ticket-triage 18080:8000 &
kubectl --context docker-desktop \
  port-forward -n triage-prod svc/ticket-triage 18081:8000 &

# 7. Test
curl http://localhost:18080/health
curl http://localhost:18081/health
curl -X POST http://localhost:18080/triage -H "Content-Type: application/json" \
  -d @api/example_request.json | python3 -m json.tool
curl -X POST http://localhost:18081/triage -H "Content-Type: application/json" \
  -d @api/example_request.json | python3 -m json.tool
```
