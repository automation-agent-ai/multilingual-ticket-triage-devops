# GitHub Actions Deployment Role - SSM-based CI/CD

# Trust policy for GitHub OIDC
data "aws_iam_policy_document" "github_actions_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github_actions.arn]
    }

    actions = ["sts:AssumeRoleWithWebIdentity"]

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Environment-based access with GitHub immutable OIDC subjects (owner/repo numeric IDs).
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = var.github_oidc_environment_subjects
    }
  }
}

# Permissions policy for SSM deployment
data "aws_iam_policy_document" "github_actions_permissions" {
  # SSM Run Command
  statement {
    sid    = "SSMRunCommand"
    effect = "Allow"

    actions = [
      "ssm:SendCommand"
    ]

    resources = [
      "arn:aws:ssm:${var.aws_region}::document/AWS-RunShellScript",
      "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/${var.ec2_instance_id}"
    ]
  }

  # SSM Get Command Results
  statement {
    sid    = "SSMGetCommandResults"
    effect = "Allow"

    actions = [
      "ssm:GetCommandInvocation"
    ]

    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }

  # SSM Describe Instances
  statement {
    sid    = "SSMDescribeInstance"
    effect = "Allow"

    actions = [
      "ssm:DescribeInstanceInformation"
    ]

    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }
}

# IAM Role for GitHub Actions
resource "aws_iam_role" "github_actions_deployer" {
  name                 = "github-actions-aws-deployer"
  assume_role_policy   = data.aws_iam_policy_document.github_actions_assume_role.json
  description          = "GitHub Actions deployment role for AWS k3s CI/CD via SSM"
  max_session_duration = 3600 # 1 hour

  tags = merge(
    var.common_tags,
    {
      Name       = "github-actions-aws-deployer"
      Purpose    = "CICD"
      Repository = var.github_repository
    }
  )
}

# Attach permissions policy
resource "aws_iam_role_policy" "github_actions_ssm" {
  name   = "SSMDeploymentPolicy"
  role   = aws_iam_role.github_actions_deployer.id
  policy = data.aws_iam_policy_document.github_actions_permissions.json
}
