provider "aws" {
  region = var.aws_region

  # Use EC2 instance profile credentials (no access keys)
  # This is the default behavior when running on EC2

  default_tags {
    tags = var.common_tags
  }
}
