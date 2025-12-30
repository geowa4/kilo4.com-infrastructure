# Deployment Guide

This guide covers deploying and managing the complete kilo4.com infrastructure on AWS.

## Overview

The kilo4 infrastructure consists of:

- **Region**: us-east-2
- **Stack Name**: kilo4-Infrastructure
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
cd /path/to/kilo4.com

# Deploy everything (including patch notifications)
./scripts/deploy.sh your-email@example.com

# Or deploy without patch manager
./scripts/deploy.sh
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
git clone https://github.com/geowa4/kilo4.com.git
cd kilo4.com
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
./scripts/deploy.sh admin@example.com
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
  --stack-name kilo4-Infrastructure \
  --region us-east-2 \
  --query 'Stacks[0].StackStatus' \
  --output text

# Expected: CREATE_COMPLETE or UPDATE_COMPLETE

# List all resources
aws cloudformation describe-stack-resources \
  --stack-name kilo4-Infrastructure \
  --region us-east-2 \
  --output table
```

### Verify EC2 Instance

```bash
# Get instance ID and status
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=kilo4-Instance" "Name=instance-state-name,Values=running" \
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
  --stack-name kilo4-Infrastructure \
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
  --query 'Associations[?starts_with(AssociationName, `kilo4-`)].[AssociationName,Status.Name]' \
  --output table

# Expected: kilo4-ansible-hardening with Success status
```

### Verify SSH Access

```bash
# Get public IP
PUBLIC_IP=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=kilo4-Instance" "Name=instance-state-name,Values=running" \
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
./scripts/infra/update-stack.sh
```

This automatically:
- Fetches your current public IP
- Updates CloudFormation stack
- Updates security group rules

### Re-run Ansible Playbooks

To manually apply playbooks:

```bash
# System hardening
./scripts/infra/run-ansible-playbook.sh playbooks/hardening.yml

# Base packages
./scripts/infra/run-ansible-playbook.sh playbooks/base-packages.yml
```

### Update Stack with Changes

After modifying `infrastructure.yaml`:

```bash
./scripts/infra/update-stack.sh
```

### Re-deploy Everything

To ensure all components are current:

```bash
./scripts/deploy.sh your-email@example.com
```

The script is idempotent - safe to run multiple times.

## Teardown

To completely remove all infrastructure:

```bash
./scripts/teardown.sh
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
./scripts/teardown.sh --force
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
./scripts/infra/update-stack.sh
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
  --stack-name kilo4-Infrastructure \
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

**Cause**: Email address not provided to deploy.sh

**Solution**:
```bash
./scripts/infra/configure-patch-manager.sh your-email@example.com
```

### Cannot SSH to Instance

**Error**: Connection timeout when SSHing

**Troubleshooting**:

1. **Verify your IP is allowed**:
```bash
aws ec2 describe-security-groups \
  --filters "Name=tag:Name,Values=kilo4-SSH-SecurityGroup" \
  --region us-east-2 \
  --query 'SecurityGroups[0].IpPermissions[0].IpRanges[0].CidrIp'
```

2. **Update security group with current IP**:
```bash
./scripts/infra/update-stack.sh
```

3. **Check instance has public IP**:
```bash
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=kilo4-Instance" \
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
./scripts/ses/verify-domain.sh kilo4.com
```

**Complete guide**: See [docs/ses-setup.md](ses-setup.md) for comprehensive SES setup instructions.

### Run Individual Scripts

All deployment scripts can be run independently:

```bash
# Update CloudFormation stack
./scripts/infra/update-stack.sh

# Upload playbooks to S3
./scripts/infra/upload-playbooks.sh

# Run specific playbook
./scripts/infra/run-ansible-playbook.sh playbooks/hardening.yml

# Create State Manager association
./scripts/infra/create-ansible-association.sh hardening.yml

# Configure Patch Manager
./scripts/infra/configure-patch-manager.sh admin@example.com

# Verify SES domain
./scripts/ses/verify-domain.sh kilo4.com

# Test SES email
python3 scripts/ses/test-email.py \
  --from noreply@kilo4.com \
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

The EC2 instance role (`kilo4-EC2-SSM-SES-Role`) has:

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
./scripts/deploy.sh admin@example.com

# Update SSH IP
./scripts/infra/update-stack.sh

# Run playbook
./scripts/infra/run-ansible-playbook.sh playbooks/hardening.yml

# Check stack status
aws cloudformation describe-stacks \
  --stack-name kilo4-Infrastructure \
  --region us-east-2

# Get instance IP
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=kilo4-Instance" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text \
  --region us-east-2

# SSH to instance
ssh ec2-user@$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=kilo4-Instance" "Name=instance-state-name,Values=running" \
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
./scripts/teardown.sh
```

### File Locations

```
kilo4.com/
├── infrastructure.yaml          # CloudFormation template
├── scripts/
│   ├── deploy.sh                # Master deployment script
│   ├── teardown.sh              # Cleanup script
│   ├── update-stack.sh          # Update stack with current IP
│   ├── upload-playbooks.sh      # Upload playbooks to S3
│   ├── run-ansible-playbook.sh  # Execute playbook via SSM
│   ├── create-ansible-association.sh  # State Manager setup
│   ├── configure-patch-manager.sh     # Patch Manager setup
│   ├── verify-ses-domain.sh     # Verify SES domain
│   ├── verify-ses-identity.sh   # Verify SES email
│   └── test-ses-email.py        # Send test email
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
