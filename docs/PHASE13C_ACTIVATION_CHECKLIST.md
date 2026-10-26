# Phase 13C — AWS CI/CD Activation Checklist

**Date:** 2026-10-13  
**Status:** Ready for Controlled Activation  

---

## Critical Issues Resolved

### Issue 1: workflow_dispatch Discoverability ✅
**Problem:** Manual PROD promotion unavailable (workflow not on main branch)  
**Solution:** Created `aws-prod-promote.yml` for main branch (minimal, PROD-only)  
**File:** `.github/workflows/aws-prod-promote.yml` (new)

### Issue 2: Duplicate Workflow Conflict ⚠️
**Problem:** Both `aws-feature-image-build.yml` and `aws-ci-cd.yml` trigger on push  
**Solution:** Delete `aws-feature-image-build.yml` (superseded by integrated workflow)  
**Action Required:** `git rm .github/workflows/aws-feature-image-build.yml`

### Issue 3: PROD Deployment Safeguards ✅
**Problem:** No fail-safe check for environment protection  
**Solution:** Added validation step to verify aws-prod has required reviewers  
**File:** `.github/workflows/aws-ci-cd.yml` (updated)

---

## Activation Prerequisites (MUST Complete Before Testing)

### 1. GitHub Environments (Repository Admin)

**Create aws-dev:**
```bash
gh api repos/automation-agent-ai/multilingual-ticket-triage-devops/environments/aws-dev \
  -X PUT \
  -f wait_timer=0 \
  -f prevent_self_review=false

# Add deployment branches
gh api repos/automation-agent-ai/multilingual-ticket-triage-devops/environments/aws-dev/deployment-branch-policies \
  -X POST \
  -f name=feat/aws-bedrock-migration

gh api repos/automation-agent-ai/multilingual-ticket-triage-devops/environments/aws-dev/deployment-branch-policies \
  -X POST \
  -f name=main
```

**Verify aws-dev:**
```bash
gh api repos/automation-agent-ai/multilingual-ticket-triage-devops/environments/aws-dev \
  --jq '{name, deployment_branch_policy}'
```

**Create aws-prod with required reviewer:**
```bash
# Get your user ID first
USER_ID=$(gh api user --jq .id)

# Create aws-prod environment
gh api repos/automation-agent-ai/multilingual-ticket-triage-devops/environments/aws-prod \
  -X PUT \
  -f wait_timer=0 \
  -f prevent_self_review=false \
  -F reviewers="[{\"type\":\"User\",\"id\":${USER_ID}}]"

# Add deployment branches
gh api repos/automation-agent-ai/multilingual-ticket-triage-devops/environments/aws-prod/deployment-branch-policies \
  -X POST \
  -f name=feat/aws-bedrock-migration

gh api repos/automation-agent-ai/multilingual-ticket-triage-devops/environments/aws-prod/deployment-branch-policies \
  -X POST \
  -f name=main
```

**Verify aws-prod has reviewer:**
```bash
gh api repos/automation-agent-ai/multilingual-ticket-triage-devops/environments/aws-prod \
  --jq '.protection_rules[] | select(.type=="required_reviewers") | .reviewers | length'
# Should return: 1 or more
```

### 2. AWS Infrastructure (Terraform Agent / AWS Admin)

**IAM OIDC Provider:**
```bash
# Check if exists
aws iam list-open-id-connect-providers | grep token.actions.githubusercontent.com

# If missing, create via Terraform or:
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
```

**IAM Role:**
```bash
# Check if exists
aws iam get-role --role-name github-actions-aws-deployer 2>/dev/null

# If missing, deploy Terraform from docs/AWS_IAM_SETUP.md
# OR create manually (trust policy with environment-based subject)
```

**SSM Agent on EC2:**
```bash
# SSH to EC2 instance i-07bc3aaf0d692974d
sudo snap install amazon-ssm-agent --classic
sudo snap start amazon-ssm-agent

# Verify from local machine
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=i-07bc3aaf0d692974d" \
  --query 'InstanceInformationList[0].PingStatus' \
  --output text
# Should return: "Online"
```

**EC2 IAM Role Enhancement:**
```bash
# Verify EC2 instance has IAM role attached
aws ec2 describe-instances --instance-ids i-07bc3aaf0d692974d \
  --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn'

# Ensure role has AmazonSSMManagedInstanceCore policy
ROLE_NAME="liora-triage-bedrock-role"
aws iam attach-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
```

**EC2 Instance Tag:**
```bash
aws ec2 create-tags \
  --resources i-07bc3aaf0d692974d \
  --tags Key=Environment,Value=production
```

### 3. Kubernetes Namespaces (EC2 Admin)

**Verify namespaces exist:**
```bash
# SSH to EC2
kubectl get namespace triage-dev
kubectl get namespace triage-prod
```

**If missing, create:**
```bash
kubectl create namespace triage-dev
kubectl create namespace triage-prod
```

---

## Activation Sequence

### Step 1: Apply Code Corrections (Local Worktree)

```bash
cd /home/ubuntu/workspaces/cicd-worktree

# Delete duplicate workflow file
git rm .github/workflows/aws-feature-image-build.yml

# Commit corrections
git add .github/workflows/aws-ci-cd.yml
git add .github/workflows/aws-prod-promote.yml
git add docs/PHASE13C_INTEGRATION_CHECK.md
git add docs/PHASE13C_ACTIVATION_CHECKLIST.md

git commit -m "fix(cicd): Phase 13C corrections - Remove duplicate workflow, add safeguards"

# Push to feat/aws-cicd
git push origin feat/aws-cicd
```

**Verify:**
```bash
git log --oneline -1
git diff origin/feat/aws-cicd HEAD  # Should be empty
```

### Step 2: Merge to feat/aws-bedrock-migration (Enables DEV)

```bash
cd /home/ubuntu/workspaces/multilingual-ticket-triage-devops
git checkout feat/aws-bedrock-migration
git pull origin feat/aws-bedrock-migration

# Merge corrected cicd branch
git merge feat/aws-cicd --no-ff -m "feat(cicd): Integrate corrected AWS CI/CD pipeline (Phase 13C)"

# Verify no duplicate workflows
ls -la .github/workflows/ | grep aws-
# Should show:
#   aws-ci-cd.yml          (integrated CI + DEV deployment)
#   aws-prod-promote.yml   (PROD promotion only, for main)

# Push (triggers automatic DEV deployment if prerequisites complete)
git push origin feat/aws-bedrock-migration
```

**Result:**
- GitHub Actions run starts on feat/aws-bedrock-migration
- If prerequisites met: Test → Build → Deploy DEV
- If prerequisites missing: Job fails with clear error message

### Step 3: Verify DEV Deployment

**Monitor GitHub Actions:**
```bash
# Watch workflow run
gh run watch

# Or via URL
echo "https://github.com/automation-agent-ai/multilingual-ticket-triage-devops/actions"
```

**Check DEV namespace (via SSM or SSH):**
```bash
kubectl get pods -n triage-dev -l app=multilingual-ticket-triage
kubectl get deployment -n triage-dev multilingual-ticket-triage -o wide

# Verify image deployed
kubectl get deployment -n triage-dev multilingual-ticket-triage \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
# Should show: ghcr.io/.../aws-sha-<commit>@sha256:<digest>
```

**Smoke test:**
```bash
# If DEV has ingress/gateway configured
curl http://dev.your-domain.com/health

# Or port-forward
kubectl port-forward -n triage-dev deployment/multilingual-ticket-triage 8080:8080
curl http://localhost:8080/health
```

### Step 4: Add PROD Promotion to main (Enables UI Button)

**After DEV validated:**
```bash
cd /home/ubuntu/workspaces/multilingual-ticket-triage-devops
git checkout main
git pull origin main

# Create feature branch
git checkout -b feat/add-prod-promotion

# Copy PROD workflow (already exists in feat/aws-bedrock-migration)
git checkout feat/aws-bedrock-migration -- .github/workflows/aws-prod-promote.yml

# Commit
git add .github/workflows/aws-prod-promote.yml
git commit -m "feat(cicd): Add AWS PROD promotion workflow (manual only)"

# Push
git push origin feat/add-prod-promotion

# Create PR to main
gh pr create \
  --base main \
  --head feat/add-prod-promotion \
  --title "Add AWS PROD Promotion Workflow" \
  --body "Adds minimal workflow for manual PROD deployment via GitHub Actions UI.

- Manual trigger only (workflow_dispatch)
- Requires typing PROMOTE
- Requires aws-prod environment approval
- Does NOT trigger on push
- Safe to merge (no automatic deployments)"

# Review and merge
gh pr view --web
```

**After merge to main:**
```bash
# Verify workflow registered
gh workflow list | grep "AWS PROD"
# Should show: AWS PROD Promotion  active  aws-prod-promote.yml

# GitHub UI now shows "Run workflow" button
echo "https://github.com/automation-agent-ai/multilingual-ticket-triage-devops/actions/workflows/aws-prod-promote.yml"
```

### Step 5: Test PROD Promotion (Manual)

**Option A: Via GitHub UI (After main merge)**
1. Go to: Actions → AWS PROD Promotion → Run workflow
2. Branch: `main` (or `feat/aws-bedrock-migration` if workflow exists there)
3. Image tag: `aws-sha-5090097636b536e2f4dc16eae2428a7fb7748ea4` (from DEV)
4. Confirm: `PROMOTE`
5. Click "Run workflow"
6. Approve as required reviewer
7. Monitor deployment

**Option B: Via API (Before main merge)**
```bash
# If aws-prod-promote.yml not yet on main, trigger from feature branch
gh api repos/automation-agent-ai/multilingual-ticket-triage-devops/actions/workflows/aws-prod-promote.yml/dispatches \
  -f ref=feat/aws-bedrock-migration \
  -f inputs[image_tag]=aws-sha-5090097636b536e2f4dc16eae2428a7fb7748ea4 \
  -f inputs[confirm_production]=PROMOTE

# Or via aws-ci-cd.yml
gh api repos/automation-agent-ai/multilingual-ticket-triage-devops/actions/workflows/aws-ci-cd.yml/dispatches \
  -f ref=feat/aws-bedrock-migration \
  -f inputs[deploy_target]=prod \
  -f inputs[confirm_production]=PROMOTE \
  -f inputs[image_tag]=aws-sha-5090097636b536e2f4dc16eae2428a7fb7748ea4
```

**Verify PROD deployment:**
```bash
kubectl get pods -n triage-prod -l app=multilingual-ticket-triage
kubectl get deployment -n triage-prod multilingual-ticket-triage \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
```

---

## Testing Checklist

### DEV Deployment (Automatic)
- [ ] Push to feat/aws-bedrock-migration triggers workflow
- [ ] Test job passes
- [ ] Build job creates and pushes image
- [ ] Deploy-dev job runs (no approval needed)
- [ ] Image deployed to triage-dev namespace
- [ ] Pods running and healthy
- [ ] Deployment uses immutable digest (@sha256:...)

### PROD Deployment (Manual)
- [ ] workflow_dispatch available (UI button or API)
- [ ] Requires typing "PROMOTE"
- [ ] Requires aws-prod environment approval
- [ ] Reviewer receives notification
- [ ] Reviewer can approve/reject
- [ ] Image deployed to triage-prod namespace
- [ ] Pods running and healthy
- [ ] Deployment uses immutable digest (@sha256:...)
- [ ] Rollback works if deployment fails

### Safeguards
- [ ] Push to feature branch does NOT deploy to PROD
- [ ] aws-prod has at least 1 required reviewer
- [ ] Fail-safe check blocks deployment if no reviewer
- [ ] Only aws-sha-* images can be deployed
- [ ] No duplicate CI runs (aws-feature-image-build.yml deleted)

---

## Emergency Rollback

**If PROD deployment fails:**

Workflows include automatic rollback, but manual rollback:

```bash
# SSH to EC2 or use SSM
kubectl rollout undo deployment/multilingual-ticket-triage -n triage-prod

# Or rollback to specific revision
kubectl rollout history deployment/multilingual-ticket-triage -n triage-prod
kubectl rollout undo deployment/multilingual-ticket-triage -n triage-prod --to-revision=<N>

# Verify
kubectl rollout status deployment/multilingual-ticket-triage -n triage-prod
```

---

## Next Steps After Activation

### Phase 14: Production Hardening
1. Add Kubernetes RBAC (namespace-scoped service accounts)
2. Separate DEV and PROD IAM roles (optional)
3. Add monitoring and alerting
4. Document runbook for on-call
5. Set up log aggregation

### Phase 15: Advanced Features
1. Canary deployments
2. Blue-green deployment strategy
3. Automated smoke tests
4. Performance regression detection

---

## Documentation References

- **Architecture:** `docs/AWS_CICD.md`
- **IAM Setup:** `docs/AWS_IAM_SETUP.md`
- **Phase 13B Report:** `docs/PHASE13B_FINAL_REPORT.md`
- **Phase 13C Analysis:** `docs/PHASE13C_INTEGRATION_CHECK.md`

---

## Summary

**Files Modified:**
- ✅ `.github/workflows/aws-ci-cd.yml` (added fail-safe check)
- ✅ `.github/workflows/aws-prod-promote.yml` (new, for main)
- ⏸️ `.github/workflows/aws-feature-image-build.yml` (to be deleted)

**Prerequisites:**
- ⏸️ GitHub Environments (aws-dev, aws-prod with reviewer)
- ⏸️ AWS IAM (OIDC provider, role, policies)
- ⏸️ SSM Agent (EC2 instance)
- ⏸️ Kubernetes namespaces (triage-dev, triage-prod)

**Activation Path:**
1. Complete prerequisites
2. Delete duplicate workflow
3. Merge to feat/aws-bedrock-migration (enables DEV)
4. Test DEV deployment
5. Add PROD workflow to main (enables UI)
6. Test PROD promotion

**Status:** Ready for controlled activation after prerequisites complete.
