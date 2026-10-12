# AWS Feature Image Build — Validation Report

**Date:** October 12, 2026  
**Branch:** `feat/aws-bedrock-migration`  
**Status:** ✅ READY FOR APPROVAL

---

## 🔒 **Safety Analysis — WSL Deployment Trigger Mechanisms**

### **Critical Finding: Single workflow_run Trigger**

The `deploy-dev.yml` workflow contains **ONE automatic trigger** that could deploy to WSL:

```yaml
workflow_run:
  workflows: ["CI — Test · Build · Scan · Publish"]
  types: [completed]
  branches: [main]
```

**Trigger conditions (ALL must be satisfied):**
1. ✅ Workflow name must **exactly match**: `"CI — Test · Build · Scan · Publish"`
2. ✅ Must complete on branch: `main`
3. ✅ Workflow conclusion must be: `success`
4. ✅ Runs on: `[self-hosted, linux, triage-dev-deployer]` (WSL runner)

### **Isolation Verification**

| Property | Production CI | New AWS Workflow | Collision Risk |
|----------|--------------|------------------|----------------|
| **Workflow Name** | `"CI — Test · Build · Scan · Publish"` | `"AWS Feature Image Build"` | ✅ **NONE** — Distinct names |
| **Trigger Branch** | `main`, `pull_request` | `feat/aws-bedrock-migration` | ✅ **NONE** — Different branch |
| **Runner Type** | `ubuntu-latest` (GH-hosted) | `ubuntu-latest` (GH-hosted) | ✅ **NONE** — No self-hosted |
| **Image Tag Prefix** | `sha-` / `latest` | `aws-sha-` | ✅ **NONE** — Distinct prefix |
| **workflow_run Match** | ❌ Name mismatch | ❌ Name mismatch | ✅ **SAFE** — Will NOT trigger |

---

## 📋 **New Workflow Specification**

### **File:** `.github/workflows/aws-feature-image-build.yml`

```yaml
name: AWS Feature Image Build

on:
  push:
    branches: [feat/aws-bedrock-migration]

permissions:
  contents: read
```

### **Jobs:**

#### **1. Test Job**
- **Runner:** `ubuntu-latest` (GitHub-hosted)
- **Reuses:** Existing CI test implementation
- **Steps:**
  - Python 3.12 setup
  - CPU-only PyTorch installation
  - Runtime dependencies from `requirements-docker.txt`
  - Pytest execution (excluding `@pytest.mark.slow`)

#### **2. Build-Scan-Push Job**
- **Runner:** `ubuntu-latest` (GitHub-hosted)
- **Permissions:**
  - `contents: read`
  - `packages: write` (GHCR push)
  - `security-events: write` (Trivy SARIF upload)
- **Authentication:** `GITHUB_TOKEN` (no PAT required)
- **Steps:**
  1. Docker Buildx setup
  2. **Pass 1:** Build + load locally for Trivy
  3. Trivy diagnostic scan (non-blocking)
  4. **Trivy vulnerability scan (BLOCKING)** — Exit code 1 on CRITICAL/HIGH
  5. SARIF upload to GitHub Security (category: `trivy-aws-image-scan`)
  6. **Pass 2:** Push to GHCR (conditional on Trivy success)

---

## 🏷️ **Image Tagging Strategy**

### **Format:**
```
ghcr.io/automation-agent-ai/multilingual-ticket-triage-devops:aws-sha-<full-40-char-commit-sha>
```

### **Example (current HEAD):**
```bash
# Assuming current commit: ec47fb57f0f1e7b1ebc9f1d2534060a12d47691d
ghcr.io/automation-agent-ai/multilingual-ticket-triage-devops:aws-sha-ec47fb57f0f1e7b1ebc9f1d2534060a12d47691d
```

### **Tag Collision Analysis:**

| Tag Type | Production Tags | AWS Feature Tags | Collision Risk |
|----------|----------------|------------------|----------------|
| Immutable commit | `sha-<sha>` | `aws-sha-<sha>` | ✅ **NONE** — Different prefix |
| Mutable | `latest` | *(not used)* | ✅ **NONE** — Not overwritten |

---

## 🔐 **Security & Permissions**

### **GITHUB_TOKEN Permissions:**
```yaml
permissions:
  contents: read           # Checkout code
  packages: write          # Push to GHCR
  security-events: write   # Upload Trivy SARIF
```

### **Authentication:**
- ✅ Uses built-in `GITHUB_TOKEN` (ephemeral, scoped)
- ✅ No PAT creation or storage required
- ✅ Registry credentials auto-managed by `docker/login-action@v3`

### **Trivy Configuration:**
- **Scanners:** `vuln` (vulnerabilities only)
- **Severity:** `CRITICAL,HIGH`
- **Exit code:** `1` (blocks push on findings)
- **Unfixed CVEs:** Ignored (`ignore-unfixed: true`)
- **SARIF upload:** Always runs (even on scan failure)

---

## 🎯 **Deployment Path (Post-Image Build)**

**IMPORTANT:** This workflow **ONLY builds and publishes the image**. It does **NOT deploy to Kubernetes.**

### **Manual Deployment Steps (After Workflow Success):**

1. **Verify image published:**
   ```bash
   # Pull the new image
   docker pull ghcr.io/automation-agent-ai/multilingual-ticket-triage-devops:aws-sha-<commit-sha>
   ```

2. **Update AWS DEV Kustomize overlay:**
   ```bash
   cd k8s/overlays/aws-dev
   kustomize edit set image \
     "ticket-triage-api=ghcr.io/automation-agent-ai/multilingual-ticket-triage-devops:aws-sha-<commit-sha>"
   ```

3. **Deploy to AWS k3s cluster:**
   ```bash
   kubectl apply -k k8s/overlays/aws-dev
   kubectl rollout status deployment/ticket-triage -n triage-dev
   ```

4. **Verify deployment:**
   ```bash
   kubectl exec -n triage-dev deploy/ticket-triage -- curl -sf http://localhost:8000/health
   ```

---

## ✅ **Pre-Flight Checklist**

- [x] Workflow YAML syntax validated (Python `yaml.safe_load` passed)
- [x] Workflow name distinct from production CI
- [x] Branch trigger limited to `feat/aws-bedrock-migration`
- [x] Runner type is GitHub-hosted only (`ubuntu-latest`)
- [x] Image tag uses distinct prefix (`aws-sha-`)
- [x] Does not overwrite production tags (`:latest`, `:sha-*`)
- [x] Trivy scan configured as blocking gate
- [x] SARIF upload to GitHub Security enabled
- [x] Uses `GITHUB_TOKEN` (no PAT required)
- [x] `workflow_run` trigger analysis confirms no deployment path
- [x] AWS migration plan preserved (`docs/AWS_MIGRATION_PLAN.md`)
- [x] WSL overlays untouched (`k8s/ci-overlays/dev`)
- [x] Does not modify `main` branch or trigger merge
- [x] No Kubernetes deployment steps included
- [x] No public endpoint exposure

---

## 📊 **Workflow Comparison Matrix**

| Feature | CI Workflow (`ci.yml`) | Deploy DEV (`deploy-dev.yml`) | **New AWS Build** |
|---------|------------------------|-------------------------------|-------------------|
| **Name** | CI — Test · Build · Scan · Publish | Deploy — DEV | **AWS Feature Image Build** |
| **Trigger** | push/PR to `main` | `workflow_run` + manual | **push to `feat/aws-bedrock-migration`** |
| **Runner** | `ubuntu-latest` | `[self-hosted, linux, triage-dev-deployer]` | **`ubuntu-latest`** |
| **Tests** | ✅ pytest | ❌ None | **✅ pytest** |
| **Trivy** | ✅ Blocking | ❌ None | **✅ Blocking** |
| **GHCR Push** | ✅ (on `main` only) | ❌ None | **✅ (always)** |
| **K8s Deploy** | ❌ None | ✅ (WSL cluster) | **❌ None** |
| **Image Tag** | `sha-<sha>`, `latest` | *(uses existing)* | **`aws-sha-<sha>`** |

---

## 🚀 **Next Steps (After Approval)**

1. **Commit the new workflow:**
   ```bash
   git add .github/workflows/aws-feature-image-build.yml
   git commit -m "feat: Add AWS feature branch image build workflow"
   ```

2. **Push to trigger the workflow:**
   ```bash
   git push origin feat/aws-bedrock-migration
   ```

3. **Monitor GitHub Actions:**
   - Navigate to: **Actions** → **AWS Feature Image Build**
   - Verify test job passes
   - Verify Trivy scan passes
   - Confirm GHCR push success

4. **Extract the image tag from job summary:**
   - Example: `aws-sha-ec47fb57f0f1e7b1ebc9f1d2534060a12d47691d`

5. **Deploy to AWS DEV (manual):**
   ```bash
   # Update kustomization
   cd k8s/overlays/aws-dev
   kustomize edit set image \
     "ticket-triage-api=ghcr.io/automation-agent-ai/multilingual-ticket-triage-devops:aws-sha-<commit-sha>"
   
   # Apply to k3s cluster
   kubectl apply -k k8s/overlays/aws-dev
   kubectl rollout status deployment/ticket-triage -n triage-dev
   ```

---

## 🔍 **Verification Commands**

### **Check workflow status:**
```bash
gh run list --workflow="AWS Feature Image Build" --branch=feat/aws-bedrock-migration
```

### **View workflow logs:**
```bash
gh run view --log
```

### **Verify GHCR image published:**
```bash
gh api \
  -H "Accept: application/vnd.github+json" \
  /user/packages/container/multilingual-ticket-triage-devops/versions \
  | jq '.[] | select(.metadata.container.tags[] | contains("aws-sha-"))'
```

### **Pull and inspect image:**
```bash
docker pull ghcr.io/automation-agent-ai/multilingual-ticket-triage-devops:aws-sha-<commit-sha>
docker inspect ghcr.io/automation-agent-ai/multilingual-ticket-triage-devops:aws-sha-<commit-sha>
```

---

## ⚠️ **Important Notes**

1. **No Automatic Deployment:** This workflow publishes the image to GHCR but does **NOT deploy to any Kubernetes cluster**. AWS DEV deployment must be triggered manually.

2. **WSL Isolation:** The WSL self-hosted runner will **NOT be triggered** because:
   - Workflow name does not match `"CI — Test · Build · Scan · Publish"`
   - Branch is `feat/aws-bedrock-migration`, not `main`
   - No `workflow_run` trigger is configured

3. **Tag Isolation:** The `aws-sha-` prefix ensures no collision with production tags (`sha-*` or `latest`).

4. **Trivy Blocking:** The workflow will **fail** if Trivy detects CRITICAL or HIGH vulnerabilities. The GHCR push step is conditional on Trivy success.

5. **One-Time Use:** This workflow is **temporary** for the AWS migration. Once the feature is merged to `main`, the standard CI workflow will publish images with the production `sha-*` tag format.

---

**Status:** ✅ **VALIDATED — READY FOR COMMIT & PUSH**
