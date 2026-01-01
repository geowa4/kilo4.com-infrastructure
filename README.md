# kilo4.com Infrastructure

AWS infrastructure using CloudFormation in us-east-2.

## Deploy

Complete infrastructure deployment:
```bash
mise run deploy
```

Or update just the CloudFormation stack:
```bash
mise run infra:update-stack
```

## Connect

```bash
# Get instance IP
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=${PROJECT_NAME}-Instance" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text \
  --region us-east-2

# SSH
ssh ec2-user@<INSTANCE_IP>
```

## Available Tasks

List all tasks:
```bash
mise tasks
```

Common tasks:
- `mise run deploy` - Deploy complete infrastructure
- `mise run teardown` - Tear down all resources
- `mise run infra:update-stack` - Update CloudFormation stack
- `mise run infra:run-ansible-playbook PLAYBOOK` - Run Ansible playbook
- `mise run ses:verify-domain DOMAIN` - Verify SES domain
- `mise run validate:playbooks` - Validate Ansible playbooks

## Stack Contents

- VPC with public subnet
- t4g.small EC2 instance (Amazon Linux 2023 ARM64)
- IAM role with SSM and SES permissions
- GitHub SSH key provisioning
