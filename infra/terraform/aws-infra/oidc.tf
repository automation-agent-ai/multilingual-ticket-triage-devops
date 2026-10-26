# GitHub OIDC Provider for Actions federation

resource "aws_iam_openid_connect_provider" "github_actions" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list = [
    "sts.amazonaws.com"
  ]

  # GitHub's stable OIDC thumbprint
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1"
  ]

  tags = merge(
    var.common_tags,
    {
      Name    = "github-actions-oidc-provider"
      Purpose = "GitHubActionsOIDC"
    }
  )
}
