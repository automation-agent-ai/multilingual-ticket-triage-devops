# Demo Guide — Multilingual Ticket Triage Cloud Platform

**Project:** Cloud-Native DevOps Graduation Project  
**Repository:** [automation-agent-ai/multilingual-ticket-triage-devops](https://github.com/automation-agent-ai/multilingual-ticket-triage-devops)  
**Branch:** `main` ([PR #4 merged](https://github.com/automation-agent-ai/multilingual-ticket-triage-devops/pull/4) 2026-10-26)  
**AWS DEV CI/CD:** Verified 2026-10-26 via [run 40256053016](https://github.com/automation-agent-ai/multilingual-ticket-triage-devops/actions/runs/40256053016)  
**AWS PROD automated promotion:** **Not verified** (workflow prepared; `aws-prod` reviewer protection incomplete)  
**AWS `triage-prod` workload:** Running and healthy (`/health` OK) on pre-existing image — **not** evidence of successful automated PROD promotion

---

## Defense Demo Strategy

This demo prioritizes the **AWS production deployment** with Amazon Bedrock integration. Historical WSL/kind local development evidence is available as fallback.

**Primary demo environment:** AWS EC2 k3s with GitHub Actions OIDC → SSM → kubectl deployment  
**Fallback environment:** WSL kind cluster (docker-desktop context) if AWS is temporarily inaccessible

---

## Demo Prerequisites (AWS)

**Verify AWS k3s cluster is accessible:**

```bash
# SSH to AWS EC2 instance (replace with your method)
ssh ubuntu@<ec2-ip-or-tailscale-hostname>

# Check k3s cluster health
kubectl get nodes
kubectl get pods -A | grep triage

# Expected:
# triage-dev         ticket-triage-<hash>   1/1   Running
# triage-prod        ticket-triage-<hash>   1/1   Running   (healthy; not from verified PROD CI)
# triage-monitoring  prometheus-...         1/1   Running
# triage-monitoring  grafana-...            1/1   Running
```

**Access requirements for live demo:**
- AWS EC2 SSH or Tailscale connection
- GitHub Actions access (public repository: [actions tab](https://github.com/automation-agent-ai/multilingual-ticket-triage-devops/actions))
- kubectl on AWS EC2 with k3s kubeconfig

**If AWS unavailable:** Use screenshots/logs from prior deployment + WSL kind cluster fallback

---

## Demo Step 1 — GitHub Actions CI/CD Evidence

**What to show:** CI evidence on `main` **plus** verified AWS **DEV** deployment (separate workflow; not triggered by `main` push alone)

Navigate to: [github.com/automation-agent-ai/multilingual-ticket-triage-devops/actions](https://github.com/automation-agent-ai/multilingual-ticket-triage-devops/actions)

### 1A — Main CI Pipeline (after PR #4 merge)

**Workflow:** CI — Test · Build · Scan · Publish  
**Run:** [40256672282](https://github.com/automation-agent-ai/multilingual-ticket-triage-devops/actions/runs/40256672282)  
**Trigger:** Push to `main` (merge commit `5bb0b99`)  
**Result:** ✅ Success (10m 47s)

**Important:** This workflow **does not** deploy to AWS k3s. It publishes `sha-<commit>` images to GHCR only.

**Point out:**
- Job **Python Tests**: `pytest tests/ -m "not slow"` — **781 tests passed** (~25s)
- Job **Build · Scan · Push**:
  - Docker build with multi-stage Dockerfile
  - Trivy diagnostic table scan (CVE details in log, non-blocking)
  - Trivy blocking scan: `CRITICAL,HIGH`, `exit-code: 1`, `ignore-unfixed: true` — **PASSED**
  - GHCR push gated on Trivy success: `ghcr.io/.../multilingual-ticket-triage-devops:sha-5bb0b99...`
  - SARIF upload to GitHub Security tab (Code scanning alerts)

### 1B — AWS CI/CD Pipeline (feature branch validation)

**Workflow:** AWS CI/CD Pipeline  
**Run:** [40256053016](https://github.com/automation-agent-ai/multilingual-ticket-triage-devops/actions/runs/40256053016)  
**Trigger:** Push to `feat/aws-bedrock-migration` (SHA `09152552`)  
**Result:** ✅ Success (3m 43s)

**Point out:**
- Job **Python Tests**: 781 tests passed (including 20 Bedrock client unit tests with mocked boto3)
- Job **Build · Scan · Push**: Trivy PASSED, image pushed with tag `aws-sha-091525522acc6875d97ac9dcc1f34231f5d015ef`
- Job **Deploy to AWS triage-dev**:
  - GitHub OIDC authentication → AWS IAM role `github-actions-aws-deployer`
  - SSM Run Command on EC2 instance `i-07bc3aaf0d692974d`
  - `kubectl apply -k k8s/overlays/aws-dev` (updated image)
  - `kubectl rollout status` — successful
  - Smoke tests: `/health` ✅, `/ready` ✅, POST `/triage` ✅ with Bedrock inference metadata

**Evidence of Bedrock integration:**
Show job logs → "Deploy to AWS triage-dev" → step "Smoke test: triage POST with Bedrock" → JSON response with:
```json
{
  "inference": {
    "provider": "bedrock",
    "model_id": "eu.amazon.nova-micro-v1:0",
    "input_tokens": 450,
    "output_tokens": 89,
    "latency_ms": 1247,
    "invocation_count": 1
  }
}
```

### 1C — Security Scanning Evidence

Navigate to: **Security** tab → **Code scanning**

Show Trivy SARIF upload (OS-layer CVEs detected but unfixed in upstream base image)

---

## Demo Step 2 — AWS Kubernetes Workloads

**What to show:** Running pods, deployed image, security context, health endpoints

```bash
# On AWS EC2 instance (via SSH or Tailscale)
# Show DEV deployment
kubectl get deployment ticket-triage -n triage-dev

# Show running pod
kubectl get pods -n triage-dev

# Show the deployed image (with AWS Bedrock support)
kubectl get deployment ticket-triage -n triage-dev \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
# → ghcr.io/automation-agent-ai/multilingual-ticket-triage-devops:aws-sha-091525522acc6875d97ac9dcc1f34231f5d015ef

# Show security context (non-root, dropped capabilities, privilege escalation denied)
kubectl get deployment ticket-triage -n triage-dev \
  -o jsonpath='{.spec.template.spec.securityContext}' | python3 -m json.tool

# Test health endpoints (in-pod check)
kubectl exec -n triage-dev deploy/ticket-triage -- \
  python -c "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:8000/health').read().decode())"
# → {"status":"ok"}

kubectl exec -n triage-dev deploy/ticket-triage -- \
  python -c "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:8000/ready').read().decode())"
# → {"ready":true,"agent_initialized":true}
```

**PROD namespace (operational, not CI-verified promotion):**

```bash
kubectl get deployment ticket-triage -n triage-prod \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
# Example (older promoted image): aws-sha-bbe590a3...

kubectl exec -n triage-prod deploy/ticket-triage -- \
  python -c "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:8000/health').read().decode())"
# → {"status":"ok"}
```

State clearly: **healthy workload ≠ verified automated PROD promotion pipeline.**

**Fallback (if SSH unavailable):** Show deployment YAML from repository + GitHub Actions job logs with smoke test output

---

## Demo Step 3 — Real Triage Request (AWS Bedrock Inference)

**What to show:** End-to-end AI pipeline with Amazon Bedrock Nova Micro

```bash
# On AWS EC2 instance
# Execute triage request against deployed service
kubectl exec -n triage-dev deploy/ticket-triage -- \
  python -c "
import urllib.request, json
req = urllib.request.Request(
    'http://127.0.0.1:8000/triage',
    data=json.dumps({
        'ticket_id': 'demo-aws-001',
        'subject': 'Double charge on my invoice',
        'body': 'I was charged twice for my insurance premium this month. Please refund the duplicate payment immediately.'
    }).encode(),
    headers={'Content-Type': 'application/json'}
)
resp = urllib.request.urlopen(req)
print(json.dumps(json.loads(resp.read().decode()), indent=2))
"
```

**Expected response fields:**
- `topic`: `"Billing / Payment"`
- `urgency`: `"High"` or `"Medium"`
- `next_action`: `"forward_to_billing_team"` or `"escalate_to_human_supervisor"`
- `confidence`: floating-point (e.g. `0.99`)
- `missing_info`: `false`
- **`inference`** (NEW in AWS deployment):
  ```json
  {
    "provider": "bedrock",
    "model_id": "eu.amazon.nova-micro-v1:0",
    "region": "eu-west-1",
    "input_tokens": 450,
    "output_tokens": 89,
    "latency_ms": 1247,
    "invocation_count": 1
  }
  ```

**Pipeline explanation:**
1. Ticket embedded with `intfloat/multilingual-e5-large` (HuggingFace)
2. LanceDB retrieves 5 most similar tickets from 3,206 reference vectors
3. Weighted neighbor vote predicts initial queue/priority
4. **Amazon Bedrock Converse API** (`eu.amazon.nova-micro-v1:0`) receives:
   - System prompt with full JSON schema
   - User prompt with ticket + neighbor context
   - Returns structured LLM analysis (topic, urgency, reasoning)
5. Pydantic validator enforces schema compliance
6. Deterministic router maps to `next_action` via business rules
7. Simulated action executor (no real external system called)

**Authentication:** EC2 instance IAM role (`liora-triage-bedrock-role`) grants `bedrock:InvokeModel` permission. No credentials in code or config.

**Fallback (if SSH unavailable):** Show GitHub Actions job logs → "Smoke test: triage POST with Bedrock" step output with full JSON response

---

## Demo Step 4 — Prometheus Monitoring (AWS k3s)

**What to show:** Monitoring stack deployed; distinguish infrastructure from application metrics.

```bash
# Monitoring pods and services (read-only)
kubectl get pods,svc -n triage-monitoring

# Prometheus scrape targets (in-pod; read-only)
kubectl exec -n triage-monitoring deploy/prometheus -- \
  wget -qO- 'http://127.0.0.1:9090/api/v1/targets' | python3 -c "
import sys, json
for t in json.load(sys.stdin)['data']['activeTargets']:
    print(t['labels'].get('job'), t['health'], t['scrapeUrl'])
"
# Expected (verified 2026-10-26):
# prometheus          up  http://localhost:9090/metrics
# ticket-triage-dev   up  ...triage-dev...:8000/metrics
# ticket-triage-prod  up  ...triage-prod...:8000/metrics
```

**What to explain:**
- **Deployed:** Prometheus + Grafana in `triage-monitoring` (ClusterIP; port-forward or SSH tunnel for UI).
- **Collecting:** HTTP `/metrics` from DEV and PROD ticket-triage Services when endpoints expose metrics.
- **Not claimed:** Full parity with WSL Grafana dashboard panels in `docs/MONITORING.md` without live UI verification.

**Fallback:** Show `k8s/aws-monitoring/` manifests + target JSON from a saved log/screenshot.

---

## Demo Step 5 — Backup Automation (Optional, partially unverified live)

**What to show:** Backup scripts and timers — **do not claim full AWS DR restore was executed.**

**Unverified live unless you run commands successfully during demo:**

```bash
# On AWS EC2 instance
# Show Restic repository health (primary EBS)
sudo restic -r /opt/restic-repo snapshots --compact

# Show latest snapshot timestamp and size
sudo restic -r /opt/restic-repo snapshots --latest 1

# Verify offsite copy exists (Hetzner S3)
# NOTE: requires RESTIC_PASSWORD_FILE and AWS_* environment variables
sudo -E restic -r rest:https://restic.storage-box-eu-central.your-server.de/liora-triage snapshots --latest 1

# Show systemd timer status
systemctl status liora-restic-backup.timer
systemctl status liora-restic-offsite-copy.service
```

**Fallback:** Show backup scripts in `ops/backup/scripts/` and systemd unit files

---

## Demo Step 6 — Terraform Modules (Optional, not full AWS reprovision)

**What to show:** Infrastructure-as-code prepared for AWS resources

```bash
# Navigate to Terraform AWS modules
ls -l infra/terraform/

# Show OIDC provider configuration
cat infra/terraform/aws-infra/oidc-provider.tf

# Show IAM role for GitHub Actions deployment
cat infra/terraform/aws-infra/iam-github-deployer.tf

# Show S3 backup bucket module
cat infra/terraform/aws-restic/restic-bucket.tf
```

**State:** Terraform modules prepared and documented. IAM/OIDC resources were provisioned manually via AWS CLI during initial AWS setup. Full `terraform apply` to align state with live resources requires state import (documented in `infra/terraform/PHASE12D_FINAL_REPORT.md`).

---

## Demo Order Summary (AWS Deployment)

| Step | What it shows | Duration |
|---|---|---|
| 1A | Main CI — pytest 781, Trivy gate, GHCR push on main | ~3 min |
| 1B | AWS CI/CD — pytest, Trivy, SSM deploy, Bedrock smoke test | ~3 min |
| 2 | kubectl — AWS k3s pod, image tag, security context, health | ~2 min |
| 3 | POST /triage — live Bedrock inference with metadata | ~2 min |
| 4 | Prometheus targets — monitoring stack + DEV/PROD scrape UP | ~2 min |
| 5 | Backup scripts/timers (optional; DR restore not claimed) | ~2 min |
| 6 | Terraform modules — prepared IaC only (optional) | ~2 min |
| **Total** | | **~7–14 min** |

**Fallback strategy:** If AWS SSH unavailable, demonstrate using GitHub Actions logs + screenshots + WSL kind cluster for Prometheus/Grafana/Terraform evidence.

---

## WSL Kind Cluster Fallback (Historical Development)

If AWS environment is inaccessible, demonstrate using the historical WSL kind cluster:

### Prerequisites

```bash
# Verify kind cluster is running
kubectl --context docker-desktop get nodes

# Port-forward services (run in separate terminals)
kubectl --context docker-desktop port-forward svc/ticket-triage 18000:8000 -n triage-dev
kubectl --context docker-desktop port-forward svc/prometheus 19090:9090 -n triage-monitoring
kubectl --context docker-desktop port-forward svc/grafana 13000:3000 -n triage-monitoring
```

### Demo Steps (WSL)

1. Show GitHub Actions CI success (same as AWS demo step 1A)
2. Show 4 pods running (triage-dev, triage-prod, prometheus, grafana)
3. POST triage request to `http://localhost:18000/triage` (uses Ollama, not Bedrock)
4. Show Prometheus targets: `http://localhost:19090/targets`
5. Show Grafana dashboard: `http://localhost:13000` (admin/admin)
6. Show `terraform plan` output (5 resources, no changes)
7. Show disaster recovery backup verification (`scripts/dr/verify.sh`)
