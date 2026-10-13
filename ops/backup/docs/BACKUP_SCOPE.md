# PHASE 11C — BACKUP SCOPE & LIMITATIONS

**Date**: October 13, 2026  
**Status**: Pre-Production (Local Testing Complete)

---

## WHAT IS BACKED UP (Scope Included)

### Application Databases ✅

**DuckDB** (`/home/ubuntu/workspaces/multilingual-ticket-triage-devops/data/tickets.duckdb`)
- **Tables**: 5 tables
  - `historical_tickets` (4,000 rows)
  - `triage_predictions`
  - `triage_metrics`
  - `triage_confusion_matrix`
  - `triage_runs`
- **Validation**: Strict consistency checks (no WAL files, 60s stability)
- **Backup Method**: File copy with SHA-256 integrity
- **Recovery Time**: ~5 seconds to restore

**LanceDB** (`/home/ubuntu/workspaces/multilingual-ticket-triage-devops/data/lancedb/`)
- **Table**: `ticket_embeddings`
- **Vectors**: 3,206 vectors (FATAL error if mismatch)
- **Dimensions**: 1,024 per vector (FATAL error if mismatch)
- **Validation**: STRICT vector count and dimension verification
- **Backup Method**: Directory copy with SHA-256 integrity
- **Recovery Time**: ~5 seconds to restore

### Backup Metadata ✅

- `backup-manifest.json` — Backup timestamp, component counts, validation status
- `CHECKSUMS.sha256` — SHA-256 hashes for all backed-up files
- Restic internal metadata — Snapshot IDs, incremental deltas, encryption keys

---

## WHAT IS NOT BACKED UP (Out of Scope)

### Operating System ❌

- **Ubuntu 22.04 LTS system files** — Not backed up
- **Installed packages** (`apt`, `snap`) — Not backed up
- **System configuration** (`/etc/`) — Not backed up
- **User home directories** (except application data) — Not backed up
- **Why**: OS is reproducible via Terraform + cloud-init in Phase 14

### EC2 Instance State ❌

- **EBS root volume** — Not backed up (requires separate EBS snapshot strategy)
- **Ephemeral storage** — Not backed up
- **Instance metadata** — Not backed up
- **Why**: Instance is cattle, not pet. Recreate via Terraform.

### Kubernetes (k3s) Infrastructure ❌

- **k3s cluster state** (`/var/lib/rancher/k3s/`) — Not backed up
- **Kubernetes deployments** (YAML manifests) — Not backed up (stored in Git)
- **Kubernetes ConfigMaps** — Not backed up
- **Kubernetes Secrets** — Not backed up
- **Persistent volumes** — Not backed up (application data only)
- **Why**: k3s cluster is reproducible via Terraform + manifests in Phase 14

### Monitoring & Observability ❌

- **Prometheus metrics** (`/var/lib/prometheus/`) — Not backed up
- **Prometheus Pushgateway state** — Not backed up
- **Node Exporter data** — Not backed up
- **Grafana dashboards** — Not backed up (stored in Git)
- **Application logs** — Not backed up
- **Why**: Monitoring data is ephemeral. Recreate monitoring stack via manifests.

### Application Configuration ❌

- **Kubernetes manifests** (`k8s/*.yaml`) — Not backed up
  - **Backed up in**: Git repository
- **Python application code** — Not backed up
  - **Backed up in**: Git repository
- **Environment configuration** (`.env`, secrets) — Not backed up
  - **Stored in**: Kubernetes secrets (recreated during deployment)
- **Why**: Configuration is version-controlled in Git

### Temporary & Cache Data ❌

- `/tmp/` — Not backed up
- `/var/cache/` — Not backed up
- `/var/log/` — Not backed up
- Python `__pycache__/` — Not backed up
- `.venv/` — Not backed up (recreated via `pip install -r requirements.txt`)
- **Why**: Temporary data is recreatable

### Hetzner Gateway ❌

- **Hetzner SSH gateway server** — Not backed up in Phase 11C
- **Why**: Separate backup scope (Phase 11D or later)
- **Backup Strategy**: TBD (likely rsync or Restic to separate S3 bucket)

---

## RECOVERY CAPABILITIES

### Scenario 1: Database Corruption or Accidental Deletion ✅

**Recovery Time Objective (RTO)**: ~5 minutes  
**Recovery Point Objective (RPO)**: Last successful backup (max 24-48 hours)

**What can be recovered**:
- ✅ DuckDB database (4,000 tickets)
- ✅ LanceDB vectors (3,206 embeddings)
- ✅ SHA-256 verified data integrity

**Procedure**:
```bash
export RESTIC_REPOSITORY="s3:s3.amazonaws.com/liora-triage-backups-523231704152"
export RESTIC_PASSWORD_FILE="/etc/liora-backup/restic-password"

# Restore to temporary location
restic restore latest --target /tmp/recovery

# Find restored data
find /tmp/recovery -name "tickets.duckdb"
find /tmp/recovery -name "lancedb"

# Validate restored data
python3 /home/ubuntu/phase11-backup-implementation/scripts/validate-databases.py /tmp/recovery/*/

# Stop application
kubectl scale deployment liora-triage --replicas=0

# Replace corrupted data
cp /tmp/recovery/.../tickets.duckdb /home/ubuntu/workspaces/.../data/
cp -r /tmp/recovery/.../lancedb /home/ubuntu/workspaces/.../data/

# Restart application
kubectl scale deployment liora-triage --replicas=1
```

**Limitations**:
- Requires EC2 instance to be running
- Requires Restic password and AWS credentials
- Data loss between last backup and corruption event

---

### Scenario 2: Complete EC2 Instance Loss ⚠️ PARTIAL RECOVERY

**Recovery Time Objective (RTO)**: TBD (Phase 14)  
**Recovery Point Objective (RPO)**: Last successful backup (max 24-48 hours)

**What Phase 11C provides**:
- ✅ Application database recovery (DuckDB + LanceDB)
- ✅ Backup validation scripts
- ✅ Recovery procedures

**What Phase 11C does NOT provide**:
- ❌ EC2 instance provisioning (requires Terraform apply)
- ❌ k3s cluster recreation (requires Phase 14)
- ❌ Kubernetes deployment (requires `kubectl apply -f k8s/`)
- ❌ Python environment setup (requires `pip install -r requirements.txt`)
- ❌ Monitoring stack recreation (requires Prometheus/Grafana manifests)
- ❌ SSH gateway recreation (requires separate backup)

**Procedure** (HIGH-LEVEL — requires Phase 14 implementation):
1. Provision new EC2 instance via Terraform
2. Install k3s (`curl -sfL https://get.k3s.io | sh -`)
3. Clone Git repository
4. Restore Python environment (`python3 -m venv .venv && pip install -r requirements.txt`)
5. Restore databases from Restic backup (as in Scenario 1)
6. Deploy Kubernetes manifests (`kubectl apply -f k8s/`)
7. Verify application health

**Estimated RTO**: 30-60 minutes (manual)  
**Automated RTO**: TBD (Phase 14 automation)

---

### Scenario 3: Full Disaster Recovery (Region Loss) ❌ NOT SUPPORTED

**Phase 11C does NOT provide**:
- ❌ Multi-region backup replication
- ❌ Cross-region S3 bucket failover
- ❌ Terraform state recovery
- ❌ DNS failover
- ❌ Git repository recovery

**Why**: Out of scope for Phase 11C cost-optimized backup

**Future Enhancement**: Multi-region disaster recovery requires:
- S3 cross-region replication
- Multi-region Terraform infrastructure
- DNS failover automation
- Cost increase: ~$5-10/month additional

---

## BACKUP VALIDATION

### Pre-Backup Validation ✅

**DuckDB**:
- ✅ File exists and readable
- ✅ NO WAL files present (FATAL if detected)
- ✅ File stable for 60+ seconds (FATAL if recent modification)
- ✅ File size > 1 MB
- ✅ STRICT consistency checks

**LanceDB**:
- ✅ Directory exists
- ✅ Table `ticket_embeddings` accessible
- ✅ Vector count = 3,206 (FATAL if mismatch)
- ✅ Vector dimensions = 1,024 (FATAL if mismatch)
- ✅ Schema integrity verified

### Post-Backup Validation ✅

- ✅ Restic snapshot created successfully
- ✅ Snapshot ID logged
- ✅ Repository integrity check (`restic check --read-data-subset=1%`)
- ✅ Snapshot count tracked
- ✅ Pruning safety checks (minimum 2 snapshots before prune)

### Restore Validation ✅

- ✅ SHA-256 checksums verified for all files
- ✅ DuckDB opens successfully (read-only mode)
- ✅ DuckDB table count = 5
- ✅ DuckDB historical_tickets count ≥ 3,500 (expected: 4,000)
- ✅ LanceDB opens successfully
- ✅ LanceDB vector count = 3,206 (FATAL if mismatch)
- ✅ LanceDB vector dimensions = 1,024 (FATAL if mismatch)

---

## BACKUP SCHEDULE & RETENTION

**Schedule**: Daily at 02:00 UTC (systemd timer)  
**Randomization**: ±5 minutes (avoid collisions)  
**Retention**: Last 7 daily snapshots  
**Pruning**: Automated with safety checks (minimum 2 snapshots)  
**Encryption**: AES-256 (client-side via Restic password)

**Estimated Backup Size**:
- Initial: ~35 MB (compressed from 107 MB raw)
- Daily incremental: ~1-5 MB (only changed data)
- 7-day retention: ~70 MB average

**Estimated Cost**: ~$0.05-0.10/month (S3 Standard, eu-west-1)

---

## RECOVERY PREREQUISITES

### Required for Database Recovery ✅

1. **Restic password** — Stored in AWS Systems Manager Parameter Store (recommended)
   - `/liora-triage/backup/restic-password` (SecureString)
2. **S3 bucket access** — IAM role `liora-triage-bedrock-role` with S3 permissions
3. **Restic binary** — Installed on recovery instance (`sudo snap install restic --classic`)
4. **Network access** — Internet connectivity to S3 (`s3.amazonaws.com`)
5. **Validation scripts** — Available in Phase 11C repository

### Required for Full Instance Recovery ❌ (Phase 14)

1. ✅ Database recovery prerequisites (above)
2. ❌ Terraform state file (`terraform.tfstate`)
3. ❌ Git repository with manifests
4. ❌ AWS credentials for Terraform
5. ❌ k3s installation script
6. ❌ Python requirements (`requirements.txt`)
7. ❌ Kubernetes secrets (recreate from secure storage)

---

## TESTING & VALIDATION

### Local Testing ✅ COMPLETE

- ✅ Backup preparation (DuckDB + LanceDB)
- ✅ Restic backup to local repository
- ✅ Restic restore to isolated directory
- ✅ Database validation (checksums, counts, dimensions)
- ✅ Cleanup and verification
- ✅ All tests passed (Oct 13, 2026)

### AWS Testing ⏳ PENDING (after Terraform apply)

- ⏳ S3 bucket backup
- ⏳ IAM permission validation
- ⏳ Automated daily backups
- ⏳ Cross-AZ restore test
- ⏳ Password recovery from Parameter Store

### Disaster Recovery Testing ⏳ DEFERRED (Phase 14)

- ⏳ New EC2 instance provisioning
- ⏳ k3s cluster recreation
- ⏳ Application redeployment
- ⏳ End-to-end recovery (RTO measurement)

---

## SCOPE BOUNDARIES

| Component | Backed Up | Recoverable | Recovery Method |
|-----------|-----------|-------------|-----------------|
| DuckDB database | ✅ Yes | ✅ Yes | Restic restore |
| LanceDB vectors | ✅ Yes | ✅ Yes | Restic restore |
| Backup metadata | ✅ Yes | ✅ Yes | Restic restore |
| Application code | ❌ No | ✅ Yes | Git clone |
| Kubernetes manifests | ❌ No | ✅ Yes | Git clone |
| k3s cluster state | ❌ No | ⚠️ Partial | Rebuild via Phase 14 |
| EC2 instance | ❌ No | ⚠️ Partial | Terraform apply |
| Monitoring data | ❌ No | ❌ No | Recreate from scratch |
| System configuration | ❌ No | ⚠️ Partial | Terraform + cloud-init |
| SSH gateway | ❌ No | ❌ No | Separate backup (Phase 11D) |

**Legend**:
- ✅ Yes: Fully supported
- ⚠️ Partial: Requires manual intervention or additional phases
- ❌ No: Out of scope

---

## COST OPTIMIZATION TRADE-OFFS

**What we sacrificed for 99% cost reduction**:
- ❌ AWS Backup managed service ($7-10/month)
- ❌ EBS snapshot automation (deferred to Phase 14)
- ❌ Full instance backup (deferred to Phase 14)
- ❌ Point-in-time recovery (limited to daily snapshots)
- ❌ Multi-region replication

**What we gained**:
- ✅ 99% cost reduction ($0.05/month vs $7-10/month)
- ✅ Client-side encryption (AES-256)
- ✅ Deduplication & compression (68% storage savings)
- ✅ Incremental backups (only changed data)
- ✅ Open-source tooling (vendor independence)
- ✅ Flexible retention policies

---

## FUTURE ENHANCEMENTS (Out of Current Scope)

### Phase 14: Full Disaster Recovery
- EC2 instance provisioning automation
- k3s cluster recreation scripts
- Application redeployment automation
- Automated DR testing
- RTO measurement and optimization

### Phase 11D: Gateway Backup
- Hetzner SSH gateway backup
- Separate S3 bucket or subdirectory
- Gateway configuration recovery

### Optional: EBS Snapshots
- Automated EBS root volume snapshots
- Cost: ~$0.05/GB-month (estimate: $1-2/month for 20 GB volume)
- Use case: Faster full instance recovery

### Optional: Multi-Region Replication
- S3 cross-region replication to us-east-1
- Cost: ~$5-10/month additional
- Use case: Region-level disaster recovery

---

## SUMMARY

**Phase 11C Provides**:
- ✅ **Application database backup** (DuckDB + LanceDB)
- ✅ **Strict validation** (vector counts, dimensions, checksums)
- ✅ **Encrypted storage** (AES-256, client-side)
- ✅ **Automated daily backups** (systemd timer)
- ✅ **Cost-optimized** ($0.05/month vs $7-10/month)
- ✅ **Tested locally** (all tests passed)

**Phase 11C Does NOT Provide**:
- ❌ Full EC2 instance backup
- ❌ k3s cluster backup
- ❌ Monitoring data backup
- ❌ Automated disaster recovery (Phase 14)
- ❌ Multi-region replication

**Use Phase 11C for**:
- Database corruption recovery
- Accidental data deletion recovery
- Data integrity verification
- Cost-effective daily backups

**Do NOT rely on Phase 11C for**:
- Complete infrastructure disaster recovery
- Sub-minute RPO requirements
- Multi-region failover
- Automated full instance recovery

**Next Steps**:
1. Terraform apply (Phase 12D) — provision S3 bucket and IAM
2. First AWS backup test
3. Verify automated daily backups
4. Plan Phase 14 (full DR automation)

---

**Document Version**: 1.0  
**Last Updated**: October 13, 2026  
**Maintained By**: Phase 11C Implementation
