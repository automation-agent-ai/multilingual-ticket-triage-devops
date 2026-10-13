# S3 backend with native locking (Terraform 1.8+)
terraform {
  backend "s3" {
    bucket       = "liora-terraform-state-523231704152"
    key          = "aws-restic/terraform.tfstate"
    region       = "eu-west-1"
    encrypt      = true
    use_lockfile = true
  }
}
