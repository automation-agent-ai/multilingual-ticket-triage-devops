# AWS CI/CD Pipeline — Complete Guide

## Overview

This document describes the complete GitHub Actions CI/CD pipeline for deploying the Multilingual Ticket Triage API to AWS EC2 k3s infrastructure with Amazon Bedrock integration.

**Verified deployment:** DEV environment on AWS k3s, validated 2026-10-26 before [PR #4](https://github.com/automation-agent-ai/multilingual-ticket-triage-devops/pull/4) merge.  
**Repository:** [automation-agent-ai/multilingual-ticket-triage-devops](https://github.com/automation-agent-ai/multilingual-ticket-triage-devops)  
**Evidence:** [AWS CI run 40256053016](https://github.com/automation-agent-ai/multilingual-ticket-triage-devops/actions/runs/40256053016) — pytest ✅, Trivy ✅, DEV deploy ✅

### Operational status (defense summary)

| Item | Status |
|------|--------|
| AWS DEV automated deploy (`aws-ci-cd.yml` → `triage-dev`) | ✅ Verified ([40256053016](https://github.com/automation-agent-ai/multilingual-ticket-triage-devops/actions/runs/40256053016)) |
| AWS `triage-prod` workload (`/health`) | ✅ Healthy on cluster (pre-existing image) |
| Automated PROD promotion (`aws-prod-promote.yml` / PROD jobs) | ❌ **Not verified** — not executed end-to-end |
| GitHub Environment `aws-prod` required reviewers | ⚠️ **Incomplete** |
| Push to `main` → AWS deploy | ❌ **No** — use feature-branch AWS workflow or manual dispatch |
| Main CI ([40256672282](https://github.com/automation-agent-ai/multilingual-ticket-triage-devops/actions/runs/40256672282)) | ✅ Build/scan/push only |

---

## Pipeline Flow

```
Push to feat/aws-bedrock-migration
  ↓
AWS CI/CD Pipeline (aws-ci-cd.yml)
  ├─ pytest (781 tests, all passed)
  ├─ Docker build
  ├─ Trivy scan (CRITICAL/HIGH blocking gate)
  └─ Push to GHCR (aws-sha-<commit>)
  ↓ (integrated workflow)
AWS DEV Deployment
  ├─ Resolve image SHA256 digest
  ├─ Deploy via OIDC → IAM → SSM to triage-dev
  ├─ kubectl apply + rollout status
  ├─ Smoke tests (/health, /ready, POST /triage)
  └─ Verify Bedrock inference metadata
  ↓ (manual workflow_dispatch only)
AWS PROD Promotion (aws-prod-promote.yml)
  ├─ Confirmation: "PROMOTE"
  ├─ ← APPROVAL GATE (GitHub Environment aws-prod)
  ├─ Deploy same immutable image to triage-prod
  ├─ Extended smoke tests + public gateway
  ├─ Automatic rollback on failure
  └─ Not verified in this project (manual workflow + approval; reviewer gate incomplete)
```

---

## Architecture

### Workflow Files

| File | Trigger | Purpose | Status |
|------|---------|---------|--------|
| `aws-ci-cd.yml` | Push to `feat/aws-bedrock-migration` | Integrated CI/CD: test → build → scan → DEV deploy | ✅ **Verified** ([run 40256053016](https://github.com/automation-agent-ai/multilingual-ticket-triage-devops/actions/runs/40256053016)) |
| `aws-prod-promote.yml` | Manual `workflow_dispatch` only | Promote validated DEV image to PROD with approval | 📝 **Prepared** (not executed) |

**Current trigger limitation:** `aws-ci-cd.yml` activates on `feat/aws-bedrock-migration` branch push only. Not yet configured for `main` branch automatic deployment.

### Deployment Method

**GitHub OIDC → AWS IAM → SSM Run Command**

```
GitHub Actions (ubuntu-latest runner)
  ↓ (OIDC authentication)
AWS STS AssumeRoleWithWebIdentity
  ↓ (short-lived credentials, 1 hour)
IAM Role: github-actions-aws-deployer
  ↓ (least privilege: SSM + ECR read)
AWS Systems Manager Run Command
  ↓ (executes on EC2, no open ports)
EC2 Instance (i-07bc3aaf0d692974d)
  ↓ (kubectl with local kubeconfig)
k3s API Server (localhost:6443)
  ↓
Kubernetes Deployment Update
  └─ triage-dev or triage-prod namespace
```

### Key Security Features

- ✅ **No static AWS credentials** — GitHub OIDC provides temporary tokens
- ✅ **No SSH access** — SSM uses AWS-managed encryption
- ✅ **No public Kubernetes API** — kubectl runs locally on EC2
- ✅ **Least privilege IAM** — deploy role has SSM only, no admin access
- ✅ **Immutable images** — pinned by digest, not mutable tags
- ✅ **Automatic rollback** — restores previous image on failure
- ✅ **Approval gates** — PROD requires manual reviewer approval

---

## Prerequisites

### 1. GitHub OIDC Provider (AWS Account)

Create the OIDC identity provider in AWS IAM:

```bash
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1 \
  --tags Key=Purpose,Value=GitHubActions Key=Repo,Value=multilingual-ticket-triage-devops
```

Verify:
```bash
aws iam get-open-id-connect-provider \
  --open-id-connect-provider-arn arn:aws:iam::523231704152:oidc-provider/token.actions.githubusercontent.com
```

### 2. IAM Role: github-actions-aws-deployer

**Trust Policy** (allows GitHub Actions from specific repo/branch):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::523231704152:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": [
            "repo:automation-agent-ai/multilingual-ticket-triage-devops:ref:refs/heads/feat/aws-bedrock-migration",
            "repo:automation-agent-ai/multilingual-ticket-triage-devops:ref:refs/heads/main"
          ]
        }
      }
    }
  ]
}
```

**Permissions Policy** (least privilege SSM access):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "SSMDeploymentAccess",
      "Effect": "Allow",
      "Action": [
        "ssm:SendCommand",
        "ssm:GetCommandInvocation",
        "ssm:DescribeInstanceInformation"
      ],
      "Resource": [
        "arn:aws:ssm:eu-west-1:523231704152:*",
        "arn:aws:ec2:eu-west-1:523231704152:instance/i-07bc3aaf0d692974d"
      ]
    },
    {
      "Sid": "SSMDocumentAccess",
      "Effect": "Allow",
      "Action": [
        "ssm:ListDocuments",
        "ssm:DescribeDocument"
      ],
      "Resource": "arn:aws:ssm:eu-west-1:523231704152:document/AWS-RunShellScript"
    }
  ]
}
```

Create the role:

```bash
# Save trust policy to trust-policy.json
# Save permissions policy to permissions-policy.json

aws iam create-role \
  --role-name github-actions-aws-deployer \
  --assume-role-policy-document file://trust-policy.json \
  --description "GitHub Actions deployment role for AWS k3s" \
  --tags Key=Purpose,Value=CICD Key=ManagedBy,Value=Terraform

aws iam put-role-policy \
  --role-name github-actions-aws-deployer \
  --policy-name SSMDeploymentPolicy \
  --policy-document file://permissions-policy.json
```

### 3. SSM Agent Installation (EC2)

Install and enable SSM Agent on Ubuntu 24.04:

```bash
# On EC2 instance
sudo snap install amazon-ssm-agent --classic
sudo snap start amazon-ssm-agent
sudo systemctl enable snap.amazon-ssm-agent.amazon-ssm-agent.service
```

Verify:
```bash
sudo systemctl status snap.amazon-ssm-agent.amazon-ssm-agent.service
sudo snap services amazon-ssm-agent
```

### 4. EC2 Instance Role Enhancement

Add SSM managed policy to the existing Bedrock role:

```bash
aws iam attach-role-policy \
  --role-name liora-triage-bedrock-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
```

Verify instance is managed:
```bash
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=i-07bc3aaf0d692974d" \
  --query 'InstanceInformationList[0].{PingStatus:PingStatus,PlatformName:PlatformName}'
```

Expected: `"PingStatus": "Online"`

### 5. GitHub Environments

Create GitHub Environments with protection rules:

**Environment: aws-dev**
- No required reviewers (optional: add for DEV approval gate)
- No wait timer

**Environment: aws-prod**
- **Required reviewers:** Add at least one reviewer
- Wait timer: 0 minutes (approval is the gate)
- Restrict to selected branches: `feat/aws-bedrock-migration`, `main`

Configure via GitHub UI:
```
Repository → Settings → Environments → New environment
  Name: aws-dev
  Deployment protection rules: (none required for DEV)

Repository → Settings → Environments → New environment
  Name: aws-prod
  Deployment protection rules:
    ☑ Required reviewers: [select at least one user]
    Branches: feat/aws-bedrock-migration, main
```

---

## Workflow Details

### AWS CI/CD Pipeline (Integrated)

**File:** `.github/workflows/aws-ci-cd.yml`

**Triggers:**
- Push to `feat/aws-bedrock-migration`
- Manual `workflow_dispatch` (DEV or PROD target)

**Jobs:**
1. **test** — pytest (781 fast tests in CI, ~30s)
2. **build-scan-push**
   - Build Docker image (GHA cache)
   - Trivy scan (CRITICAL/HIGH fails build)
   - Push to GHCR: `aws-sha-<40-char-commit>`

**Outputs:**
- `image-digest`: SHA256 digest (immutable)
- `image-tag`: `aws-sha-<commit>`

**Image naming:**
```
ghcr.io/automation-agent-ai/multilingual-ticket-triage-devops:aws-sha-<commit>
```

### AWS DEV Deployment (within `aws-ci-cd.yml`)

**File:** `.github/workflows/aws-ci-cd.yml` (deploy jobs in same workflow)

**Triggers:**
- Push to `feat/aws-bedrock-migration` (after test/build jobs)
- `workflow_dispatch` with `deploy_target: dev`

**Jobs:**

1. **validate**
   - Verify image tag format (`aws-sha-<40-hex>`)
   - Check image exists in GHCR
   - Record current deployed image (for rollback)

2. **deploy**
   - AWS OIDC authentication
   - Verify SSM connectivity
   - Generate deployment script
   - Execute via SSM Run Command:
     - `cd k8s/overlays/aws-dev`
     - `kustomize edit set image`
     - `kubectl apply -k .`
     - `kubectl rollout status --timeout=300s`
   - Automatic rollback on failure

3. **smoke-test**
   - GET `/health` — basic liveness
   - GET `/ready` — agent initialization
   - POST `/triage` — Bedrock inference test
   - Verify model metadata in response

**Environment:** `aws-dev` (optional approval gate)

**Concurrency:** Group `aws-dev-deployment`, no cancellation

### AWS PROD Promotion

**File:** `.github/workflows/aws-prod-promote.yml` (also optional PROD path in `aws-ci-cd.yml` via `workflow_dispatch`)

**Verification:** ❌ **Not executed successfully in this repository** — document as prepared only.

**Triggers:**
- `workflow_dispatch` ONLY (manual)

**Inputs:**
- `image_tag` (required): `aws-sha-<40-char>` from DEV
- `confirm_production` (required): Must type "PROMOTE"
- `skip_smoke_test` (optional): Emergency rollback only

**Jobs:**

1. **validate**
   - Verify "PROMOTE" confirmation
   - Validate image tag format
   - Check image exists in GHCR
   - Record current PROD image for rollback
   - Show rollback instructions in summary

2. **deploy** ← **APPROVAL GATE HERE**
   - **GitHub Environment:** `aws-prod` (requires reviewer approval)
   - AWS OIDC authentication
   - Deploy same image to `triage-prod`
   - Extended rollout timeout (600s)
   - Automatic rollback on deployment failure

3. **smoke-test**
   - Internal health checks
   - Public gateway check (`https://triage.automation-agent.ai`)
   - Bedrock inference test
   - Prometheus `/metrics` verification

4. **rollback** (conditional)
   - Runs ONLY if deployment succeeded but smoke test failed
   - Restores previous image automatically

5. **summary**
   - Final deployment report
   - Job status table
   - Rollback instructions if needed

**Environment:** `aws-prod` (required reviewer approval)

**Concurrency:** Group `aws-prod-deployment`, no cancellation

---

## Usage Guide

### Deploy to DEV (Automatic)

1. **Push code** to `feat/aws-bedrock-migration`:
   ```bash
   git push origin feat/aws-bedrock-migration
   ```

2. **CI runs automatically:**
   - GitHub Actions → AWS Feature Image Build
   - Wait for tests, build, and Trivy scan

3. **DEV deployment triggers automatically:**
   - After CI success, AWS DEV Deployment starts
   - Watch deployment: Actions → AWS DEV Deployment

4. **Verify DEV deployment:**
   - Check job summary for smoke test results
   - SSH to EC2 and verify:
     ```bash
     kubectl get pods -n triage-dev
     kubectl logs -n triage-dev -l app=ticket-triage --tail=50
     ```

### Deploy to DEV (Manual)

Use for rollback or re-deployment:

```
GitHub → Actions → AWS DEV Deployment → Run workflow
  Branch: feat/aws-bedrock-migration
  image_tag: aws-sha-<40-char-commit>
  skip_smoke_test: false
→ Run workflow
```

### Promote to PROD

**Prerequisites:**
- DEV deployment successful
- Smoke tests passed in DEV
- Know the exact image tag from DEV

**Steps:**

1. **Get DEV image tag:**
   ```bash
   kubectl get deployment/ticket-triage -n triage-dev \
     -o jsonpath='{.spec.template.spec.containers[0].image}'
   ```
   
   Example: `ghcr.io/.../aws-sha-bbe590a3b19b569785251cbfd005d8ea86ecf084`

2. **Trigger PROD promotion:**
   ```
   GitHub → Actions → AWS PROD Promotion → Run workflow
     Branch: feat/aws-bedrock-migration
     image_tag: aws-sha-bbe590a3b19b569785251cbfd005d8ea86ecf084
     confirm_production: PROMOTE
     skip_smoke_test: false
   → Run workflow
   ```

3. **Approve deployment:**
   - Workflow pauses at "Deploy to AWS triage-prod" job
   - GitHub sends notification to required reviewers
   - Reviewer clicks "Review deployments" → Approve

4. **Monitor deployment:**
   - Watch job progress in Actions UI
   - Check smoke test results in job summary
   - Verify: https://triage.automation-agent.ai/docs

5. **Verify PROD:**
   ```bash
   # On EC2
   kubectl get pods -n triage-prod
   kubectl logs -n triage-prod -l app=ticket-triage --tail=50
   
   # Check public gateway
   curl -s https://triage.automation-agent.ai/health
   ```

### Rollback PROD

**Automatic rollback:**
- If smoke test fails, rollback is automatic
- Previous image is restored automatically

**Manual rollback:**

1. **Find previous PROD image:**
   - Check "PROD Promotion Report" job summary
   - Or: `grep newTag k8s/overlays/aws-prod/kustomization.yaml.backup`

2. **Re-run PROD promotion workflow** with previous tag:
   ```
   image_tag: aws-sha-<previous-commit>
   confirm_production: PROMOTE
   ```

3. **Or rollback via kubectl on EC2:**
   ```bash
   cd /home/ubuntu/workspaces/multilingual-ticket-triage-devops/k8s/overlays/aws-prod
   
   # Restore backup
   cp kustomization.yaml.backup kustomization.yaml
   
   # Apply
   kubectl apply -k .
   kubectl rollout status deployment/ticket-triage -n triage-prod --timeout=300s
   ```

---

## Isolation from WSL Pipeline

**CRITICAL:** The AWS CI/CD workflows are completely isolated from the existing WSL deployment pipeline.

### Key Differences

| Aspect | WSL Pipeline | AWS Pipeline |
|--------|--------------|--------------|
| **Workflow names** | "Deploy — DEV" | "AWS DEV Deployment" |
| **Runner** | self-hosted (triage-dev-deployer) | ubuntu-latest (GitHub-hosted) |
| **Overlays** | `k8s/ci-overlays/dev` | `k8s/overlays/aws-dev` |
| **Image tags** | `sha-<commit>` | `aws-sha-<commit>` |
| **CI workflow** | "CI — Test · Build · Scan · Publish" | "AWS Feature Image Build" |
| **Target** | Local kind cluster (127.0.0.1) | AWS k3s (via SSM) |
| **Namespace** | triage-dev (kind) | triage-dev (k3s) |

### Protection Mechanisms

1. **Different workflow_run sources:**
   - WSL: triggers on "CI — Test · Build · Scan · Publish"
   - AWS: triggers on "AWS Feature Image Build"

2. **Different branch triggers:**
   - WSL: main branch only
   - AWS: feat/aws-bedrock-migration branch

3. **Different runner constraints:**
   - WSL: requires self-hosted runner (unavailable to GitHub-hosted)
   - AWS: uses GitHub-hosted (cannot reach kind cluster)

4. **Different image registries:**
   - WSL: GHCR with `sha-` prefix
   - AWS: GHCR with `aws-sha-` prefix

5. **No cross-contamination:**
   - Pushing to feat/aws-bedrock-migration → AWS pipeline only
   - Pushing to main → WSL pipeline only (when merged)

---

## Troubleshooting

### SSM Command Fails

**Error:** `EC2 instance is not online in SSM`

**Fix:**
```bash
# On EC2
sudo systemctl status snap.amazon-ssm-agent.amazon-ssm-agent.service
sudo snap start amazon-ssm-agent

# Verify from local machine
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=i-07bc3aaf0d692974d"
```

### OIDC Authentication Fails

**Error:** `AssumeRoleWithWebIdentity failed`

**Check:**
1. OIDC provider exists:
   ```bash
   aws iam get-open-id-connect-provider \
     --open-id-connect-provider-arn arn:aws:iam::523231704152:oidc-provider/token.actions.githubusercontent.com
   ```

2. IAM role trust policy includes GitHub repo:
   ```bash
   aws iam get-role --role-name github-actions-aws-deployer \
     --query 'Role.AssumeRolePolicyDocument'
   ```

3. Branch name matches trust policy condition

### Image Not Found in GHCR

**Error:** `Image not found in GHCR`

**Fix:**
1. Check CI workflow completed successfully
2. Verify image was published:
   ```bash
   docker manifest inspect ghcr.io/automation-agent-ai/multilingual-ticket-triage-devops:aws-sha-<commit>
   ```
3. Check repository visibility (must be public or workflow needs GHCR auth)

### Rollout Timeout

**Error:** `error: timed out waiting for the condition`

**Debug:**
```bash
# On EC2
kubectl get pods -n triage-dev -l app=ticket-triage
kubectl describe pod -n triage-dev <pod-name>
kubectl logs -n triage-dev <pod-name> --previous

# Check events
kubectl get events -n triage-dev --sort-by='.lastTimestamp'
```

**Common causes:**
- Image pull failure (GHCR authentication)
- Insufficient resources (memory/CPU)
- Volume mount issues (/mnt/data paths)
- Startup probe timeout (model loading)

### Smoke Test Fails

**Error:** `/ready check failed - agent not initialized`

**Debug:**
```bash
# Check pod logs
kubectl logs -n triage-dev -l app=ticket-triage --tail=100

# Check pod exec access
kubectl exec -n triage-dev <pod-name> -- curl -v http://localhost:8000/ready
```

**Common causes:**
- Bedrock IAM permissions missing
- Model cache not accessible
- Database files corrupted
- Environment variables incorrect

---

## Security Considerations

### Secrets Management

**No secrets required in GitHub!**

- AWS credentials: GitHub OIDC (temporary, 1-hour lifetime)
- Bedrock: EC2 instance role (no keys)
- kubectl: local access on EC2 (no exposed API)

### IAM Permissions Audit

Review IAM role permissions:
```bash
aws iam list-attached-role-policies --role-name github-actions-aws-deployer
aws iam list-role-policies --role-name github-actions-aws-deployer
aws iam get-role-policy --role-name github-actions-aws-deployer --policy-name SSMDeploymentPolicy
```

**Verify:**
- No EC2 admin permissions
- No IAM modify permissions
- No S3/RDS access
- Only SSM for specific instance

### SSM Command Audit

View SSM command history:
```bash
aws ssm list-commands \
  --filters "Key=InvokedAfter,Value=2026-10-01" \
  --query 'Commands[?InstanceIds[0]==`i-07bc3aaf0d692974d`].[CommandId,DocumentName,Status,RequestedDateTime]' \
  --output table
```

### Network Security

- ✅ No SSH ports exposed
- ✅ No Kubernetes API exposed to internet
- ✅ All deployment traffic over AWS-managed encryption (SSM)
- ✅ Application traffic via Traefik with TLS

---

## Cost Estimate

**GitHub Actions minutes (free tier: 2000/month):**
- CI build: ~5 minutes
- DEV deployment: ~3 minutes
- PROD promotion: ~4 minutes
- **Per deployment cycle:** ~12 minutes

**AWS costs:**
- SSM Run Command: **FREE** (no charge for commands)
- OIDC: **FREE** (no charge for STS operations)
- EC2 instance: Already running (no additional cost)

**Total additional cost for CI/CD:** $0/month

---

## Maintenance

### Rotate IAM Role Credentials

GitHub OIDC tokens rotate automatically every workflow run (1-hour lifetime).

**No manual rotation needed.**

### Update SSM Agent

```bash
# On EC2
sudo snap refresh amazon-ssm-agent
sudo snap restart amazon-ssm-agent
```

### Update Workflow Dependencies

GitHub Actions versions (update in workflow files):
- `actions/checkout`: Currently v4
- `aws-actions/configure-aws-credentials`: Currently v4
- `docker/*-action`: Check for updates quarterly

### Monitor Failed Deployments

Set up GitHub notifications:
```
Settings → Notifications → Actions
  ☑ Notify me when a workflow run fails
```

---

## Future Enhancements

### Planned Improvements

1. **Multi-region deployment**
   - Extend to eu-central-1 or us-east-1
   - Same SSM pattern, different instance IDs

2. **Canary deployments**
   - Deploy to subset of pods
   - Gradual traffic shift
   - Automatic promotion on success

3. **Integration tests**
   - Run full test suite against DEV
   - Validate before PROD promotion

4. **Slack notifications**
   - Deployment start/success/failure
   - Approval requests

5. **Terraform integration**
   - IAM role managed by Terraform
   - Workflow references Terraform outputs

### Optional: Tailscale Alternative

If AWS SSM is not feasible:

**Setup:**
1. Create Tailscale ephemeral auth key
2. Store in GitHub secret: `TAILSCALE_AUTH_KEY`
3. Workflow connects via Tailscale
4. kubectl over Tailscale tunnel

**Trade-offs:**
- ✅ No SSM Agent required
- ✅ Works with any Kubernetes cluster
- ❌ Requires Tailscale account
- ❌ Additional dependency

---

## Appendix: Kustomize Overlays

### DEV Overlay Structure

```
k8s/overlays/aws-dev/
├── kustomization.yaml    # Base + patches + image
├── namespace.yaml        # triage-dev namespace
├── configmap.yaml        # AWS/Bedrock config
└── patches/
    └── deployment.yaml   # Resource limits, volumes, env
```

**Key configurations:**
- Image: GHCR with aws-sha tag
- Replicas: 1
- Resources: 500m/2Gi request, 2000m/5Gi limit
- Volumes: /mnt/data/app-data-dev, /mnt/data/hf-cache
- Config: Bedrock endpoint, region, model

### PROD Overlay Structure

```
k8s/overlays/aws-prod/
├── kustomization.yaml    # Base + patches + image
├── namespace.yaml        # triage-prod namespace
├── configmap.yaml        # AWS/Bedrock config (RELOAD=false)
└── patches/
    └── deployment.yaml   # Higher resources, read-only data
```

**Differences from DEV:**
- RELOAD: false (no auto-reload)
- Resources: Higher CPU/memory allocation
- Volumes: /mnt/data/app-data-prod (separate data copy)
- Labels: environment=aws-prod

---

## Demo Checklist

Pre-defense demonstration steps:

### Setup (Before Demo)
- [ ] Verify SSM Agent running
- [ ] Confirm aws-prod environment has required reviewer
- [ ] Check GHCR for latest aws-sha image
- [ ] Verify DEV and PROD are stable

### Demo Flow
1. [ ] Show current DEV image tag
2. [ ] Trigger DEV deployment (manual or show automatic)
3. [ ] Wait for rollout and smoke tests
4. [ ] Show job summary with results
5. [ ] Trigger PROD promotion
6. [ ] Show approval gate pause
7. [ ] Approve as reviewer
8. [ ] Wait for PROD deployment
9. [ ] Show public gateway smoke test
10. [ ] Verify Grafana metrics

### Verification
- [ ] Both namespaces running same image
- [ ] Smoke tests green in both DEV and PROD
- [ ] Public API responding: https://triage.automation-agent.ai/docs
- [ ] Grafana showing metrics
- [ ] No errors in pod logs

---

## Support

**Documentation:**
- This file: `docs/AWS_CICD.md`
- IAM setup: `docs/AWS_IAM_SETUP.md`
- Disaster recovery: `docs/DISASTER_RECOVERY.md`

**Logs:**
- GitHub Actions: Repository → Actions → [workflow run]
- SSM commands: AWS Console → Systems Manager → Run Command → Command history
- Application logs: `kubectl logs -n <namespace> -l app=ticket-triage`

**Contact:**
- Repository: automation-agent-ai/multilingual-ticket-triage-devops
- Issues: https://github.com/automation-agent-ai/multilingual-ticket-triage-devops/issues
