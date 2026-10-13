# PHASE 11C — TERRAFORM HANDOFF FOR RESTIC BACKUP

**Date**: October 13, 2026  
**Phase 11C (Restic)** → **Phase 12C Terraform**  
**Status**: Implementation Complete, Ready for AWS Provisioning

---

## EXECUTIVE SUMMARY

Phase 11C has implemented a **Restic-based encrypted backup solution** with:
- ✅ Consistent database backup preparation (Python helpers)
- ✅ Encrypted, incremental, deduplicated backups (Restic)
- ✅ SHA-256 integrity verification
- ✅ Automated daily scheduling (systemd)
- ✅ Isolated restore testing validated
- ✅ Local testing complete (all passed)

**Terraform must provision**: S3 bucket + minimal IAM permissions

**Cost**: ~$0.05-0.10/month (vs $7-10/month with AWS Backup)

---

## TERRAFORM REQUIREMENTS

### 1. S3 Bucket for Restic Repository

**Resource**: `aws_s3_bucket.restic_backup`

```hcl
resource "aws_s3_bucket" "restic_backup" {
  bucket = "liora-triage-backups-${data.aws_caller_identity.current.account_id}"
  
  tags = {
    Name        = "liora-triage-backups"
    Purpose     = "ResticBackupRepository"
    Project     = "liora-triage"
    ManagedBy   = "terraform"
    Phase       = "phase11c"
  }
}
```

**Configuration**:
- Name: `liora-triage-backups-523231704152`
- Region: `eu-west-1`
- Versioning: **Optional** (Restic handles versions internally)
- Encryption: **AES-256 (SSE-S3)** or KMS
- Public access: **Blocked**
- Lifecycle: **NO Glacier transitions** (Restic repository must stay accessible)

### 2. S3 Bucket Encryption

```hcl
resource "aws_s3_bucket_server_side_encryption_configuration" "restic_backup" {
  bucket = aws_s3_bucket.restic_backup.id
  
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"  # or "aws:kms" with CMK
    }
  }
}
```

### 3. S3 Public Access Block

```hcl
resource "aws_s3_bucket_public_access_block" "restic_backup" {
  bucket = aws_s3_bucket.restic_backup.id
  
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
```

### 4. IAM Policy for EC2 Instance Role

**CRITICAL**: Restic requires these **specific S3 operations**

```hcl
resource "aws_iam_role_policy" "ec2_restic_backup" {
  name = "restic-backup-s3-access"
  role = "liora-triage-bedrock-role"  # Existing instance role
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ResticS3BucketAccess"
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = aws_s3_bucket.restic_backup.arn
      },
      {
        Sid    = "ResticS3ObjectAccess"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject"
        ]
        Resource = "${aws_s3_bucket.restic_backup.arn}/*"
      }
    ]
  })
}
```

**Why DeleteObject?**: Restic's `forget --prune` operation removes old snapshots

**Why NO**: CreateBucket, PutBucketPolicy, PutLifecycleConfiguration  
**Reason**: Terraform creates bucket, EC2 only reads/writes objects

### 5. Terraform Outputs

```hcl
output "restic_s3_bucket" {
  description = "S3 bucket name for Restic repository"
  value       = aws_s3_bucket.restic_backup.id
}

output "restic_s3_bucket_arn" {
  description = "S3 bucket ARN"
  value       = aws_s3_bucket.restic_backup.arn
}

output "restic_repository_url" {
  description = "Restic repository URL (for RESTIC_REPOSITORY env var)"
  value       = "s3:s3.amazonaws.com/${aws_s3_bucket.restic_backup.id}"
}
```

---

## RESTIC REPOSITORY URL FORMAT

After Terraform provisions the bucket, the Restic repository URL is:

```
s3:s3.amazonaws.com/liora-triage-backups-523231704152
```

Or with region:

```
s3:s3.eu-west-1.amazonaws.com/liora-triage-backups-523231704152
```

**Set in**: systemd service unit `Environment` directive

---

## RESTIC PASSWORD MANAGEMENT

### Initial Setup (One-Time)

**CRITICAL**: The password must NEVER be echoed to terminal, logged, or committed to Git.

```bash
# Create password file directory
sudo mkdir -p /etc/liora-backup

# Generate secure password (32 characters) - NO ECHO
openssl rand -base64 32 | sudo tee /etc/liora-backup/restic-password > /dev/null

# Restrict permissions (readable only by ubuntu)
sudo chmod 600 /etc/liora-backup/restic-password
sudo chown ubuntu:ubuntu /etc/liora-backup/restic-password

# Verify permissions (should show: -rw------- 1 ubuntu ubuntu 45 ...)
sudo ls -l /etc/liora-backup/restic-password

# Verify password file is not empty (should show 45 bytes)
stat -f %z /etc/liora-backup/restic-password 2>/dev/null || stat -c %s /etc/liora-backup/restic-password
```

**DO NOT**:
- ❌ `cat` the password file to console
- ❌ Echo password in terminal history
- ❌ Store password in shell variables (except RESTIC_PASSWORD_FILE)
- ❌ Commit password to Git
- ❌ Include password in Terraform state
- ❌ Log password in systemd logs or backup scripts

**systemd Service Access**:
- Service runs as user `ubuntu` (via `User=ubuntu` in unit file)
- Password file owned by `ubuntu:ubuntu` with `600` permissions
- Environment variable `RESTIC_PASSWORD_FILE` points to file path
- Restic reads password directly from file (never in environment)

### Password Storage & Recovery Documentation

**CRITICAL**: The Restic password MUST be stored securely **outside the instance**  
**WITHOUT the password, all backups are PERMANENTLY UNRECOVERABLE**

**Recommended: AWS Systems Manager Parameter Store** (encrypted, free, IAM-controlled)

```bash
# Store password in Parameter Store (one-time, requires IAM permission)
sudo aws ssm put-parameter \
  --name "/liora-triage/backup/restic-password" \
  --value "file:///etc/liora-backup/restic-password" \
  --type "SecureString" \
  --region eu-west-1 \
  --description "Restic backup encryption password for liora-triage (Phase 11C)"

# Verify storage (should show creation timestamp)
aws ssm describe-parameters \
  --filters "Key=Name,Values=/liora-triage/backup/restic-password"

# Retrieve during recovery (to new instance)
aws ssm get-parameter \
  --name "/liora-triage/backup/restic-password" \
  --with-decryption \
  --query "Parameter.Value" \
  --output text | sudo tee /etc/liora-backup/restic-password > /dev/null

sudo chmod 600 /etc/liora-backup/restic-password
sudo chown ubuntu:ubuntu /etc/liora-backup/restic-password
```

**Alternative: Secure password manager** (1Password, LastPass, KeePass)
- Title: "Liora Triage Restic Backup Password"
- Category: Production Infrastructure
- Tags: liora-triage, backup, restic, phase11c, disaster-recovery
- Store as secure note or password entry
- Document recovery procedure in team runbook

**Recovery Test** (do NOT run on production instance):
```bash
# Simulate instance loss: delete password file
sudo rm /etc/liora-backup/restic-password

# Recover from Parameter Store
aws ssm get-parameter --name "/liora-triage/backup/restic-password" \
  --with-decryption --query "Parameter.Value" --output text | \
  sudo tee /etc/liora-backup/restic-password > /dev/null

sudo chmod 600 /etc/liora-backup/restic-password
sudo chown ubuntu:ubuntu /etc/liora-backup/restic-password

# Verify repository access
export RESTIC_PASSWORD_FILE="/etc/liora-backup/restic-password"
export RESTIC_REPOSITORY="s3:s3.amazonaws.com/liora-triage-backups-523231704152"
restic snapshots  # Should list snapshots without error
```

**Document in**: `docs/AWS_BACKUP_RECOVERY.md` (Phase 14)

---

## IMPLEMENTATION SEQUENCE

### Phase 1: Terraform Apply (Phase 12C)

```bash
cd /path/to/terraform/phase12c-restic-backup/
terraform init
terraform plan -out=restic-backup.tfplan
terraform apply restic-backup.tfplan
```

**Outputs to capture**:
```bash
terraform output restic_s3_bucket
terraform output restic_repository_url
```

### Phase 2: Initialize Restic Repository (Phase 11C)

```bash
# Set environment variables
export RESTIC_REPOSITORY="$(cd /path/to/terraform && terraform output -raw restic_repository_url)"
export RESTIC_PASSWORD_FILE="/etc/liora-backup/restic-password"

# Initialize repository (one-time)
/home/ubuntu/phase11-backup-implementation/scripts/restic-init.sh
```

**Expected output**:
```
[...] Initializing new Restic repository...
created restic repository ... at s3:...
✓ Repository initialized successfully
```

### Phase 3: Update systemd Service (Phase 11C)

Edit `/home/ubuntu/phase11-backup-implementation/systemd/liora-restic-backup.service`:

```ini
# Add actual repository URL from Terraform output
Environment="RESTIC_REPOSITORY=s3:s3.amazonaws.com/liora-triage-backups-523231704152"
```

### Phase 4: First Manual Backup Test (Phase 11C)

```bash
# Set environment
export RESTIC_REPOSITORY="s3:s3.amazonaws.com/liora-triage-backups-523231704152"
export RESTIC_PASSWORD_FILE="/etc/liora-backup/restic-password"

# Run backup manually
/home/ubuntu/phase11-backup-implementation/scripts/restic-backup.sh
```

**Expected**:
- Data preparation: ~2 seconds
- Restic backup: ~30-60 seconds
- Total: ~1-2 minutes
- Compressed size: ~35 MB (from 107 MB raw)
- Exit code: 0

### Phase 5: Verify Backup (Phase 11C)

```bash
# List snapshots
restic snapshots

# Check repository
restic check --read-data-subset=5%
```

### Phase 6: Isolated Restore Test (Phase 11C)

```bash
/home/ubuntu/phase11-backup-implementation/scripts/restic-restore-test.sh
```

**Success criteria**:
- ✓ Snapshot restored
- ✓ SHA-256 checksums verified
- ✓ DuckDB: 4000 tickets
- ✓ LanceDB: 3206 vectors
- ✓ Exit code: 0

### Phase 7: Install systemd Automation (Phase 11C)

```bash
# Install service and timer
sudo cp /home/ubuntu/phase11-backup-implementation/systemd/liora-restic-backup.* \
  /etc/systemd/system/

# Reload systemd
sudo systemctl daemon-reload

# Enable timer (start on boot)
sudo systemctl enable liora-restic-backup.timer

# Start timer now
sudo systemctl start liora-restic-backup.timer

# Verify schedule
sudo systemctl list-timers liora-restic-backup.timer
```

**Expected**: Next run at 02:00 UTC

---

## LOCAL TESTING RESULTS

### Test Environment
- Repository: Local filesystem (`/tmp/restic-test-repo`)
- Password: Test password (600 permissions)
- Python: venv from main repository

### Test 1: Data Preparation ✅ PASSED

```
[2026-10-13T00:13:17Z] === Backup Preparation Complete ===
Size: 106.63 MB
DuckDB: 4000 tickets
LanceDB: 3206 vectors
✓ Consistency validated
✓ Ready for Restic backup
```

**Validation**:
- ✓ No WAL files detected
- ✓ File copy consistency checks passed
- ✓ All 5 DuckDB tables present
- ✓ SHA-256 manifest created (21 files)

### Test 2: Restic Backup ✅ PASSED

```
Files:    22 new, 0 changed, 0 unmodified
Dirs:     10 new, 0 changed, 0 unmodified
Added to repository: 56.618 MiB (34.089 MiB stored)
snapshot 11a4076e saved
```

**Performance**:
- Backup time: <1 second
- Compression ratio: 68% (34 MB stored from 107 MB raw)
- Deduplication: Working (incremental ready)

### Test 3: Restic Restore ✅ PASSED

```
Restored 32 files/dirs (106.633 MiB) in 0:00
```

### Test 4: Database Validation ✅ PASSED

```
[2026-10-13T00:13:35Z] === Restore Validation Complete ===
✓ All validations passed
✓ Checksums verified (21 files)
✓ DuckDB validated (5 tables, 4000 tickets)
✓ LanceDB validated (3206 vectors, 13 schema fields)
✓ Restore is consistent and complete
```

**All tests passed** — Ready for AWS S3 deployment

---

## ESTIMATED COSTS

### S3 Storage (Restic Repository)

**Initial backup**: ~35 MB stored (compressed)  
**Daily incremental**: ~1-5 MB/day (only changed data)  
**7-day retention**: ~35 + (5 × 7) = ~70 MB average

**S3 Standard pricing** (eu-west-1):
- Storage: 0.07 GB × $0.023/GB-month = **$0.002/month**
- PUT requests: 30/month × $0.005/1000 = **$0.0002/month**
- GET requests: 10/month × $0.0004/1000 = **negligible**

**Total S3 cost**: **$0.05-0.10/month** (including buffer)

**Annual**: ~$0.60-1.20/year

### Cost Comparison

| Solution | Monthly | Annual | Notes |
|----------|---------|--------|-------|
| Phase 11A (AWS Backup) | $7-10 | $84-120 | EBS snapshots + S3 |
| Phase 11C (Restic) | $0.05-0.10 | $0.60-1.20 | S3 only |
| **Savings** | **$6.90-9.95** | **$82.80-119.40** | **~99% reduction** |

**Why so cheap?**:
- Restic's deduplication & compression (68% reduction)
- No AWS Backup service charges
- No EBS snapshot costs (deferred)
- Incremental backups only store deltas

---

## MONITORING & HEALTH CHECKS

### Check Backup Health

```bash
export RESTIC_REPOSITORY="s3:s3.amazonaws.com/liora-triage-backups-523231704152"
export RESTIC_PASSWORD_FILE="/etc/liora-backup/restic-password"

/home/ubuntu/phase11-backup-implementation/scripts/check-backup-health.sh
```

**Exit codes**:
- 0 = Healthy (backup < 48 hours old)
- 1 = Warning (backup 30-48 hours old)
- 2 = Critical (backup > 48 hours or missing)

### View Backup Logs

```bash
# Recent backup logs
sudo journalctl -u liora-restic-backup.service -n 100

# Follow live logs
sudo journalctl -u liora-restic-backup.service -f

# Service status
sudo systemctl status liora-restic-backup.service
```

### Manual Backup Trigger

```bash
# Trigger backup immediately
sudo systemctl start liora-restic-backup.service

# Check result
sudo systemctl status liora-restic-backup.service
```

---

## RECOVERY SCENARIOS

### Scenario 1: Data Restoration (RTO: ~5 minutes)

**What's recovered**:
- ✓ DuckDB database (4000 tickets)
- ✓ LanceDB vectors (3206 embeddings)
- ✓ All data validated with SHA-256 checksums

**Procedure**:
```bash
export RESTIC_REPOSITORY="s3:s3.amazonaws.com/liora-triage-backups-523231704152"
export RESTIC_PASSWORD_FILE="/etc/liora-backup/restic-password"

# Restore to temporary location
restic restore latest --target /tmp/recovery

# Find restored data
find /tmp/recovery -name "tickets.duckdb"

# Copy to production (after validation)
# cp /tmp/recovery/.../tickets.duckdb /path/to/data/
```

### Scenario 2: Complete EC2 Instance Loss (RTO: Phase 14)

**Phase 11C provides**:
- ✓ Application data recovery (DuckDB + LanceDB)
- ✓ Backup verification scripts
- ✓ Recovery procedures documented

**NOT included** (require additional work):
- ❌ EC2 instance provisioning (Terraform)
- ❌ k3s cluster recreation (Phase 14)
- ❌ Kubernetes application redeployment (Phase 14)
- ❌ EBS system restoration (optional enhancement)

**Full DR test**: Phase 14 scope

---

## SECURITY CONSIDERATIONS

### Data at Rest
- ✓ Restic encryption (AES-256 counter mode)
- ✓ S3 server-side encryption (SSE-S3)
- ✓ Password file restricted (600 permissions)

### Data in Transit
- ✓ HTTPS/TLS to S3
- ✓ AWS SDK signature verification

### Access Control
- ✓ IAM instance profile (no long-lived keys)
- ✓ Least-privilege S3 permissions
- ✓ No public bucket access

### Secrets Management
- ✓ Password file outside Git
- ✓ No credentials in logs
- ✓ systemd service hardening (PrivateTmp, ProtectSystem)

---

## TROUBLESHOOTING

### Issue: "repository does not exist"

**Cause**: Repository not initialized  
**Fix**:
```bash
export RESTIC_REPOSITORY="s3:s3.amazonaws.com/..."
export RESTIC_PASSWORD_FILE="/etc/liora-backup/restic-password"
restic init
```

### Issue: "wrong password or no key found"

**Cause**: Incorrect password or corrupted password file  
**Fix**: Restore password from secure backup (see Password Management section)

### Issue: "AccessDenied" from S3

**Cause**: IAM permissions not applied  
**Fix**: Verify Terraform applied IAM policy:
```bash
aws iam list-role-policies --role-name liora-triage-bedrock-role
```

### Issue: "lock already exists"

**Cause**: Previous backup didn't complete cleanly  
**Fix**:
```bash
restic unlock
```

---

## DELIVERABLES

### Scripts Created

```
/home/ubuntu/phase11-backup-implementation/scripts/
├── prepare-backup-data.py       (14 KB) - Database preparation & validation
├── validate-databases.py        (7.7 KB) - Post-restore validation
├── restic-backup.sh             (8.4 KB) - Main backup wrapper
├── restic-restore-test.sh       (7.9 KB) - Isolated restore test
├── restic-init.sh               (2.2 KB) - Repository initialization
└── check-backup-health.sh       (3.3 KB) - Health monitoring
```

### systemd Units

```
/home/ubuntu/phase11-backup-implementation/systemd/
├── liora-restic-backup.service  - Backup service
└── liora-restic-backup.timer    - Daily 02:00 UTC schedule
```

### Documentation

- This document: Terraform handoff specification
- Local testing results: All tests passed
- Cost estimates: ~$0.05-0.10/month
- Recovery procedures: Data & system

---

## VALIDATION CHECKLIST

After Terraform apply:

- [ ] S3 bucket created: `liora-triage-backups-523231704152`
- [ ] Bucket encryption enabled (AES-256)
- [ ] Public access blocked
- [ ] IAM policy attached to EC2 role
- [ ] Restic repository initialized
- [ ] Password file created (600 permissions)
- [ ] Password backed up securely (outside instance)
- [ ] First backup completed
- [ ] Snapshot visible: `restic snapshots`
- [ ] Restore test passed
- [ ] systemd timer enabled
- [ ] Health check passing
- [ ] Logs accessible via journalctl

---

## APPROVAL REQUIRED BEFORE

- [ ] Terraform apply (creates S3 bucket)
- [ ] IAM policy attachment
- [ ] Restic repository initialization
- [ ] systemd timer activation

---

**Document Status**: READY FOR TERRAFORM APPLY  
**Implementation Status**: ✅ COMPLETE & TESTED  
**Cost**: ~$0.05-0.10/month  
**Next Step**: Phase 12C Terraform provisioning
