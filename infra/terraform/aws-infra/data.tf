# Data sources for existing AWS resources
# These are READ-ONLY queries; no resources are created or modified

# EC2 instance hosting the k3s cluster
data "aws_instance" "capstone_ec2" {
  instance_id = var.ec2_instance_id
}

# VPC containing the EC2 instance
data "aws_vpc" "capstone_vpc" {
  id = var.vpc_id
}

# Subnet where EC2 instance is deployed
data "aws_subnet" "capstone_subnet" {
  id = var.subnet_id
}

# IAM role attached to EC2 instance
data "aws_iam_role" "capstone_role" {
  name = var.iam_role_name
}

# Get AWS account ID (for constructing ARNs)
data "aws_caller_identity" "current" {}

# Get availability zone from subnet
data "aws_availability_zone" "current" {
  name = data.aws_subnet.capstone_subnet.availability_zone
}
