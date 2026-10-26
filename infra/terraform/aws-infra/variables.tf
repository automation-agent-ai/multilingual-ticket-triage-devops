variable "aws_region" {
  description = "AWS region for resources"
  type        = string
  default     = "eu-west-1"
}

variable "ec2_instance_id" {
  description = "EC2 instance ID (existing resource)"
  type        = string

  validation {
    condition     = can(regex("^i-[0-9a-f]{17}$", var.ec2_instance_id))
    error_message = "EC2 instance ID must be in format i-xxxxxxxxxxxxxxxxx"
  }
}

variable "vpc_id" {
  description = "VPC ID (existing resource)"
  type        = string

  validation {
    condition     = can(regex("^vpc-[0-9a-f]{17}$", var.vpc_id))
    error_message = "VPC ID must be in format vpc-xxxxxxxxxxxxxxxxx"
  }
}

variable "subnet_id" {
  description = "Subnet ID (existing resource)"
  type        = string

  validation {
    condition     = can(regex("^subnet-[0-9a-f]{17}$", var.subnet_id))
    error_message = "Subnet ID must be in format subnet-xxxxxxxxxxxxxxxxx"
  }
}

variable "iam_role_name" {
  description = "IAM role name (existing resource)"
  type        = string
  default     = "liora-triage-bedrock-role"
}

variable "github_repository" {
  description = "GitHub repository slug (tags and documentation; OIDC trust uses immutable sub claims)"
  type        = string
  default     = "automation-agent-ai/multilingual-ticket-triage-devops"
}

# GitHub Actions OIDC subject claims (immutable owner/repo IDs).
# Must match GET .../actions/oidc/customization/sub and live IAM trust policy.
variable "github_oidc_environment_subjects" {
  description = "Exact token.actions.githubusercontent.com:sub values for aws-dev and aws-prod"
  type        = list(string)
  default = [
    "repo:automation-agent-ai@212631714/multilingual-ticket-triage-devops@1413133651:environment:aws-dev",
    "repo:automation-agent-ai@212631714/multilingual-ticket-triage-devops@1413133651:environment:aws-prod",
  ]

  validation {
    condition     = length(var.github_oidc_environment_subjects) == 2
    error_message = "Exactly two environment OIDC subject claims are required (aws-dev and aws-prod)."
  }
}

variable "common_tags" {
  description = "Common tags applied to all resources"
  type        = map(string)
  default = {
    Project     = "liora-triage"
    Environment = "production"
    ManagedBy   = "terraform"
    Repository  = "multilingual-ticket-triage-devops"
    Region      = "eu-west-1"
  }
}
