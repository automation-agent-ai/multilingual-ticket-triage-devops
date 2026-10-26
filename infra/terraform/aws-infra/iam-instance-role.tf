# EC2 instance role: SSM managed instance core (imported attachment).
# Restic S3 inline policy lives in infra/terraform/aws-restic/ (optional stack; not deployed).

resource "aws_iam_role_policy_attachment" "ec2_ssm_managed_instance" {
  role       = data.aws_iam_role.capstone_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
