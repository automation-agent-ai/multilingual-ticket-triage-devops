# S3 backend with native locking (Terraform 1.8+)
# Phase 12B: Remote state for production use

terraform {
  backend "s3" {
    bucket       = "liora-terraform-state-523231704152"
    key          = "aws-infra/terraform.tfstate"
    region       = "eu-west-1"
    encrypt      = true
    use_lockfile = true # Native S3 locking (no DynamoDB needed)

    # Uses EC2 instance profile (no access/secret keys)
  }
}

# Initial setup (before S3 bucket exists):
# Comment out the backend block above and use local backend:
# terraform {
#   backend "local" {
#     path = "terraform-aws-infra.tfstate"
#   }
# }
#
# After S3 bucket created, uncomment S3 backend and run:
# terraform init -migrate-state
