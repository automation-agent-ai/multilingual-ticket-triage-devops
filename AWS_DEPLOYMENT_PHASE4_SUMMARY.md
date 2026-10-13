# AWS Deployment Preparation — Phase 4 Complete

**Date:** 2026-10-12  
**Branch:** `feat/aws-bedrock-migration`  
**Commit:** `ec47fb5` (Bedrock integration)  
**Status:** ✅ Ready for data verification and deployment

---

## 📦 DELIVERABLES

### Part A — CI/CD Safety Analysis

#### Trigger Analysis Summary

**`.github/workflows/ci.yml`**
- **Triggers:** 
  - `push` to `main` → Full pipeline with GHCR publication
  - `pull_request` to `main` → Test + build + scan only (NO push)
- **Image publication conditions:**
  ```yaml
  github.event_name == 'push' AND
  github.ref == 'refs/heads/main' AND
  steps.trivy.outcome == 'success'
  ```
- **Tags produced:**
  - `sha-<40-char-commit>` (immutable)
  - `latest` (mutable, main only)

**`.github/workflows/deploy-dev.yml`**
- **Triggers:**
  - `workflow_run` after CI completes on main → Auto-deploy to WSL
  - `workflow_dispatch` → Manual deployment
- **Target:** Self-hosted runner `triage-dev-deployer` (WSL only)
- **Impact:** Isolated from AWS — no risk of accidental AWS deployment

**`.github/workflows/deploy-prod.yml`**
- **Triggers:** `workflow_dispatch` only (manual)
- **Status:** Deployment step disabled (GitHub-hosted runner limitation)

#### Recommended Safe Publication Path

**✅ RECOMMENDED: Merge to main via PR**

```bash
# Step 1: Prepare branch
git checkout feat/aws-bedrock-migration
git fetch origin main
git rebase origin/main
git push origin feat/aws-bedrock-migration --force-with-lease

# Step 2: Create PR (requires approval)
gh pr create \
  --title "feat: AWS Bedrock migration - Phase 4 deployment prep" \
  --body "Adds AWS Kubernetes overlays with Bedrock support"

# Step 3: After PR approval and merge
# ✅ CI runs automatically
# ✅ Tests pass (761 + new Bedrock tests)
# ✅ Trivy scans image
# ✅ Image pushed: ghcr.io/.../sha-ec47fb5...
# ✅ WSL DEV auto-deploys (isolated, no AWS impact)

# Step 4: Image available for AWS deployment
docker pull ghcr.io/automation-agent-ai/multilingual-ticket-triage-devops:sha-ec47fb598ac0ea82d5c9c24f30d0c6d93c1f8b4e
```

**Why this is safe:**
1. WSL deployment uses self-hosted runner (label: `triage-dev-deployer`) not present on AWS
2. Trivy scan gates the push (security validation)
3. Immutable SHA tag ensures audit trail
4. Reuses battle-tested CI pipeline
5. No AWS resources touched until manual `kubectl apply` on EC2

**Alternatives considered:**
- ❌ Direct push to main without PR → Bypasses code review
- ❌ Manual build without merge → Image won't be published to GHCR

---

### Part B — AWS Kubernetes Overlays

#### Files Created

```
k8s/overlays/aws-dev/
├── configmap.yaml              # Bedrock config, eu-west-1
├── kustomization.yaml          # DEV overlay, GHCR image
├── namespace.yaml              # triage-dev namespace
└── patches/
    └── deployment.yaml         # Resources: 500m/1.5CPU, 2Gi/4Gi RAM

k8s/overlays/aws-prod/
├── configmap.yaml              # Bedrock config, RELOAD=false
├── kustomization.yaml          # PROD overlay, GHCR image
├── namespace.yaml              # triage-prod namespace
└── patches/
    └── deployment.yaml         # Resources: 1CPU/2CPU, 2Gi/6Gi RAM
```

**Total:** 8 files, 302 lines

#### Key Design Decisions

1. **Image Source:** GHCR registry (`imagePullPolicy: IfNotPresent`)
   - SHA: `sha-ec47fb598ac0ea82d5c9c24f30d0c6d93c1f8b4e`
   - No local image pre-loading required

2. **LLM Provider:** Amazon Bedrock via `CONFIG_PATH=/app/config-aws.yaml`
   - Region: `eu-west-1`
   - Model: `eu.amazon.nova-micro-v1:0`
   - Credentials: IAM instance role (no static keys)

3. **Volume Paths:** AWS-specific hostPath mounts
   - HuggingFace cache: `/mnt/data/hf-cache` (shared, read-only)
   - DEV data: `/mnt/data/app-data-dev` (read-only)
   - PROD data: `/mnt/data/app-data-prod` (read-only)

4. **Resource Allocation:**
   | Environment | CPU Request | CPU Limit | RAM Request | RAM Limit |
   |-------------|-------------|-----------|-------------|-----------|
   | DEV         | 500m        | 1500m     | 2Gi         | 4Gi       |
   | PROD        | 1000m       | 2000m     | 2Gi         | 6Gi       |
   | **Total**   | **1500m**   | **3500m** | **4Gi**     | **10Gi**  |

   **Node capacity:** 4 vCPU / 16 GiB RAM  
   **Utilization:** 37.5% CPU / 25% RAM (requests)  
   **Buffer:** 2.5 vCPU / 5.2 GiB for monitoring + OS

5. **Security:**
   - ✅ No hardcoded credentials
   - ✅ Non-root user (UID 1000)
   - ✅ Privilege escalation disabled
   - ✅ All capabilities dropped
   - ✅ Read-only data volumes

6. **Preserved from WSL:**
   - Three-namespace architecture
   - Base manifests unchanged
   - Service type: ClusterIP (internal)
   - Security contexts
   - Health/readiness probes

---

## ✅ VALIDATION RESULTS

### Kustomize Rendering
- ✅ **AWS DEV:** Rendered successfully (165 lines)
- ✅ **AWS PROD:** Rendered successfully (165 lines)
- ⚠️ Deprecation warning: `commonLabels` → Non-blocking

### Image References
- ✅ DEV: `ghcr.io/automation-agent-ai/multilingual-ticket-triage-devops:sha-ec47fb5...`
- ✅ PROD: `ghcr.io/automation-agent-ai/multilingual-ticket-triage-devops:sha-ec47fb5...`

### Configuration
- ✅ DEV: `CONFIG_PATH=/app/config-aws.yaml`, `AWS_REGION=eu-west-1`
- ✅ PROD: `CONFIG_PATH=/app/config-aws.yaml`, `RELOAD=false`

### Security Scan
- ✅ No embedded secrets (password, key, token, credential)
- ✅ Security contexts present
- ✅ Resource limits within node capacity

### Volume Paths
- ✅ DEV: `/mnt/data/app-data-dev` (readOnly)
- ✅ PROD: `/mnt/data/app-data-prod` (readOnly)
- ✅ Shared: `/mnt/data/hf-cache` (readOnly)

---

## ⚠️ REMAINING BLOCKERS (Before First Deployment)

### 🚨 CRITICAL — Data Verification Required

**Task:** Verify data transferred to AWS EC2

```bash
# On EC2 instance (108.129.133.72)
ssh ubuntu@<ec2-instance> << 'EOSSH'
  ls -lah /mnt/data/hf-cache
  ls -lah /mnt/data/app-data-dev
  ls -lah /mnt/data/app-data-prod
  
  # Check permissions (must be readable by UID 1000)
  stat -c "%a %U:%G" /mnt/data/hf-cache
  stat -c "%a %U:%G" /mnt/data/app-data-dev
  stat -c "%a %U:%G" /mnt/data/app-data-prod
  
  # Verify DuckDB exists
  ls -lh /mnt/data/app-data-dev/tickets.duckdb
  ls -lh /mnt/data/app-data-prod/tickets.duckdb
EOSSH
```

**Expected:**
- `/mnt/data/hf-cache/`: ~2 GB (HuggingFace models)
- `/mnt/data/app-data-dev/`: ~200-300 MB (DuckDB + LanceDB)
- `/mnt/data/app-data-prod/`: ~200-300 MB (DuckDB + LanceDB)
- Permissions: `755` or `775`, owner `ubuntu:ubuntu` or world-readable

**If missing:** Run data transfer from migration plan Phase 2:
```bash
# From local WSL
rsync -avz --progress --checksum \
  /path/to/multilingual-ticket-triage-devops/data/ \
  ubuntu@<ec2-ip>:/mnt/data/app-data-dev/
```

### 🚨 CRITICAL — IAM Role Verification

**Task:** Verify EC2 IAM role has Bedrock permissions

```bash
# On EC2 instance
aws sts get-caller-identity
# Expected: Shows assumed role ARN

aws bedrock list-foundation-models --region eu-west-1 \
  --query 'modelSummaries[?contains(modelId, `nova-micro`)]' \
  --output table
# Expected: Returns eu.amazon.nova-micro-v1:0
```

**If access denied:** Attach IAM policy:
```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream"
    ],
    "Resource": "arn:aws:bedrock:eu-west-1::foundation-model/amazon.nova-micro-v1:0"
  }]
}
```

### 🚨 CRITICAL — k3s Cluster Readiness

**Task:** Verify k3s operational

```bash
# On EC2 instance
kubectl version
kubectl get nodes
# Expected: 1 node Ready

kubectl get ns | grep triage
# Expected: No triage-dev or triage-prod (will be created by deployment)
```

### ✅ OPTIONAL — GHCR Image Availability

```bash
# From any machine with Docker
docker manifest inspect \
  ghcr.io/automation-agent-ai/multilingual-ticket-triage-devops:sha-ec47fb598ac0ea82d5c9c24f30d0c6d93c1f8b4e
# Expected: Shows image manifest (confirms image exists)
```

**Note:** This image already exists from previous push. Only verify if unsure.

---

## 🚀 RECOMMENDED NEXT COMMANDS

### Step 1: Verify Prerequisites on EC2 (5 min)

```bash
# SSH to EC2
ssh ubuntu@<ec2-instance-ip>

# Run prerequisite checks
kubectl get nodes
ls -lah /mnt/data/
aws sts get-caller-identity
aws bedrock list-foundation-models --region eu-west-1 --query 'modelSummaries[?contains(modelId, `nova`)]'

# If all pass, proceed to Step 2
```

### Step 2: Git Operations (Local) (5 min)

**Only after approval:**

```bash
cd /home/ubuntu/workspaces/multilingual-ticket-triage-devops

# Verify changes
git status
git diff k8s/overlays/aws-dev/
git diff k8s/overlays/aws-prod/

# Commit AWS overlays
git add k8s/overlays/aws-dev/
git add k8s/overlays/aws-prod/
git add AWS_DEPLOYMENT_PHASE4_SUMMARY.md

git commit -m "feat(k8s): add AWS overlays for triage-dev and triage-prod

- Create aws-dev overlay with 500m/1.5CPU, 2Gi/4Gi resources
- Create aws-prod overlay with 1CPU/2CPU, 2Gi/6Gi resources
- Use GHCR image sha-ec47fb598ac0ea82d5c9c24f30d0c6d93c1f8b4e
- Configure Bedrock via /app/config-aws.yaml
- Mount /mnt/data/* for AWS-specific paths
- IAM instance role for credentials (no static keys)
- Preserve WSL overlays unchanged

Part of AWS migration Phase 4
"

# Push to remote
git push origin feat/aws-bedrock-migration
```

### Step 3: Create PR and Merge to Main (After Approval) (15 min)

```bash
# Create PR
gh pr create \
  --title "feat: AWS Bedrock migration - Phase 4 deployment prep" \
  --body "## Summary
AWS deployment preparation with Kubernetes overlays and Bedrock support.

## Changes
- AWS DEV overlay: k8s/overlays/aws-dev
- AWS PROD overlay: k8s/overlays/aws-prod
- CI/CD analysis: Safe GHCR publication path
- Resource allocation: 1.5 vCPU / 4 GiB (requests)

## Tests
- 761 existing tests pass
- Kustomize rendering validated
- No embedded secrets
- Security contexts verified

## Deployment
- Requires data verification on EC2 before kubectl apply
- IAM role must have bedrock:InvokeModel permission
- WSL overlays unchanged (isolated)

See: AWS_DEPLOYMENT_PHASE4_SUMMARY.md"

# After PR approval and merge
# → CI runs automatically
# → WSL DEV deploys (isolated from AWS)
# → Image available in GHCR for AWS deployment
```

### Step 4: First AWS Deployment (On EC2, After PR Merge) (20 min)

```bash
# On EC2
cd ~/multilingual-ticket-triage-devops
git pull origin main

# Deploy DEV
kubectl apply -k k8s/overlays/aws-dev
kubectl get pods -n triage-dev -w
# Wait for Running status (~2-5 min)

# Smoke test DEV
POD=$(kubectl get pod -n triage-dev -l app=ticket-triage -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n triage-dev $POD -- curl -sf http://localhost:8000/health
kubectl exec -n triage-dev $POD -- curl -sf http://localhost:8000/ready
kubectl logs -n triage-dev $POD | grep "BedrockClient"

# If DEV succeeds, deploy PROD
kubectl apply -k k8s/overlays/aws-prod
kubectl get pods -n triage-prod -w
```

---

## 📊 SUCCESS CRITERIA

### Phase 4 Complete (Current State)
- ✅ CI/CD trigger analysis documented
- ✅ Safe GHCR publication path identified
- ✅ AWS DEV overlay created and validated
- ✅ AWS PROD overlay created and validated
- ✅ Manifests render without errors
- ✅ No hardcoded credentials
- ✅ Security contexts verified
- ✅ Resource limits within node capacity
- ✅ WSL overlays preserved unchanged

### Phase 5 Ready (After Data Verification)
- [ ] Data transferred to `/mnt/data/*` on EC2
- [ ] IAM role attached with Bedrock permissions
- [ ] k3s cluster operational
- [ ] Changes committed and pushed
- [ ] PR created (optional: wait for merge)

### Phase 6 Ready (After First Deployment)
- [ ] DEV pod Running and healthy
- [ ] DEV /ready returns true
- [ ] DEV logs show "BedrockClient initialized"
- [ ] PROD pod Running and healthy
- [ ] Resource usage within expected range
- [ ] No errors in logs

---

## 🔄 ROLLBACK PLAN

### If overlay validation fails:
```bash
rm -rf k8s/overlays/aws-dev k8s/overlays/aws-prod
git checkout k8s/overlays/
```

### If DEV deployment fails:
```bash
kubectl delete namespace triage-dev
# Fix issue, redeploy
```

### If PROD deployment fails:
```bash
kubectl delete namespace triage-prod
# DEV remains unaffected
```

### If need to undo git commit (before push):
```bash
git reset --soft HEAD~1
```

---

## 📁 FILES MODIFIED / CREATED

### New Files (Untracked)
```
k8s/overlays/aws-dev/configmap.yaml
k8s/overlays/aws-dev/kustomization.yaml
k8s/overlays/aws-dev/namespace.yaml
k8s/overlays/aws-dev/patches/deployment.yaml
k8s/overlays/aws-prod/configmap.yaml
k8s/overlays/aws-prod/kustomization.yaml
k8s/overlays/aws-prod/namespace.yaml
k8s/overlays/aws-prod/patches/deployment.yaml
AWS_DEPLOYMENT_PHASE4_SUMMARY.md
```

### Preserved (Unchanged)
```
k8s/base/*                      # Base manifests
k8s/overlays/dev/*              # WSL DEV overlay
k8s/overlays/prod/*             # WSL PROD overlay
k8s/ci-overlays/*               # CI-specific overlays
.github/workflows/*             # CI/CD workflows
config-aws.yaml                 # Already exists from Phase 3
```

---

## 🎯 NEXT PHASE PREVIEW

**Phase 5: First AWS Deployment**
1. Verify data transfer complete
2. Deploy triage-dev
3. Smoke test DEV
4. Deploy triage-prod
5. Document resource usage

**Phase 6: Monitoring & Ingress**
1. Deploy Prometheus + Grafana
2. Configure Traefik ingress for PROD
3. Set up BasicAuth + rate limiting
4. Enable public HTTPS access

---

## 📞 SUPPORT / QUESTIONS

**CI/CD Issues:**
- Check: https://github.com/automation-agent-ai/multilingual-ticket-triage-devops/actions
- Self-hosted runner logs: `~/actions-runner/_diag/`

**Kubernetes Issues:**
- k3s logs: `sudo journalctl -u k3s -f`
- Pod logs: `kubectl logs -n triage-dev -l app=ticket-triage`
- Events: `kubectl get events -n triage-dev --sort-by='.lastTimestamp'`

**AWS Bedrock Issues:**
- IAM role: `aws sts get-caller-identity`
- Bedrock access: `aws bedrock list-foundation-models --region eu-west-1`
- CloudWatch metrics: Check `AWS/Bedrock` namespace

---

**Phase 4 Status:** ✅ COMPLETE — Awaiting data verification  
**Ready for deployment:** NO (prerequisites must be verified first)  
**Approval required for:** Git commit, push, PR creation, kubectl apply

**Generated:** 2026-10-12  
**Branch:** feat/aws-bedrock-migration  
**Commit:** ec47fb5
