# PHASE 11 — TERRAFORM HANDOFF SPECIFICATION

**Date**: October 13, 2026  
**Phase 11 Agent** → **Phase 12B Terraform**  
**Status**: Ready for Terraform Apply

---

## EXECUTIVE SUMMARY

Phase 11 has prepared application backup scripts and systemd automation. Phase 12B Terraform configurations are ready at `/tmp/terraform-phase12b/aws-backup/`.

**This document specifies**:
1. What Terraform must provision
2. What IAM permissions are required
3. What Phase 11 scripts expect as inputs
4. How to coordinate the handoff

---

## TERRAFORM-MANAGED RESOURCES

### Required AWS Resources

Phase 12B Terraform **MUST provision**:

1. **S3 Backup Bucket**
   - Name pattern: `liora-triage-backups-${account_id}`
   - Region: `eu-west-1`
   - Versioning: Enabled
   - Encryption: AES-256 (SSE-S3)
   - Public access: Blocked
   - Lifecycle: 90-day noncurrent version expiration
   - Glacier transition: After 30 days (optional)

2. **AWS Backup Vault**
   - Name: `liora-triage-backup-vault`
   - Region: `eu-west-1`
   - Tags: `Project=liora-triage`, `ManagedBy=terraform`

3. **AWS Backup Plan**
   - Name: `liora-triage-backup-plan`
   - Daily rule: 02:00 UTC, 7-day retention
   - Weekly rule: 02:00 UTC Monday, 30-day retention
   - Target: EBS volumes tagged `Project=liora-triage`

4. **IAM Role: AWS Backup Service**
   - Name: `aws-backup-service-role`
   - Trust: `backup.amazonaws.com`
   - Policies: 
     - `AWSBackupServiceRolePolicyForBackup` (AWS managed)
     - `AWSBackupServiceRolePolicyForRestores` (AWS managed)

5. **IAM Policy: EC2 S3 Backup Access**
   - Name: `liora-ec2-s3-backup-policy`
   - Permissions: S3 PutObject, GetObject, ListBucket (restricted to backup bucket)
   - Attach to: `liora-triage-bedrock-role` (existing instance role)

### Terraform Outputs Required by Phase 11

Phase 11 backup scripts need these outputs from `terraform output`:

```hcl
output "backup_s3_bucket" {
  description = "S3 bucket name for application backups"
  value       = aws_s3_bucket.backup_storage.id
}

output "backup_s3_bucket_arn" {
  description = "S3 bucket ARN"
  value       = aws_s3_bucket.backup_storage.arn
}

output "backup_vault_name" {
  description = "AWS Backup vault name"
  value       = aws_backup_vault.liora_triage.name
}

output "backup_plan_id" {
  description = "AWS Backup plan ID"
  value       = aws_backup_plan.daily_weekly.id
}

output "backup_service_role_arn" {
  description = "AWS Backup service role ARN"
  value       = aws_iam_role.aws_backup_service.arn
}
```

---

## IAM ARCHITECTURE

### Principle: Separation of Duties

**DO NOT** attach broad backup administration permissions to the application EC2 instance role.

### Identity Separation

| Identity | Purpose | Permissions |
|----------|---------|-------------|
| **Terraform Admin** | Provision AWS resources | IAM, S3, Backup, EC2 (admin) |
| **AWS Backup Service Role** | Execute EBS snapshots | AWS managed backup policies |
| **EC2 Instance Role** | Upload application data | S3 PutObject/GetObject (backup bucket only) |
| **Application** | Inference | Bedrock only (unchanged) |

### EC2 Instance Role Policy (Minimal)

Add this inline policy to `liora-triage-bedrock-role`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "S3BackupWrite",
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::liora-triage-backups-${account_id}",
        "arn:aws:s3:::liora-triage-backups-${account_id}/*"
      ]
    },
    {
      "Sid": "S3ListBackupBucket",
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket"
      ],
      "Resource": "arn:aws:s3:::liora-triage-backups-${account_id}"
    }
  ]
}
```

**Terraform Resource**:
```hcl
resource "aws_iam_role_policy" "ec2_backup_upload" {
  name   = "s3-backup-upload"
  role   = "liora-triage-bedrock-role"  # Existing role
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3BackupWrite"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.backup_storage.arn,
          "${aws_s3_bucket.backup_storage.arn}/*"
        ]
      }
    ]
  })
}
```

**NO additional permissions required** for:
- EC2 instance describe
- EBS snapshot creation (handled by AWS Backup service role)
- Backup vault administration (handled by Terraform)

---

## PHASE 11 SCRIPT DEPENDENCIES

### Backup Script Requirements

`/home/ubuntu/phase11-backup-implementation/scripts/backup-to-s3.sh` expects:

**Environment Variables** (optional):
```bash
S3_BUCKET="s3://liora-triage-backups-523231704152"  # Default, can override
REPO_ROOT="/home/ubuntu/workspaces/multilingual-ticket-triage-devops"  # Default
```

**Filesystem**:
- Read access: `/home/ubuntu/workspaces/multilingual-ticket-triage-devops/data/`
- Write access: `/tmp/` (200+ MB free space)
- Log file: `/var/log/liora-backup.log` (writable by ubuntu user)

**AWS CLI**:
- Installed: `/usr/bin/aws` or `/usr/local/bin/aws`
- Credentials: Instance profile (automatic)
- Permissions: S3 PutObject, GetObject, ListBucket

**Python venv**:
- Path: `${REPO_ROOT}/.venv/bin/python`
- Modules: `duckdb`, `lancedb`, `pyarrow`
- Purpose: Integrity verification only (backup works without)

### Script Outputs

**Success (exit 0)**:
- S3 objects uploaded: `s3://<bucket>/databases/<timestamp>/*`
- Files:
  - `tickets.duckdb` (~26 MB)
  - `lancedb/` (~82 MB)
  - `MANIFEST.sha256` (checksums)
  - `backup-metadata.json` (JSON metadata)
- Log entry: `/var/log/liora-backup.log`
- Systemd journal: `journalctl -u liora-backup.service`

**Failure (exit 1-3)**:
- Log to syslog/journal
- Systemd retries once after 5 minutes
- Manual intervention if retry fails

### Restore Script Usage

```bash
# After Terraform applies and first backup completes:
/home/ubuntu/phase11-backup-implementation/scripts/restore-test.sh \
  s3://liora-triage-backups-523231704152/databases/20261013T020000Z/
```

**Verifies**:
1. SHA-256 checksums
2. DuckDB: 5 tables, 4,000+ tickets
3. LanceDB: 3,206 vectors
4. Original data unchanged

---

## COORDINATION SEQUENCE

### Step 1: Terraform Apply (Phase 12B)

```bash
cd /tmp/terraform-phase12b/aws-backup/
terraform init
terraform plan -out=backup.tfplan
# Review plan carefully
terraform apply backup.tfplan
```

**Verify outputs**:
```bash
terraform output backup_s3_bucket
terraform output backup_vault_name
terraform output backup_plan_id
```

### Step 2: Validate IAM Permissions (Phase 11)

```bash
# On EC2 instance, test S3 access
aws s3 ls s3://liora-triage-backups-523231704152/

# Should succeed (empty bucket is OK)
# Should NOT return AccessDenied
```

### Step 3: Install systemd Files (Phase 11)

```bash
# Copy systemd files
sudo cp /home/ubuntu/phase11-backup-implementation/systemd/liora-backup.service \
  /etc/systemd/system/

sudo cp /home/ubuntu/phase11-backup-implementation/systemd/liora-backup.timer \
  /etc/systemd/system/

# Reload systemd
sudo systemctl daemon-reload

# Enable but DO NOT start timer yet
sudo systemctl enable liora-backup.timer
```

### Step 4: Test Backup Manually (Phase 11)

```bash
# Dry run first
/home/ubuntu/phase11-backup-implementation/scripts/backup-to-s3.sh --dry-run

# Real backup
sudo systemctl start liora-backup.service

# Check status
sudo systemctl status liora-backup.service
sudo journalctl -u liora-backup.service -n 50

# Verify S3 upload
aws s3 ls s3://liora-triage-backups-523231704152/databases/ --recursive
```

### Step 5: Execute Restore Test (Phase 11)

```bash
# Get latest backup timestamp
LATEST=$(aws s3 ls s3://liora-triage-backups-523231704152/databases/ | tail -1 | awk '{print $2}')

# Run restore test
/home/ubuntu/phase11-backup-implementation/scripts/restore-test.sh \
  "s3://liora-triage-backups-523231704152/databases/${LATEST}"

# Should exit 0 with ✓ RESTORE TEST PASSED
```

### Step 6: Activate Automated Scheduling (Phase 11)

```bash
# Start timer
sudo systemctl start liora-backup.timer

# Verify next run
sudo systemctl list-timers liora-backup.timer

# Should show: Next run at 02:00 UTC daily
```

### Step 7: Verify EBS Backup (Phase 12B/Phase 11)

```bash
# Wait 24 hours or trigger manual backup
aws backup start-backup-job \
  --backup-vault-name liora-triage-backup-vault \
  --resource-arn arn:aws:ec2:eu-west-1:523231704152:volume/<volume-id> \
  --iam-role-arn $(terraform output -raw backup_service_role_arn) \
  --region eu-west-1

# Monitor progress
aws backup list-backup-jobs \
  --by-backup-vault-name liora-triage-backup-vault \
  --region eu-west-1
```

---

## ESTIMATED COSTS

| Resource | Monthly | Annual | Notes |
|----------|---------|--------|-------|
| S3 Storage (4 GB) | $0.09 | $1.08 | Application data |
| S3 Glacier (after 30d) | $0.004 | $0.05 | Optional transition |
| EBS Snapshots (120 GB avg) | $6.00 | $72.00 | Incremental |
| AWS Backup restore tests | $1.20 | $14.40 | Monthly 60 GB restore |
| **Total** | **$7.29** | **$87.48** | |
| **Budget** | **$10.00** | **$120.00** | With buffer |

**Cost Controls**:
- Lifecycle policy: Delete noncurrent versions after 90 days
- Glacier transition: After 30 days
- Retention limits: 7 daily + 4 weekly (max ~11 EBS snapshots)

---

## VALIDATION CHECKLIST

After Terraform apply, verify:

- [ ] S3 bucket exists and is encrypted
- [ ] S3 public access is blocked
- [ ] S3 versioning is enabled
- [ ] AWS Backup vault exists
- [ ] AWS Backup plan is active
- [ ] AWS Backup selection targets correct EBS volume
- [ ] EC2 instance role has S3 PutObject permission
- [ ] Terraform outputs are readable
- [ ] Manual backup script succeeds
- [ ] S3 upload verified
- [ ] Restore test passes
- [ ] systemd timer scheduled correctly
- [ ] EBS snapshot completes (or is scheduled)

---

## ROLLBACK PLAN

If issues occur:

### Rollback Terraform Resources
```bash
cd /tmp/terraform-phase12b/aws-backup/
terraform destroy -auto-approve
```

### Disable systemd Automation
```bash
sudo systemctl stop liora-backup.timer
sudo systemctl disable liora-backup.timer
```

### Remove IAM Permissions
Terraform destroy will remove the EC2 S3 backup policy automatically.

**Recovery Time**: < 5 minutes  
**Data Loss**: None (no production data modified)

---

## HANDOFF COMPLETE

**Phase 11 Deliverables**:
- ✓ Backup script with integrity verification
- ✓ Restore test script
- ✓ systemd service and timer
- ✓ IAM permission specification
- ✓ Coordination sequence
- ✓ Cost estimate

**Phase 12B Responsibilities**:
- Apply Terraform configuration
- Verify resource creation
- Provide outputs to Phase 11
- Coordinate IAM policy application

**Approval Required Before**:
1. Terraform apply (creates billable resources)
2. systemd timer activation (starts daily backups)
3. EBS backup trigger (creates first snapshot)

---

**Document Status**: READY FOR TERRAFORM APPLY  
**Prepared By**: Phase 11 Agent  
**Date**: October 13, 2026  
**Coordination Required**: Yes (Phase 12B Terraform)
