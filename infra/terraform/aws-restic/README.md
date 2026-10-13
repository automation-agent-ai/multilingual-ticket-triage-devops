# AWS Restic Backup Infrastructure

**Purpose:** Minimal S3 storage for Restic backup repository with proper IAM permissions.

**Architecture:**
- Single S3 bucket for Restic repository
- Server-side encryption (AES256)
- Versioning enabled (Restic-safe)
- Public access blocked
- IAM permissions for EC2 instance

**Integration:**
- EC2 instance role has Restic S3 permissions
- Restic repository password managed outside Terraform
- Daily systemd timer (Phase 11C)

---

## Resources Managed

1. **S3 Bucket** — Restic repository storage
2. **S3 Encryption** — AES256 at rest
3. **S3 Versioning** — Enabled (Restic-safe)
4. **S3 Public Access Block** — All blocked
5. **S3 Lifecycle** — Optional old version cleanup

**Cost:** ~$0.50/month (assuming ~20 GB repository)

---

## Restic Requirements

**S3 Operations:**
- Bucket: ListBucket, GetBucketLocation
- Objects: GetObject, PutObject, DeleteObject (for pruning)
- Multipart: AbortMultipartUpload, ListMultipartUploadParts

**Security:**
- Repository password NOT in Terraform state
- Access restricted to specific bucket prefix
- No broad S3 admin rights

---

## Usage

```bash
cd terraform/aws-restic
terraform init
terraform plan
terraform apply
```

**Output:**
```bash
terraform output restic_bucket_name
# liora-triage-restic-523231704152
```

**Restic Configuration:**
```bash
export AWS_REGION=eu-west-1
export RESTIC_REPOSITORY=s3:s3.eu-west-1.amazonaws.com/liora-triage-restic-523231704152/repo
export RESTIC_PASSWORD_FILE=/etc/restic/password

# Initialize repository (one-time)
restic init

# Backup
restic backup /path/to/data

# Verify
restic check
```

---

## Security

- ✅ S3 encryption at rest
- ✅ Public access blocked
- ✅ IAM role-based access (no keys)
- ✅ Repository password separate from Terraform
- ✅ Prefix-restricted permissions
- ⚠️ No Glacier transitions (breaks Restic)

---

## Integration with Phase 11C

Phase 11C Restic implementation uses this S3 bucket:
- Daily systemd timer
- Python database consistency validation
- Restore verification

Terraform provides infrastructure, Phase 11C provides operations.
