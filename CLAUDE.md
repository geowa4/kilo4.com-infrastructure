# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repository contains AWS infrastructure-as-code for deploying a VPC, EC2 instance, and related services in us-east-2. The infrastructure uses CloudFormation for deployment and AWS Systems Manager (SSM) for agentless Ansible management.

## Core Architecture

**Infrastructure Model**: Single CloudFormation template (`infrastructure.yaml`) that defines:
- VPC with public subnet and internet gateway
- EC2 instance (t4g.small ARM-based) with IAM role for SSM, SES, and S3 backup access
- Security group restricting SSH to a single parameterized IP
- SSH key provisioning from GitHub (https://github.com/geowa4.keys) via UserData
- S3 buckets for Ansible playbooks and backups (versioned, KMS-encrypted)
- SNS topics for SES bounce/complaint notifications
- CloudWatch alarms for SES reputation monitoring

**Management Pattern**: AWS Systems Manager provides agentless configuration management. The `AWS-ApplyAnsiblePlaybooks` SSM document executes playbooks without a dedicated Ansible control node—SSM downloads playbooks from S3, installs Ansible on the target instance, and executes locally.

**Region**: All resources are in us-east-2

## CloudFormation Stack Management

### Update stack (recommended)
```bash
mise run infra:update-stack
```

This task automatically:
- Fetches your current public IP
- Validates the template
- Updates the stack
- Waits for completion
- Displays outputs

### Manual update
```bash
aws cloudformation update-stack \
  --stack-name ${PROJECT_NAME}-Infrastructure \
  --template-body file://infrastructure.yaml \
  --parameters ParameterKey=SSHAllowedIP,ParameterValue=<IP>/32 \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-east-2

aws cloudformation wait stack-update-complete --stack-name ${PROJECT_NAME}-Infrastructure --region us-east-2
```

## EC2 Instance Details

- **Instance Type**: t4g.small (ARM-based Graviton)
- **AMI**: Dynamically resolved via SSM parameter `/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64`
- **SSH Access**: GitHub user `geowa4`'s public keys are automatically provisioned
- **IAM Role**: Includes `AmazonSSMManagedInstanceCore`, SES sending permissions, and S3 backup bucket access

### Get instance public IP
```bash
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=${PROJECT_NAME}-Instance" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text \
  --region us-east-2
```

## Mise Tasks

All operational tasks are managed via mise. Tasks are defined in `.mise/tasks/` with the following namespaces:

- `deploy` / `teardown` - Full deployment/teardown
- `infra:*` - Infrastructure operations (CloudFormation, Ansible, Patch Manager, Backups)
- `ses:*` - Amazon SES email configuration
- `validate:*` - Code/config validation

List all available tasks:
```bash
mise tasks
```

Run a task:
```bash
mise run <task-name>
```

## Development Task Management

Development tasks are organized in `tasks/` directory:
- `tasks/todo/` - Pending tasks with requirements and acceptance criteria
- `tasks/done/` - Completed tasks (moved from todo after completion)
- `tasks/dev-plan.md` - Master implementation guide with detailed technical documentation

When completing a task, move it from `tasks/todo/` to `tasks/done/`.
Never commit tasks.

## Ansible Playbooks

### Running Playbooks

Execute playbooks on the EC2 instance via SSM using the consolidated task:

```bash
mise run infra:run-ansible-playbook playbooks/hardening.yml
```

The task automatically:
- Validates the playbook file exists
- Retrieves instance ID and S3 bucket from CloudFormation stack outputs
- Uploads the playbook to S3
- Executes it via SSM `AWS-ApplyAnsiblePlaybooks` document
- Waits for completion and displays results

### Authoring Playbooks

Playbooks are stored in `playbooks/` directory. Follow these conventions:

**Naming**: Use descriptive names without redundancy (e.g., `hardening.yml`, not `hardening-playbook.yml`)

**Requirements**:
- Must pass `uv run ansible-lint playbooks/<name>.yml` with production profile
- Use `become: true` (not `yes`) for privilege escalation
- Use `true`/`false` for all boolean values (not `yes`/`no`)
- Handler names must start with uppercase letter
- All tasks must be idempotent (safe to run multiple times)

**Validation**:
```bash
# YAML syntax
uv run python -c "import yaml; yaml.safe_load(open('playbooks/<name>.yml'))"

# Ansible best practices
uv run ansible-lint playbooks/<name>.yml
```

### Existing Playbooks

- `playbooks/hardening.yml` - System hardening (SSH, firewall, fail2ban)
- `playbooks/base-packages.yml` - Development tools (git, golang)
- `playbooks/s3-backup.yml` - S3 backup system deployment

## Systems Manager Integration

### Manual SSM Command (not recommended - use task instead)
```bash
aws ssm send-command \
  --document-name "AWS-ApplyAnsiblePlaybooks" \
  --instance-ids "i-XXXXXXXXX" \
  --parameters '{
      "SourceType":["S3"],
      "SourceInfo":["{\"path\":\"https://s3.amazonaws.com/BUCKET/playbooks/playbook.yml\"}"],
      "InstallDependencies":["True"],
      "PlaybookFile":["playbook.yml"],
      "ExtraVariables":["SSM=True"],
      "Verbose":["-v"]
  }' \
  --region us-east-2
```

### Create State Manager association (scheduled playbook execution)
```bash
aws ssm create-association \
  --name "AWS-ApplyAnsiblePlaybooks" \
  --targets "Key=tag:Name,Values=${PROJECT_NAME}-Instance" \
  --parameters '{...}' \
  --schedule-expression "rate(1 day)" \
  --region us-east-2
```

## Amazon SES Email Service

### Overview
- **Sender Domain**: ${DOMAIN_NAME}
- **Sender Address**: noreply@${DOMAIN_NAME}
- **Status**: Domain verified with DKIM
- **Mode**: Sandbox (200 emails/day, verified recipients only)

### SES Tasks
```bash
# Verify email identity
mise run ses:verify-identity noreply@${DOMAIN_NAME}

# Verify domain with DKIM
mise run ses:verify-domain ${DOMAIN_NAME}

# Send test email
mise run ses:test-email -- \
  --from noreply@${DOMAIN_NAME} \
  --to recipient@example.com \
  --subject "Test" \
  --body "Test email"

# Request production access
mise run ses:request-production -- \
  --use-case "Transactional emails for user notifications"
```

### SES Infrastructure
CloudFormation manages:
- SNS topics for bounce/complaint notifications
- CloudWatch alarms for reputation monitoring (>5% bounce, >0.1% complaint)

Manual configuration required (no CloudFormation support):
- Linking SES identity to SNS topics (documented in `docs/ses-production-checklist.md`)
- SNS topic subscriptions

### Documentation
- `docs/ses-setup.md` - Complete SES setup guide
- `docs/ses-production-checklist.md` - Production access prerequisites and checklist

## S3 Backup System

### Overview
Automated backup solution for critical files on the EC2 instance to a versioned S3 bucket with lifecycle management.

- **Schedule**: Daily backups at 02:00 (with 5-minute random delay)
- **Storage**: Versioned S3 bucket with KMS encryption
- **Lifecycle**: STANDARD (30 days) → GLACIER (60 days) → Deleted (90 days for non-current versions)
- **Multi-file support**: Configurable file list

### Infrastructure
CloudFormation manages:
- S3 backup bucket with versioning and KMS encryption
- IAM permissions for EC2 instance to access backup bucket
- Lifecycle policies for cost optimization

**Bucket outputs**:
- `BackupBucketName`: S3 bucket name for backups
- `BackupBucketArn`: S3 bucket ARN for backups

### Deployment

Deploy the backup system using the Ansible playbook:

```bash
# Get the backup bucket name from CloudFormation outputs
BACKUP_BUCKET=$(mise run infra:stack-outputs | jq -r '.BackupBucketName')

# Deploy backup system (pass bucket as extra variable)
mise run infra:run-ansible-playbook playbooks/s3-backup.yml "" "backup_bucket=$BACKUP_BUCKET"
```

The playbook automatically:
- Installs prerequisites (AWS CLI v2, jq)
- Deploys backup scripts to `/usr/local/bin/`
- Creates configuration files in `/etc/s3-backup/`
- Installs and enables systemd timer for daily backups

### Backup Tasks

```bash
# Trigger immediate backup
mise run infra:backup-run

# List all versions of a file
mise run infra:backup-list-versions fail2ban.sqlite3

# Download a specific version to EC2 instance
mise run infra:backup-download fail2ban.sqlite3 <version-id> [/path/to/dest]

# Restore a version as current in S3
mise run infra:backup-restore fail2ban.sqlite3 <version-id>
```

### Configuration

**Backup configuration**: `/etc/s3-backup/backup.conf`
```bash
S3_BUCKET="<bucket-name>"
S3_PREFIX="backups"
AWS_REGION="us-east-2"
FILES_CONF="/etc/s3-backup/files.conf"
```

**File list**: `/etc/s3-backup/files.conf`
```bash
# One file path per line
/var/lib/fail2ban/fail2ban.sqlite3
```

### Adding New Files to Backup

1. SSH to the instance or use SSM Session Manager
2. Edit `/etc/s3-backup/files.conf` and add the file path
3. Trigger immediate backup to test: `sudo systemctl start s3-backup.service`
4. Check logs: `sudo journalctl -u s3-backup.service -n 50`

Alternatively, update the `backup_files` variable in `playbooks/s3-backup.yml` and re-run the playbook.

### Monitoring

Check backup timer status:
```bash
# Via SSM
aws ssm send-command \
  --document-name "AWS-RunShellScript" \
  --instance-ids <instance-id> \
  --parameters "commands=['systemctl status s3-backup.timer']" \
  --region us-east-2

# Via SSH
ssh ec2-user@<instance-ip> 'sudo systemctl status s3-backup.timer'
```

Check recent backup logs:
```bash
ssh ec2-user@<instance-ip> 'sudo journalctl -u s3-backup.service -n 100'
```

## Important Constraints

- **ARM Architecture**: Instance uses t4g (Graviton), so always use ARM64 AMIs and binaries
- **Security**: SSH restricted to single IP via SSHAllowedIP parameter
- **No Key Pairs**: SSH keys come exclusively from GitHub (geowa4 user)
- **SSM Agent**: Pre-installed on Amazon Linux 2023, no manual installation needed
- **DependsOn**: The PublicRoute resource requires `DependsOn: VPCGatewayAttachment` to ensure proper creation order
