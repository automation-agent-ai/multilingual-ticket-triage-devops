# AWS PROD Deployment Requirements Analysis
**Target:** Secure production deployment with HTTPS and authentication  
**Current Status:** DEV deployment operational, PROD namespace exists but unused

---

## Current DEV → PROD Gaps

### 1. Network Exposure ❌
**Current:** ClusterIP service (cluster-internal only)  
**PROD Requirement:** External HTTPS access for Liora client integration

**Options:**
- **A. LoadBalancer service** (AWS NLB/ALB via k3s ServiceLB or cloud-controller-manager)
- **B. Ingress + cert-manager** (nginx-ingress + Let's Encrypt)
- **C. API Gateway + k3s proxy** (AWS API Gateway → EC2 endpoint)

**Recommendation:** **Option B (Ingress + cert-manager)**
- Native Kubernetes pattern
- Automated TLS certificate management
- Path-based routing for future multi-service expansion
- No additional AWS resources or costs
- Well-tested with k3s (Traefik or nginx-ingress)

### 2. TLS/HTTPS ❌
**Current:** HTTP only (port 8000)  
**PROD Requirement:** TLS 1.2+ with valid certificate

**Solution (for Option B):**
- Install cert-manager (Helm chart or kubectl apply)
- Configure ClusterIssuer for Let's Encrypt (HTTP-01 or DNS-01 challenge)
- Create Ingress resource with tls section
- Domain: Requires DNS A record pointing to EC2 public IP

**Estimated setup time:** 30-60 minutes

### 3. Authentication/Authorization ❌
**Current:** No authentication (open API)  
**PROD Requirement:** Restrict access to authorized Liora agents

**Options:**
- **A. API Key authentication** (simplest, add to application)
  - Liora sends `X-API-Key` header
  - Application validates against secret
  - No external dependencies
  
- **B. OAuth2/JWT** (industry standard, more complex)
  - Requires identity provider (Keycloak, Auth0, AWS Cognito)
  - JWT validation in application or ingress middleware
  - Higher operational complexity

- **C. Mutual TLS (mTLS)** (certificate-based)
  - Liora presents client certificate
  - Ingress validates certificate authority
  - No application changes needed
  - Operationally complex (certificate lifecycle)

**Recommendation:** **Option A (API Key)**
- Fastest to implement (add FastAPI dependency injection)
- Sufficient for MVP/pre-defense
- Can upgrade to OAuth2 later without breaking changes
- Secret stored in Kubernetes Secret, injected as env var

**Estimated development time:** 2-4 hours

### 4. Secrets Management ❌
**Current:** No secrets (IAM role only)  
**PROD Requirement:** Secure API key storage

**Solution:**
```bash
# Create secret in triage-prod namespace
kubectl create secret generic triage-api-key \
  -n triage-prod \
  --from-literal=api-key=$(openssl rand -base64 32)

# Reference in deployment
env:
  - name: TRIAGE_API_KEY
    valueFrom:
      secretKeyRef:
        name: triage-api-key
        key: api-key
```

**Estimated setup time:** 15 minutes

### 5. Rate Limiting ⚠️
**Current:** No rate limiting (unbounded)  
**PROD Requirement:** Protect against abuse/cost overruns

**Solution:**
- Application-level: Add FastAPI SlowAPI middleware
- Ingress-level: nginx-ingress annotations (rate-limit-rpm)

**Recommendation:** Start with ingress-level (no code changes)
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  annotations:
    nginx.ingress.kubernetes.io/rate-limit: "10"  # 10 req/s per IP
```

**Estimated setup time:** 5 minutes

### 6. Monitoring & Alerting ⚠️
**Current:** Prometheus metrics exposed, no scraping  
**PROD Requirement:** Active monitoring and alerting

**Options:**
- **A. Prometheus + Grafana** (k3s cluster)
  - Full observability stack
  - Requires cluster resources (~500 MB RAM)
  - Retention and backup strategy needed
  
- **B. AWS CloudWatch** (serverless)
  - Export metrics via CloudWatch agent
  - Native AWS integration
  - Costs apply ($0.30/metric/month)

- **C. Datadog/Grafana Cloud** (SaaS)
  - No operational burden
  - Monthly subscription
  - Best for production-grade observability

**Recommendation (MVP):** **Option A (minimal Prometheus)**
- Deploy kube-prometheus-stack with Helm
- Single Grafana dashboard for DEV+PROD
- Alert on: pod restarts, HTTP 5xx rate, latency P95 > 3s

**Estimated setup time:** 2-3 hours

### 7. Backup & Disaster Recovery ⚠️
**Current:** No backups (data is reproducible)  
**PROD Requirement:** Configuration backup, rapid recovery

**Critical assets:**
- Kubernetes manifests (already in Git ✅)
- LanceDB vector data (26 MB, can rebuild from DuckDB)
- DuckDB evaluation data (source of truth, ~26 MB)
- Secrets (API keys)

**Solution:**
- **Git:** All manifests committed (already done ✅)
- **S3:** Daily backup of DuckDB + LanceDB to S3 bucket
- **Secrets:** Export to secure location (1Password, AWS Secrets Manager)

**Estimated setup time:** 1-2 hours (backup script + cron)

### 8. Deployment Strategy ⚠️
**Current:** Direct kubectl apply (manual)  
**PROD Requirement:** Safe, rollback-capable deployments

**Options:**
- **A. Kubernetes rolling update** (default, basic)
  - Built-in, zero downtime
  - Automatic rollback on health check failure
  - Already configured via deployment.yaml
  
- **B. Blue-green deployment** (manual traffic switch)
  - Run old + new versions simultaneously
  - Manual service selector update
  - Requires 2x resources during deployment

- **C. Canary deployment** (gradual traffic shift)
  - Requires service mesh (Istio, Linkerd) or advanced ingress
  - Overkill for single-pod deployment

**Recommendation:** **Option A (rolling update)**
- Already implemented via Kubernetes Deployment
- `maxUnavailable: 0` ensures zero downtime
- Fast rollback: `kubectl rollout undo`

**No additional work needed ✅**

---

## Shortest Path to Secure PROD Deployment

### Phase 1: Network & TLS (1-2 hours)
1. Install nginx-ingress controller on k3s
2. Install cert-manager
3. Configure DNS A record (triage.liora.ai → EC2 public IP)
4. Create ClusterIssuer for Let's Encrypt
5. Create Ingress resource with TLS

### Phase 2: Authentication (2-4 hours)
1. Add FastAPI-SimpleAuth or custom middleware
2. Generate API key and store in Kubernetes Secret
3. Update application startup to load secret
4. Add authentication decorator to `/triage` endpoint
5. Test with `Authorization: Bearer <key>` header

### Phase 3: Deploy PROD (30 minutes)
1. Update `k8s/overlays/aws-prod/kustomization.yaml` with same image
2. Apply: `kubectl apply -k k8s/overlays/aws-prod`
3. Verify health checks
4. Test authenticated request

### Phase 4: Monitoring (2-3 hours, can be done after launch)
1. Install kube-prometheus-stack
2. Configure ServiceMonitor for triage-prod
3. Import Grafana dashboard
4. Set up alerting rules

**Total estimated time:** 6-9 hours (excluding monitoring)

---

## Immediate PROD Blockers (Must-Resolve)

### Critical Blockers
1. ❌ **DNS domain** - Requires domain ownership or subdomain delegation
   - **Decision needed:** Use existing domain or register new?
   - **Alternative:** Use EC2 public IP + self-signed cert (NOT recommended for production)

2. ❌ **API authentication** - Requires code changes to application
   - **Workaround:** Deploy without auth initially (if acceptable for pre-defense)
   - **Risk:** API is publicly accessible to anyone with domain

### Non-Blocking (Can Deploy Without)
- ⚠️ Rate limiting (add later)
- ⚠️ Monitoring/alerting (can observe manually initially)
- ⚠️ Backups (data is reproducible)

---

## Recommended Deployment Order

### Pre-Defense MVP (Minimal PROD)
**Goal:** Demonstrate PROD deployment without full production-readiness

**Requirements:**
- ✅ Same image as DEV (already tested)
- ✅ Separate namespace (triage-prod)
- ⚠️ HTTP only (skip TLS for demo, acknowledge as known gap)
- ⚠️ No authentication (acknowledge as next step)
- ✅ Resource limits (already configured)
- ✅ Health/readiness probes (already configured)

**Deployment steps:**
1. Create triage-prod namespace ✅ (already exists)
2. Update aws-prod overlay image tag
3. Apply overlay: `kubectl apply -k k8s/overlays/aws-prod`
4. Verify pod starts successfully
5. Demo via `kubectl port-forward` (no external ingress yet)

**Time:** 15 minutes  
**Risk:** Low (same code as working DEV)

### Post-Defense Production-Grade
**Goal:** Secure, externally accessible API with authentication

**Additional requirements:**
- ✅ HTTPS with valid certificate
- ✅ API key authentication
- ✅ Rate limiting
- ✅ Monitoring dashboard
- ✅ Automated backups

**Time:** 6-9 hours (full implementation)

---

## Security Checklist for PROD

- [ ] TLS 1.2+ enforced (no HTTP fallback)
- [ ] API authentication required (API key minimum)
- [ ] Rate limiting configured (protect against abuse)
- [ ] Secrets stored in Kubernetes Secrets (not ConfigMaps)
- [ ] Non-root container (already ✅)
- [ ] Read-only root filesystem (already ✅)
- [ ] Resource limits enforced (already ✅)
- [ ] Network policies (optional, isolate namespaces)
- [ ] Ingress firewall rules (restrict source IPs if possible)
- [ ] Audit logging enabled (track API access)
- [ ] Security scanning (Trivy already ✅)
- [ ] Dependency updates (Dependabot or Renovate)

---

## Cost Estimate (AWS PROD vs DEV)

### Current DEV Cost
- EC2 m6i.xlarge: ~$30/month (shared with PROD)
- Bedrock Nova Micro: ~$0.15 per 1M input tokens
- S3 backups: ~$1/month (if implemented)
- EBS volume: ~$8/month (30 GB gp3)
- **Total:** ~$39/month + per-request Bedrock costs

### Additional PROD Cost
- **Same infrastructure** (DEV + PROD colocated on same node)
- **Additional Bedrock usage** (depends on production traffic)
- **ALB/NLB** (if using LoadBalancer): +$16/month
  - **Avoided** if using Ingress (nginx runs in-cluster)
- **CloudWatch metrics** (if implemented): +$5-10/month
- **S3 backups:** +$1/month

**PROD incremental cost:** $0-2/month (Ingress approach, shared node)  
**With separate monitoring:** +$5-10/month

---

## Recommendation

### For Pre-Defense Demo (Next 1-2 Days)
**Deploy minimal PROD without TLS/auth:**
1. Update aws-prod overlay image tag
2. Deploy to triage-prod namespace
3. Demo via port-forward (show namespace isolation)
4. Acknowledge TLS/auth as "next steps" in presentation

**Effort:** 15 minutes  
**Risk:** Minimal  
**Demo value:** Shows multi-environment deployment pattern

### For Post-Defense Production Launch (Next 1-2 Weeks)
**Full secure deployment:**
1. Obtain domain or subdomain
2. Install ingress-nginx + cert-manager
3. Implement API key authentication
4. Configure rate limiting
5. Set up monitoring dashboard
6. Document runbook and incident response

**Effort:** 6-9 hours over 2-3 sessions  
**Risk:** Low (well-trodden path)  
**Production-ready:** Yes
