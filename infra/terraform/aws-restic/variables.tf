variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "eu-west-1"
}

variable "restic_bucket_suffix" {
  description = "Suffix for Restic S3 bucket (will be prefixed with account ID)"
  type        = string
  default     = "liora-triage-restic"
}

variable "enable_versioning" {
  description = "Enable S3 versioning (Restic-safe, helps with accidental deletions)"
  type        = bool
  default     = true
}

variable "lifecycle_noncurrent_days" {
  description = "Days to keep noncurrent versions (0 = keep forever)"
  type        = number
  default     = 30
}

variable "common_tags" {
  description = "Common tags"
  type        = map(string)
  default = {
    Project     = "liora-triage"
    Environment = "production"
    ManagedBy   = "terraform"
    Backup      = "restic"
  }
}
