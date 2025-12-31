# Deployment Guide

This guide covers deploying and managing the project infrastructure on AWS.

## Overview

The infrastructure consists of:

- **Region**: us-east-2
- **Stack Name**: ${PROJECT_NAME}-Infrastructure
- **Primary Components**: VPC, EC2 instance (t4g.small ARM), IAM roles, S3 bucket, SNS topics
- **Management**: AWS Systems Manager (SSM) with Ansible for configuration
- **Automation**: CloudFormation for infrastructure, Ansible for configuration

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ VPC (10.0.0.0/16)                                           │
│                                                             │
│  ┌────────────────────────────────────────────────────┐    │
│  │ Public Subnet (10.0.1.0/24)                        │    │
│  │                                                     │    │
│  │  ┌──────────────────────────────────┐              │    │
│  │  │ EC2 Instance (t4g.small)         │              │    │
│  │  │ - Amazon Linux 2023 (ARM)        │              │    │
│  │  │ - SSM Agent                      │◄─────────────┼────┼── Systems Manager
│  │  │ - IAM Role (SSM + SES)           │              │    │
│  │  └──────────────────────────────────┘              │    │
│  │           │                                         │    │
│  └───────────┼─────────────────────────────────────────┘    │
│              │                                              │
│  ┌───────────▼────────┐                                     │
│  │ Internet Gateway   │                                     │
│  └────────────────────┘                                     │
└─────────────────────────────────────────────────────────────┘
         │
         │
    ┌────▼────┐      ┌──────────┐      ┌─────────────┐
    │   S3    │      │   SNS    │      │ CloudWatch  │
    │ Bucket  │      │  Topics  │      │   Alarms    │
    └─────────┘      └──────────┘      └─────────────┘
```

## Prerequisites

Before deploying, ensure you have:

### Required Software

- **AWS CLI v2**: [Installation guide](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
- **jq**: JSON processor for parsing AWS responses
  - macOS: `brew install jq`
  - Linux: `apt-get install jq` or `yum install jq`
- **curl**: For fetching public IP (usually pre-installed)

### AWS Account Setup

- **AWS Account**: With administrator access
- **AWS Credentials**: Configured with `aws configure`
- **Region**: us-east-2 (set in AWS CLI config)
- **Permissions**: Ability to create CloudFormation stacks, EC2, VPC, IAM, S3, SNS, SSM resources

### Verify Prerequisites

```bash
# Check AWS CLI
aws --version

# Check jq
jq --version

# Check AWS credentials
aws sts get-caller-identity

# Verify region
aws configure get region
# Should output: us-east-2
```

## Quick Start

For a complete deployment from scratch:

```bash
# Clone repository
cd <your-repo-directory>

# Deploy everything
mise run deploy
```

The script will:
1. Create/update CloudFormation stack (VPC, EC2, IAM, S3, SNS)
2. Wait for EC2 instance to register with SSM
3. Upload Ansible playbooks to S3
4. Run system hardening (SSH, firewall, fail2ban)
5. Install base packages (git, golang)
6. Create State Manager association for scheduled hardening
7. Configure Patch Manager (if email provided)

**Deployment time**: Approximately 10-15 minutes

## Detailed Deployment Steps

### Step 1: Clone Repository

```bash
git clone <your-repo-url>
cd <your-repo-directory>
```

### Step 2: Review Infrastructure Template

The CloudFormation template defines all infrastructure resources:

```bash
cat infrastructure.yaml
```

Key resources:
- VPC with public subnet
- EC2 instance (t4g.small, ARM-based Graviton)
- Security group (SSH restricted to your IP)
- IAM role with SSM and SES permissions
- S3 bucket for Ansible playbooks
- SNS topics for SES notifications
- CloudWatch alarms for SES monitoring

### Step 3: Run Deployment Script

```bash
mise run deploy
```

The script performs the following phases:

#### Phase 1: Prerequisites Check
- Validates AWS CLI, jq, curl installed
- Checks AWS credentials and region
- Verifies infrastructure.yaml and playbooks/ exist

#### Phase 2: CloudFormation Stack
- Detects current public IP for SSH access
- Creates stack (if new) or updates (if exists)
- Waits for stack completion
- Creates: VPC, EC2, IAM, S3, SNS, CloudWatch

#### Phase 3: SSM Agent Registration
- Polls SSM for instance registration
- Timeout: 5 minutes (typical: 2-3 minutes)
- Verifies instance is online and ready

#### Phase 4: Ansible Playbooks
- Uploads playbooks to S3 bucket
- Runs hardening playbook (SSH, firewall, fail2ban)
- Runs base packages playbook (git, golang)

#### Phase 5: Automation Setup
- Creates State Manager association (daily hardening)
- Configures Patch Manager (if email provided)
- Sets up maintenance windows for Sunday 2AM UTC

#### Phase 6: Deployment Summary
- Displays instance public IP
- Shows SSH command
- Lists CloudFormation outputs
- Provides next steps

### Step 4: Verify Deployment

See [Verification](#verification) section below.

## Verification

### Verify CloudFormation Stack

```bash
# Check stack status
aws cloudformation describe-stacks \
  --stack-name ${PROJECT_NAME}-Infrastructure \
  --region us-east-2 \
  --query 'Stacks[0].StackStatus' \
  --output text

# Expected: CREATE_COMPLETE or UPDATE_COMPLETE

# List all resources
aws cloudformation describe-stack-resources \
  --stack-name ${PROJECT_NAME}-Infrastructure \
  --region us-east-2 \
  --output table
```

### Verify EC2 Instance

```bash
# Get instance ID and status
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=${PROJECT_NAME}-Instance" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].[InstanceId,State.Name,PublicIpAddress]' \
  --output table \
  --region us-east-2

# Expected: Instance ID, running, public IP
```

### Verify SSM Agent

```bash
# Check SSM agent status
aws ssm describe-instance-information \
  --region us-east-2 \
  --query 'InstanceInformationList[*].[InstanceId,PingStatus,PlatformName,PlatformVersion]' \
  --output table

# Expected: Instance listed with PingStatus = Online
```

### Verify Ansible Playbooks

```bash
# List playbooks in S3
BUCKET=$(aws cloudformation describe-stacks \
  --stack-name ${PROJECT_NAME}-Infrastructure \
  --region us-east-2 \
  --query "Stacks[0].Outputs[?OutputKey=='AnsiblePlaybooksBucketName'].OutputValue" \
  --output text)

aws s3 ls s3://$BUCKET/playbooks/

# Expected: hardening.yml, base-packages.yml
```

### Verify State Manager Association

```bash
# List State Manager associations
aws ssm list-associations \
  --region us-east-2 \
  --query 'Associations[?starts_with(AssociationName, `${PROJECT_NAME}-`)].[AssociationName,Status.Name]' \
  --output table

# Expected: ${PROJECT_NAME}-hardening-Playbook with Success status
```

### Verify SSH Access

```bash
# Get public IP
PUBLIC_IP=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=${PROJECT_NAME}-Instance" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text \
  --region us-east-2)

# SSH to instance
ssh ec2-user@$PUBLIC_IP

# Check hardening applied
sudo systemctl status fail2ban
sudo firewall-cmd --list-all

# Check base packages
git --version
go version
```

## Updating the Infrastructure

### Update SSH Allowed IP

If your IP address changes:

```bash
mise run infra:update-stack
```

This automatically:
- Fetches your current public IP
- Updates CloudFormation stack
- Updates security group rules

### Re-run Ansible Playbooks

To manually apply playbooks:

```bash
# System hardening
mise run infra:run-ansible-playbook playbooks/hardening.yml

# Base packages
mise run infra:run-ansible-playbook playbooks/base-packages.yml
```

### Update Stack with Changes

After modifying `infrastructure.yaml`:

```bash
mise run infra:update-stack
```

### Re-deploy Everything

To ensure all components are current:

```bash
mise run deploy
```

The script is idempotent - safe to run multiple times.

## Teardown

To completely remove all infrastructure:

```bash
mise run teardown
```

This will:
1. Prompt for confirmation (type "yes" to proceed)
2. Delete State Manager associations
3. Delete Patch Manager resources (windows, baselines)
4. Empty S3 bucket
5. Delete CloudFormation stack (removes all resources)

**Note**: SES domain verifications are NOT deleted.

### Force Teardown (Skip Confirmation)

```bash
mise run teardown -- --force
```

### What Gets Deleted

| Resource Type | Deleted |
|--------------|---------|
| CloudFormation Stack | ✓ Yes |
| VPC and Networking | ✓ Yes (via stack) |
| EC2 Instance | ✓ Yes (via stack) |
| IAM Roles | ✓ Yes (via stack) |
| S3 Bucket | ✓ Yes (via stack) |
| SNS Topics | ✓ Yes (via stack) |
| CloudWatch Alarms | ✓ Yes (via stack) |
| State Manager Associations | ✓ Yes |
| Patch Manager Config | ✓ Yes |
| SES Domain Verification | ✗ No (manual) |

## Troubleshooting

### Stack Creation Fails

**Error**: Stack creation fails with "No updates are to be performed"

**Solution**: Stack already exists. Use update instead:
```bash
mise run infra:update-stack
```

---

**Error**: Template validation error

**Solution**: Validate template syntax:
```bash
aws cloudformation validate-template \
  --template-body file://infrastructure.yaml \
  --region us-east-2
```

### SSM Agent Not Registering

**Error**: "Timeout waiting for SSM Agent registration"

**Troubleshooting steps**:

1. **Check instance is running**:
```bash
INSTANCE_ID=$(aws cloudformation describe-stacks \
  --stack-name ${PROJECT_NAME}-Infrastructure \
  --region us-east-2 \
  --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue" \
  --output text)

aws ec2 describe-instances \
  --instance-ids $INSTANCE_ID \
  --region us-east-2 \
  --query 'Reservations[0].Instances[0].State.Name' \
  --output text
```

2. **Check console output for errors**:
```bash
aws ec2 get-console-output \
  --instance-id $INSTANCE_ID \
  --region us-east-2 \
  --output text
```

3. **Verify IAM role attached**:
```bash
aws ec2 describe-instances \
  --instance-ids $INSTANCE_ID \
  --region us-east-2 \
  --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn'
```

4. **Wait longer**: SSM registration can take 3-5 minutes on first boot.

### Playbook Execution Fails

**Error**: Playbook execution times out or fails

**Check execution status**:
```bash
# List recent SSM commands
aws ssm list-commands \
  --region us-east-2 \
  --max-items 5 \
  --query 'Commands[*].[CommandId,Status,DocumentName]' \
  --output table

# Get detailed output for a command
aws ssm get-command-invocation \
  --command-id <command-id> \
  --instance-id <instance-id> \
  --region us-east-2
```

**Common causes**:
- S3 bucket permissions: Verify IAM role has GetObject access
- Ansible syntax errors: Validate playbook locally with `ansible-lint`
- Network issues: Check VPC internet gateway and route table

### Patch Manager Not Configured

**Error**: Patch Manager skipped during deployment

**Cause**: EMAIL_ADDRESS not set in mise.toml

**Solution**:
Set EMAIL_ADDRESS in mise.toml and run:
```bash
mise run infra:configure-patch-manager
```

### Cannot SSH to Instance

**Error**: Connection timeout when SSHing

**Troubleshooting**:

1. **Verify your IP is allowed**:
```bash
aws ec2 describe-security-groups \
  --filters "Name=tag:Name,Values=${PROJECT_NAME}-SSH-SecurityGroup" \
  --region us-east-2 \
  --query 'SecurityGroups[0].IpPermissions[0].IpRanges[0].CidrIp'
```

2. **Update security group with current IP**:
```bash
mise run infra:update-stack
```

3. **Check instance has public IP**:
```bash
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=${PROJECT_NAME}-Instance" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --region us-east-2
```

4. **Verify SSH key**:
The instance uses SSH keys from https://github.com/geowa4.keys. Ensure your local SSH key matches.

## Manual Operations

### Configure SES Email

SES configuration is separate from infrastructure deployment.

**Verify domain**:
```bash
mise run ses:verify-domain ${DOMAIN_NAME}
```

**Complete guide**: See [docs/ses-setup.md](ses-setup.md) for comprehensive SES setup instructions.

### Run Individual Tasks

All tasks can be run independently:

```bash
# Update CloudFormation stack
mise run infra:update-stack

# Upload playbooks to S3
mise run infra:upload-playbooks

# Run specific playbook
mise run infra:run-ansible-playbook playbooks/hardening.yml

# Create State Manager association
mise run infra:create-ansible-association hardening.yml

# Configure Patch Manager
mise run infra:configure-patch-manager

# Verify SES domain
mise run ses:verify-domain ${DOMAIN_NAME}

# Test SES email
mise run ses:test-email -- \
  --from noreply@${DOMAIN_NAME} \
  --to test@example.com \
  --subject "Test" \
  --body "Test message"
```

## Architecture Details

### Security Model

**Network Security**:
- VPC isolated network (10.0.0.0/16)
- Public subnet for internet-facing instance
- Security group restricts SSH to single IP (parameterized)
- No inbound traffic except SSH

**IAM Security**:
- EC2 instance role with minimum required permissions:
  - AmazonSSMManagedInstanceCore (SSM access)
  - SES SendEmail (email sending)
  - S3 GetObject for playbooks bucket
- No AWS credentials stored on instance

**System Security** (via hardening playbook):
- SSH hardening: Root login disabled, password auth disabled
- Firewall: firewalld with drop zone, SSH allowed only
- Intrusion prevention: fail2ban with SSH jail

### IAM Permissions

The EC2 instance role (`${PROJECT_NAME}-EC2-SSM-SES-Role`) has:

1. **Managed Policy**: AmazonSSMManagedInstanceCore
   - Allows SSM agent communication
   - Enables Run Command, Session Manager, Patch Manager

2. **Inline Policy**: SESEmailPolicy
   - `ses:SendEmail`
   - `ses:SendRawEmail`
   - `ses:GetSendQuota`

3. **Inline Policy**: S3PlaybookAccessPolicy
   - `s3:GetObject` on playbooks bucket
   - `s3:ListBucket` on playbooks bucket

### Network Topology

```
VPC: 10.0.0.0/16 (us-east-2)
├── Public Subnet: 10.0.1.0/24 (us-east-2a)
│   └── EC2 Instance (dynamic private IP)
│       └── Elastic IP: (dynamic public IP)
├── Internet Gateway
└── Route Table
    └── Default Route: 0.0.0.0/0 → Internet Gateway
```

### CloudFormation Outputs

The stack provides these outputs for scripting:

| Output Key | Description | Used By |
|------------|-------------|---------|
| AnsiblePlaybooksBucketName | S3 bucket name | upload-playbooks.sh, run-ansible-playbook.sh |
| AnsiblePlaybooksBucketArn | S3 bucket ARN | IAM policies |
| InstanceId | EC2 instance ID | All SSM scripts |
| SESBouncesTopicArn | SNS topic for bounces | SES configuration |
| SESComplaintsTopicArn | SNS topic for complaints | SES configuration |

## Quick Reference

### Common Commands

```bash
# Deploy everything
mise run deploy

# Update SSH IP
mise run infra:update-stack

# Run playbook
mise run infra:run-ansible-playbook playbooks/hardening.yml

# Check stack status
aws cloudformation describe-stacks \
  --stack-name ${PROJECT_NAME}-Infrastructure \
  --region us-east-2

# Get instance IP
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=${PROJECT_NAME}-Instance" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text \
  --region us-east-2

# SSH to instance
ssh ec2-user@$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=${PROJECT_NAME}-Instance" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text \
  --region us-east-2)

# Check SSM agent
aws ssm describe-instance-information --region us-east-2

# View playbook execution history
aws ssm list-commands \
  --region us-east-2 \
  --filters "Key=DocumentName,Values=AWS-ApplyAnsiblePlaybooks" \
  --max-items 10

# Teardown everything
mise run teardown
```

### File Locations

```
<project-directory>/
├── infrastructure.yaml          # CloudFormation template
├── .mise/
│   └── tasks/                   # Mise task definitions
│       ├── deploy               # Master deployment task
│       ├── teardown             # Cleanup task
│       ├── infra/               # Infrastructure tasks
│       └── ses/                 # SES tasks
├── playbooks/
│   ├── hardening.yml            # System hardening
│   └── base-packages.yml        # Development tools
└── docs/
    ├── deployment-guide.md      # This file
    ├── ses-setup.md             # SES configuration guide
    └── ses-production-checklist.md  # Production access prep
```

### AWS Console Links

- [CloudFormation Console](https://us-east-2.console.aws.amazon.com/cloudformation)
- [EC2 Instances](https://us-east-2.console.aws.amazon.com/ec2/v2/home?region=us-east-2#Instances)
- [Systems Manager Fleet Manager](https://us-east-2.console.aws.amazon.com/systems-manager/managed-instances)
- [Systems Manager Run Command](https://us-east-2.console.aws.amazon.com/systems-manager/run-command)
- [Systems Manager State Manager](https://us-east-2.console.aws.amazon.com/systems-manager/state-manager)
- [Systems Manager Patch Manager](https://us-east-2.console.aws.amazon.com/systems-manager/patch-manager)
- [SES Console](https://us-east-2.console.aws.amazon.com/ses)
- [S3 Buckets](https://s3.console.aws.amazon.com/s3/buckets?region=us-east-2)
