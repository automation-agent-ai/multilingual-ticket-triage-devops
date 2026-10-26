# Optional EC2 inline policy for Restic → S3 (ResticBackupPolicy).
# Apply only with the aws-restic stack after the S3 bucket exists.
# Not part of aws-infra imports: live backups use local Restic + Hetzner REST.

variable "ec2_iam_role_name" {
  description = "IAM role attached to the k3s EC2 instance"
  type        = string
  default     = "liora-triage-bedrock-role"
}

data "aws_iam_role" "ec2_backup" {
  name = var.ec2_iam_role_name
}

data "aws_iam_policy_document" "ec2_restic_permissions" {
  statement {
    sid    = "ResticBucketOperations"
    effect = "Allow"

    actions = [
      "s3:ListBucket",
      "s3:GetBucketLocation",
      "s3:ListBucketVersions",
      "s3:ListBucketMultipartUploads"
    ]

    resources = [
      "arn:aws:s3:::liora-triage-restic-*"
    ]
  }

  statement {
    sid    = "ResticObjectOperations"
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts"
    ]

    resources = [
      "arn:aws:s3:::liora-triage-restic-*/repo/*"
    ]
  }
}

resource "aws_iam_role_policy" "ec2_restic" {
  name   = "ResticBackupPolicy"
  role   = data.aws_iam_role.ec2_backup.id
  policy = data.aws_iam_policy_document.ec2_restic_permissions.json
}
