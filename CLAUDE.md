# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repository contains AWS infrastructure-as-code for deploying a VPC, EC2 instance, and related services in us-east-2. The infrastructure uses CloudFormation for deployment and AWS Systems Manager (SSM) for agentless Ansible management.

## Core Architecture

**Infrastructure Model**: Single CloudFormation template (`infrastructure.yaml`) that defines:
- VPC with public subnet and internet gateway
- EC2 instance (t4g.small ARM-based) with IAM role for SSM and SES
- Security group restricting SSH to a single parameterized IP
- SSH key provisioning from GitHub (https://github.com/geowa4.keys) via UserData

**Management Pattern**: AWS Systems Manager provides agentless configuration management. The `AWS-ApplyAnsiblePlaybooks` SSM document executes playbooks without a dedicated Ansible control node—SSM downloads playbooks from S3, installs Ansible on the target instance, and executes locally.

**Region**: All resources are in us-east-2

## CloudFormation Commands

### Validate template
```bash
aws cloudformation validate-template --template-body file://infrastructure.yaml --region us-east-2
```

### Deploy stack (use update-stack for existing stack)
```bash
aws cloudformation update-stack \
  --stack-name kilo4-Infrastructure \
  --template-body file://infrastructure.yaml \
  --parameters ParameterKey=SSHAllowedIP,ParameterValue=<IP>/32 \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-east-2
```

### Wait for stack completion
```bash
aws cloudformation wait stack-update-complete --stack-name kilo4-Infrastructure --region us-east-2
```

## EC2 Instance Details

- **Instance Type**: t4g.small (ARM-based Graviton)
- **AMI**: Dynamically resolved via SSM parameter `/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64`
- **SSH Access**: GitHub user `geowa4`'s public keys are automatically provisioned
- **IAM Role**: Includes `AmazonSSMManagedInstanceCore` and SES sending permissions

### Get instance public IP
```bash
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=kilo4-Instance" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text \
  --region us-east-2
```

## Task Management

Tasks are organized in `tasks/` directory:
- `tasks/todo/` - Pending tasks with requirements and acceptance criteria
- `tasks/done/` - Completed tasks (moved from todo after completion)
- `tasks/dev-plan.md` - Master implementation guide with detailed technical documentation

When completing a task, move it from `tasks/todo/` to `tasks/done/`.
Never commit tasks.

## Systems Manager Integration

### Execute Ansible playbook via SSM Run Command
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
  --targets "Key=tag:Name,Values=kilo4-Instance" \
  --parameters '{...}' \
  --schedule-expression "rate(1 day)" \
  --region us-east-2
```

## Important Constraints

- **ARM Architecture**: Instance uses t4g (Graviton), so always use ARM64 AMIs and binaries
- **Security**: SSH restricted to single IP via SSHAllowedIP parameter
- **No Key Pairs**: SSH keys come exclusively from GitHub (geowa4 user)
- **SSM Agent**: Pre-installed on Amazon Linux 2023, no manual installation needed
- **DependsOn**: The PublicRoute resource requires `DependsOn: VPCGatewayAttachment` to ensure proper creation order
