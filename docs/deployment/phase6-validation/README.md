# Phase 6 & 7 — AWS DEV/PROD Validation & Deployment

This directory contains validation reports, test results, and deployment documentation for the AWS Bedrock migration.

## Phase 6 — AWS DEV Validation (2026-10-12)

**Objective:** Validate the AWS DEV deployment with Amazon Bedrock Nova Micro and prepare for pre-defense demo.

### Documents

- **`phase6_final_report.md`** — Complete validation report with all test results and metrics
- **`demo_runbook.md`** — 20-minute demo script with step-by-step commands
- **`prod_requirements.md`** — Comprehensive PROD deployment gap analysis
- **`test_results.jsonl`** — Machine-readable test data for 6 synthetic tickets
- **`results_analysis.md`** — Classification validation and accuracy assessment
- **`metrics_summary.md`** — Prometheus metrics status and availability
- **`bedrock_verification.md`** — Amazon Bedrock connectivity proof
- **`resource_summary.md`** — Kubernetes resource usage analysis

### Test Results Summary

**6 Synthetic Tickets Tested:**
1. English billing issue — ✅ Correct classification
2. German insurance claim — ✅ Multilingual support verified
3. Spanish customer request — ✅ Multilingual support verified
4. Low-urgency inquiry — ✅ Appropriate routing
5. Missing information ticket — ⚠️ Routing correct, flag detection needs improvement
6. High-urgency claim — ✅ Correct escalation

**Performance:**
- Success rate: 100% (6/6 HTTP 200)
- Average response time: 1.00 seconds
- Classification accuracy: 91% (5.5/6)
- Bedrock connectivity: ✅ IAM role authentication working
- Zero crashes or restarts

### Key Findings

✅ **Demo-ready** — All core functionality validated  
✅ **Multilingual support** — English, German, Spanish working correctly  
✅ **Bedrock operational** — Nova Micro processing all requests successfully  
✅ **Performance acceptable** — Sub-1.1s response times  
⚠️ **Missing info detection** — Needs improvement but not a blocker  

---

## Phase 7 — AWS PROD Deployment (2026-10-12)

**Objective:** Deploy the same tested Bedrock image to a separate `triage-prod` namespace for internal demo.

### Documents

- **`phase7_deployment_record.md`** — Complete PROD deployment record

### Deployment Summary

**Image:** `ghcr.io/automation-agent-ai/multilingual-ticket-triage-devops:aws-sha-bbe590a3b19b569785251cbfd005d8ea86ecf084`
- Same validated image as DEV
- GitHub Actions workflow: 38283289592
- Trivy scan: PASSED

**PROD Pod Status:**
- Namespace: triage-prod
- Status: 1/1 Running ✅
- Restart count: 0
- CPU: 1m (idle)
- Memory: 751 MiB

**Configuration:**
- CONFIG_PATH: /app/config-aws.yaml ✅
- ENVIRONMENT: aws-prod ✅
- RELOAD: false (production mode) ✅
- AWS_REGION: eu-west-1 ✅

**Validation:**
- Health check: ✅ OK
- Readiness check: ✅ Ready
- End-to-end ticket: ✅ Claims/Damage classified correctly
- Bedrock processing: ✅ 0.95 confidence, 1.38s response time

### Environment Comparison

| Metric | DEV | PROD | Status |
|--------|-----|------|--------|
| Pod Status | 1/1 Running | 1/1 Running | ✅ Both Ready |
| Restart Count | 0 | 0 | ✅ Stable |
| CPU Usage | 2m | 1m | ✅ Normal |
| Memory Usage | 1,014 MiB | 751 MiB | ✅ Efficient |
| Image | aws-sha-bbe590a | aws-sha-bbe590a | ✅ Identical |

### Node Capacity

**Total usage (DEV + PROD):**
- CPU: 79m (1% of 4 cores)
- Memory: 3,428 MiB (21% of 15.7 GB)
- Remaining: 99% CPU, 79% memory available

---

## Remaining Blockers for Public PROD

### Critical (Must-Resolve)
1. ❌ DNS domain — No DNS record configured
2. ❌ HTTPS/TLS — No certificate
3. ❌ API authentication — No auth middleware
4. ❌ Public ingress — No Ingress/LoadBalancer

### Current Deployment Status
- ✅ Technical functionality: Both environments operational
- ✅ Internal validation: End-to-end tests passed
- ✅ Pre-defense demo: Ready (via port-forward)
- ⚠️ Public production: Security hardening required

### Recommendation

**Current deployment is suitable for:**
- ✅ Internal demo via kubectl port-forward
- ✅ Pre-defense presentation (namespace isolation proof)
- ✅ Load testing via internal ClusterIP service

**NOT suitable for:**
- ❌ Public production traffic (requires TLS + auth + ingress)

**Next steps for public PROD:** See `prod_requirements.md` (estimated 6-9 hours)

---

## Demo Instructions

### Quick Demo (5 minutes)

```bash
# Show both environments
kubectl get pods -A | grep triage

# Show DEV health
kubectl exec -n triage-dev deployment/ticket-triage -- curl -s http://localhost:8000/ready | jq

# Show PROD health
kubectl exec -n triage-prod deployment/ticket-triage -- curl -s http://localhost:8000/ready | jq

# Port-forward to PROD
kubectl port-forward -n triage-prod svc/ticket-triage 8001:8000 &

# Test PROD with a ticket
curl -X POST http://localhost:8001/triage \
  -H "Content-Type: application/json" \
  -d '{
    "ticket_id": "DEMO-001",
    "subject": "Accident claim",
    "body": "I need to file a claim for a car accident."
  }' | jq '{topic, urgency, confidence}'

# Stop port-forward
pkill -f "port-forward.*8001"
```

### Full Demo (20 minutes)

See `demo_runbook.md` for complete step-by-step demo script with expected outputs.

---

## Files Index

```
.
├── README.md                        # This file
├── phase6_final_report.md           # Phase 6 complete validation report (14 KB)
├── phase7_deployment_record.md      # Phase 7 PROD deployment record (4 KB)
├── demo_runbook.md                  # 20-minute demo script (9 KB)
├── prod_requirements.md             # PROD deployment analysis (11 KB)
├── test_results.jsonl               # Machine-readable test data
├── results_analysis.md              # Classification validation
├── metrics_summary.md               # Prometheus metrics status
├── bedrock_verification.md          # Bedrock connectivity proof
└── resource_summary.md              # Resource usage analysis
```

---

**Documentation Date:** 2026-10-12  
**Status:** ✅ Both DEV and PROD operational  
**Next Phase:** Secure PROD with TLS + Auth + Ingress (post-defense)
