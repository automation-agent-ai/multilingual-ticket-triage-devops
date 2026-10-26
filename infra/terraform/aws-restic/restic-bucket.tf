# Get AWS account information
data "aws_caller_identity" "current" {}

# S3 bucket for Restic repository
resource "aws_s3_bucket" "restic" {
  bucket = "${var.restic_bucket_suffix}-${data.aws_caller_identity.current.account_id}"

  tags = merge(
    var.common_tags,
    {
      Name    = "liora-triage-restic"
      Purpose = "ResticBackupRepository"
    }
  )
}

# Enable versioning (Restic-safe)
resource "aws_s3_bucket_versioning" "restic" {
  bucket = aws_s3_bucket.restic.id

  versioning_configuration {
    status = var.enable_versioning ? "Enabled" : "Suspended"
  }
}

# Enable server-side encryption
resource "aws_s3_bucket_server_side_encryption_configuration" "restic" {
  bucket = aws_s3_bucket.restic.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = false
  }
}

# Block all public access
resource "aws_s3_bucket_public_access_block" "restic" {
  bucket = aws_s3_bucket.restic.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Lifecycle policy for old versions (optional cleanup)
resource "aws_s3_bucket_lifecycle_configuration" "restic" {
  count = var.lifecycle_noncurrent_days > 0 ? 1 : 0

  bucket = aws_s3_bucket.restic.id

  rule {
    id     = "cleanup-old-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.lifecycle_noncurrent_days
    }

    # Clean up expired delete markers
    expiration {
      expired_object_delete_marker = true
    }
  }
}
