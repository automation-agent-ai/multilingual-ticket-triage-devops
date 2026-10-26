# GitHub OIDC Provider for Actions federation

resource "aws_iam_openid_connect_provider" "github_actions" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list = [
    "sts.amazonaws.com"
  ]

  # Live thumbprint on token.actions.githubusercontent.com (eu-west-1 account 523231704152).
  # Differs from legacy docs that list 6938fd4d…; must match imported provider or plan shows change.
  thumbprint_list = [
    "ab9d0263244dd0326eb67015705a667e79cfe998"
  ]
}
