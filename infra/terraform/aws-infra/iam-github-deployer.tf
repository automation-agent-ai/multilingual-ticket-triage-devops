# GitHub Actions Deployment Role - SSM-based CI/CD
# Source aligned to live IAM (CloudShell G11.2 authoritative export).

data "aws_iam_policy_document" "github_actions_assume_role" {
  statement {
    sid    = "GitHubActionsOIDCAssumeRole"
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

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = var.github_oidc_environment_subjects
    }
  }
}

data "aws_iam_policy_document" "github_actions_permissions" {
  statement {
    sid    = "AllowApprovedSSMDocument"
    effect = "Allow"

    actions = [
      "ssm:SendCommand"
    ]

    resources = [
      "arn:aws:ssm:${var.aws_region}::document/AWS-RunShellScript"
    ]
  }

  statement {
    sid    = "AllowOnlyLioraEC2Instance"
    effect = "Allow"

    actions = [
      "ssm:SendCommand"
    ]

    resources = [
      "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/${var.ec2_instance_id}"
    ]
  }

  statement {
    sid    = "AllowCommandResultLookup"
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

  statement {
    sid    = "AllowSSMInstancePreflight"
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

resource "aws_iam_role" "github_actions_deployer" {
  name                 = "github-actions-aws-deployer"
  assume_role_policy   = data.aws_iam_policy_document.github_actions_assume_role.json
  description          = "GitHub Actions CI/CD deployment role for Liora AI Ticket Triage"
  max_session_duration = 3600
}

resource "aws_iam_role_policy" "github_actions_ssm" {
  name   = "SSMDeploymentPolicy"
  role   = aws_iam_role.github_actions_deployer.id
  policy = data.aws_iam_policy_document.github_actions_permissions.json
}
