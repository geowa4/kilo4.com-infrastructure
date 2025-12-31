# Amazon SES Setup Guide

This guide covers setting up Amazon Simple Email Service (SES) for sending emails from the infrastructure.

## Overview

Amazon SES is a cloud-based email sending service that provides a reliable, cost-effective way to send transactional and marketing emails. This setup uses:
- **Region**: us-east-2
- **Sender**: noreply@${DOMAIN_NAME}
- **Domain**: ${DOMAIN_NAME}
- **Sending Methods**: Both API (boto3) and SMTP

## SES Sandbox Mode

### What is Sandbox Mode?

All new SES accounts start in sandbox mode with the following limitations:

- **Daily sending limit**: 200 emails per 24-hour period
- **Rate limit**: 1 email per second
- **Recipient restrictions**: Can only send to verified email addresses and domains
- **Sender restrictions**: All sender addresses must be verified

### Sandbox vs Production

| Feature | Sandbox Mode | Production Access |
|---------|--------------|-------------------|
| Daily limit | 200 emails | 50,000+ (adjustable) |
| Rate limit | 1/second | 14/second (adjustable) |
| Recipients | Verified only | Any email address |
| Use case | Testing | Production workloads |

### Requesting Production Access

Once you've tested your email sending and are ready for production:

1. Go to the [SES Console](https://console.aws.amazon.com/ses/)
2. Navigate to "Account dashboard"
3. Click "Request production access"
4. Provide details about your use case:
   - Email types you'll send (transactional, marketing, etc.)
   - How you handle bounces and complaints
   - Estimated sending volume
   - Your process for managing email lists

Review typically takes 24-48 hours.

## Email Identity Verification

### Verify Email Addresses

Use the mise task to verify sender and recipient email addresses:

```bash
# Verify sender email
mise run ses:verify-identity noreply@${DOMAIN_NAME}

# Verify additional recipient emails (for sandbox testing)
mise run ses:verify-identity noreply@${DOMAIN_NAME} test@example.com
```

What happens:
1. Script sends verification request to SES
2. Amazon sends an email with a verification link to each address
3. Click the link in each email to verify
4. Re-run the script to check verification status

### Verify Domain with DKIM

Domain verification is recommended for better deliverability and required before requesting production access:

```bash
mise run ses:verify-domain ${DOMAIN_NAME}
```

The task will output DNS records you need to add to your domain:

#### Domain Verification Record
```
Name:  _amazonses.${DOMAIN_NAME}
Type:  TXT
Value: <verification-token>
```

#### DKIM Records (3 CNAME records)
```
Name:  <token1>._domainkey.${DOMAIN_NAME}
Type:  CNAME
Value: <token1>.dkim.amazonses.com

Name:  <token2>._domainkey.${DOMAIN_NAME}
Type:  CNAME
Value: <token2>.dkim.amazonses.com

Name:  <token3>._domainkey.${DOMAIN_NAME}
Type:  CNAME
Value: <token3>.dkim.amazonses.com
```

### DNS Propagation

After adding DNS records:
- Propagation typically takes 15-30 minutes
- Can take up to 72 hours in rare cases
- Check propagation status:
  ```bash
  dig TXT _amazonses.${DOMAIN_NAME} +short
  dig CNAME <token>._domainkey.${DOMAIN_NAME} +short
  ```

### Why DKIM?

DKIM (DomainKeys Identified Mail) provides:
- **Authentication**: Proves emails actually come from your domain
- **Deliverability**: Reduces likelihood of being marked as spam
- **Reputation**: Builds trust with email providers
- **Required for production**: AWS requires DKIM for production access

## Sending Methods

### API Sending (Recommended)

The mise task uses boto3 to send via the SES API:

```bash
mise run ses:test-email -- \
    --from noreply@${DOMAIN_NAME} \
    --to recipient@example.com \
    --subject "Test Email" \
    --body "This is a test email from Amazon SES"
```

#### Advantages of API
- Simpler authentication (uses IAM roles)
- Better error handling and response details
- No port/firewall concerns
- Easier to integrate with Python applications

#### IAM Permissions Required
The EC2 instance role includes these SES permissions:
```json
{
    "Effect": "Allow",
    "Action": [
        "ses:SendEmail",
        "ses:SendRawEmail"
    ],
    "Resource": "*"
}
```

### SMTP Sending

SES also provides SMTP endpoints for applications that require SMTP:

#### SMTP Endpoint Details
- **Server**: email-smtp.us-east-2.amazonaws.com
- **Port 587**: TLS (STARTTLS) - Recommended
- **Port 465**: TLS Wrapper
- **Port 25**: Throttled by AWS (not recommended)

#### SMTP Credentials

SMTP credentials are different from AWS access keys:

```bash
# Create SMTP credentials via AWS Console:
# 1. Go to SES Console > SMTP Settings
# 2. Click "Create My SMTP Credentials"
# 3. Save the username and password securely
```

Or via AWS CLI:
```bash
aws iam create-user --user-name ses-smtp-user
aws iam create-access-key --user-name ses-smtp-user
# Use the access key ID and secret to derive SMTP password
# (requires special conversion process - use Console instead)
```

#### Port Considerations

| Port | Protocol | Status | Notes |
|------|----------|--------|-------|
| 25 | SMTP | ⚠️ Throttled | AWS EC2 throttles port 25 by default |
| 587 | STARTTLS | ✅ Recommended | Most compatible, good security |
| 465 | TLS Wrapper | ✅ Supported | Also secure, less common |
| 2587 | STARTTLS | ✅ Alternative | If 587 is blocked |

**Best Practice**: Use port 587 with STARTTLS encryption.

#### Example: Python with SMTP

```python
import smtplib
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart

# SMTP configuration
smtp_server = "email-smtp.us-east-2.amazonaws.com"
smtp_port = 587
smtp_username = "<SMTP_USERNAME>"
smtp_password = "<SMTP_PASSWORD>"

# Email content
sender = "noreply@${DOMAIN_NAME}"
recipient = "recipient@example.com"
subject = "Test Email via SMTP"

msg = MIMEMultipart()
msg['From'] = sender
msg['To'] = recipient
msg['Subject'] = subject
msg.attach(MIMEText("This is a test email via SMTP", 'plain'))

# Send email
with smtplib.SMTP(smtp_server, smtp_port) as server:
    server.starttls()
    server.login(smtp_username, smtp_password)
    server.send_message(msg)
```

## Testing Email Sending

### Pre-flight Checks

Before sending test emails:

```bash
# 1. Verify identities are confirmed
mise run ses:verify-identity noreply@${DOMAIN_NAME}

# 2. Check sending quota
aws ses get-send-quota --region us-east-2

# 3. Verify account is enabled for sending
aws ses get-account-sending-enabled --region us-east-2
```

### Send Test Email

```bash
# Simple text email
mise run ses:test-email -- \
    --from noreply@${DOMAIN_NAME} \
    --to your-email@example.com \
    --subject "SES Test Email" \
    --body "This is a test email to verify SES is working correctly."

# HTML email
mise run ses:test-email -- \
    --from noreply@${DOMAIN_NAME} \
    --to your-email@example.com \
    --subject "SES HTML Test" \
    --body "Plain text version" \
    --html "<h1>HTML Version</h1><p>This is the HTML version of the email.</p>"
```

### Troubleshooting

#### Error: Email address is not verified
```
❌ Error: Email address not verified
```
**Solution**: Verify the email address:
```bash
mise run ses:verify-identity noreply@${DOMAIN_NAME} recipient@example.com
```

#### Error: Daily sending quota exceeded
```
❌ Error: Daily message quota exceeded
```
**Solution**: Wait 24 hours or request production access to increase limits.

#### Error: No credentials found
```
❌ Error: AWS credentials not found
```
**Solution**:
- On EC2: Ensure instance has IAM role with SES permissions
- Locally: Configure AWS CLI or set environment variables

## Monitoring and Best Practices

### Monitor Bounce and Complaint Rates

High bounce/complaint rates can damage your reputation:

```bash
# Check sending statistics
aws ses get-send-statistics --region us-east-2

# View reputation metrics
aws sesv2 get-account --region us-east-2
```

**Acceptable rates**:
- Bounce rate: < 5%
- Complaint rate: < 0.1%

### Handle Bounces and Complaints

Set up SNS topics to receive notifications:
1. Hard bounces (invalid addresses)
2. Soft bounces (temporary failures)
3. Complaints (spam reports)

Remove addresses that hard bounce or complain from your mailing lists.

### Email Best Practices

1. **Authentication**: Always use DKIM and SPF
2. **Opt-in**: Only send to users who subscribed
3. **Unsubscribe**: Provide easy unsubscribe links
4. **Content**: Avoid spam trigger words and all-caps
5. **Frequency**: Don't overwhelm recipients
6. **From address**: Use consistent, recognizable sender

### Cost Optimization

SES pricing (as of 2024):
- **API/SMTP**: $0.10 per 1,000 emails sent
- **Free tier**: 62,000 emails/month when called from EC2

Monitor usage:
```bash
aws ce get-cost-and-usage \
    --time-period Start=2024-01-01,End=2024-01-31 \
    --granularity MONTHLY \
    --metrics BlendedCost \
    --filter file://ses-filter.json
```

## Integration with EC2

The EC2 instance has the SES permissions via its IAM role, allowing email sending without credential management.

## Additional Resources

- [SES Developer Guide](https://docs.aws.amazon.com/ses/latest/dg/)
- [SES API Reference](https://docs.aws.amazon.com/ses/latest/APIReference/)
- [boto3 SES Documentation](https://boto3.amazonaws.com/v1/documentation/api/latest/reference/services/ses.html)
- [Email Authentication Best Practices](https://docs.aws.amazon.com/ses/latest/dg/send-email-authentication-dmarc.html)

## Quick Reference

```bash
# Verify email address
mise run ses:verify-identity noreply@${DOMAIN_NAME}

# Verify domain with DKIM
mise run ses:verify-domain ${DOMAIN_NAME}

# Send test email
mise run ses:test-email -- \
    --from noreply@${DOMAIN_NAME} \
    --to recipient@example.com \
    --subject "Test" \
    --body "Test email"

# Check quota
aws ses get-send-quota --region us-east-2

# Check verification status
aws ses list-identities --region us-east-2
aws ses get-identity-verification-attributes \
    --identities noreply@${DOMAIN_NAME} \
    --region us-east-2
```
