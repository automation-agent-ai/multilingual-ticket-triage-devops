provider "aws" {
  region = var.aws_region

  # Use EC2 instance profile credentials (no access keys).
  # default_tags intentionally omitted: imported IAM/OIDC were created without provider-wide tags.
}
