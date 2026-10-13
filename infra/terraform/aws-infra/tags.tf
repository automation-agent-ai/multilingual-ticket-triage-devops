# Common tags for all resources
locals {
  common_tags = merge(
    var.common_tags,
    {
      Terraform   = "true"
      Environment = "production"
      Project     = "liora-triage"
    }
  )
}
