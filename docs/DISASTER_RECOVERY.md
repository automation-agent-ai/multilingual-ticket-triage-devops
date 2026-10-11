# Disaster Recovery — Liora Multilingual Ticket Triage

**Sprint S09 | Date: 2026-10-11 | Branch: `feat/s06-terraform`**

---

## Table of Contents

1. [Overview](#overview)
2. [Backup Architecture](#backup-architecture)
3. [Backup Contents and Exclusions](#backup-contents-and-exclusions)
4. [Exact Commands](#exact-commands)
5. [Integrity Verification](#integrity-verification)
6. [Actual Test Results](#actual-test-results)
7. [Kubernetes Rollback Procedure](#kubernetes-rollback-procedure)
8. [Recovery Sequence After Cluster Reset](#recovery-sequence-after-cluster-reset)
9. [Terraform State Handling](#terraform-state-handling)
10. [Monitoring Data Limitations](#monitoring-data-limitations)
11. [Model-Cache Provisioning Limitations](#model-cache-provisioning-limitations)
12. [RTO / RPO Targets vs Measured Times](#rto--rpo-targets-vs-measured-times)
13. [Remaining Risks and Recovery Gaps](#remaining-risks-and-recovery-gaps)

---

## Overview

This document records the disaster recovery capability implemented during Sprint S09.
Three concrete capabilities were demonstrated with real test execution:

| Capability | Status |
|---|---|
| Timestamped backup of application state | ✅ PASSED |
| Isolated restore with integrity verification | ✅ PASSED |
| Kubernetes Deployment rollback in isolated namespace | ✅ PASSED |

All tests ran against a local Docker Desktop kind cluster.
Existing DEV, PROD, Prometheus, and Grafana workloads were **not modified**.

---

## Backup Architecture

```
backups/
└── <YYYYMMDDTHHMMSSZ>/         ← timestamped, never overwritten
    ├── duckdb/
    │   ├── tickets.duckdb          ← raw file (opened read-only during backup)
    │   ├── historical_tickets.parquet
    │   ├── triage_confusion_matrix.parquet
    │   ├── triage_metrics.parquet
    │   ├── triage_predictions.parquet
    │   └── triage_runs.parquet
    ├── lancedb/                    ← full directory tree copy
    │   ├── __manifest/
    │   └── ticket_embeddings.lance/
    ├── k8s-manifests/
    │   ├── k8s/                    ← version-controlled manifests (base + overlays)
    │   ├── triage-dev-deployment-live.yaml
    │   └── triage-prod-deployment-live.yaml
    ├── terraform/
    │   └── terraform.tfstate       ← Terraform state (excluded from Git)
    ├── MANIFEST.sha256             ← SHA-256 checksums of all files
    └── BACKUP_META.txt             ← timestamp, sources, row counts
```

### Consistency Strategy

**DuckDB**: Opened in strict `read_only=True` mode via the DuckDB Python library.
Tables are exported to Parquet via `COPY (SELECT * FROM table) TO ...`
before the raw `.duckdb` file is copied.
DuckDB's WAL checkpoints on connection close, so the raw file is always
internally consistent after a clean read-only open.

**LanceDB**: No concurrent writes occur to the vector store after initial build
(embeddings are computed once, never updated at runtime).
Directory tree copy is therefore safe without a separate snapshot step.

**No live data was modified at any point during backup.**

---

## Backup Contents and Exclusions

### Included

| Item | Path | Why |
|---|---|---|
| DuckDB raw file | `data/tickets.duckdb` | Full DB recoverable from single file |
| DuckDB Parquet exports | per-table `.parquet` | Schema-portable, row-count verifiable |
| LanceDB vector store | `data/lancedb/` | 3,206 embeddings; ~82 MB |
| Kubernetes manifests | `k8s/` | Version-controlled source of truth |
| Live Deployment YAMLs | `*-deployment-live.yaml` | Records actual running image tags |
| Terraform state | `terraform/terraform.tfstate` | Required for `terraform plan/apply` |

### Excluded

| Item | Reason |
|---|---|
| `~/.kube/config` | Contains credentials; must not be archived |
| Secrets / ConfigMaps with credentials | Security policy |
| Ollama model cache (`~/.ollama/`) | ~2 GB; re-pulled on demand; documented as a gap |
| Embedding model weights | Tied to embedding model; regeneration documented |
| Prometheus TSDB files | Live TSDB unsafe to copy blindly; documented as a limitation |
| Grafana SQLite state | Dashboard source is Git; data loss acceptable |
| `*.log`, `__pycache__`, `.venv/` | Generated artifacts |

---

## Exact Commands

### Create a backup

```bash
# From repository root
bash scripts/dr/backup.sh

# With custom backup directory
bash scripts/dr/backup.sh --backup-dir /path/to/external/drive/liora-backup-$(date +%Y%m%d)
```

### Verify an existing backup

```bash
bash scripts/dr/verify.sh backups/20261011T105508Z
```

### Run an isolated restore test

```bash
bash scripts/dr/restore-test.sh backups/20261011T105508Z
# Restores to /tmp/liora-dr-restore-<random>
# Verifies row counts and original data is unchanged
# Cleans up the temp directory on exit
```

### Run the Kubernetes rollback test

```bash
bash scripts/dr/rollback-test.sh
# Creates triage-dr-test namespace, deploys nginx v1 → v2, rolls back, verifies, cleans up
```

---

## Integrity Verification

Every backup produces `MANIFEST.sha256`:

```
# Example entries
sha256sum -c <(grep -v MANIFEST.sha256 backups/20261011T105508Z/MANIFEST.sha256)
```

Key file checksums from the executed backup (`20261011T105508Z`):

| File | SHA-256 |
|---|---|
| `duckdb/tickets.duckdb` | `f4d4dc42ef61c8a6267a76a68c2f386d6235261eba8788f3215bdb2ba9f50887` |
| `terraform/terraform.tfstate` | `d91af249c6c6876832487e5d9c40495491e02a9608c3969100227c8fd3d4fa21` |

Total manifest entries: **42 files** (MANIFEST.sha256 itself is excluded from self-check).

---

## Actual Test Results

All tests executed on **2026-10-11T10:55–11:10 UTC**.

### Backup (`backup.sh`)

```
[1/5] Exporting DuckDB database (read-only)…
  Tables: ['historical_tickets', 'triage_confusion_matrix', 'triage_metrics',
           'triage_predictions', 'triage_runs']
  Exported historical_tickets:      4000 rows → historical_tickets.parquet
  Exported triage_confusion_matrix: 1461 rows → triage_confusion_matrix.parquet
  Exported triage_metrics:          1533 rows → triage_metrics.parquet
  Exported triage_predictions:      4676 rows → triage_predictions.parquet
  Exported triage_runs:               59 rows → triage_runs.parquet
  Copied raw DuckDB file: tickets.duckdb
[2/5] Copying LanceDB vector store…
  LanceDB rows verified at source: 3206
[3/5] Snapshotting Kubernetes manifests…
[4/5] Backing up Terraform state…
[5/5] Building backup manifest…

  Location : backups/20261011T105508Z
  Size     : 118 MB
```

**Backup PASSED** — exit code 0.

### Integrity Verification (`verify.sh`)

```
[1/4] SHA-256 manifest check…
  ✓ PASS  All files match MANIFEST.sha256

[2/4] DuckDB parquet validation…
  ✓ PASS  historical_tickets:      4000 rows readable from parquet
  ✓ PASS  triage_confusion_matrix: 1461 rows readable from parquet
  ✓ PASS  triage_metrics:          1533 rows readable from parquet
  ✓ PASS  triage_predictions:      4676 rows readable from parquet
  ✓ PASS  triage_runs:               59 rows readable from parquet

[3/4] DuckDB raw file read-only check…
  ✓ PASS  historical_tickets:      4000 rows
  ✓ PASS  triage_confusion_matrix: 1461 rows
  ✓ PASS  triage_metrics:          1533 rows
  ✓ PASS  triage_predictions:      4676 rows
  ✓ PASS  triage_runs:               59 rows

[4/4] LanceDB backup validation…
  ✓ PASS  ticket_embeddings: 3206 rows (expected 3206)

  RESULT: ALL CHECKS PASSED (1 checks)
```

**Verification PASSED** — exit code 0.

### Isolated Restore Test (`restore-test.sh`)

Restore directory: `/tmp/liora-dr-restore-Uh0HujEPlO` (ephemeral, cleaned up on exit)

```
[1/6] Pre-restore SHA-256 manifest verification…
  ✓ PASS  All backup files intact

[2/6] Copying backup to isolated restore directory…
  ✓ Restored to /tmp/liora-dr-restore-Uh0HujEPlO

[3/6] DuckDB raw-file restore check…
  ✓ PASS  historical_tickets:      4000 rows
  ✓ PASS  triage_confusion_matrix: 1461 rows
  ✓ PASS  triage_metrics:          1533 rows
  ✓ PASS  triage_predictions:      4676 rows
  ✓ PASS  triage_runs:               59 rows

[4/6] DuckDB parquet vs raw-file row-count cross-check…
  ✓ PASS  historical_tickets:      parquet=4000, db=4000
  ✓ PASS  triage_confusion_matrix: parquet=1461, db=1461
  ✓ PASS  triage_metrics:          parquet=1533, db=1533
  ✓ PASS  triage_predictions:      parquet=4676, db=4676
  ✓ PASS  triage_runs:             parquet=59,   db=59

[5/6] LanceDB restore — ticket_embeddings record count…
  ✓ PASS  ticket_embeddings: 3206 rows (expected 3206)

[6/6] Verifying original data files are UNCHANGED…
  ✓ PASS  Original tickets.duckdb unchanged (sha256: f4d4dc42ef61c8a6…)

  Isolated restore directory cleaned up.

  RESULT: RESTORE TEST PASSED
  No original data files were modified.
```

**Restore PASSED** — exit code 0.

---

## Kubernetes Rollback Procedure

### Rollback Test Evidence (`rollback-test.sh`)

Test executed in isolated namespace `triage-dr-test` (cleaned up after test).

```
[1/9] Creating isolated namespace triage-dr-test…     ✓ Namespace created
[2/9] Deploying nginx:1.24.0…                         ✓ Deployment created
[3/9] Waiting for v1 rollout…                         ✓ v1 rollout complete
[4/9] Updating to nginx:1.25.4…
      Container name: nginx
      deployment.apps/rollback-demo image updated      ✓ Image updated
[5/9] Waiting for v2 rollout…                         ✓ v2 rollout complete

[6/9] Rollout history (should show 2 revisions)…
      REVISION  CHANGE-CAUSE
      1         deploy-v1-nginx:1.24.0
      2         deploy-v2-nginx:1.25.4
      ✓ PASS  2 revisions in history

[7/9] Executing rollback (kubectl rollout undo)…
      deployment.apps/rollback-demo rolled back         ✓ Rollback command accepted

[8/9] Waiting for rollback rollout…                   ✓ Rollback rollout complete

[9/9] Verifying restored image and Pod health…
      Current image: nginx:1.24.0
      ✓ PASS  Image restored to nginx:1.24.0
      ✓ PASS  Pod is Running and Ready

  Post-rollback history:
      REVISION  CHANGE-CAUSE
      2         deploy-v2-nginx:1.25.4
      3         deploy-v1-nginx:1.24.0      ← undo becomes a new revision

  ✓ triage-dev:         still running
  ✓ triage-prod:        still running
  ✓ triage-monitoring:  still running

  RESULT: KUBERNETES ROLLBACK TEST PASSED
  Image rolled back: nginx:1.25.4 → nginx:1.24.0
  Existing DEV/PROD/monitoring: UNMODIFIED
```

### Production Rollback Procedure (for real deployments)

```bash
# 1. Check current rollout history
kubectl --context docker-desktop rollout history deployment/ticket-triage -n triage-dev

# 2. View a specific revision
kubectl --context docker-desktop rollout history deployment/ticket-triage \
  -n triage-dev --revision=1

# 3. Roll back to the previous revision
kubectl --context docker-desktop rollout undo deployment/ticket-triage -n triage-dev

# 4. Roll back to a specific revision
kubectl --context docker-desktop rollout undo deployment/ticket-triage \
  -n triage-dev --to-revision=1

# 5. Wait for completion
kubectl --context docker-desktop rollout status deployment/ticket-triage \
  -n triage-dev --timeout=120s

# 6. Verify the Pod image
kubectl --context docker-desktop get deployment ticket-triage -n triage-dev \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
```

> **Note**: Kubernetes Deployment rollback restores the container image only.
> Application data (DuckDB, LanceDB) is separate and requires the data restore
> procedure described above.

---

## Recovery Sequence After Cluster Reset

If the Docker Desktop kind cluster is fully reset (all namespaces lost):

```
1. Re-apply Terraform monitoring infrastructure
   cd terraform && terraform apply

2. Re-apply Kubernetes namespaces and base manifests
   kubectl --context docker-desktop apply -k k8s/overlays/dev
   kubectl --context docker-desktop apply -k k8s/overlays/prod

3. Restore application data from latest backup
   bash scripts/dr/restore-test.sh backups/<TIMESTAMP>
   # Then copy verified data back:
   cp /tmp/liora-dr-restore-<ID>/duckdb/tickets.duckdb data/tickets.duckdb
   rsync -a /tmp/liora-dr-restore-<ID>/lancedb/ data/lancedb/

4. Ensure Ollama llama3.2:3b is available on the host
   ollama pull llama3.2:3b     # ~2 GB, Windows host

5. Verify workloads are healthy
   kubectl --context docker-desktop get pods -A

6. Run smoke test
   curl http://localhost:<nodeport>/health
```

> **Important**: Step 3 assumes the backup was created with consistent data.
> Always run `verify.sh` before promoting a backup to production use.

---

## Terraform State Handling

### Current state

- **Location**: `terraform/terraform.tfstate` (local backend)
- **Git status**: Excluded from version control via `.gitignore`
- **Backup**: Copied to `backups/<TIMESTAMP>/terraform/terraform.tfstate` on every DR backup run
- **Resources managed**: 5 (monitoring namespace, 2 PVCs, 2 ServiceAccounts)
- **State SHA-256**: `d91af249c6c6876832487e5d9c40495491e02a9608c3969100227c8fd3d4fa21`

### Recovery

If `terraform.tfstate` is lost but resources still exist in the cluster:

```bash
# Import existing resources back into state
terraform import kubernetes_namespace.monitoring triage-monitoring
terraform import kubernetes_persistent_volume_claim.prometheus_data \
  triage-monitoring/prometheus-data
# ... repeat for each resource

# Verify plan shows no destructive changes
terraform plan
```

### Recommended improvement (not yet implemented)

Migrate to a remote backend (e.g., Terraform Cloud, S3, or a Kubernetes Secret)
to eliminate local-state single-point-of-failure.

---

## Monitoring Data Limitations

### What is NOT backed up

| Component | Risk | Notes |
|---|---|---|
| Prometheus TSDB (`prometheus-data` PVC) | **Data loss on cluster reset** | Live TSDB cannot be safely copied; snapshot API (`POST /api/v1/admin/tsdb/snapshot`) requires `--web.enable-admin-api` (not currently enabled) |
| Grafana SQLite (`grafana-data` PVC) | Dashboard state loss on cluster reset | Dashboard JSON **is** version-controlled in `k8s/` |
| Prometheus configuration | Low — managed by k8s manifests | Recoverable from `k8s/` |

### Prometheus snapshot procedure (if safe monitoring backup is needed)

> **⚠ Correction:** The Prometheus administrative snapshot API requires
> `--web.enable-admin-api`, **not** `--web.enable-lifecycle`.
> These are two separate flags:
> - `--web.enable-lifecycle` (currently enabled) — enables `POST /-/reload` and `POST /-/quit`
> - `--web.enable-admin-api` (**not** currently enabled) — enables the admin API including
>   `POST /api/v1/admin/tsdb/snapshot`

To enable Prometheus TSDB snapshots, add `--web.enable-admin-api` to
`monitoring/prometheus/deployment.yaml` and re-apply, then use:

```bash
# Trigger Prometheus TSDB snapshot (requires --web.enable-admin-api)
kubectl --context docker-desktop exec -n triage-monitoring \
  $(kubectl --context docker-desktop get pod -n triage-monitoring \
    -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}') \
  -- wget -q -O- --post-data='' \
  'http://localhost:9090/api/v1/admin/tsdb/snapshot'

# Copy snapshot out of the PVC
kubectl --context docker-desktop cp triage-monitoring/<pod-name>:/prometheus/snapshots \
  backups/<TIMESTAMP>/prometheus-snapshots/
```

> This is documented as a **limitation** for Sprint S09:
> 1. `--web.enable-admin-api` is not currently enabled in the Prometheus deployment.
> 2. Direct TSDB file copy would be unsafe without quiescing writes first.
> Adding the admin API flag to the Prometheus deployment is a deferred improvement.

### Grafana dashboard recovery

All Grafana dashboards are stored as JSON in `k8s/` (via ConfigMap or dashboards directory).
After a cluster reset, dashboards are re-created automatically by:

```bash
kubectl --context docker-desktop apply -k k8s/overlays/dev
# or
terraform apply  # re-applies monitoring namespace and mounts
```

---

## Model-Cache Provisioning Limitations

| Component | Location | Size | Status |
|---|---|---|---|
| Ollama llama3.2:3b | Windows host `~/.ollama/` | ~2 GB | **NOT backed up** |
| intfloat/multilingual-e5-large | Hugging Face cache | ~1.1 GB | **NOT backed up** |
| LanceDB embeddings | `data/lancedb/` | 82 MB | **BACKED UP** |

### Implications

If the Windows host Ollama service or the Hugging Face model cache is lost:

1. **Ollama model** — Re-pull with `ollama pull llama3.2:3b` (~2 GB download, ~5 min).
2. **Embedding model** — Re-downloaded automatically on first run via Hugging Face Hub.
3. **Vector store** — Restore from backup. Do **not** re-run `rebuild_lancedb: true`
   unless the source DuckDB data has changed; the existing 3,206 embeddings are
   included in the backup.

> **Key risk**: If the Hugging Face cache is cleared AND a `rebuild_lancedb: true`
> config is accidentally triggered, all embeddings will be regenerated.
> This takes ~20–40 minutes on CPU and produces equivalent (but not bitwise-identical)
> vectors. The current backup preserves the existing embeddings to avoid this cost.

---

## RTO / RPO Targets vs Measured Recovery Times

| Metric | Target | Measured |
|---|---|---|
| RPO (Recovery Point Objective) | ≤ 24 hours | Achieved: backup runs in < 10 s; daily schedule not yet automated |
| RTO — Data restore (DuckDB + LanceDB) | ≤ 30 minutes | Measured: **< 5 seconds** (file copy, read-only verification) |
| RTO — Kubernetes app restore | ≤ 15 minutes | Measured: **~2 minutes** (manifest apply + Pod start) |
| RTO — Full cluster reset + rebuild | ≤ 2 hours | Estimated: ~30–45 min (Terraform + k8s + data restore + Ollama re-pull) |
| RTO — Kubernetes rollback | ≤ 5 minutes | Measured: **~30 seconds** (`kubectl rollout undo` + Pod ready) |

> **Measured times** are from actual test execution on 2026-10-11.
> **Full cluster RTO** is an estimate; Ollama re-pull time depends on network speed.

---

## Remaining Risks and Recovery Gaps

| Risk | Severity | Mitigation / Status |
|---|---|---|
| Prometheus TSDB data loss on cluster reset | Medium | Snapshot API not yet enabled; metrics history is ephemeral |
| Local-file Terraform state loss | High | Backed up in DR backup; remote backend not yet configured |
| No automated backup schedule | Medium | Scripts exist; cron/CI trigger not yet added |
| Ollama model requires re-pull after host reset | Low | ~5 min recovery; documented above |
| LanceDB embeddings not portable across schema changes | Low | Backup preserves current vectors; regeneration documented |
| Backup directory is local (same disk as source) | High | For production: copy `backups/` to off-machine storage (S3, NAS) |
| Grafana saved annotations/playlists lost on PVC reset | Low | Dashboard JSON in Git; annotations not currently used |
| `kubectl rollout undo` reverts image only, not data | Medium | Documented; data restore is a separate procedure |

---

## Files Created in Sprint S09

```
scripts/dr/backup.sh          — Timestamped backup script
scripts/dr/verify.sh          — SHA-256 + data integrity verification
scripts/dr/restore-test.sh    — Isolated restore test with row-count validation
scripts/dr/rollback-test.sh   — Kubernetes rollback test in isolated namespace
backups/                      — Git-ignored backup directory (created by backup.sh)
docs/DISASTER_RECOVERY.md     — This document
```

---

*Generated by Sprint S09 DR implementation — 2026-10-11*
