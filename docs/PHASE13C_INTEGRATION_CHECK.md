# Phase 13C — Final Integration Check Report

**Date:** 2026-10-13  
**Branch:** feat/aws-cicd  
**Status:** CRITICAL ISSUES IDENTIFIED — Corrections Required  

---

## Executive Summary

Conducted comprehensive integration check of corrected AWS CI/CD architecture. Identified **two critical blocking issues** that prevent safe activation:

1. ❌ **workflow_dispatch visibility** — Manual PROD promotion unavailable until workflow on main
2. ⚠️ **Workflow file conflict** — Both `aws-feature-image-build.yml` and `aws-ci-cd.yml` trigger on same event

**Recommendation:** Require controlled merge to main OR redesign for feature-branch operation.

---

## Issue 1: workflow_dispatch Discoverability (CRITICAL)

### GitHub Actions Constraint

**Documentation:** [Events that trigger workflows - workflow_dispatch](https://docs.github.com/en/actions/using-workflows/events-that-trigger-workflows#workflow_dispatch)

> **Key constraint:** To manually trigger a workflow using `workflow_dispatch`, the workflow file **must exist in the default branch** (main).

**Evidence from repository:**
```bash
$ gh api repos/.../actions/workflows --jq '.workflows[] | select(.name | contains("AWS"))'
{
  "name": "AWS Feature Image Build",
  "path": ".github/workflows/aws-feature-image-build.yml",
  "state": "active"
}
# aws-ci-cd.yml NOT REGISTERED (only exists on feat/aws-cicd)
```

**Default branch:** `main`  
**Current workflow location:** `feat/aws-cicd` and `feat/aws-bedrock-migration` (after merge)  
**Not on:** `main`

### Impact

❌ **Manual PROD promotion NOT AVAILABLE** — Workflow won't appear in GitHub Actions UI  
❌ **workflow_dispatch button invisible** — No way to trigger manual deployment  
❌ **Cannot test on feature branch** — Even with API or gh CLI  

**GitHub UI behavior:**
- Actions → Workflows → Only shows workflows from default branch
- "Run workflow" dropdown → Only lists workflows from main
- Feature branch workflows → Hidden from manual trigger UI

### Verification

**Current state:**
```bash
# On main branch (via API)
$ gh api repos/.../contents/.github/workflows --jq '.[] | select(.name | contains("aws"))'
# Returns: aws-feature-image-build.yml ONLY

# aws-ci-cd.yml does NOT exist on main
```

### Solution Options

**Option A: Merge aws-ci-cd.yml to main (SIMPLEST)**

1. Merge feat/aws-cicd → feat/aws-bedrock-migration
2. Create PR: feat/aws-bedrock-migration → main
3. Merge to main (makes workflow_dispatch available)

**Pros:**
- ✅ workflow_dispatch immediately functional
- ✅ Automatic DEV deployment works
- ✅ Manual PROD promotion available

**Cons:**
- ⚠️ Workflow now registered on main
- ⚠️ Must coordinate with WSL pipeline
- ⚠️ Permanent addition to repository

**Option B: Replace aws-feature-image-build.yml on main (CLEANER)**

1. On main: Delete `aws-feature-image-build.yml`
2. On main: Add `aws-ci-cd.yml`
3. Result: Single integrated workflow on main

**Pros:**
- ✅ Eliminates workflow file conflict
- ✅ Cleaner architecture
- ✅ workflow_dispatch available

**Cons:**
- ⚠️ Requires main branch modification
- ⚠️ Loses separation of CI from CD

**Option C: workflow_dispatch via GitHub API (WORKAROUND)**

GitHub Actions API can trigger workflows on non-default branches:
```bash
gh api repos/.../actions/workflows/aws-ci-cd.yml/dispatches \
  -f ref=feat/aws-bedrock-migration \
  -f inputs[deploy_target]=prod \
  -f inputs[confirm_production]=PROMOTE \
  -f inputs[image_tag]=aws-sha-XXXXX
```

**Pros:**
- ✅ Works without main branch merge
- ✅ Feature branch testing possible

**Cons:**
- ❌ Not user-friendly (requires CLI/API knowledge)
- ❌ No GitHub UI button
- ❌ Harder for emergency rollback

**Option D: Separate PROD promotion workflow on main (RECOMMENDED)**

Create minimal `aws-prod-promote.yml` on main:
```yaml
name: AWS PROD Promotion

on:
  workflow_dispatch:
    inputs:
      image_tag:
        required: true
      confirm_production:
        required: true

jobs:
  promote:
    runs-on: ubuntu-latest
    environment: aws-prod
    # ... same PROD deployment logic
```

**Pros:**
- ✅ workflow_dispatch available (on main)
- ✅ Minimal main branch impact
- ✅ DEV deployment stays on feature branch
- ✅ Clear separation: CI/DEV (feature) vs PROD (main)

**Cons:**
- ⚠️ Requires one workflow on main
- ⚠️ Duplication of PROD deployment logic

### Recommended Solution

**Use Option D** — Separate PROD promotion workflow on main.

**Rationale:**
1. Preserves feature-branch CI/DEV workflow
2. Minimal main branch impact (one small workflow)
3. workflow_dispatch available for PROD promotion
4. Clear operational boundary (DEV=feature, PROD=main)
5. Safer (PROD promotion more visible/auditable)

---

## Issue 2: Duplicate Workflow Conflict

### Current State

**On feat/aws-bedrock-migration (after merge):**
- `aws-feature-image-build.yml` (CI only)
- `aws-ci-cd.yml` (integrated CI+CD)

**Both trigger on:** `push` to `feat/aws-bedrock-migration`

### Conflict Analysis

```yaml
# aws-feature-image-build.yml
on:
  push:
    branches: [feat/aws-bedrock-migration]
jobs:
  test: ...
  build-scan-push: ...

# aws-ci-cd.yml
on:
  push:
    branches: [feat/aws-bedrock-migration]
jobs:
  test: ...
  build: ...
  resolve-image: ...
  deploy-dev: ...
```

**Result on push:**
- ❌ TWO GitHub Actions runs start
- ❌ TWO CI builds (duplicate resource usage)
- ❌ TWO image pushes (same tag, race condition)
- ❌ ONE DEV deployment (from aws-ci-cd.yml)

**Image tag conflict:**
```
aws-feature-image-build.yml → ghcr.io/.../aws-sha-ABC123
aws-ci-cd.yml               → ghcr.io/.../aws-sha-ABC123  # SAME TAG
```

**GHCR behavior:** Last push wins (second workflow overwrites first)

### Impact

⚠️ **Resource waste** — Duplicate CI runs (2x cost)  
⚠️ **Race condition** — Two pushes to same GHCR tag  
⚠️ **Deployment confusion** — Which image was actually deployed?  
⚠️ **Pipeline reliability** — Non-deterministic behavior  

### Solution

**Delete aws-feature-image-build.yml after merging aws-ci-cd.yml**

**Migration plan:**
1. Merge feat/aws-cicd → feat/aws-bedrock-migration
2. Delete `aws-feature-image-build.yml` from feat/aws-bedrock-migration
3. Keep only `aws-ci-cd.yml`
4. Result: Single integrated workflow

**Verification:**
```bash
# After merge
cd feat/aws-bedrock-migration
git rm .github/workflows/aws-feature-image-build.yml
git commit -m "remove: Replace aws-feature-image-build with integrated aws-ci-cd"
git push
```

---

## Issue 3: GitHub Environment Protection

### Current Status

```bash
$ gh api repos/.../environments --jq '.environments[] | {name, protection_rules}'
{
  "name": "dev",
  "protection_rules": 0
}
# aws-dev and aws-prod DO NOT EXIST
```

**Missing environments:**
- ❌ `aws-dev` (needed for DEV deployment)
- ❌ `aws-prod` (needed for PROD approval gate)

### Required Configuration

**Environment: aws-dev**
```
Name: aws-dev
Wait timer: 0 minutes
Required reviewers: 0 (optional for testing)
Deployment branches: Selected branches
  - feat/aws-bedrock-migration
  - main
Deployment protection rules: None (optional)
```

**Environment: aws-prod**
```
Name: aws-prod
Wait timer: 0 minutes
Required reviewers: 1+ (MANDATORY)
  - [Select at least one reviewer]
Deployment branches: Selected branches
  - feat/aws-bedrock-migration
  - main
Deployment protection rules: Required reviewers
```

### Verification Points

**1. Repository eligibility:**
```bash
$ gh api repos/.../  --jq '{owner: .owner.type, visibility: .visibility}'
{
  "owner": "User",
  "visibility": "public"
}
```

✅ **Public repository** — Environment protection available  
✅ **User account** — Required reviewers available (even on free plan)

**2. Branch protection:**

**Critical:** Environment deployment branches must be configured to prevent:
- ❌ Deployments from untrusted forks
- ❌ Deployments from pull requests
- ❌ Deployments from arbitrary branches

**3. Approval enforcement:**

**Current workflow:**
```yaml
deploy-prod:
  environment: aws-prod  # ← Relies on environment existing
  needs: [resolve-image, validate-prod]
```

**Risk if aws-prod doesn't exist:**
- ⚠️ Job runs WITHOUT approval
- ⚠️ PROD deployment proceeds automatically
- ⚠️ No reviewer gate enforced

**Fix required:** Add fail-safe validation:
```yaml
deploy-prod:
  steps:
    - name: Verify environment protection
      run: |
        # Fail if aws-prod has no required reviewers
        REVIEWERS=$(gh api repos/${{ github.repository }}/environments/aws-prod \
          --jq '.protection_rules[] | select(.type=="required_reviewers") | .reviewers | length' \
          2>/dev/null || echo "0")
        
        if [ "$REVIEWERS" -lt 1 ]; then
          echo "::error::aws-prod environment has no required reviewers"
          echo "PROD deployment BLOCKED for safety"
          exit 1
        fi
```

---

## Issue 4: OIDC Subject Claim Format

### Current IAM Trust Policy

**In docs/AWS_IAM_SETUP.md:**
```json
{
  "Condition": {
    "StringEquals": {
      "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
      "token.actions.githubusercontent.com:sub": [
        "repo:automation-agent-ai/multilingual-ticket-triage-devops:environment:aws-dev",
        "repo:automation-agent-ai/multilingual-ticket-triage-devops:environment:aws-prod"
      ]
    }
  }
}
```

### Verification

**GitHub OIDC token subject format with environments:**

**Official documentation:** [Understanding the OIDC token](https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/about-security-hardening-with-openid-connect#understanding-the-oidc-token)

**Subject claim when using `environment`:**
```
repo:<org>/<repo>:environment:<environment-name>
```

**Example for this repository:**
```
# deploy-dev job (environment: aws-dev)
repo:automation-agent-ai/multilingual-ticket-triage-devops:environment:aws-dev

# deploy-prod job (environment: aws-prod)
repo:automation-agent-ai/multilingual-ticket-triage-devops:environment:aws-prod
```

### Repository Identity

**Owner type:** User (not Organization)  
**Account:** `automation-agent-ai`  
**Repository:** `multilingual-ticket-triage-devops`

**OIDC subject EXACTLY:**
```
repo:automation-agent-ai/multilingual-ticket-triage-devops:environment:aws-dev
repo:automation-agent-ai/multilingual-ticket-triage-devops:environment:aws-prod
```

### Trust Policy Correctness

✅ **Trust policy format:** CORRECT (environment-based)  
✅ **Repository name:** CORRECT (automation-agent-ai/multilingual-ticket-triage-devops)  
✅ **Environment names:** CORRECT (aws-dev, aws-prod)  
✅ **Audience claim:** CORRECT (sts.amazonaws.com)  

**No changes needed** — Trust policy in docs/AWS_IAM_SETUP.md is accurate.

---

## Issue 5: PROD Deployment Safeguards

### Current Conditions

**Job: resolve-image**
```yaml
- name: Decide deployment targets
  id: decide
  run: |
    DEPLOY_DEV="false"
    DEPLOY_PROD="false"
    
    if [ "${{ github.event_name }}" = "push" ]; then
      # Automatic: deploy to DEV only
      DEPLOY_DEV="true"
    elif [ "${{ github.event_name }}" = "workflow_dispatch" ]; then
      # Manual: deploy to selected target
      if [ "${{ github.event.inputs.deploy_target }}" = "dev" ]; then
        DEPLOY_DEV="true"
      elif [ "${{ github.event.inputs.deploy_target }}" = "prod" ]; then
        DEPLOY_PROD="true"
      fi
    fi
```

**Job: deploy-prod**
```yaml
deploy-prod:
  needs: [resolve-image, validate-prod]
  if: needs.resolve-image.outputs.deploy-prod == 'true'
  environment: aws-prod
```

### Analysis

**Automatic push to feat/aws-bedrock-migration:**
- `github.event_name` = `"push"`
- Logic: `DEPLOY_DEV="true"`, `DEPLOY_PROD="false"`
- Result: ✅ DEV deploys, ❌ PROD does NOT deploy

**Manual workflow_dispatch with deploy_target=dev:**
- `github.event_name` = `"workflow_dispatch"`
- `inputs.deploy_target` = `"dev"`
- Logic: `DEPLOY_DEV="true"`, `DEPLOY_PROD="false"`
- Result: ✅ DEV deploys, ❌ PROD does NOT deploy

**Manual workflow_dispatch with deploy_target=prod:**
- `github.event_name` = `"workflow_dispatch"`
- `inputs.deploy_target` = `"prod"`
- Logic: `DEPLOY_DEV="false"`, `DEPLOY_PROD="true"`
- Result: ❌ DEV does NOT deploy, ✅ PROD deploys (requires approval)

### Safeguards Verified

✅ **Feature-branch push:** NEVER deploys to PROD  
✅ **Explicit workflow_dispatch required:** PROD only via manual trigger  
✅ **Input validation:** Must select `deploy_target=prod`  
✅ **Confirmation required:** Must type `confirm_production=PROMOTE`  
✅ **Environment gate:** `environment: aws-prod` blocks until approval  
✅ **Job dependencies:** validate-prod must pass first  

### Additional Hardening Recommended

**Add explicit branch check:**
```yaml
deploy-prod:
  steps:
    - name: Verify deployment branch
      run: |
        ALLOWED_BRANCHES="feat/aws-bedrock-migration main"
        CURRENT_BRANCH="${{ github.ref_name }}"
        
        if ! echo "$ALLOWED_BRANCHES" | grep -qw "$CURRENT_BRANCH"; then
          echo "::error::PROD deployment not allowed from branch: $CURRENT_BRANCH"
          echo "Allowed branches: $ALLOWED_BRANCHES"
          exit 1
        fi
        
        echo "✅ Branch verified: $CURRENT_BRANCH"
```

**Add deployment frequency check:**
```yaml
- name: Check recent PROD deployments
  run: |
    # Warn if PROD deployed recently (prevent rapid changes)
    LAST_DEPLOY=$(gh api repos/${{ github.repository }}/deployments \
      --jq 'map(select(.environment=="aws-prod")) | .[0].created_at' \
      2>/dev/null || echo "")
    
    if [ -n "$LAST_DEPLOY" ]; then
      SECONDS_AGO=$(( $(date +%s) - $(date -d "$LAST_DEPLOY" +%s) ))
      if [ "$SECONDS_AGO" -lt 3600 ]; then
        echo "::warning::PROD was deployed $((SECONDS_AGO / 60)) minutes ago"
        echo "Consider waiting before deploying again"
      fi
    fi
```

---

## Issue 6: IAM and SSM Prerequisites Coordination

### Namespace Isolation Limits

**Architecture:**
- Single EC2 instance: `i-07bc3aaf0d692974d`
- Single k3s cluster
- Two namespaces: `triage-dev`, `triage-prod`
- Shared host: `/home/ubuntu/workspaces/`

**Security boundary:**
```
GitHub Actions (DEV or PROD)
  ↓ OIDC (environment-based trust)
IAM Role: github-actions-aws-deployer
  ↓ SSM Run Command
EC2 Instance (shared)
  ↓ kubectl (no namespace restrictions)
k3s Cluster
  ├─ triage-dev
  └─ triage-prod
```

### Current IAM Role Permissions

**SSM Policy:**
```json
{
  "Action": ["ssm:SendCommand"],
  "Resource": [
    "arn:aws:ssm:eu-west-1::document/AWS-RunShellScript",
    "arn:aws:ec2:eu-west-1:523231704152:instance/i-07bc3aaf0d692974d"
  ]
}
```

**Limitation:** Single IAM role can execute ANY command on EC2, including:
- ✅ Deploy to triage-dev
- ✅ Deploy to triage-prod
- ✅ Read/write any file on host
- ✅ Access any namespace
- ✅ Modify Kubernetes cluster-wide resources

### Namespace Isolation Analysis

**What OIDC trust provides:**
- ✅ Separate claims: `environment:aws-dev` vs `environment:aws-prod`
- ✅ GitHub Environment approval gates
- ✅ Audit trail (which environment triggered deployment)

**What IAM CANNOT enforce:**
- ❌ Namespace-level kubectl restrictions
- ❌ Prevention of DEV job deploying to PROD namespace
- ❌ File system access restrictions on shared host
- ❌ Cross-namespace resource access

**Root cause:** SSM executes commands as EC2 user (ubuntu) with full kubectl access.

### Improvement Options

**Option 1: Separate IAM roles (LIMITED BENEFIT)**

```
IAM Role: github-actions-aws-dev-deployer
  - Trust: environment:aws-dev only
  - SSM: Same EC2 instance

IAM Role: github-actions-aws-prod-deployer
  - Trust: environment:aws-prod only
  - SSM: Same EC2 instance
```

**Pros:**
- ✅ Separate audit trails
- ✅ Cannot accidentally use wrong role

**Cons:**
- ❌ Both roles can still deploy to any namespace (SSM limitation)
- ❌ Minimal security improvement
- ⚠️ More complexity (two roles, two trust policies)

**Option 2: Kubernetes RBAC (BETTER)**

Create service accounts with namespace restrictions:

```bash
# DEV service account (namespace-scoped)
kubectl create serviceaccount github-cicd-dev -n triage-dev
kubectl create rolebinding github-cicd-dev -n triage-dev \
  --clusterrole=edit \
  --serviceaccount=triage-dev:github-cicd-dev

# PROD service account (namespace-scoped)
kubectl create serviceaccount github-cicd-prod -n triage-prod
kubectl create rolebinding github-cicd-prod -n triage-prod \
  --clusterrole=edit \
  --serviceaccount=triage-prod:github-cicd-prod
```

**Deployment script changes:**
```bash
# DEV deployment
kubectl apply -k . --as=system:serviceaccount:triage-dev:github-cicd-dev

# PROD deployment
kubectl apply -k . --as=system:serviceaccount:triage-prod:github-cicd-prod
```

**Pros:**
- ✅ Kubernetes enforces namespace isolation
- ✅ DEV job CANNOT modify PROD namespace
- ✅ Proper RBAC audit trail
- ✅ Best practice for multi-tenant k8s

**Cons:**
- ⚠️ Requires Kubernetes configuration
- ⚠️ More setup complexity

**Option 3: Separate EC2 instances (STRONGEST)**

```
EC2 Instance: i-XXX-dev (DEV only)
  - k3s cluster (DEV)
  - Namespace: triage-dev

EC2 Instance: i-YYY-prod (PROD only)
  - k3s cluster (PROD)
  - Namespace: triage-prod
```

**Pros:**
- ✅ Complete isolation (separate VMs, networks, clusters)
- ✅ IAM can restrict by instance ID
- ✅ No cross-contamination possible
- ✅ True production isolation

**Cons:**
- ❌ 2x infrastructure cost
- ❌ More operational overhead
- ❌ Out of scope for Phase 13

### Recommended Approach

**Phase 13: Single IAM role (ACCEPTABLE)**

**Rationale:**
- GitHub Environment protection provides approval gate
- Workflow logic prevents accidental PROD deploy
- Audit trail via GitHub Actions logs
- Sufficient for MVP/Capstone

**Phase 14+: Add Kubernetes RBAC (Option 2)**

**Rationale:**
- Enforces namespace isolation
- Minimal infrastructure cost
- Standard Kubernetes best practice
- Easy to add incrementally

### Terraform Coordination

**For Terraform agent:**

**1. IAM Resources Required:**
```terraform
# Single IAM role with environment-based trust
resource "aws_iam_role" "github_actions_deployer" {
  name = "github-actions-aws-deployer"
  
  assume_role_policy = jsonencode({
    Statement = [{
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = [
            "repo:automation-agent-ai/multilingual-ticket-triage-devops:environment:aws-dev",
            "repo:automation-agent-ai/multilingual-ticket-triage-devops:environment:aws-prod"
          ]
        }
      }
    }]
  })
}

# SSM policy (instance-specific)
resource "aws_iam_role_policy" "ssm_deployment" {
  name = "SSMDeploymentPolicy"
  role = aws_iam_role.github_actions_deployer.id
  
  policy = jsonencode({
    Statement = [{
      Sid = "SSMRunCommand"
      Action = ["ssm:SendCommand"]
      Resource = [
        "arn:aws:ssm:eu-west-1::document/AWS-RunShellScript",
        "arn:aws:ec2:eu-west-1:523231704152:instance/i-07bc3aaf0d692974d"
      ]
      Condition = {
        StringEquals = {
          "ssm:resourceTag/Environment" = ["production"]
        }
      }
    }]
  })
}
```

**2. EC2 Instance Role Enhancement:**
```terraform
data "aws_iam_role" "bedrock_role" {
  name = "liora-triage-bedrock-role"
}

resource "aws_iam_role_policy_attachment" "ssm_managed_instance" {
  role       = data.aws_iam_role.bedrock_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_ec2_tag" "instance_environment" {
  resource_id = "i-07bc3aaf0d692974d"
  key         = "Environment"
  value       = "production"
}
```

**3. Document Limitations:**

Add to Terraform outputs:
```terraform
output "namespace_isolation_note" {
  value = <<-EOT
    SECURITY NOTE: The github-actions-aws-deployer role can execute commands
    on EC2 instance i-07bc3aaf0d692974d with full kubectl access to ALL namespaces.
    
    Namespace isolation is enforced by:
    - GitHub Environment approval gates (aws-prod requires reviewer)
    - Workflow logic (deploy-dev vs deploy-prod jobs)
    - GitHub Actions audit trail
    
    Kubernetes RBAC is NOT enforced by IAM. Consider adding namespace-scoped
    service accounts for stronger isolation.
  EOT
}
```

---

## Safest Activation Procedure

### Prerequisites (MUST complete before activation)

**1. GitHub Environments (Repository Admin)**

```bash
# Create aws-dev environment
gh api repos/automation-agent-ai/multilingual-ticket-triage-devops/environments/aws-dev \
  -X PUT \
  -f wait_timer=0 \
  -f prevent_self_review=false \
  -F deployment_branch_policy='{"protected_branches":false,"custom_branch_policies":true}'

# Add deployment branches to aws-dev
gh api repos/.../environments/aws-dev/deployment-branch-policies \
  -X POST \
  -f name=feat/aws-bedrock-migration
gh api repos/.../environments/aws-dev/deployment-branch-policies \
  -X POST \
  -f name=main

# Create aws-prod environment with required reviewer
gh api repos/.../environments/aws-prod \
  -X PUT \
  -f wait_timer=0 \
  -F reviewers='[{"type":"User","id":<user-id>}]' \
  -F deployment_branch_policy='{"protected_branches":false,"custom_branch_policies":true}'

# Add deployment branches to aws-prod
gh api repos/.../environments/aws-prod/deployment-branch-policies \
  -X POST \
  -f name=feat/aws-bedrock-migration
gh api repos/.../environments/aws-prod/deployment-branch-policies \
  -X POST \
  -f name=main
```

**2. Terraform IAM Resources**

Deploy resources from `docs/AWS_IAM_SETUP.md`:
- GitHub OIDC provider
- IAM role: github-actions-aws-deployer (environment-based trust)
- SSM deployment policy
- EC2 instance role SSM enhancement
- EC2 instance Environment tag

**3. SSM Agent (EC2 Admin)**

```bash
sudo snap install amazon-ssm-agent --classic
sudo snap start amazon-ssm-agent

# Verify
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=i-07bc3aaf0d692974d" \
  --query 'InstanceInformationList[0].PingStatus'
# Should return: "Online"
```

### Activation Steps

**Step 1: Resolve workflow file conflict**

```bash
cd /home/ubuntu/workspaces/cicd-worktree

# Delete aws-feature-image-build.yml (will be replaced by aws-ci-cd.yml)
git rm .github/workflows/aws-feature-image-build.yml
git commit -m "remove: Replace aws-feature-image-build with integrated aws-ci-cd"
```

**Step 2: Add fail-safe PROD validation**

```bash
# Edit aws-ci-cd.yml, add to deploy-prod job BEFORE checkout:
```

```yaml
deploy-prod:
  name: Deploy to AWS triage-prod
  runs-on: ubuntu-latest
  needs: [resolve-image, validate-prod]
  environment: aws-prod
  
  steps:
    # NEW: Fail-safe environment protection check
    - name: Verify aws-prod has required reviewers
      run: |
        REVIEWERS=$(gh api repos/${{ github.repository }}/environments/aws-prod \
          --jq '.protection_rules[] | select(.type=="required_reviewers") | .reviewers | length' \
          2>/dev/null || echo "0")
        
        if [ "$REVIEWERS" -lt 1 ]; then
          echo "::error::aws-prod environment has no required reviewers"
          echo "PROD deployment BLOCKED for safety"
          exit 1
        fi
        
        echo "✅ aws-prod has $REVIEWERS required reviewer(s)"
    
    - name: Checkout code
      # ... rest of job
```

**Step 3: Create minimal PROD promotion workflow on main**

Create `.github/workflows/aws-prod-promote.yml` (to be added to main later):

```yaml
name: AWS PROD Promotion

on:
  workflow_dispatch:
    inputs:
      image_tag:
        description: "Image tag from DEV (aws-sha-<commit>)"
        required: true
      confirm_production:
        description: 'Type "PROMOTE" to confirm'
        required: true

permissions:
  contents: read
  id-token: write

env:
  AWS_REGION: eu-west-1
  EC2_INSTANCE_ID: i-07bc3aaf0d692974d
  REGISTRY: ghcr.io
  IMAGE_NAME: automation-agent-ai/multilingual-ticket-triage-devops

jobs:
  validate:
    name: Validate PROD Promotion
    runs-on: ubuntu-latest
    steps:
      - name: Verify PROMOTE confirmation
        run: |
          if [ "${{ inputs.confirm_production }}" != "PROMOTE" ]; then
            echo "::error::Must type PROMOTE"
            exit 1
          fi
      
      - name: Verify environment protection
        run: |
          REVIEWERS=$(gh api repos/${{ github.repository }}/environments/aws-prod \
            --jq '.protection_rules[] | select(.type=="required_reviewers") | .reviewers | length' \
            2>/dev/null || echo "0")
          
          if [ "$REVIEWERS" -lt 1 ]; then
            echo "::error::aws-prod has no required reviewers"
            exit 1
          fi

  deploy-prod:
    name: Deploy to AWS triage-prod
    runs-on: ubuntu-latest
    needs: validate
    environment: aws-prod  # ← APPROVAL GATE
    
    steps:
      - name: Checkout code
        uses: actions/checkout@v4
      
      # ... same PROD deployment logic as aws-ci-cd.yml
```

**Step 4: Merge to feat/aws-bedrock-migration**

```bash
cd /home/ubuntu/workspaces/cicd-worktree
git push  # Push corrections from Step 1-2

cd /home/ubuntu/workspaces/multilingual-ticket-triage-devops
git checkout feat/aws-bedrock-migration
git merge feat/aws-cicd --no-ff -m "feat(cicd): Integrate corrected AWS CI/CD pipeline"
git push origin feat/aws-bedrock-migration
```

**Result:** Automatic DEV deployment triggers (if prerequisites met)

**Step 5: Add PROD promotion to main (later)**

```bash
# After DEV validated, create PR to main with ONLY aws-prod-promote.yml
git checkout main
git checkout -b feat/add-prod-promotion
cp /path/to/aws-prod-promote.yml .github/workflows/
git add .github/workflows/aws-prod-promote.yml
git commit -m "feat(cicd): Add AWS PROD promotion workflow (manual only)"
git push origin feat/add-prod-promotion

# Create PR, review, merge to main
# Result: workflow_dispatch button appears for PROD promotion
```

### Testing Sequence

**Test 1: DEV deployment (automatic)**

1. Prerequisites must be complete
2. Push to feat/aws-bedrock-migration triggers aws-ci-cd.yml
3. Verify: test → build → deploy-dev runs
4. Check: triage-dev namespace updated
5. Verify: Smoke tests pass

**Test 2: PROD promotion (manual, via API)**

Until aws-prod-promote.yml on main:
```bash
gh api repos/automation-agent-ai/multilingual-ticket-triage-devops/actions/workflows/aws-ci-cd.yml/dispatches \
  -f ref=feat/aws-bedrock-migration \
  -f inputs[deploy_target]=prod \
  -f inputs[confirm_production]=PROMOTE \
  -f inputs[image_tag]=aws-sha-5090097636b536e2f4dc16eae2428a7fb7748ea4
```

**Test 3: PROD promotion (UI, after main merge)**

After aws-prod-promote.yml on main:
1. GitHub UI: Actions → AWS PROD Promotion → Run workflow
2. Enter image tag from DEV
3. Type "PROMOTE"
4. Approve as required reviewer
5. Verify: triage-prod updated
6. Check: Public gateway functional

---

## Summary of Required Corrections

### Code Changes

1. ✅ **Delete aws-feature-image-build.yml** (prevents duplicate CI)
2. ✅ **Add fail-safe PROD validation** to aws-ci-cd.yml
3. ✅ **Create aws-prod-promote.yml** for main branch

### Infrastructure

1. ⏸️ **Create GitHub Environments** (aws-dev, aws-prod)
2. ⏸️ **Deploy Terraform IAM** (OIDC provider, role, policies)
3. ⏸️ **Install SSM Agent** on EC2
4. ⏸️ **Tag EC2 instance** (Environment=production)

### Workflow

1. ✅ **Merge corrections** to feat/aws-bedrock-migration
2. ⏸️ **Test DEV deployment** (after prerequisites)
3. ⏸️ **Add PROD workflow to main** (for UI button)
4. ⏸️ **Test PROD promotion** (with approval)

---

## Final Status

**Phase 13C findings:**

| Issue | Status | Resolution |
|-------|--------|------------|
| **workflow_dispatch visibility** | ❌ BLOCKING | Need workflow on main OR use API |
| **Duplicate workflows** | ⚠️ WARNING | Delete aws-feature-image-build.yml |
| **Environment protection** | ⏸️ MISSING | Create aws-dev and aws-prod |
| **OIDC format** | ✅ CORRECT | No changes needed |
| **PROD safeguards** | ✅ ADEQUATE | Add fail-safe check recommended |
| **IAM coordination** | ✅ DOCUMENTED | Single role acceptable |
| **Namespace isolation** | ⚠️ LIMITED | Document limitations, Kubernetes RBAC future |

**Recommended path:**
1. Apply code corrections (delete duplicate workflow, add fail-safe)
2. Complete prerequisites (environments, IAM, SSM)
3. Merge to feat/aws-bedrock-migration (enables DEV)
4. Add aws-prod-promote.yml to main (enables PROD UI)

**Status:** **INTEGRATION ISSUES IDENTIFIED** — Safe activation path defined

---

## References

- GitHub workflow_dispatch: https://docs.github.com/en/actions/using-workflows/events-that-trigger-workflows#workflow_dispatch
- GitHub Environments: https://docs.github.com/en/actions/deployment/targeting-different-environments/using-environments-for-deployment
- GitHub OIDC: https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/about-security-hardening-with-openid-connect

**Next:** Apply corrections, complete prerequisites, test activation sequence
