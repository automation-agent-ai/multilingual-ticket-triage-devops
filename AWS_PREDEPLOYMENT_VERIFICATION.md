# AWS Pre-Deployment Verification Report
**Date:** 2026-10-12  
**Phase:** Pre-deployment verification and path correction  
**Status:** ✅ Ready for GHCR image publication

---

## 🔍 ISSUE #1: DATA PATHS — RESOLVED

### **Problem Identified**
AWS overlays referenced non-existent `/mnt/data/*` paths.

### **Actual Data Location (Verified)**
```
/home/ubuntu/workspaces/multilingual-ticket-triage-devops/data/
├── tickets.duckdb       (26 MB, 755, ubuntu:ubuntu)
└── lancedb/             (81 MB)
    ├── __manifest/
    └── ticket_embeddings.lance/
```

### **Data Integrity Verification**
✅ **DuckDB SHA-256:** `f4d4dc42ef61c8a6267a76a68c2f386d6235261eba8788f3215bdb2ba9f50887`  
✅ **LanceDB Structure:** Complete (manifests + transactions present)  
✅ **Permissions:** `755 ubuntu:ubuntu` (UID 1000, readable by pod)  
✅ **Total Size:** 107 MB  

### **Resolution Applied**
Updated both `aws-dev` and `aws-prod` overlay patches:

**Before:**
```yaml
volumes:
  - name: app-data
    hostPath:
      path: /mnt/data/app-data-dev  # WRONG - doesn't exist
```

**After:**
```yaml
volumes:
  - name: app-data
    hostPath:
      path: /home/ubuntu/workspaces/multilingual-ticket-triage-devops/data
      type: Directory  # Verified existing path
```

**HuggingFace Cache:**
```yaml
  - name: hf-cache
    hostPath:
      path: /home/ubuntu/.cache/huggingface
      type: DirectoryOrCreate  # Will be created on first pod startup
```

---

## 🐳 ISSUE #2: CONTAINER IMAGE — CRITICAL BLOCKER

### **Problem Identified**
Commit `ec47fb5` (Bedrock support) is **NOT yet published to GHCR**.

### **Current State**
- **Feature branch commit:** `ec47fb57f0f1e7b1ebc9f1d2534060a12d47691d` (Bedrock)
- **Main branch commit:** `44360bc73f7ac62a627480faef7a9b5374b87b99` (Terraform, NO Bedrock)
- **Latest GHCR image:** `sha-44360bc...` (NO Bedrock support)
- **Bedrock image status:** ❌ NOT YET BUILT OR PUBLISHED

### **Why Bedrock Image Doesn't Exist**
1. ✅ Feature branch exists: `feat/aws-bedrock-migration`
2. ❌ Not merged to `main` (main is still at `44360bc`)
3. ❌ CI workflow only publishes images on push to `main`
4. ❌ Pull requests build and scan, but do NOT push to GHCR

### **CI/CD Trigger Analysis**

**`.github/workflows/ci.yml`:**
```yaml
on:
  push:
    branches: [main]        # ← Publishes to GHCR
  pull_request:
    branches: [main]        # ← NO GHCR push (test + scan only)
```

**Image publication conditions (ALL required):**
```yaml
if: >-
  github.event_name == 'push'              # NOT pull_request
  && github.ref == 'refs/heads/main'       # NOT feature branch
  && steps.trivy.outcome == 'success'      # Trivy scan passed
```

**`.github/workflows/deploy-dev.yml`:**
```yaml
runs-on: [self-hosted, linux, triage-dev-deployer]  # WSL runner ONLY
```

**Key Safety Finding:**
✅ **WSL deployment is ISOLATED from AWS**
- Deploy-dev requires self-hosted runner with label `triage-dev-deployer`
- This AWS EC2 instance has **NO GitHub runner installed**
- Auto-deployment after merge will **ONLY affect WSL**, not AWS

### **Safest GHCR Publication Path**

**✅ RECOMMENDED: Merge via Pull Request**

```bash
# Step 1: Create PR from feature branch to main
cd /home/ubuntu/workspaces/multilingual-ticket-triage-devops
gh pr create \
  --title "feat: AWS Bedrock migration with k8s overlays" \
  --body "Adds Bedrock support + AWS deployment overlays"

# Step 2: PR triggers CI
# → Tests run (761 + new Bedrock tests)
# → Docker build + Trivy scan
# → NO GHCR push (PR limitation)

# Step 3: After PR approval and merge to main
# → CI runs AGAIN automatically
# → Tests pass
# → Trivy scan passes
# → Image pushed: ghcr.io/.../sha-ec47fb57f0f1e7b1ebc9f1d2534060a12d47691d
# → WSL deploy-dev triggers (self-hosted runner, NOT AWS)

# Step 4: Bedrock image now available for AWS deployment
docker pull ghcr.io/automation-agent-ai/multilingual-ticket-triage-devops:sha-ec47fb57f0f1e7b1ebc9f1d2534060a12d47691d
```

**Why This is Safe:**
1. ✅ Trivy scan enforced (security gate)
2. ✅ Tests validated (761 + Bedrock unit tests)
3. ✅ WSL deployment isolated (self-hosted runner not on AWS)
4. ✅ Immutable SHA tag for audit trail
5. ✅ No manual Docker build required (uses tested CI pipeline)

### **Current Overlay Configuration**
Overlays reference Bedrock image with documentation:

```yaml
images:
  - name: ticket-triage-api
    newName: ghcr.io/automation-agent-ai/multilingual-ticket-triage-devops
    newTag: sha-ec47fb57f0f1e7b1ebc9f1d2534060a12d47691d  # Bedrock commit

# Comment added:
# ⚠️ PREREQUISITE: Bedrock image must be published to GHCR before deployment
# DO NOT deploy until Bedrock image is published.
```

---

## ☸️ ISSUE #3: KUBERNETES READINESS — VERIFIED

### **k3s Cluster Status**
✅ **Cluster operational:**
```
NAME              STATUS   AGE
ip-172-31-43-47   Ready    3h58m   (v1.36.5+k3s1)
```

✅ **kubectl configured:** Client v1.36.5+k3s1, Kustomize v5.8.1  
✅ **Existing namespaces:** `default`, `kube-system`, `kube-node-lease`, `kube-public`  
✅ **No triage namespaces yet:** `triage-dev` and `triage-prod` will be created by deployment

### **Overlay Rendering Validation**

**AWS DEV:**
```bash
kubectl kustomize k8s/overlays/aws-dev
✅ Rendered successfully: 167 lines
✅ No YAML syntax errors
```

**AWS PROD:**
```bash
kubectl kustomize k8s/overlays/aws-prod
✅ Rendered successfully: 167 lines
✅ No YAML syntax errors
```

### **Configuration Verification**

| Component | DEV Value | PROD Value | Status |
|-----------|-----------|------------|--------|
| **Namespace** | `triage-dev` | `triage-prod` | ✅ Correct |
| **Image** | `sha-ec47fb5...` | `sha-ec47fb5...` | ⚠️ Not published |
| **CONFIG_PATH** | `/app/config-aws.yaml` | `/app/config-aws.yaml` | ✅ Bedrock |
| **AWS_REGION** | `eu-west-1` | `eu-west-1` | ✅ Correct |
| **Data Path** | `/home/ubuntu/.../data` | `/home/ubuntu/.../data` | ✅ Verified |
| **HF Cache** | `~/.cache/huggingface` | `~/.cache/huggingface` | ✅ Will create |
| **Service Type** | `ClusterIP` | `ClusterIP` | ✅ Internal |
| **CPU Request** | 500m | 1000m | ✅ Within capacity |
| **CPU Limit** | 1500m | 2000m | ✅ Within capacity |
| **RAM Request** | 2Gi | 2Gi | ✅ Within capacity |
| **RAM Limit** | 4Gi | 6Gi | ✅ Within capacity |
| **Readiness Probe** | `/ready` | `/ready` | ✅ Present |
| **Security Context** | Non-root, UID 1000 | Non-root, UID 1000 | ✅ Hardened |

### **Resource Allocation Summary**
**Total Requests:** 1.5 vCPU / 4 GiB (37.5% / 25% of node)  
**Total Limits:** 3.5 vCPU / 10 GiB (87.5% / 62.5% of node)  
**Node Capacity:** 4 vCPU / 16 GiB  
**Buffer Remaining:** 2.5 vCPU / 6 GiB (for OS, k3s, monitoring)

### **Security Validation**
✅ **No hardcoded credentials**  
✅ **IAM instance role** (credentials will be available via EC2 metadata in pod)  
✅ **Data volumes read-only**  
✅ **Non-root container** (UID 1000)  
✅ **Capabilities dropped** (ALL)  
✅ **Privilege escalation disabled**  
✅ **Services internal** (ClusterIP, no public exposure)

### **IAM Instance Role — Runtime Verification Required**

⚠️ **Cannot verify Bedrock access from host:**
- AWS CLI not installed on this EC2 instance
- IAM metadata service returned empty response
- **Verification must happen at runtime** after pod deployment

**Runtime Verification Plan:**
```bash
# After first pod deployment:
POD=$(kubectl get pod -n triage-dev -l app=ticket-triage -o jsonpath='{.items[0].metadata.name}')

# Check IAM role available in pod
kubectl exec -n triage-dev $POD -- env | grep AWS

# Check Bedrock access from pod
kubectl exec -n triage-dev $POD -- python3 -c "
import boto3
sts = boto3.client('sts', region_name='eu-west-1')
print('IAM Identity:', sts.get_caller_identity())

bedrock = boto3.client('bedrock', region_name='eu-west-1')
models = bedrock.list_foundation_models()
print('Bedrock accessible:', len(models['modelSummaries']), 'models')
"
```

**Expected Pod Environment:**
- `AWS_DEFAULT_REGION=eu-west-1`
- `AWS_REGION=eu-west-1`
- IAM credentials available via EC2 metadata (169.254.169.254)

**If IAM role is missing:**
1. Attach IAM role to EC2 instance via AWS Console
2. Restart pod: `kubectl rollout restart deployment/ticket-triage -n triage-dev`

**Required IAM Policy:**
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

---

## 📋 REMAINING BLOCKERS

### 🚨 CRITICAL BLOCKER #1: Bedrock Image Not Published

**Status:** ❌ BLOCKING  
**Issue:** Commit `ec47fb5` with Bedrock support not in GHCR  
**Resolution:** Merge `feat/aws-bedrock-migration` to `main` via PR  
**ETA:** ~15 minutes (PR creation + CI pipeline)

**Action Required:**
```bash
# Create PR (requires approval)
gh pr create \
  --title "feat: AWS Bedrock migration" \
  --body "Adds Bedrock provider + AWS k8s overlays. Data paths corrected."

# After merge: CI publishes image automatically
# Monitor: https://github.com/automation-agent-ai/multilingual-ticket-triage-devops/actions
```

### ⚠️ RUNTIME VERIFICATION #2: IAM Role Bedrock Access

**Status:** ⚠️ CANNOT VERIFY YET  
**Issue:** AWS CLI not installed on EC2, metadata service unresponsive  
**Resolution:** Verify after first pod deployment (runtime check)  

**If Bedrock access fails at runtime:**
1. Attach IAM role with `bedrock:InvokeModel` permission
2. Restart deployment

---

## ✅ SHORTEST SAFE PATH TO FIRST WORKING AWS DEV POD

### **Phase 1: Publish Bedrock Image (15 min)**

```bash
# On this EC2 instance:
cd /home/ubuntu/workspaces/multilingual-ticket-triage-devops

# Step 1: Review corrected overlays
git diff k8s/overlays/aws-dev/
git diff k8s/overlays/aws-prod/

# Step 2: Commit path corrections
git add k8s/overlays/aws-dev/
git add k8s/overlays/aws-prod/
git add AWS_PREDEPLOYMENT_VERIFICATION.md

git commit -m "fix(k8s): correct AWS overlay data paths to actual EC2 locations

- Change /mnt/data/* to /home/ubuntu/workspaces/.../data
- Verify DuckDB integrity (SHA-256)
- Document Bedrock image publication requirement
- Add IAM role runtime verification plan"

# Step 3: Push to remote
git push origin feat/aws-bedrock-migration

# Step 4: Create PR
gh pr create \
  --title "feat: AWS Bedrock migration with corrected data paths" \
  --body "## Changes
- Bedrock provider with Nova Micro support
- AWS k8s overlays (triage-dev, triage-prod)
- Corrected data paths to actual EC2 locations
- IAM instance role for credentials

## Verification
- Data integrity verified: DuckDB SHA-256 confirmed
- Overlay rendering: PASS
- Security scan: No embedded credentials
- WSL overlays: Unchanged

See: AWS_PREDEPLOYMENT_VERIFICATION.md"

# Step 5: Wait for PR approval and merge
# → CI runs automatically
# → Image published to GHCR
# → WSL deployment (isolated from AWS)
```

### **Phase 2: Deploy DEV Pod (5 min)**

```bash
# After CI completes and image is published:

# Step 1: Pull latest code (includes merged changes)
git checkout main
git pull origin main

# Step 2: Verify image exists (optional)
# If docker installed:
# docker manifest inspect ghcr.io/automation-agent-ai/multilingual-ticket-triage-devops:sha-ec47fb57f0f1e7b1ebc9f1d2534060a12d47691d

# Step 3: Deploy DEV
kubectl apply -k k8s/overlays/aws-dev

# Expected output:
# namespace/triage-dev created
# service/ticket-triage created
# deployment.apps/ticket-triage created

# Step 4: Watch pod startup
kubectl get pods -n triage-dev -w
# Wait for: Running status (2-5 min for model download)
```

### **Phase 3: Verify DEV Pod (3 min)**

```bash
# Step 1: Check pod status
kubectl get pods -n triage-dev -o wide

POD=$(kubectl get pod -n triage-dev -l app=ticket-triage -o jsonpath='{.items[0].metadata.name}')
echo "Pod name: $POD"

# Step 2: Check startup logs
kubectl logs -n triage-dev $POD --tail=50

# Expected logs:
# "Loading config from: /app/config-aws.yaml"
# "Initializing BedrockClient: model=eu.amazon.nova-micro-v1:0, region=eu-west-1"
# "Agent initialized successfully"
# "Application startup complete"

# Step 3: Health check
kubectl exec -n triage-dev $POD -- curl -sf http://localhost:8000/health
# Expected: {"status": "healthy"}

# Step 4: Readiness check
kubectl exec -n triage-dev $POD -- curl -sf http://localhost:8000/ready
# Expected: {"ready": true, "message": "Agent initialized"}

# Step 5: Verify IAM role and Bedrock access
kubectl exec -n triage-dev $POD -- env | grep AWS
# Expected: AWS_REGION=eu-west-1

kubectl exec -n triage-dev $POD -- python3 -c "
import boto3
sts = boto3.client('sts', region_name='eu-west-1')
print('✅ IAM role:', sts.get_caller_identity()['Arn'])

bedrock = boto3.client('bedrock', region_name='eu-west-1')
models = bedrock.list_foundation_models()
print('✅ Bedrock accessible:', len(models['modelSummaries']), 'models')
"

# Step 6: Smoke test Bedrock inference
kubectl exec -n triage-dev $POD -- curl -sf http://localhost:8000/triage \
  -X POST \
  -H "Content-Type: application/json" \
  -d '{
    "ticket_id": "smoke-001",
    "subject": "Cannot access my account",
    "body": "I forgot my password and the reset link expired. Please help urgently."
  }' | python3 -m json.tool

# Expected response:
# {
#   "ticket_id": "smoke-001",
#   "topic": "Technical / Online Access",
#   "urgency": "High",
#   "confidence": 0.85,
#   ...
# }
```

---

## 🎯 SUCCESS CRITERIA

### **Phase 1 Complete:**
- [x] Data paths corrected to actual EC2 locations
- [x] Overlays render without errors
- [x] Data integrity verified (DuckDB SHA-256)
- [x] Security validation (no embedded credentials)
- [ ] PR created (awaiting approval)
- [ ] PR merged to main
- [ ] CI publishes Bedrock image to GHCR

### **Phase 2 Complete:**
- [ ] DEV namespace created
- [ ] DEV pod reaches Running status
- [ ] Pod logs show "BedrockClient initialized"
- [ ] HuggingFace model downloaded to cache

### **Phase 3 Complete:**
- [ ] `/health` returns 200
- [ ] `/ready` returns `{"ready": true}`
- [ ] IAM role credentials accessible in pod
- [ ] Bedrock `list_foundation_models` succeeds
- [ ] Smoke test `/triage` returns valid response
- [ ] No errors in pod logs

---

## 📊 FILES MODIFIED

```
k8s/overlays/aws-dev/patches/deployment.yaml    # Data paths corrected
k8s/overlays/aws-dev/kustomization.yaml         # Image documentation updated
k8s/overlays/aws-prod/patches/deployment.yaml   # Data paths corrected
k8s/overlays/aws-prod/kustomization.yaml        # Image documentation updated
AWS_PREDEPLOYMENT_VERIFICATION.md               # This report
```

**Git status:**
```
modified:   k8s/overlays/aws-dev/patches/deployment.yaml
modified:   k8s/overlays/aws-dev/kustomization.yaml
modified:   k8s/overlays/aws-prod/patches/deployment.yaml
modified:   k8s/overlays/aws-prod/kustomization.yaml
untracked:  AWS_PREDEPLOYMENT_VERIFICATION.md
```

---

## 🔄 ROLLBACK PLAN

### If PR merge fails:
```bash
# No changes to main; feature branch remains isolated
```

### If CI build fails:
```bash
# Fix issue on feature branch
git commit --amend
git push --force-with-lease
# Re-request PR merge
```

### If DEV deployment fails:
```bash
# Delete namespace and retry
kubectl delete namespace triage-dev

# Check logs:
kubectl describe pod -n triage-dev <pod-name>
kubectl logs -n triage-dev <pod-name>

# Common fixes:
# 1. IAM role missing: Attach role, restart pod
# 2. Data path issue: Verify hostPath in patch
# 3. Image pull fail: Verify GHCR image exists
```

---

**Report Date:** 2026-10-12  
**Verification Status:** ✅ Overlays corrected and validated  
**Blocking Issues:** 1 critical (Bedrock image not published)  
**Runtime Verifications:** 1 (IAM role Bedrock access)  
**Ready for Deployment:** NO (awaiting image publication)  
**Estimated Time to First Pod:** 20 minutes (after PR merge)
