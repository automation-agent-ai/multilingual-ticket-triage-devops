# IAM Policy Requirements for AWS Backup Integration

**Instance**: i-07bc3aaf0d692974d  
**Current Role**: liora-triage-bedrock-role  
**Status**: Requires additional permissions for backup operations  

---

## Current Limitations

The existing IAM role `liora-triage-bedrock-role` does not have permissions for:
- EBS volume snapshots
- S3 bucket operations
- AWS Backup service
- EC2 volume management

**Impact**: Backups are currently LOCAL ONLY (stored on /backup/local/)

---

## Required IAM Policy Addition

### Option 1: Managed Policy (Recommended for Quick Setup)

Attach these AWS managed policies to `liora-triage-bedrock-role`:

```json
{
  "ManagedPolicies": [
    "arn:aws:iam::aws:policy/AWSBackupServiceRolePolicyForBackup",
    "arn:aws:iam::aws:policy/AWSBackupServiceRolePolicyForRestores"
  ]
}
```

### Option 2: Custom Least-Privilege Policy (Recommended for Production)

Create and attach this custom policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EBSSnapshotPermissions",
      "Effect": "Allow",
      "Action": [
        "ec2:CreateSnapshot",
        "ec2:CreateSnapshots",
        "ec2:DeleteSnapshot",
        "ec2:DescribeVolumes",
        "ec2:DescribeSnapshots",
        "ec2:DescribeInstances",
        "ec2:CreateTags"
      ],
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "ec2:ResourceTag/Project": "liora-triage"
        }
      }
    },
    {
      "Sid": "S3BackupPermissions",
      "Effect": "Allow",
      "Action": [
        "s3:CreateBucket",
        "s3:ListBucket",
        "s3:GetBucketLocation",
        "s3:GetBucketVersioning",
        "s3:PutBucketVersioning",
        "s3:PutBucketEncryption",
        "s3:PutBucketPublicAccessBlock"
      ],
      "Resource": "arn:aws:s3:::liora-triage-backups-*"
    },
    {
      "Sid": "S3ObjectPermissions",
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:DeleteObject",
        "s3:PutObjectAcl"
      ],
      "Resource": "arn:aws:s3:::liora-triage-backups-*/*"
    },
    {
      "Sid": "AWSBackupService",
      "Effect": "Allow",
      "Action": [
        "backup:CreateBackupPlan",
        "backup:CreateBackupSelection",
        "backup:CreateBackupVault",
        "backup:DeleteBackupPlan",
        "backup:DeleteBackupSelection",
        "backup:DeleteBackupVault",
        "backup:DescribeBackupJob",
        "backup:DescribeBackupVault",
        "backup:DescribeRestoreJob",
        "backup:GetBackupPlan",
        "backup:GetBackupSelection",
        "backup:GetBackupVaultAccessPolicy",
        "backup:ListBackupJobs",
        "backup:ListBackupPlans",
        "backup:ListBackupSelections",
        "backup:ListBackupVaults",
        "backup:ListRecoveryPointsByBackupVault",
        "backup:ListRestoreJobs",
        "backup:ListTags",
        "backup:PutBackupVaultAccessPolicy",
        "backup:StartBackupJob",
        "backup:StartRestoreJob",
        "backup:TagResource",
        "backup:UntagResource"
      ],
      "Resource": "*"
    },
    {
      "Sid": "KMSEncryptionPermissions",
      "Effect": "Allow",
      "Action": [
        "kms:CreateGrant",
        "kms:DescribeKey",
        "kms:GenerateDataKey"
      ],
      "Resource": "*",
      "Condition": {
        "StringLike": {
          "kms:ViaService": [
            "ec2.eu-west-1.amazonaws.com",
            "s3.eu-west-1.amazonaws.com"
          ]
        }
      }
    },
    {
      "Sid": "CloudWatchLogsPermissions",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "arn:aws:logs:eu-west-1:523231704152:log-group:/aws/backup/*"
    }
  ]
}
```

**Policy Name**: `liora-triage-backup-policy`

---

## Trust Relationship (No Changes Needed)

The existing trust relationship should already allow EC2 to assume the role:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

---

## Implementation Steps

### Via AWS Console

1. Navigate to IAM → Roles
2. Select role: `liora-triage-bedrock-role`
3. Click "Add permissions" → "Create inline policy"
4. Paste the custom policy JSON above
5. Name it: `liora-triage-backup-policy`
6. Click "Create policy"

### Via AWS CLI (if credentials available elsewhere)

```bash
# Save the policy to a file
cat > /tmp/backup-policy.json << 'EOF'
<paste policy JSON here>
EOF

# Attach the policy
aws iam put-role-policy \
  --role-name liora-triage-bedrock-role \
  --policy-name liora-triage-backup-policy \
  --policy-document file:///tmp/backup-policy.json \
  --region eu-west-1
```

### Via Terraform

```hcl
resource "aws_iam_role_policy" "liora_backup" {
  name   = "liora-triage-backup-policy"
  role   = "liora-triage-bedrock-role"
  policy = file("${path.module}/backup-policy.json")
}
```

---

## Verification

After applying the policy, verify permissions:

```bash
# From EC2 instance
aws sts get-caller-identity

# Test EBS permissions
aws ec2 describe-volumes --region eu-west-1

# Test S3 permissions
aws s3 ls --region eu-west-1

# Test AWS Backup permissions
aws backup list-backup-vaults --region eu-west-1
```

Expected output: Commands should succeed without "AccessDenied" errors.

---

## S3 Bucket Configuration (After IAM Policy Applied)

Create a dedicated backup bucket:

```bash
# Create bucket with encryption and versioning
BUCKET_NAME="liora-triage-backups-${AWS_ACCOUNT_ID}"

aws s3api create-bucket \
  --bucket "${BUCKET_NAME}" \
  --region eu-west-1 \
  --create-bucket-configuration LocationConstraint=eu-west-1

# Enable versioning
aws s3api put-bucket-versioning \
  --bucket "${BUCKET_NAME}" \
  --versioning-configuration Status=Enabled

# Enable encryption
aws s3api put-bucket-encryption \
  --bucket "${BUCKET_NAME}" \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {
        "SSEAlgorithm": "AES256"
      }
    }]
  }'

# Block public access
aws s3api put-public-access-block \
  --bucket "${BUCKET_NAME}" \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

# Enable lifecycle policy for old backups
aws s3api put-bucket-lifecycle-configuration \
  --bucket "${BUCKET_NAME}" \
  --lifecycle-configuration '{
    "Rules": [{
      "Id": "DeleteOldBackups",
      "Status": "Enabled",
      "Expiration": {"Days": 90},
      "NoncurrentVersionExpiration": {"NoncurrentDays": 30}
    }]
  }'
```

---

## AWS Backup Vault Configuration

Create backup vault (after IAM permissions):

```bash
# Create backup vault
aws backup create-backup-vault \
  --backup-vault-name liora-triage-vault \
  --region eu-west-1

# Create backup plan
aws backup create-backup-plan \
  --backup-plan file:///home/ubuntu/backup-scripts/aws-backup-plan.json \
  --region eu-west-1
```

---

## Cost Impact

**Monthly cost estimate after implementation**:

### EBS Snapshots
- Volume size: 60 GB
- Daily snapshots with incremental changes
- Estimated storage: 60 GB initial + ~2 GB/day × 30 days = 120 GB
- Cost: 120 GB × $0.05/GB = **$6.00/month**

### S3 Standard
- Database backups: ~125 MB × 30 days = 3.75 GB
- Cost: 3.75 GB × $0.023/GB = **$0.09/month**

### AWS Backup Service
- Recovery points managed: ~37 per month (7 daily + 4 weekly)
- Cost: Typically $0.10 per recovery point = **$3.70/month**

**Total estimated monthly cost: ~$10/month**

---

## Risk Assessment

### Without IAM Permissions (Current State)
- ✗ Backups stored only on same EBS volume
- ✗ EC2 instance failure = total data loss
- ✗ No off-instance backup retention
- ✗ No automated backup scheduling
- ✗ Manual backup process required

### With IAM Permissions (Proposed)
- ✓ EBS snapshots independent of instance
- ✓ S3 backups in separate service
- ✓ Automated scheduling via AWS Backup
- ✓ Point-in-time recovery capability
- ✓ 7-day daily + 4-week retention
- ✓ Estimated RPO: 24 hours
- ✓ Estimated RTO: 60 minutes

---

## Approval Required

**This document proposes IAM policy changes.**

Before proceeding:
1. Review the custom policy above
2. Approve the policy attachment to `liora-triage-bedrock-role`
3. Approve S3 bucket creation
4. Approve estimated $10/month cost

**Status**: ⏸ Awaiting approval before implementation
