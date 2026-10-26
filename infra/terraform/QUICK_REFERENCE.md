# Phase 12D Quick Reference

**Status:** ✅ EXECUTION-READY  
**Location:** `/home/ubuntu/workspaces/terraform-phase12d/`  
**Cost:** ~$0.50/month

---

## What Changed from Phase 12C

**Removed:**
- ❌ AWS Backup vaults, plans, EBS snapshots ($6.50/month saved)
- ❌ aws-backup/ directory (11 resources removed)
- ❌ aws-monitoring/ directory (deferred)

**Added:**
- ✅ aws-restic/ — Minimal Restic S3 storage (5 resources)
- ✅ Restic IAM permissions (bucket + prefix-restricted)
- ✅ Permanent location (not /tmp or agent store)

**Result:**
- 19 → 13 resources (-6)
- $7.00 → $0.50/month (-93%)
- Simpler, cheaper, Restic-aligned

---

## Two Terraform Roots

```
aws-infra/    (~8 resources, $0/month)
  - GitHub OIDC provider
  - GitHub Actions IAM role (environment-based)
  - EC2 SSM managed-instance policy
  - EC2 Restic S3 permissions

aws-restic/   (~5 resources, ~$0.50/month)
  - S3 bucket (liora-triage-restic-*)
  - Encryption + versioning + lifecycle
  - Public access blocked
```

---

## Validation Results

```bash
✅ aws-infra/   (13 files) → terraform validate PASSED
✅ aws-restic/  ( 8 files) → terraform validate PASSED

Total: 21 Terraform files — 100% passing
```

---

## Restic IAM Permissions

**Bucket operations:**
- s3:ListBucket
- s3:GetBucketLocation
- s3:ListBucketVersions
- s3:ListBucketMultipartUploads

**Object operations (prefix-restricted):**
- s3:GetObject
- s3:PutObject
- s3:DeleteObject (for pruning)
- s3:AbortMultipartUpload

**Security:**
- ✅ Bucket-specific (liora-triage-restic-*)
- ✅ Prefix-restricted (repo/*)
- ✅ No broad S3 admin
- ✅ Restic password NOT in Terraform

---

## GitHub OIDC (Phase 13D Aligned)

**Trust Policy:**
```hcl
condition {
  test     = "StringLike"
  variable = "token.actions.githubusercontent.com:sub"
  values = [
    "repo:...:environment:aws-dev",
    "repo:...:environment:aws-prod"
  ]
}
```

**Status:** ✅ Environment-based (not branch-based)

---

## Execution Order

1. **Create S3 state bucket** (bootstrap)
2. **Apply aws-infra** (OIDC + IAM)
3. **Apply aws-restic** (S3 bucket)
4. **Configure Restic** (Phase 11C integration)
5. **Test GitHub Actions** (Phase 13D)

---

## Required Approvals

- [ ] IAM changes (OIDC + roles + policies)
- [ ] S3 buckets (~$0.50/month)
- [ ] Phase 11C/13D coordination

---

## Key Outputs

```bash
# After apply
terraform output -raw github_actions_role_arn
terraform output -raw restic_bucket_name
terraform output -raw restic_repository_uri
```

---

**Phase 12D:** Minimal, validated, ready for controlled apply.
