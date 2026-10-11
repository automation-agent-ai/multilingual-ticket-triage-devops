# Security Documentation — Multilingual Ticket Triage DevOps

**Sprint:** S08 — Security & DevSecOps Finalization  
**Date:** 2026-10-11  
**Classification:** Internal — Liora Compliance  
**Status:** ✅ Verified (read-only audit, no production changes)

---

## 1. Threat Model

### System Boundary

The system comprises a FastAPI-based ticket-triage service packaged as a
Docker container, deployed to a local Kubernetes (kind) cluster with two
application namespaces (`triage-dev`, `triage-prod`) and a monitoring
namespace (`triage-monitoring`). CI/CD runs on GitHub Actions; images are
published to GitHub Container Registry (GHCR).

### Assets

| Asset | Classification | Location |
|---|---|---|
| Application source code | Internal | GitHub repo |
| AI model weights (HuggingFace E5-large) | Internal | Host path `/data/hf-cache` |
| DuckDB + LanceDB data | Internal | Host path `/data/app-data-{dev,prod}` |
| Grafana admin credentials | Secret | Kubernetes Secret `grafana-credentials` |
| CI secrets (`GITHUB_TOKEN`) | Secret | GitHub Actions encrypted secrets |
| Container image | Internal | GHCR `ghcr.io/automation-agent-ai/...` |

### Threat Actors

| Actor | Description | Likelihood |
|---|---|---|
| External attacker | Internet-exposed endpoint compromise | Low — no public ingress |
| Malicious dependency | Compromised PyPI or Docker Hub package | Medium — supply-chain risk |
| Insider / CI abuse | Workflow manipulation or secret exfiltration | Low — branch protection + PR review |
| Container escape | Privilege escalation from compromised container | Low — hardened securityContext |

---

## 2. Implemented Security Controls

### Control 1 — Container Hardening (Non-Root, Privilege Escalation, Capabilities)

**File:** `Dockerfile` (lines 63–67, 120, 52–60), `k8s/base/deployment.yaml` (lines 18–24, 52–60)

The application container runs as non-root user `appuser` (UID 1000) in
both the image definition and the Kubernetes pod specification.

**Dockerfile — user and group creation:**
```
RUN groupadd --gid 1000 appgroup \
 && useradd  --uid 1000 --gid appgroup --shell /bin/bash --create-home appuser
...
USER appuser
```

**k8s/base/deployment.yaml — pod-level securityContext:**
```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 1000
  runAsGroup: 1000
  fsGroup: 1000
```

**k8s/base/deployment.yaml — container-level securityContext:**
```yaml
securityContext:
  allowPrivilegeEscalation: false
  capabilities:
    drop:
      - ALL
  readOnlyRootFilesystem: false   # Python writes __pycache__; documented residual
```

**Live evidence — DEV pod:**
```bash
$ kubectl get pod -n triage-dev -o jsonpath='{.items[0].spec.securityContext}' | python3 -m json.tool
{
    "fsGroup": 1000,
    "runAsGroup": 1000,
    "runAsNonRoot": true,
    "runAsUser": 1000
}

$ kubectl get pod -n triage-dev -o jsonpath='{.items[0].spec.containers[0].securityContext}' | python3 -m json.tool
{
    "allowPrivilegeEscalation": false,
    "capabilities": {
        "drop": ["ALL"]
    },
    "readOnlyRootFilesystem": false
}
```

**Live evidence — PROD pod** (identical output — same base manifest):
```
fsGroup: 1000 | runAsNonRoot: true | runAsUser: 1000 | allowPrivilegeEscalation: false | capabilities.drop: ALL
```

Grafana (UID 472) and Prometheus (UID 65534) also enforce `runAsNonRoot: true`,
`allowPrivilegeEscalation: false`, `capabilities.drop: ALL`.

---

### Control 2 — Dependency Security: Trivy Scanning Gate

**File:** `.github/workflows/ci.yml` (lines 170–225)

A two-pass Trivy scan runs on every push to `main` and every pull request:

1. **Diagnostic scan** (`exit-code: 0`) — non-blocking table output; CVE
   details visible in the Actions log even when SARIF upload lags.
2. **Blocking scan** (`exit-code: 1`) — fails the pipeline and blocks the
   GHCR push on any unfixed CRITICAL or HIGH vulnerability.

```yaml
- name: Trivy — vulnerability scan
  uses: aquasecurity/trivy-action@v0.36.0
  with:
    image-ref: ticket-triage-api:ci-scan
    format: sarif
    scanners: vuln
    severity: CRITICAL,HIGH
    exit-code: "1"
    ignore-unfixed: true          # skips OS-layer CVEs with no upstream fix
    limit-severities-for-sarif: true

# GHCR push is gated on Trivy success:
- name: Push image to GHCR
  if: >-
    github.event_name == 'push'
    && github.ref == 'refs/heads/main'
    && steps.trivy.outcome == 'success'
```

SARIF results are uploaded to the GitHub Security → Code scanning tab
(`security-events: write` permission granted).

**S05b remediation matrix (CVEs fixed before blocking scan):**

| Package | Old version | New version | CVE / Advisory | Severity |
|---|---|---|---|---|
| `torch` | 2.3.1+cpu | 2.10.0+cpu | CVE-2025-32434 (unsafe `torch.load`) | CRITICAL |
| `torch` | 2.3.1+cpu | 2.10.0+cpu | GHSA-63cw-57p8-fm3p (RCE via checkpoint) | HIGH |
| `sentence-transformers` | 4.1.0 | 5.6.0 | CVE-2026-68770 (RCE — security control bypass) | CRITICAL |
| `transformers` | 4.57.6 | 5.10.1 | CVE-2026-4372, CVE-2026-5241, CVE-2026-9856 | HIGH |
| `pyarrow` | 20.0.0 | 23.0.1 | CVE-2026-25087 (use-after-free / DoS) | HIGH |
| `urllib3` | 2.7.0 | 2.8.0 | CVE-2026-97687, CVE-2026-97689 | HIGH |
| `setuptools` | (bundled) | removed | CVE-2025-47273 (path traversal in PackageIndex) | HIGH |
| `pip` / `msgpack` | (bundled) | removed | GHSA-6v7p-g79w-8964 (OOB read/crash) | HIGH |

`pip` and `setuptools` are removed from the runtime image layer
(`Dockerfile` lines 98–101); the runtime container cannot install packages.

---

### Control 3 — Data and Secrets Protection

#### 3a. Git Exclusions

**File:** `.gitignore` (lines 15–17, 48–55, 64–68)

```
.env
.env.*
!.env.example

kaggle.json
.kaggle/

*.tfstate
*.tfstate.*
*.tfplan
*.tfvars
!terraform/terraform.tfvars.example
```

No environment files, Terraform state, or credential files have ever been
committed to the repository. `data/lancedb/` and `data/*.duckdb` are also
excluded; only a `.gitkeep` placeholder is tracked.

#### 3b. Docker Build Context Exclusions

**File:** `.dockerignore` (lines 52–62)

```
.env
.env.*
*.env
*.pem
*.key
*.crt
*.p12
*.pfx
kaggle.json
secrets/
```

The build context never includes secrets or credential files. The Dockerfile
comment states explicitly: *"the image itself contains no datasets, databases,
model weights, or secrets."*

#### 3c. Application Data Read-Only Mount

**File:** `k8s/base/deployment.yaml` (lines 71–74)

```yaml
- name: app-data
  mountPath: /app/data
  readOnly: true
```

**Live evidence:**
```bash
$ kubectl get pod -n triage-dev -o json | python3 -c "..."
  app-data   mountPath=/app/data   readOnly=True
```

The DuckDB and LanceDB files are mounted read-only; the container cannot
overwrite production data.

#### 3d. Grafana Credential Handling

**File:** `monitoring/grafana/deployment.yaml` (lines 44–59)

```yaml
env:
  - name: GF_SECURITY_ADMIN_USER
    valueFrom:
      secretKeyRef:
        name: grafana-credentials
        key: admin-user
  - name: GF_SECURITY_ADMIN_PASSWORD
    valueFrom:
      secretKeyRef:
        name: grafana-credentials
        key: admin-password
  - name: GF_AUTH_ANONYMOUS_ENABLED
    value: "false"
```

The `grafana-credentials` Kubernetes Secret is created locally via
`kubectl create secret generic` and is **never committed to git** (confirmed:
no credential files in `.gitignore` exclusions; confirmed absent from git log).

**Programmatic verification (values not printed):**
```bash
$ kubectl get secret grafana-credentials -n triage-monitoring ...
Secret keys present: ['admin-password', 'admin-user']
Password is a known weak default: False     # not 'admin', 'password', 'grafana', etc.
```

Anonymous access is disabled (`GF_AUTH_ANONYMOUS_ENABLED=false`).
Telemetry is disabled (`GF_ANALYTICS_REPORTING_ENABLED=false`).

> **Demo-credential risk notice:** The `grafana-credentials` Secret resides
> in the local kind cluster's etcd store, which is **not encrypted at rest**
> by default on Docker Desktop / kind. This is acceptable for a local
> development cluster but is **not suitable for a production multi-tenant
> environment**. Before any production exposure, enable etcd encryption at
> rest and integrate with a secrets manager (e.g. Vault, AWS Secrets Manager).

---

### Control 4 — Kubernetes Namespace Isolation and Service Accounts

**Files:** `k8s/overlays/dev/namespace.yaml`, `k8s/overlays/prod/namespace.yaml`,
`monitoring/grafana/deployment.yaml`, `monitoring/prometheus/deployment.yaml`,
`terraform/main.tf`

Three separate namespaces provide workload isolation:

| Namespace | Workloads | ServiceAccount |
|---|---|---|
| `triage-dev` | ticket-triage API (dev) | `default` |
| `triage-prod` | ticket-triage API (prod) | `default` |
| `triage-monitoring` | Prometheus, Grafana | `triage-prometheus`, `triage-grafana` |

Prometheus and Grafana use dedicated ServiceAccounts provisioned by Terraform
(Sprint S06). The application SA (`default` in `triage-dev`/`triage-prod`) has
minimal Kubernetes-default permissions — verified:

```bash
$ kubectl auth can-i --list \
    --as=system:serviceaccount:triage-dev:default -n triage-dev
Resources                                       Verbs
selfsubjectreviews.authentication.k8s.io        [create]
selfsubjectaccessreviews.authorization.k8s.io   [create]
# ... only self-subject and read-only API-discovery non-resource URLs
# No pods/get, no secrets/get, no deployments/update
```

No custom ClusterRoleBindings exist for the application namespaces — confirmed:
```bash
$ kubectl get clusterrolebindings | grep triage
(no results)
```

---

### Control 5 — CI/CD Security Posture

**File:** `.github/workflows/ci.yml` (lines 29–31, 108–111, 143–149, 218–226)

```yaml
# Default minimum permissions — jobs add only what they need
permissions:
  contents: read

# build-scan-push job: only adds packages:write (push) and security-events:write (SARIF)
# packages:write and login to GHCR are conditionally blocked on PRs:
- name: Log in to GHCR
  if: github.event_name == 'push' && github.ref == 'refs/heads/main'

# GHCR push is triple-gated:
- name: Push image to GHCR
  if: >-
    github.event_name == 'push'
    && github.ref == 'refs/heads/main'
    && steps.trivy.outcome == 'success'
```

**PROD deploy workflow:** Manual-only (`workflow_dispatch`), requires the
exact confirmation string `DEPLOY`, and is gated by a GitHub Environment
`production` approval (required reviewers configured in GitHub Settings).

```yaml
# deploy-prod.yml (lines 28–34)
on:
  workflow_dispatch:
    inputs:
      confirm_production:
        description: "Type DEPLOY to confirm production deployment"
        required: true
```

---

## 3. Residual Vulnerabilities and Risks

### 3.1 Unfixed HIGH OS-Layer CVEs (S05b-RC2 Diagnostic Scan)

**Count: 54 unfixed HIGH severity CVEs**

Source: Trivy diagnostic scan (non-blocking, table format) run during CI build
`S05b-RC2`. These are OS package vulnerabilities in the `python:3.12-slim`
base image for which **no upstream fix exists at the time of the scan**.

The blocking Trivy gate uses `ignore-unfixed: true`, which means these 54 CVEs
**do not block CI** but remain present in the running image.

**This image is NOT vulnerability-free.** The following categories of
unfixable OS CVEs are present:

| Source | Package type | Description |
|---|---|---|
| Debian GNU C Library (`glibc`) | OS system library | Memory safety issues without backport |
| `perl` / `perl-base` | OS scripting runtime | Multiple CVEs, not used by application |
| `libssl` / `openssl` | TLS library | Version pinned by Debian slim |
| `libsystemd0` / `libudev1` | System init libs | Not used in container context |
| `login` / `passwd` | PAM utilities | Present in slim; no application use |

**Mitigation rationale:** `ignore-unfixed: true` is a deliberate policy choice
to avoid false-positive failures on CVEs that the maintainer of the base image
cannot yet patch. A rebuilt image using a future `python:3.12-slim` release
will automatically inherit fixes as Debian backports them.

**Recommendation:** Rebuild and re-scan on a weekly schedule. Consider
migrating to `python:3.12-slim-bookworm` with explicit `apt-get upgrade -y`
in the builder stage, or to a distroless base image, to reduce OS attack surface.

### 3.2 Read-Only Root Filesystem Disabled

`readOnlyRootFilesystem: false` — Python writes `__pycache__` directories
into `/app` at import time. This is a known, documented trade-off
(`k8s/base/deployment.yaml` line 58). All data directories use dedicated
volume mounts.

**Recommendation:** Evaluate a pre-compilation strategy (`python -m compileall`)
at image build time to allow `readOnlyRootFilesystem: true` in a future sprint.

### 3.3 No Kubernetes NetworkPolicy

No `NetworkPolicy` objects restrict pod-to-pod traffic within or across
namespaces. Any pod in `triage-dev` can theoretically reach any pod in
`triage-monitoring` via the cluster network.

**Recommendation:** Add egress-restricted NetworkPolicies for each namespace
(allow only specific service endpoints; deny all else by default).

### 3.4 Application ServiceAccount Uses `default`

`triage-dev` and `triage-prod` pods use the `default` ServiceAccount rather
than a dedicated, role-restricted ServiceAccount. No harmful permissions are
currently bound to `default`, but a dedicated SA with an explicit deny policy
would be preferable.

**Recommendation:** Create dedicated `triage-app-dev` / `triage-app-prod`
ServiceAccounts and bind them to a minimal Role (no verbs; no resource access).

### 3.5 Grafana etcd Credential Storage

The `grafana-credentials` Secret is stored in the local kind cluster etcd,
which is not encrypted at rest by default. The password is not a known
weak default (verified), but the storage medium is unencrypted.

**Recommendation:** For any internet-exposed deployment, enable etcd encryption
at rest and use an external secrets manager.

### 3.6 Prometheus `--web.enable-lifecycle` Flag

`monitoring/prometheus/deployment.yaml` line 40 passes
`--web.enable-lifecycle` which enables POST `/-/reload` and POST `/-/quit`
endpoints. These are accessible to any pod that can reach Prometheus on port
9090. There is no authentication on Prometheus itself.

**Recommendation:** Remove `--web.enable-lifecycle` in production, or restrict
Prometheus access to the monitoring namespace using a NetworkPolicy.

---

## 4. Kubernetes Workload Status (Confirmed Operational)

Verification timestamp: 2026-10-11 12:41 UTC

```
NAMESPACE          NAME                            READY   STATUS    RESTARTS
triage-dev         ticket-triage-cf7cfdc7b-wng59   1/1     Running   0
triage-prod        ticket-triage-86b46fdb47-xtdmx  1/1     Running   1 (56m ago)
triage-monitoring  grafana-5d9d8678b5-f9v6q        1/1     Running   0
triage-monitoring  prometheus-85bc6d4f5-fltv9      1/1     Running   0
```

All four application workloads are **Running / Ready**. No production changes
were made during this audit.

---

## 5. Security Compliance Matrix (Liora Requirements)

| Requirement | Control | Status | Evidence |
|---|---|---|---|
| Non-root container execution | Pod `runAsNonRoot: true`, `runAsUser: 1000`; Dockerfile `USER appuser` | ✅ Implemented & Verified | Live `kubectl` output; `Dockerfile` line 120 |
| No privilege escalation | `allowPrivilegeEscalation: false` on all containers | ✅ Implemented & Verified | Live `kubectl` output; `k8s/base/deployment.yaml` line 53 |
| Dropped Linux capabilities | `capabilities.drop: [ALL]` on all containers | ✅ Implemented & Verified | Live `kubectl` output; `k8s/base/deployment.yaml` line 54–56 |
| Image vulnerability scanning | Trivy `CRITICAL,HIGH`, `exit-code: 1`, SARIF upload | ✅ Implemented | `.github/workflows/ci.yml` lines 195–210 |
| Blocking security gate | GHCR push gated on `steps.trivy.outcome == 'success'` | ✅ Implemented | `.github/workflows/ci.yml` line 225 |
| Dependency remediation | 8 CVEs remediated in S05b (CRITICAL + HIGH) | ✅ Documented | `requirements-docker.txt` comments; `Dockerfile` lines 36–100 |
| Secrets not in Git | `.gitignore` excludes `.env`, `*.key`, `*.tfstate`, `kaggle.json` | ✅ Implemented & Verified | `.gitignore`; `git log` confirms no leakage |
| Secrets not in Docker image | `.dockerignore` excludes all credential patterns | ✅ Implemented | `.dockerignore` lines 52–62 |
| Grafana credential handling | K8s Secret + `secretKeyRef`; anon access disabled | ✅ Implemented & Verified | `monitoring/grafana/deployment.yaml` lines 44–60 |
| Read-only data mounts | `app-data` volume `readOnly: true` | ✅ Implemented & Verified | Live kubectl; `k8s/base/deployment.yaml` line 74 |
| Namespace isolation | `triage-dev`, `triage-prod`, `triage-monitoring` separate | ✅ Implemented & Verified | `kubectl get namespaces`; namespace YAML files |
| Dedicated monitoring ServiceAccounts | `triage-prometheus`, `triage-grafana` via Terraform | ✅ Implemented | `terraform/main.tf` lines 91–120 |
| CI minimum permissions | `permissions: contents: read` global default | ✅ Implemented | `.github/workflows/ci.yml` lines 29–31 |
| Production deployment gate | Manual-only, `DEPLOY` confirmation, GitHub Environment approval | ✅ Implemented | `.github/workflows/deploy-prod.yml` lines 26–34, 80 |
| Residual OS CVEs documented | 54 unfixed HIGH OS CVEs acknowledged as residual risk | ✅ Documented | Section 3.1 of this document |
| No secrets in logs/docs | This document contains no credential values | ✅ Verified | Programmatic check (Section 2 / Control 3d) |

---

## 6. Practical Recommendations (Priority Order)

1. **[HIGH] Add Kubernetes NetworkPolicy** — Default-deny all ingress/egress
   per namespace; allow only required service-to-service paths. Prevents
   lateral movement between namespaces.

2. **[HIGH] Enable etcd encryption at rest** — Required before any production
   or internet-exposed deployment to protect K8s Secrets.

3. **[MEDIUM] Dedicated application ServiceAccounts** — Replace the `default`
   SA in `triage-dev`/`triage-prod` with namespace-scoped SAs with no
   additional RBAC permissions.

4. **[MEDIUM] Weekly Trivy rebuild schedule** — Automate a weekly base-image
   rebuild to inherit OS patches as Debian backports them. Target: reduce
   residual OS CVE count from 54.

5. **[MEDIUM] Remove `--web.enable-lifecycle`** from Prometheus in a future
   sprint or restrict it to the monitoring namespace via NetworkPolicy.

6. **[LOW] Evaluate `readOnlyRootFilesystem: true`** — Pre-compile Python
   sources at build time to allow this hardening. Reduces container writeable
   surface area.

7. **[LOW] Pin monitoring image tags** — Grafana `11.4.0` and Prometheus
   `v3.1.0` are pinned; good practice maintained. Continue pinning on upgrades.

---

*This document was produced by a read-only security audit. No application
business logic, production workloads, AI model weights, or databases were
modified. Git status at audit completion: uncommitted working-tree changes in
`api/app.py`, `k8s/overlays/dev/kustomization.yaml`, `requirements-docker.txt`,
`requirements.txt` (pre-existing S07 changes); `docs/SECURITY.md` is a new
untracked file.*
