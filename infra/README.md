# Infrastructure as Code

This directory contains infrastructure automation for the Liora AI Ticket Triage system.

## Structure

```
infra/
├── terraform/          # Terraform modules for AWS infrastructure
│   ├── aws-infra/     # Core AWS infrastructure (OIDC, IAM, SSM)
│   └── aws-restic/    # Restic backup S3 bucket and IAM
└── README.md          # This file
```

## Terraform Modules

See [terraform/README.md](terraform/README.md) for complete documentation.

### aws-infra

- GitHub Actions OIDC provider
- IAM role for GitHub Actions deployment (SSM-based)
- EC2 instance IAM role enhancements for SSM
- SSM-based CI/CD deployment pipeline

### aws-restic

- S3 bucket for Restic encrypted backups
- IAM instance profile for backup access
- Lifecycle policies for cost optimization

## Usage

Each module is designed to be deployed independently using Terraform. See the module-specific README files for detailed instructions.

## Related Documentation

- Backup implementation: [../ops/backup/README.md](../ops/backup/README.md)
- CI/CD workflows: [../docs/AWS_CICD.md](../docs/AWS_CICD.md)
- IAM setup guide: [../docs/AWS_IAM_SETUP.md](../docs/AWS_IAM_SETUP.md)
