# kilo4.com Infrastructure

AWS infrastructure for kilo4.com using CloudFormation in us-east-2.

## Deploy

```bash
aws cloudformation update-stack \
  --stack-name kilo4-Infrastructure \
  --template-body file://infrastructure.yaml \
  --parameters ParameterKey=SSHAllowedIP,ParameterValue=YOUR.IP/32 \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-east-2
```

## Connect

```bash
# Get instance IP
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=kilo4-Instance" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text \
  --region us-east-2

# SSH
ssh ec2-user@<INSTANCE_IP>
```

## Stack Contents

- VPC with public subnet
- t4g.small EC2 instance (Amazon Linux 2023 ARM64)
- IAM role with SSM and SES permissions
- Security group (SSH from single IP)
- GitHub SSH key provisioning (geowa4)
