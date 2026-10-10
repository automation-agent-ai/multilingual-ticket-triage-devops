# CI/CD Pipeline — Sprint S05

## Overview

This document describes the GitHub Actions CI/CD pipeline for the Liora
Multilingual Ticket Triage API.  It covers pipeline stages, security controls,
deployment options, and the connectivity limitation that currently prevents
automated cluster access.

---

## 1. Pipeline stages

```
push to main / PR → main
        │
        ├─ Job: test
        │   ├─ Install CPU torch + requirements-docker.txt
        │   └─ pytest tests/ -m "not slow"  (741 tests, ~25 s)
        │
        └─ Job: build-scan-push  (needs: test)
            ├─ Build Docker image  (load into local daemon)
            ├─ Trivy scan          (CRITICAL/HIGH → fail; SARIF → GitHub Security)
            └─ Push to GHCR        (main push only, if scan passed)
```

```
CI workflow completes on main
        │
        └─ Workflow: deploy-dev  (automatic, after CI success)
            ├─ Resolve image tag (sha-<40-char-sha>)
            ├─ kustomize edit set image  (workspace only)
            ├─ kubectl kustomize k8s/ci-overlays/dev  (dry-run)
            └─ kubectl apply  ← DISABLED until cluster access is authorised
```

```
Manual trigger
        │
        └─ Workflow: deploy-prod  (workflow_dispatch only)
            ├─ Input validation  (confirm_production == "DEPLOY")
            ├─ ── APPROVAL GATE ─────────────────────────────────────
            │   GitHub Environment "production" pauses here.
            │   A required reviewer must approve in the GitHub UI.
            │   Configure: Settings → Environments → production
            │              → Required reviewers → add reviewer(s)
            ├─ kubectl kustomize k8s/ci-overlays/prod  (dry-run)
            └─ kubectl apply  ← DISABLED until cluster access is authorised
```

---

## 2. Workflow files

| File | Trigger | Purpose |
|---|---|---|
| `.github/workflows/ci.yml` | push/PR → main | Tests, Docker build, Trivy scan, GHCR publish |
| `.github/workflows/deploy-dev.yml` | after CI on main / manual | DEV deploy (dry-run until cluster access) |
| `.github/workflows/deploy-prod.yml` | manual with approval | PROD deploy (dry-run until cluster access) |

---

## 3. Permissions model

The pipelines follow the principle of minimum privilege.

| Scope | Level | Why |
|---|---|---|
| `contents` | `read` | Checkout only |
| `packages` | `write` | Push to GHCR — `build-scan-push` job, main push events only |
| `security-events` | `write` | Upload Trivy SARIF to GitHub Security tab |

**PRs from forks** receive the default `contents: read` token and can never
write packages.  The push step is conditioned on
`github.event_name == 'push' && github.ref == 'refs/heads/main'`.

**`GITHUB_TOKEN`** is used throughout; no personal access tokens are required.

---

## 4. Image naming and immutability

```
ghcr.io/automation-agent-ai/multilingual-ticket-triage-devops
  :sha-<40-character-git-sha>   ← immutable; used for Kubernetes deployment
  :latest                       ← mutable convenience tag (main branch only)
```

The full 40-character SHA tag is used in Kubernetes deployments to guarantee
bit-for-bit image identity.  The `latest` tag is a convenience alias only;
production deployments should always reference a `sha-` tag.

After the image is pushed, the deploy workflow exposes the image **digest**
(`sha256:…`) in the job summary.  Either the SHA tag or the digest can be
used as an immutable reference.

---

## 5. Trivy security scanning

Trivy runs as an initial DevSecOps gate on every build.

| Setting | Value | Rationale |
|---|---|---|
| Scanner | Trivy | Recommended by AquaSec; well-supported in GitHub Actions |
| Severity | `CRITICAL,HIGH` | Fails the build on findings at these levels |
| `exit-code` | `1` | Non-zero exit stops the pipeline; GHCR push is blocked |
| `ignore-unfixed` | `true` | Skips OS-layer CVEs with no available patch (reduces noise) |
| Format | SARIF | Uploaded to GitHub Security → Code scanning alerts |

Results appear in the repository's **Security** tab under **Code scanning**.

---

## 6. Kubernetes overlays

Two overlay trees exist:

| Path | Purpose | `imagePullPolicy` | Image |
|---|---|---|---|
| `k8s/overlays/dev` | Local dev (kind) | `Never` (pre-staged) | `ticket-triage-api:latest` |
| `k8s/overlays/prod` | Local prod (kind) | `Never` (pre-staged) | `ticket-triage-api:latest` |
| `k8s/ci-overlays/dev` | CI/registry dev | `IfNotPresent` | `ghcr.io/…:latest` (overridden) |
| `k8s/ci-overlays/prod` | CI/registry prod | `IfNotPresent` | `ghcr.io/…:latest` (overridden) |

**Local development** continues to use `k8s/overlays/{dev,prod}` unchanged.
The CI overlays (`k8s/ci-overlays/`) are used exclusively by GitHub Actions
and extend the existing overlays via kustomize composition.

Before applying, the deploy workflows run:
```bash
kustomize edit set image \
  "ticket-triage-api=ghcr.io/automation-agent-ai/multilingual-ticket-triage-devops:sha-<sha>"
```
This modifies the `images:` block in the workflow's local workspace copy only
(never committed to the repository).

---

## 7. Deployment connectivity limitation

### Current state

GitHub-hosted runners (`ubuntu-latest`) execute on **Azure infrastructure**.
They have no network route to the local Docker Desktop kind cluster on the
developer workstation (WSL2 / Windows).

Therefore, the `kubectl apply` step in both deploy workflows is **disabled**
(`if: false`) to prevent misleading failures.  The workflows do execute:

- Input validation
- `kustomize edit set image` (workspace edit)
- `kubectl kustomize` (full manifest render + YAML validation)

These steps verify the pipeline is correct end-to-end without touching the
cluster.

### Enabling live cluster deployment

Choose one of the following approaches.  **Do not implement either without
explicit approval** (as stated in the sprint requirements).

#### Option A — Self-hosted runner (recommended for initial activation)

A GitHub Actions runner registered as a Kubernetes pod or a VM inside the
cluster network can reach the cluster API directly.

Pros:
- No kubeconfig needs to leave the cluster boundary.
- No Kubernetes API surface is exposed to the internet.
- Works for the local kind cluster without changes.

Cons:
- The runner pod or host must be maintained and kept up-to-date.
- If run as a privileged pod, it has cluster-admin–equivalent access.
  Use least-privilege RBAC for the runner's ServiceAccount.

Activation steps (after approval):
1. Create a GitHub Actions runner pod in the cluster.
2. Assign a ServiceAccount with `get`, `list`, `create`, `update`, `patch`
   on `Deployment` resources in `triage-dev` (and separately `triage-prod`).
3. Change `runs-on: ubuntu-latest` to the runner label in deploy workflows.
4. Uncomment the `kubectl apply` steps.

#### Option B — Remote cluster (Hetzner k3s, recommended for production-grade CI)

A k3s cluster on Hetzner provides a stable, internet-accessible Kubernetes
endpoint that GitHub-hosted runners can reach.

Pros:
- GitHub-hosted runners work without changes.
- Better isolation from the developer workstation.
- Aligns with future production infrastructure goals.

Cons:
- Requires provisioning a Hetzner server (cost ~€4/month for CX22).
- A scoped kubeconfig must be stored as a GitHub Actions secret.
- Kubernetes API is reachable from the internet — mTLS and network policies
  are important.

Activation steps (after approval):
1. Provision a Hetzner CX22 VM and install k3s.
2. Create a kubeconfig scoped to the `triage-dev` namespace with minimal RBAC.
3. Store it as GitHub Actions secret `KUBECONFIG_DEV` (and `KUBECONFIG_PROD`).
4. Uncomment the `kubectl apply` steps; inject the secret via `env:`.

#### Security evaluation summary

| Control | Self-hosted runner | Hetzner k3s |
|---|---|---|
| API surface exposed to internet | No | Yes (behind TLS) |
| kubeconfig stored outside cluster | No | Yes (GitHub Actions secrets) |
| Blast radius if runner compromised | Local cluster | Hetzner cluster |
| Runner maintenance burden | Medium | Low (stateless GH runners) |
| Time to enable | ~2 h | ~4 h + server provisioning |

**Recommendation**: Start with Option A (self-hosted runner on the local
cluster) to validate the full pipeline.  Migrate to Option B when the workload
needs to run on production infrastructure.

---

## 8. Validation commands

### Local: run tests (as CI does)

```bash
# In the project root with the venv active:
pytest tests/ -m "not slow" -v --tb=short
# Expected: 741 passed, 3 deselected
```

### Local: render CI manifests (as deploy workflow does)

```bash
# DEV
kubectl kustomize k8s/ci-overlays/dev

# PROD
kubectl kustomize k8s/ci-overlays/prod

# Verify image reference (should show ghcr.io/... + IfNotPresent)
kubectl kustomize k8s/ci-overlays/dev \
  | grep -A2 "image:\|imagePullPolicy"
```

### Local: simulate kustomize edit (as deploy workflow does)

```bash
# Create a scratch copy to test without modifying committed files
cp -r k8s/ci-overlays/dev /tmp/ci-dev-test
cd /tmp/ci-dev-test
kustomize edit set image \
  "ticket-triage-api=ghcr.io/automation-agent-ai/multilingual-ticket-triage-devops:sha-8320bf24a3c3e29c3a5c4e0d5b1e8fc6d4ce2347"
kubectl kustomize .
# Verify: image field shows the full sha- tag
```

### Local: simulate a manual DEV deploy (after pulling from GHCR)

```bash
GHCR_IMAGE="ghcr.io/automation-agent-ai/multilingual-ticket-triage-devops:sha-<sha>"

# 1. Pull image
docker pull "$GHCR_IMAGE"

# 2. Stage into kind node
KIND_NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
docker save "$GHCR_IMAGE" \
  | docker exec -i "$KIND_NODE" ctr -n k8s.io images import -

# 3. Patch kustomization and apply
cd k8s/overlays/dev
kustomize edit set image "ticket-triage-api=$GHCR_IMAGE"
kubectl apply -k .

# 4. Watch rollout
kubectl rollout status deployment/ticket-triage -n triage-dev --timeout=300s

# 5. Smoke test
kubectl port-forward svc/ticket-triage 8080:8000 -n triage-dev &
curl -s http://localhost:8080/health
curl -s -X POST http://localhost:8080/triage \
  -H 'Content-Type: application/json' \
  -d '{"ticket_id":"smoke-01","subject":"Billing","body":"Double charge on my account"}'
```

### GitHub Actions: trigger PROD deploy

```
1. Go to:  Actions → Deploy — PROD → Run workflow
2. image_tag: sha-<commit-sha-from-ci-workflow>
3. confirm_production: DEPLOY
4. Run workflow
5. In the "Deploy to triage-prod" job, approve the environment protection rule.
```

---

## 9. Executed CI stages (Sprint S05)

The following stages were **actually executed** and verified during this sprint.

| Stage | Execution | Evidence |
|---|---|---|
| pytest 741 tests (-m "not slow") | ✅ Local | `741 passed, 3 deselected` |
| `kubectl kustomize k8s/ci-overlays/dev` | ✅ Local | GHCR image + `IfNotPresent` in output |
| `kubectl kustomize k8s/ci-overlays/prod` | ✅ Local | GHCR image + `IfNotPresent` in output |
| Local dev overlay unchanged | ✅ Verified | `ticket-triage-api:latest` + `Never` |
| Docker build (local) | ✅ Prior sprints | S04 verified with real inference |
| Docker push to GHCR | ⏳ Pending | Requires `git push` to trigger CI |
| Trivy scan | ⏳ Pending | Runs inside CI after `git push` |
| DEV `kubectl apply` | ⏳ Pending | Blocked by connectivity limitation (§7) |
| PROD `kubectl apply` | ⏳ Pending | Blocked by connectivity limitation (§7) |

The pipeline YAML, CI overlay renders, and test suite constitute the
verifiable deliverables of S05.  Automated cluster deployment will be
activated in a separate sprint once cluster access is authorised.
