# EC2 Instance Role Enhancements for SSM and Restic Backups

# Attach AWS managed SSM policy
resource "aws_iam_role_policy_attachment" "ec2_ssm_managed_instance" {
  role       = data.aws_iam_role.capstone_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Restic S3 backup permissions
data "aws_iam_policy_document" "ec2_restic_permissions" {
  # S3 Bucket operations for Restic
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

  # S3 Object operations for Restic repository
  statement {
    sid    = "ResticObjectOperations"
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",         # Required for restic prune
      "s3:AbortMultipartUpload", # Cleanup failed uploads
      "s3:ListMultipartUploadParts"
    ]

    resources = [
      "arn:aws:s3:::liora-triage-restic-*/repo/*"
    ]
  }
}

# Attach Restic permissions
resource "aws_iam_role_policy" "ec2_restic" {
  name   = "ResticBackupPolicy"
  role   = data.aws_iam_role.capstone_role.name
  policy = data.aws_iam_policy_document.ec2_restic_permissions.json
}

# NOTE: Terraform backend access REMOVED per Phase 12C security review
# Application EC2 instance does not need to manage infrastructure state
# State access should be granted to workstation/admin users or CI runners only

# NOTE: AWS Backup vault/EBS snapshot permissions removed per Phase 12D
# Using Restic with S3 instead of AWS Backup service
