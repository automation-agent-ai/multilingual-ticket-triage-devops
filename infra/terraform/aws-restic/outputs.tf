output "restic_bucket_name" {
  description = "S3 bucket name for Restic repository"
  value       = aws_s3_bucket.restic.id
}

output "restic_bucket_arn" {
  description = "S3 bucket ARN for Restic repository"
  value       = aws_s3_bucket.restic.arn
}

output "restic_bucket_region" {
  description = "S3 bucket region"
  value       = aws_s3_bucket.restic.region
}

output "restic_repository_uri" {
  description = "Restic S3 repository URI"
  value       = "s3:s3.${var.aws_region}.amazonaws.com/${aws_s3_bucket.restic.id}/repo"
}
