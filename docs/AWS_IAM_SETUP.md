# AWS IAM Setup for GitHub Actions CI/CD

## Overview

This document provides the exact IAM configuration required for GitHub Actions to deploy to AWS k3s via Systems Manager.

**Security Model:**
- GitHub OIDC federation (no static credentials)
- Least-privilege IAM role
- Limited to specific EC2 instance
- No cluster-admin or EC2 terminate permissions

---

## Prerequisites

- AWS CLI configured with admin permissions (for setup)
- GitHub repository: `automation-agent-ai/multilingual-ticket-triage-devops`
- AWS Account ID: `523231704152`
- AWS Region: `eu-west-1`
- EC2 Instance ID: `i-07bc3aaf0d692974d`

---

## Step 1: Create GitHub OIDC Provider

**Purpose:** Allow GitHub Actions to authenticate to AWS without static credentials.

### Check if provider exists

```bash
aws iam get-open-id-connect-provider \
  --open-id-connect-provider-arn arn:aws:iam::523231704152:oidc-provider/token.actions.githubusercontent.com \
  2>&1 || echo "Provider does not exist"
```

### Create provider

```bash
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1 \
  --tags \
    Key=Purpose,Value=GitHubActionsOIDC \
    Key=Repository,Value=multilingual-ticket-triage-devops \
    Key=ManagedBy,Value=Manual
```

**Thumbprint explanation:**
- GitHub's OIDC thumbprint is stable: `6938fd4d98bab03faadb97b34396831e3780aea1`
- This is the root CA thumbprint for GitHub's identity provider
- Source: https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services

### Verify

```bash
aws iam list-open-id-connect-providers

# Should show:
# "Arn": "arn:aws:iam::523231704152:oidc-provider/token.actions.githubusercontent.com"
```

---

## Step 2: Create IAM Deployment Role

### Trust Policy

Create `github-actions-trust-policy.json`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::523231704152:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": [
            "repo:automation-agent-ai/multilingual-ticket-triage-devops:ref:refs/heads/feat/aws-bedrock-migration",
            "repo:automation-agent-ai/multilingual-ticket-triage-devops:ref:refs/heads/main"
          ]
        }
      }
    }
  ]
}
```

**Trust policy breakdown:**
- `Federated`: GitHub OIDC provider ARN
- `aud`: Must be `sts.amazonaws.com` (AWS STS audience)
- `sub`: Repository and branch pattern
  - `repo:<org>/<repo>:ref:refs/heads/<branch>`
  - Allows `feat/aws-bedrock-migration` and `main` branches
  - **Blocks all other branches and forks**

### Permissions Policy

Create `github-actions-permissions-policy.json`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "SSMRunCommand",
      "Effect": "Allow",
      "Action": [
        "ssm:SendCommand"
      ],
      "Resource": [
        "arn:aws:ssm:eu-west-1::document/AWS-RunShellScript",
        "arn:aws:ec2:eu-west-1:523231704152:instance/i-07bc3aaf0d692974d"
      ],
      "Condition": {
        "StringEquals": {
          "ssm:resourceTag/Environment": [
            "production",
            "staging"
          ]
        }
      }
    },
    {
      "Sid": "SSMGetCommandResults",
      "Effect": "Allow",
      "Action": [
        "ssm:GetCommandInvocation",
        "ssm:ListCommandInvocations"
      ],
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "aws:RequestedRegion": "eu-west-1"
        }
      }
    },
    {
      "Sid": "SSMDescribeInstance",
      "Effect": "Allow",
      "Action": [
        "ssm:DescribeInstanceInformation"
      ],
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "aws:RequestedRegion": "eu-west-1"
        }
      }
    }
  ]
}
```

**Permissions breakdown:**

| Action | Resource | Condition | Rationale |
|--------|----------|-----------|-----------|
| `ssm:SendCommand` | AWS-RunShellScript document | Instance must have Environment tag | Execute deployment scripts |
| `ssm:SendCommand` | Specific instance only | | Restricted to k3s EC2 |
| `ssm:GetCommandInvocation` | Any command | Region: eu-west-1 | Read deployment results |
| `ssm:DescribeInstanceInformation` | Any instance | Region: eu-west-1 | Verify SSM connectivity |

**What this role CANNOT do:**
- ❌ Terminate or modify EC2 instances
- ❌ Create or modify IAM roles/policies
- ❌ Access S3, RDS, or other AWS services
- ❌ Send commands to other EC2 instances
- ❌ Operate in other regions
- ❌ Access Bedrock (uses EC2 instance role instead)

### Create the role

```bash
# Create role with trust policy
aws iam create-role \
  --role-name github-actions-aws-deployer \
  --assume-role-policy-document file://github-actions-trust-policy.json \
  --description "GitHub Actions deployment role for AWS k3s CI/CD" \
  --max-session-duration 3600 \
  --tags \
    Key=Purpose,Value=CICD \
    Key=ManagedBy,Value=Manual \
    Key=Repository,Value=multilingual-ticket-triage-devops

# Attach permissions policy
aws iam put-role-policy \
  --role-name github-actions-aws-deployer \
  --policy-name SSMDeploymentPolicy \
  --policy-document file://github-actions-permissions-policy.json
```

### Verify role

```bash
# Check role exists
aws iam get-role --role-name github-actions-aws-deployer

# Check trust policy
aws iam get-role \
  --role-name github-actions-aws-deployer \
  --query 'Role.AssumeRolePolicyDocument' \
  --output json

# Check permissions
aws iam get-role-policy \
  --role-name github-actions-aws-deployer \
  --policy-name SSMDeploymentPolicy \
  --output json
```

---

## Step 3: Tag EC2 Instance

The permissions policy uses a condition to require an `Environment` tag.

```bash
aws ec2 create-tags \
  --resources i-07bc3aaf0d692974d \
  --tags \
    Key=Environment,Value=production \
    Key=Application,Value=liora-triage \
    Key=ManagedBy,Value=Terraform
```

Verify:
```bash
aws ec2 describe-tags \
  --filters "Name=resource-id,Values=i-07bc3aaf0d692974d" \
  --query 'Tags[?Key==`Environment`]'
```

---

## Step 4: Enhance EC2 Instance Role

The existing `liora-triage-bedrock-role` needs SSM permissions.

### Check current policies

```bash
aws iam list-attached-role-policies --role-name liora-triage-bedrock-role
aws iam list-role-policies --role-name liora-triage-bedrock-role
```

### Attach SSM managed policy

```bash
aws iam attach-role-policy \
  --role-name liora-triage-bedrock-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
```

**What this adds:**
- SSM Agent can register with SSM service
- SSM Agent can receive commands
- SSM Agent can report status
- CloudWatch Logs for SSM (optional)

**What this does NOT add:**
- No additional Bedrock permissions (already exists)
- No S3 or other service access

### Verify

```bash
aws iam list-attached-role-policies --role-name liora-triage-bedrock-role \
  | grep AmazonSSMManagedInstanceCore
```

---

## Step 5: Install and Configure SSM Agent

### On EC2 instance

```bash
# Connect via SSH or AWS Session Manager
ssh ubuntu@<ec2-public-ip>

# Install SSM Agent via snap (Ubuntu 24.04)
sudo snap install amazon-ssm-agent --classic

# Enable and start
sudo snap start amazon-ssm-agent
sudo systemctl enable snap.amazon-ssm-agent.amazon-ssm-agent.service

# Check status
sudo snap services amazon-ssm-agent
```

Expected output:
```
Service                                    Startup  Current   Notes
amazon-ssm-agent.amazon-ssm-agent          enabled  active    -
```

### Verify SSM registration

From local machine:

```bash
# Check instance is online in SSM
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=i-07bc3aaf0d692974d" \
  --query 'InstanceInformationList[0].{PingStatus:PingStatus,PlatformName:PlatformName,PlatformVersion:PlatformVersion,AgentVersion:AgentVersion}' \
  --output table
```

Expected:
```
---------------------------------------------------------
|            DescribeInstanceInformation                |
+---------------+---------------------------------------+
| AgentVersion  |  3.x.x.x                             |
| PingStatus    |  Online                               |
| PlatformName  |  Ubuntu                               |
| PlatformVersion| 24.04                                |
+---------------+---------------------------------------+
```

### Test SSM connectivity

```bash
# Send test command
COMMAND_ID=$(aws ssm send-command \
  --instance-ids i-07bc3aaf0d692974d \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["echo SSM test successful"]' \
  --comment "SSM connectivity test" \
  --timeout-seconds 30 \
  --query 'Command.CommandId' \
  --output text)

echo "Command ID: $COMMAND_ID"

# Wait for completion
aws ssm wait command-executed \
  --command-id "$COMMAND_ID" \
  --instance-id i-07bc3aaf0d692974d \
  --timeout 60

# Get result
aws ssm get-command-invocation \
  --command-id "$COMMAND_ID" \
  --instance-id i-07bc3aaf0d692974d \
  --query 'StandardOutputContent' \
  --output text
```

Expected: `SSM test successful`

---

## Step 6: Create GitHub Environments

### Environment: aws-dev

No required reviewers (optional approval gate):

```bash
# Via GitHub CLI
gh api \
  --method PUT \
  "repos/automation-agent-ai/multilingual-ticket-triage-devops/environments/aws-dev" \
  --input - <<EOF
{
  "wait_timer": 0,
  "deployment_branch_policy": {
    "protected_branches": false,
    "custom_branch_policies": true
  }
}
EOF
```

Or via GitHub UI:
```
Repository → Settings → Environments → New environment
  Name: aws-dev
  Deployment branches: feat/aws-bedrock-migration, main
  Wait timer: 0
  Required reviewers: (none)
```

### Environment: aws-prod

**Required reviewers for production:**

```bash
# Get reviewer user IDs first
gh api /repos/automation-agent-ai/multilingual-ticket-triage-devops/collaborators \
  --jq '.[] | "\(.login): \(.id)"'

# Create environment with required reviewer
gh api \
  --method PUT \
  "repos/automation-agent-ai/multilingual-ticket-triage-devops/environments/aws-prod" \
  --input - <<EOF
{
  "wait_timer": 0,
  "reviewers": [
    {
      "type": "User",
      "id": <reviewer-user-id>
    }
  ],
  "deployment_branch_policy": {
    "protected_branches": false,
    "custom_branch_policies": true
  }
}
EOF
```

Or via GitHub UI:
```
Repository → Settings → Environments → New environment
  Name: aws-prod
  Deployment branches: feat/aws-bedrock-migration, main
  Wait timer: 0
  Required reviewers: [select at least one user]
```

---

## Verification Checklist

### OIDC Provider
- [ ] Provider exists: `arn:aws:iam::523231704152:oidc-provider/token.actions.githubusercontent.com`
- [ ] Thumbprint correct: `6938fd4d98bab03faadb97b34396831e3780aea1`
- [ ] Audience: `sts.amazonaws.com`

### IAM Role: github-actions-aws-deployer
- [ ] Role exists
- [ ] Trust policy allows GitHub repo
- [ ] Trust policy restricts to specific branches
- [ ] Permissions include `ssm:SendCommand` for specific instance
- [ ] Permissions include `ssm:GetCommandInvocation`
- [ ] No admin or destructive permissions

### EC2 Instance
- [ ] Tagged with `Environment=production`
- [ ] Instance role has `AmazonSSMManagedInstanceCore`
- [ ] SSM Agent installed and running
- [ ] Instance shows "Online" in SSM console

### SSM Connectivity
- [ ] Test command succeeds
- [ ] Command output retrieved successfully
- [ ] No permission errors

### GitHub Environments
- [ ] `aws-dev` environment exists
- [ ] `aws-prod` environment exists
- [ ] `aws-prod` has required reviewer configured

---

## Testing IAM Setup

### Test OIDC authentication locally (requires GitHub token)

```bash
# This requires a GitHub Actions OIDC token, which is only available within workflows.
# Testing must be done via actual workflow run.
```

### Test SSM permissions with GitHub role

This can only be tested from within a GitHub Actions workflow because:
1. OIDC tokens are issued to running workflows
2. Local AWS CLI cannot assume the GitHub OIDC role directly

**Test workflow snippet:**

```yaml
jobs:
  test-iam:
    runs-on: ubuntu-latest
    permissions:
      id-token: write
      contents: read
    
    steps:
      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::523231704152:role/github-actions-aws-deployer
          aws-region: eu-west-1
      
      - name: Test SSM access
        run: |
          aws sts get-caller-identity
          aws ssm describe-instance-information \
            --filters "Key=InstanceIds,Values=i-07bc3aaf0d692974d"
```

---

## Terraform Alternative

If using Terraform to manage IAM:

### Provider configuration

```hcl
terraform {
  required_version = ">= 1.5"
  
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "eu-west-1"
}
```

### OIDC Provider

```hcl
resource "aws_iam_openid_connect_provider" "github_actions" {
  url = "https://token.actions.githubusercontent.com"
  
  client_id_list = [
    "sts.amazonaws.com"
  ]
  
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1"
  ]
  
  tags = {
    Purpose    = "GitHubActionsOIDC"
    Repository = "multilingual-ticket-triage-devops"
    ManagedBy  = "Terraform"
  }
}
```

### IAM Role

```hcl
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
    
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:automation-agent-ai/multilingual-ticket-triage-devops:ref:refs/heads/feat/aws-bedrock-migration",
        "repo:automation-agent-ai/multilingual-ticket-triage-devops:ref:refs/heads/main"
      ]
    }
  }
}

data "aws_iam_policy_document" "github_actions_permissions" {
  statement {
    sid    = "SSMRunCommand"
    effect = "Allow"
    
    actions = [
      "ssm:SendCommand"
    ]
    
    resources = [
      "arn:aws:ssm:eu-west-1::document/AWS-RunShellScript",
      "arn:aws:ec2:eu-west-1:523231704152:instance/i-07bc3aaf0d692974d"
    ]
    
    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/Environment"
      values   = ["production", "staging"]
    }
  }
  
  statement {
    sid    = "SSMGetCommandResults"
    effect = "Allow"
    
    actions = [
      "ssm:GetCommandInvocation",
      "ssm:ListCommandInvocations"
    ]
    
    resources = ["*"]
    
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = ["eu-west-1"]
    }
  }
  
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
      values   = ["eu-west-1"]
    }
  }
}

resource "aws_iam_role" "github_actions_deployer" {
  name               = "github-actions-aws-deployer"
  assume_role_policy = data.aws_iam_policy_document.github_actions_assume_role.json
  description        = "GitHub Actions deployment role for AWS k3s CI/CD"
  max_session_duration = 3600
  
  tags = {
    Purpose    = "CICD"
    ManagedBy  = "Terraform"
    Repository = "multilingual-ticket-triage-devops"
  }
}

resource "aws_iam_role_policy" "github_actions_permissions" {
  name   = "SSMDeploymentPolicy"
  role   = aws_iam_role.github_actions_deployer.id
  policy = data.aws_iam_policy_document.github_actions_permissions.json
}
```

### EC2 Instance Role Enhancement

```hcl
data "aws_iam_role" "bedrock_role" {
  name = "liora-triage-bedrock-role"
}

resource "aws_iam_role_policy_attachment" "ssm_managed_instance" {
  role       = data.aws_iam_role.bedrock_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
```

### Outputs

```hcl
output "github_actions_role_arn" {
  description = "IAM role ARN for GitHub Actions workflows"
  value       = aws_iam_role.github_actions_deployer.arn
}

output "oidc_provider_arn" {
  description = "GitHub OIDC provider ARN"
  value       = aws_iam_openid_connect_provider.github_actions.arn
}
```

---

## Security Best Practices

### Regular Audits

```bash
# Review IAM role permissions quarterly
aws iam get-role-policy \
  --role-name github-actions-aws-deployer \
  --policy-name SSMDeploymentPolicy

# Check for unused permissions
aws iam generate-service-last-accessed-details \
  --arn arn:aws:iam::523231704152:role/github-actions-aws-deployer
```

### Monitor SSM Commands

```bash
# Review recent SSM commands
aws ssm list-commands \
  --filters "Key=InvokedAfter,Value=$(date -u -d '7 days ago' '+%Y-%m-%dT%H:%M:%SZ')" \
  --query 'Commands[?InstanceIds[0]==`i-07bc3aaf0d692974d`].[CommandId,DocumentName,Status,RequestedDateTime,Comment]' \
  --output table
```

### Enable CloudTrail

Ensure CloudTrail is logging SSM and IAM events:

```bash
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=SendCommand \
  --max-results 10
```

### Rotate OIDC Thumbprint

GitHub's OIDC thumbprint is stable, but verify quarterly:

```bash
# Check current thumbprint
aws iam get-open-id-connect-provider \
  --open-id-connect-provider-arn arn:aws:iam::523231704152:oidc-provider/token.actions.githubusercontent.com \
  --query 'ThumbprintList'

# Should be: ["6938fd4d98bab03faadb97b34396831e3780aea1"]
```

---

## Troubleshooting

### OIDC provider creation fails

**Error:** `EntityAlreadyExists: Provider with name token.actions.githubusercontent.com already exists`

**Fix:** Provider already exists. Verify configuration:
```bash
aws iam get-open-id-connect-provider \
  --open-id-connect-provider-arn arn:aws:iam::523231704152:oidc-provider/token.actions.githubusercontent.com
```

### AssumeRole fails in workflow

**Error:** `User: arn:aws:sts::... is not authorized to perform: sts:AssumeRoleWithWebIdentity`

**Check:**
1. Trust policy includes your repository:
   ```bash
   aws iam get-role --role-name github-actions-aws-deployer \
     --query 'Role.AssumeRolePolicyDocument.Statement[0].Condition'
   ```

2. Branch name matches pattern in trust policy

3. OIDC provider exists and is correctly configured

### SSM Agent not registering

**Error:** Instance not showing in `ssm describe-instance-information`

**Fix:**
1. Verify instance role has `AmazonSSMManagedInstanceCore`
2. Restart SSM Agent: `sudo snap restart amazon-ssm-agent`
3. Check agent logs: `sudo journalctl -u snap.amazon-ssm-agent.amazon-ssm-agent -n 50`
4. Verify outbound HTTPS (port 443) is allowed to `ssm.eu-west-1.amazonaws.com`

### SendCommand permission denied

**Error:** `AccessDeniedException: User ... is not authorized to perform: ssm:SendCommand`

**Check:**
1. Instance is tagged with `Environment=production`
2. IAM role has `SSMDeploymentPolicy` attached
3. Resource ARNs in policy match instance ID

---

## Rollback

If you need to remove the IAM setup:

```bash
# Detach SSM policy from EC2 instance role
aws iam detach-role-policy \
  --role-name liora-triage-bedrock-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

# Delete GitHub Actions role policy
aws iam delete-role-policy \
  --role-name github-actions-aws-deployer \
  --policy-name SSMDeploymentPolicy

# Delete GitHub Actions role
aws iam delete-role --role-name github-actions-aws-deployer

# Delete OIDC provider
aws iam delete-open-id-connect-provider \
  --open-id-connect-provider-arn arn:aws:iam::523231704152:oidc-provider/token.actions.githubusercontent.com
```

---

## Summary

**What you created:**
1. GitHub OIDC provider in AWS
2. IAM role `github-actions-aws-deployer` with SSM permissions
3. Enhanced EC2 instance role with SSM managed policy
4. Tagged EC2 instance for permission conditions
5. Installed and verified SSM Agent
6. Created GitHub Environments with approval gates

**Security guarantees:**
- No static AWS credentials in GitHub
- Temporary tokens (1-hour lifetime)
- Limited to specific instance and region
- No admin or destructive permissions
- Conditional on instance tags
- Branch-restricted in trust policy

**Next steps:**
- Run AWS DEV deployment workflow
- Verify SSM connectivity in GitHub Actions
- Test smoke tests via SSM
- Promote to PROD with approval

**Cost:** $0/month (OIDC, STS, and SSM Run Command are free)
