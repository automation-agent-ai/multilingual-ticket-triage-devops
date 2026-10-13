# AWS Infrastructure Outputs

output "aws_account_id" {
  description = "AWS account ID"
  value       = data.aws_caller_identity.current.account_id
}

output "aws_region" {
  description = "AWS region"
  value       = var.aws_region
}

output "availability_zone" {
  description = "Availability zone"
  value       = data.aws_availability_zone.current.name
}

# EC2 Instance Outputs
output "ec2_instance_id" {
  description = "EC2 instance ID"
  value       = data.aws_instance.capstone_ec2.id
}

output "ec2_instance_type" {
  description = "EC2 instance type"
  value       = data.aws_instance.capstone_ec2.instance_type
}

output "ec2_ami_id" {
  description = "AMI ID used by EC2 instance"
  value       = data.aws_instance.capstone_ec2.ami
}

output "ec2_public_ip" {
  description = "EC2 public IP address"
  value       = data.aws_instance.capstone_ec2.public_ip
}

output "ec2_private_ip" {
  description = "EC2 private IP address"
  value       = data.aws_instance.capstone_ec2.private_ip
}

output "ec2_public_dns" {
  description = "EC2 public DNS name"
  value       = data.aws_instance.capstone_ec2.public_dns
}

output "ec2_state" {
  description = "EC2 instance state"
  value       = data.aws_instance.capstone_ec2.instance_state
}

output "ec2_root_device_type" {
  description = "Root device type (ebs/instance-store)"
  value       = try(tolist(data.aws_instance.capstone_ec2.root_block_device)[0].volume_type, "unknown")
}

output "ec2_root_volume_size" {
  description = "Root EBS volume size (GB)"
  value       = try(tolist(data.aws_instance.capstone_ec2.root_block_device)[0].volume_size, 0)
}

# IAM Outputs
output "iam_role_name" {
  description = "IAM role name"
  value       = data.aws_iam_role.capstone_role.name
}

output "iam_role_arn" {
  description = "IAM role ARN"
  value       = data.aws_iam_role.capstone_role.arn
}

output "iam_instance_profile_arn" {
  description = "IAM instance profile ARN"
  value       = data.aws_instance.capstone_ec2.iam_instance_profile
}

# Network Outputs
output "vpc_id" {
  description = "VPC ID"
  value       = data.aws_vpc.capstone_vpc.id
}

output "vpc_cidr_block" {
  description = "VPC CIDR block"
  value       = data.aws_vpc.capstone_vpc.cidr_block
}

output "subnet_id" {
  description = "Subnet ID"
  value       = data.aws_subnet.capstone_subnet.id
}

output "subnet_cidr_block" {
  description = "Subnet CIDR block"
  value       = data.aws_subnet.capstone_subnet.cidr_block
}

output "security_group_ids" {
  description = "Security group IDs attached to EC2 instance"
  value       = data.aws_instance.capstone_ec2.vpc_security_group_ids
}

# Tags Output
output "ec2_tags" {
  description = "Tags applied to EC2 instance"
  value       = data.aws_instance.capstone_ec2.tags
}

# GitHub Actions CI/CD Outputs
output "github_actions_role_arn" {
  description = "GitHub Actions deployment role ARN"
  value       = aws_iam_role.github_actions_deployer.arn
}

output "oidc_provider_arn" {
  description = "GitHub OIDC provider ARN"
  value       = aws_iam_openid_connect_provider.github_actions.arn
}
