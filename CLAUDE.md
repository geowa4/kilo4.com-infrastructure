# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repository contains AWS infrastructure-as-code for deploying a VPC, EC2 instance, and related services in us-east-2. The infrastructure uses CloudFormation for deployment and AWS Systems Manager (SSM) for agentless Ansible management.

## Core Architecture

**Infrastructure Model**: Single CloudFormation template (`infrastructure.yaml`) that defines:
- VPC with public subnet and internet gateway
- EC2 instance (t4g.small ARM-based) with IAM role for SSM, SES, and S3 backup access
- Security group with egress-only rules (no inbound ports, access via SSM)
- SSH key provisioning from GitHub (https://github.com/<username>.keys) via UserData
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
- Validates the template
- Updates the stack
- Waits for completion
- Displays outputs

### Manual update
```bash
aws cloudformation update-stack \
  --stack-name ${PROJECT_NAME}-Infrastructure \
  --template-body file://infrastructure.yaml \
  --parameters \
    ParameterKey=ProjectName,ParameterValue=${PROJECT_NAME} \
    ParameterKey=GitHubUsername,ParameterValue=${GITHUB_USERNAME} \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-east-2

aws cloudformation wait stack-update-complete --stack-name ${PROJECT_NAME}-Infrastructure --region us-east-2
```

## EC2 Instance Details

- **Instance Type**: t4g.small (ARM-based Graviton)
- **AMI**: Dynamically resolved via SSM parameter `/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64`
- **Access**: Via AWS Systems Manager Session Manager (no SSH port 22 exposed)
- **SSH Keys**: GitHub user's public keys are automatically provisioned for SSH-over-SSM
- **IAM Role**: Includes `AmazonSSMManagedInstanceCore`, SES sending permissions, and S3 backup bucket access

### Get instance ID
```bash
aws cloudformation describe-stacks \
  --stack-name ${PROJECT_NAME}-Infrastructure \
  --region us-east-2 \
  --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue" \
  --output text
```

## Connecting to EC2 Instances

All instance access is via AWS Systems Manager Session Manager (no inbound SSH port 22). Three connection methods are available:

### SSM Session Manager (recommended)
```bash
# Interactive shell via SSM
mise run infra:ssm-connect
```

### SSH over SSM
Requires SSH config (automatically configured in `~/.ssh/config`):
```bash
# Get SSH command
mise run infra:ssh-command

# Connect via SSH over SSM tunnel
ssh ec2-user@i-<instance-id>
```

SSH config (`~/.ssh/config`):
```
Host i-* mi-*
    ProxyCommand sh -c "aws ssm start-session --target %h --document-name AWS-StartSSHSession --parameters 'portNumber=%p'"
    User ec2-user
```

### Port Forwarding
Forward remote ports (RDS, ElastiCache, etc.) to local machine:
```bash
# Forward RDS PostgreSQL to local port 5432
mise run infra:port-forward 5432 mydb.cluster-xxx.rds.amazonaws.com 5432

# Forward service on EC2 instance
mise run infra:port-forward 8080 localhost 80
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
- `playbooks/caddy.yml` - Caddy web server with automatic HTTPS
- `playbooks/s3-backup.yml` - S3 backup system deployment
- `playbooks/blog.yml` - Blog application deployment (PocketBase)

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

1. Connect to the instance: `mise run infra:ssm-connect`
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

# Via SSM shell
mise run infra:ssm-connect
sudo systemctl status s3-backup.timer
```

Check recent backup logs:
```bash
mise run infra:ssm-connect
sudo journalctl -u s3-backup.service -n 100
```

## Blog Application (PocketBase)

### Overview
The blog is a Go/Hugo application (https://github.com/geowa4/kilo4.com-blog) built with PocketBase that runs as a systemd service behind the Caddy reverse proxy.

- **Binary**: `/usr/local/bin/pocketbase`
- **Data Directory**: `/var/lib/blog/pb_data/`
- **Source Code**: `/var/lib/blog/src/kilo4.com-blog`
- **Port**: 8090 (localhost only, not exposed externally)
- **User**: `blog` (system user)
- **Health Endpoint**: `http://127.0.0.1:8090/api/health`
- **Admin Endpoint**: `http://127.0.0.1:8090/_/` (blocked from external access)

### Deployment

Deploy or update the blog application:

```bash
mise run infra:run-ansible-playbook playbooks/blog.yml
```

The playbook performs the following:
1. Creates `blog` system user if not exists
2. Installs Hugo via Go (`go install github.com/gohugoio/hugo@latest`)
3. Clones or updates the blog repository from GitHub
4. Initializes git submodules (Hugo theme)
5. Builds the binary on the EC2 instance (`make build`)
6. Backs up the current binary (if exists)
7. Deploys the new binary to `/usr/local/bin/pocketbase`
8. Starts/restarts the `blog` systemd service
9. Performs health check on `/api/health` endpoint
10. Automatically rolls back to previous binary if health check fails
11. Updates Caddy configuration to proxy traffic to the blog
12. Adds blog data files to S3 backup configuration

### Health Check and Rollback

The deployment process includes automatic health checks:
- After deployment, the playbook polls `http://127.0.0.1:8090/api/health` (30 retries, 2 seconds apart)
- If the health check fails:
  - Finds the most recent backup binary from `/var/lib/blog/backups/`
  - Restores the previous binary
  - Restarts the service
  - Verifies the rollback succeeded
  - Fails the playbook with an error message

### Accessing the Admin Interface

The admin endpoint (`/_/`) is **blocked from external access** for security. Caddy returns a 404 for any requests to `/_/*` paths.

To access the admin interface, use SSM port forwarding:

```bash
# Start port forwarding session
mise run infra:port-forward 8090 localhost 8090

# In your browser, navigate to:
# http://localhost:8090/_/
```

The port forwarding session will remain active until you press `Ctrl+C`.

### Caddy Reverse Proxy Configuration

The blog playbook automatically configures Caddy (`/etc/caddy/Caddyfile`) to:
- Proxy all public requests to the blog backend on `127.0.0.1:8090`
- Block the admin endpoint `/_/*` from external access (returns 404)
- Provide automatic HTTPS via Let's Encrypt

### Data Backup

The blog's database files are automatically added to the S3 backup configuration (`/etc/s3-backup/files.conf`):
- `/var/lib/blog/pb_data/auxiliary.db` - Auxiliary database
- `/var/lib/blog/pb_data/data.db` - Main database
- `/var/lib/blog/pb_data/types.d.ts` - TypeScript type definitions

These files are backed up daily at 02:00 via the existing S3 backup system.

To manually trigger a backup:
```bash
mise run infra:backup-run
```

To list or restore backup versions:
```bash
# List all versions
mise run infra:backup-list-versions data.db

# Restore a specific version
mise run infra:backup-restore data.db <version-id>
```

### Service Management

Check blog service status:
```bash
mise run infra:ssm-connect
sudo systemctl status blog
```

View blog logs:
```bash
mise run infra:ssm-connect
sudo journalctl -u blog -n 100 -f
```

Restart the blog service:
```bash
mise run infra:ssm-connect
sudo systemctl restart blog
```

## Important Constraints

- **ARM Architecture**: Instance uses t4g (Graviton), so always use ARM64 AMIs and binaries
- **Security**: No inbound ports exposed - all access via AWS Systems Manager Session Manager
- **SSH Keys**: SSH keys come exclusively from GitHub, used for SSH-over-SSM
- **SSM Agent**: Pre-installed on Amazon Linux 2023, no manual installation needed
- **DependsOn**: The PublicRoute resource requires `DependsOn: VPCGatewayAttachment` to ensure proper creation order
