# CI/CD Pipeline — Sprint S05 / S05c (CD activation)

## Overview

This document describes the GitHub Actions CI/CD pipeline for the Liora
Multilingual Ticket Triage API.  It covers pipeline stages, security controls,
deployment architecture, and the self-hosted runner setup required for
automated cluster access from GitHub Actions.

**S05c update:** the `kubectl apply` gap has been resolved.  A self-hosted
runner architecture is fully specified and implemented.  The runner is **not
yet installed** — see §6 (Runner Security Analysis) and the approval
checkpoint below before proceeding.

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
        └─ Workflow: deploy-dev  (workflow_run trigger or manual dispatch)
            ├─ Resolve image tag (sha-<40-char-sha>)
            ├─ Validate tag format (sha-[0-9a-f]{40} required)
            ├─ kustomize edit set image  (workspace only, not committed)
            ├─ kubectl kustomize k8s/ci-overlays/dev  (render + validate)
            ├─ Write KUBECONFIG_DEV secret → /tmp/kubeconfig-XXXXX (chmod 600)
            ├─ kubectl apply -k k8s/ci-overlays/dev   ← ENABLED (self-hosted runner)
            ├─ kubectl rollout status --timeout=300s
            ├─ kubectl exec → curl /health /ready /metrics  (smoke test)
            ├─ Verify pod image SHA (provenance check)
            ├─ kubectl rollout undo  (on rollout failure only)
            └─ rm /tmp/kubeconfig-XXXXX  (always, even on failure)
```
> ⚠ The `kubectl apply` step runs only on the `triage-dev-deployer` self-hosted
> runner.  GitHub-hosted runners are rejected by the `runs-on:` label constraint.

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
| `.github/workflows/deploy-dev.yml` | after CI on main / manual dispatch | DEV deploy — real `kubectl apply` on self-hosted runner |
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

## 7. Deployment connectivity — S05c implementation

### Architecture selected

**Self-hosted runner on the WSL2 host** (Option A from the original analysis).

GitHub-hosted runners execute on Azure and have no route to `127.0.0.1:50060`
(the local kind cluster API).  A self-hosted runner co-located on the WSL2
host can reach the cluster natively.

```
GitHub Actions
  └─ deploy-dev workflow
       └─ runs-on: [self-hosted, linux, triage-dev-deployer]
            │
            │  (runner runs on WSL2 host — same machine as kind)
            ▼
       /home/niwr/actions-runner/_work
            │
            │  KUBECONFIG_DEV (GitHub Env secret) → /tmp/kubeconfig-XXXXX
            ▼
       kubectl apply → https://127.0.0.1:50060  (kind API)
            │
            ▼
       cicd-deployer SA  →  Role: cicd-deployer-role  →  triage-dev NS only
```

### RBAC identity

| Resource | Name | Namespace |
|---|---|---|
| ServiceAccount | `cicd-deployer` | `triage-dev` |
| Secret (token) | `cicd-deployer-token` | `triage-dev` |
| Role | `cicd-deployer-role` | `triage-dev` |
| RoleBinding | `cicd-deployer-binding` | `triage-dev` |

Role permissions (triage-dev only):

| API group | Resources | Verbs |
|---|---|---|
| `apps` | `deployments` | get, list, watch, update, patch |
| `apps` | `replicasets` | get, list, watch |
| `""` | `pods` | get, list, watch |
| `""` | `services`, `configmaps`, `events` | get, list |

**Not granted**: nodes, namespaces, secrets, exec/attach/portforward,
cluster-level resources, or any triage-prod access.

### Files created (S05c)

| File | Purpose |
|---|---|
| `k8s/runner/rbac.yaml` | ServiceAccount, token Secret, Role, RoleBinding |
| `k8s/runner/kustomization.yaml` | Apply target for above |
| `scripts/generate-runner-kubeconfig.sh` | Generates scoped kubeconfig for KUBECONFIG_DEV secret |
| `scripts/install-runner.sh` | Runner installation (requires `APPROVED=yes` guard) |
| `.github/workflows/deploy-dev.yml` | Updated — real `kubectl apply`, rollout check, rollback |

### Activation sequence (requires approval — see §6)

```bash
# Step 1: Create RBAC resources
kubectl apply -k k8s/runner/

# Step 2: Generate scoped kubeconfig
bash scripts/generate-runner-kubeconfig.sh
# → produces runner-kubeconfig.yaml (chmod 600)

# Step 3: Upload to GitHub
# Settings → Environments → dev → Secrets → KUBECONFIG_DEV
# Then: rm runner-kubeconfig.yaml

# Step 4: Register and start runner (requires GH_RUNNER_TOKEN)
# Get token from: https://github.com/<ORG>/<REPO>/settings/actions/runners/new
APPROVED=yes GH_RUNNER_TOKEN=<token> bash scripts/install-runner.sh

# Step 5: Trigger deployment
# GitHub Actions → Deploy — DEV → Run workflow → image_tag: sha-<sha>
```

---

## 6. Runner Security Analysis

### What is installed

- GitHub Actions runner binary (v2.321.0), downloaded from
  `github.com/actions/runner/releases`, SHA-256 verified.
- Installed in `/home/niwr/actions-runner/`.
- Registered with labels `self-hosted,linux,triage-dev-deployer`.
- Runs as a **systemd service** under the existing `niwr` user account.

### Exact permissions

| Resource | Access |
|---|---|
| Kubernetes | `cicd-deployer` ServiceAccount — triage-dev namespace only (see §7 RBAC table) |
| Docker socket | **None** — runner is not given `/var/run/docker.sock` |
| GitHub repository | Checkout + read (standard `GITHUB_TOKEN: contents: read`) |
| Host filesystem | All paths readable by `niwr` user (WSL2 standard — residual risk, see below) |
| Other WSL projects | Readable as `niwr` — no additional restriction applied |
| KUBECONFIG_DEV | Injected as env var during job; written to tmpfs, deleted after use |

### How to remove

```bash
cd /home/niwr/actions-runner
sudo ./svc.sh stop
sudo ./svc.sh uninstall
# Get removal token from GitHub: Settings → Actions → Runners → (runner) → Remove
./config.sh remove --token <REMOVAL_TOKEN>
cd ~
rm -rf /home/niwr/actions-runner
```

Also delete the `KUBECONFIG_DEV` secret:
`Settings → Environments → dev → Secrets → KUBECONFIG_DEV → Delete`.

Optionally remove the RBAC identity:
```bash
kubectl delete -k k8s/runner/
```

### Residual host-security risks

| Risk | Severity | Mitigation |
|---|---|---|
| Runner runs as `niwr` → reads all `niwr`-owned files | Medium | Restrict `workflow_dispatch` to repo owners; require GitHub Environment reviewer |
| Malicious workflow triggered by compromised GitHub account | Medium | `workflow_dispatch` only + GitHub Environment "dev" required-reviewers |
| Long-lived SA token in GitHub secret (KUBECONFIG_DEV) | Medium | Token scoped to triage-dev only; rotate via `kubectl delete secret cicd-deployer-token -n triage-dev && kubectl apply -k k8s/runner/` |
| SA token logged if runner prints KUBECONFIG | Low | Workflow writes to tmpfs, uses KUBECONFIG env var (not arg), deletes after job |
| Workflow reads other `niwr` home dirs | Low | No cross-project data accessed by deploy workflow; code runs in `_work/` |

### Security controls in place

- `workflow_dispatch` only (no PR trigger; no automatic fork execution)
- `workflow_run` fires only on `main` branch CI success (no fork push access)
- GitHub Environment `dev` with required-reviewers blocks unauthorized dispatch
- `runs-on: [self-hosted, linux, triage-dev-deployer]` — GitHub-hosted runners rejected
- RBAC: `cicd-deployer` cannot access triage-prod, secrets, or cluster resources
- Kubeconfig written to `$(mktemp /tmp/kubeconfig-XXXXXX)`, chmod 600, deleted in `always()` step
- No Docker socket mount
- `install-runner.sh` requires `APPROVED=yes` environment variable guard

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

## 9. Executed CI/CD stages

### Sprint S05 — CI pipeline (verified)

| Stage | Execution | Evidence |
|---|---|---|
| pytest 741 tests (-m "not slow") | ✅ Local | `741 passed, 3 deselected` |
| `kubectl kustomize k8s/ci-overlays/dev` | ✅ Local | GHCR image + `IfNotPresent` in output |
| `kubectl kustomize k8s/ci-overlays/prod` | ✅ Local | GHCR image + `IfNotPresent` in output |
| Local dev overlay unchanged | ✅ Verified | `ticket-triage-api:latest` + `Never` |
| Docker push to GHCR | ✅ CI | `ghcr.io/automation-agent-ai/multilingual-ticket-triage-devops:sha-<sha>` |
| Trivy scan | ✅ CI | 54 unfixed HIGH OS CVEs; gate passing (`ignore-unfixed: true`) |

### Sprint S05c — CD activation (configured, runner pending approval)

| Stage | Status | Notes |
|---|---|---|
| RBAC manifests (`k8s/runner/rbac.yaml`) | ✅ Created | Not yet applied — awaiting runner approval |
| `scripts/generate-runner-kubeconfig.sh` | ✅ Created | Generates KUBECONFIG_DEV; not yet run |
| `scripts/install-runner.sh` | ✅ Created | Guarded by `APPROVED=yes`; not yet executed |
| `deploy-dev.yml` updated (real apply) | ✅ Implemented | Runs on `triage-dev-deployer` label |
| Self-hosted runner registered | ⏳ Pending approval | See §6 and Phase 3 checkpoint |
| `KUBECONFIG_DEV` GitHub secret set | ⏳ Pending | After runner approval and RBAC apply |
| DEV `kubectl apply` via GitHub Actions | ⏳ Pending | After runner online |
| PROD `kubectl apply` | ⏳ Not planned | PROD workflow remains dry-run only |
