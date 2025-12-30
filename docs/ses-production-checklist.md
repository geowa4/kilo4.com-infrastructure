# SES Production Access Checklist

This checklist helps ensure all prerequisites are met before requesting Amazon SES production access.

## Overview

Production access removes sandbox limitations and allows sending to any email address. AWS typically approves requests within 24-72 hours. Initial production limits are:
- **Daily sending limit**: 50,000 emails
- **Rate limit**: 14 emails per second

Both limits can be increased further by submitting support requests.

## Prerequisites Checklist

### 1. Domain Identity Verification

**Status**: Verify domain is confirmed in SES

```bash
# Check domain verification status
aws ses get-identity-verification-attributes \
    --identities kilo4.com \
    --region us-east-2 \
    --output json | \
    jq -r '.VerificationAttributes["kilo4.com"].VerificationStatus'
```

**Expected Output**: `Success`

**If not verified**:
```bash
./scripts/ses/verify-domain.sh kilo4.com
```

### 2. DKIM Configuration

**Status**: Verify DKIM is enabled and verified

```bash
# Check DKIM status
aws ses get-identity-dkim-attributes \
    --identities kilo4.com \
    --region us-east-2 \
    --output json | \
    jq '.DkimAttributes["kilo4.com"]'
```

**Expected Output**:
```json
{
  "DkimEnabled": true,
  "DkimVerificationStatus": "Success"
}
```

**If not enabled**:
```bash
./scripts/ses/verify-domain.sh kilo4.com
```

### 3. SPF Record Configuration

**Status**: Verify SPF record includes Amazon SES

```bash
# Check SPF record
dig TXT kilo4.com +short | grep spf
```

**Expected Output**: Should include `include:amazonses.com` or similar

**Recommended SPF Record**:
```
v=spf1 include:amazonses.com ~all
```

Add this TXT record to your domain's DNS if not present.

### 4. Bounce Handling Setup

**Status**: Configure SNS topics for bounce notifications

AWS requires a mechanism to handle bounced emails to maintain sender reputation.

The SNS topic for bounces is managed in CloudFormation (`infrastructure.yaml`). Get the topic ARN from stack outputs:

```bash
# Get the bounce topic ARN from CloudFormation stack
BOUNCE_TOPIC_ARN=$(aws cloudformation describe-stacks \
    --stack-name kilo4-Infrastructure \
    --region us-east-2 \
    --query 'Stacks[0].Outputs[?OutputKey==`SESBouncesTopicArn`].OutputValue' \
    --output text)

echo "Bounce Topic ARN: $BOUNCE_TOPIC_ARN"
```

#### Configure SES to Publish Bounces

```bash
# Set bounce notification topic (use the ARN from above)
aws ses set-identity-notification-topic \
    --identity kilo4.com \
    --notification-type Bounce \
    --sns-topic "$BOUNCE_TOPIC_ARN" \
    --region us-east-2
```

#### Subscribe to Bounce Notifications

Option 1: Email subscription (simple for low volume)
```bash
aws sns subscribe \
    --topic-arn "$BOUNCE_TOPIC_ARN" \
    --protocol email \
    --notification-endpoint your-email@example.com \
    --region us-east-2
```

Option 2: HTTPS endpoint (for automated processing)
```bash
aws sns subscribe \
    --topic-arn "$BOUNCE_TOPIC_ARN" \
    --protocol https \
    --notification-endpoint https://your-domain.com/ses/bounces \
    --region us-east-2
```

### 5. Complaint Handling Setup

**Status**: Configure SNS topics for complaint notifications

Handle spam complaints to maintain sender reputation and comply with AWS requirements.

The SNS topic for complaints is managed in CloudFormation (`infrastructure.yaml`). Get the topic ARN from stack outputs:

```bash
# Get the complaint topic ARN from CloudFormation stack
COMPLAINT_TOPIC_ARN=$(aws cloudformation describe-stacks \
    --stack-name kilo4-Infrastructure \
    --region us-east-2 \
    --query 'Stacks[0].Outputs[?OutputKey==`SESComplaintsTopicArn`].OutputValue' \
    --output text)

echo "Complaint Topic ARN: $COMPLAINT_TOPIC_ARN"
```

#### Configure SES to Publish Complaints

```bash
# Set complaint notification topic (use the ARN from above)
aws ses set-identity-notification-topic \
    --identity kilo4.com \
    --notification-type Complaint \
    --sns-topic "$COMPLAINT_TOPIC_ARN" \
    --region us-east-2
```

#### Subscribe to Complaint Notifications

```bash
aws sns subscribe \
    --topic-arn "$COMPLAINT_TOPIC_ARN" \
    --protocol email \
    --notification-endpoint your-email@example.com \
    --region us-east-2
```

### 6. Website and Business Legitimacy

**Status**: Ensure you have a legitimate business use case

AWS reviews production access requests to prevent spam. Be prepared to demonstrate:

- **Live website**: https://kilo4.com should be accessible
- **Contact information**: Website should have visible contact details
- **Privacy policy**: If collecting email addresses
- **Terms of service**: If applicable
- **Clear purpose**: Explain what emails you'll send and why

### 7. Use Case Description

**Status**: Prepare a detailed use case description

For **transactional emails**, describe:

```
We use Amazon SES to send transactional emails from our website kilo4.com.
These include:
- User account notifications
- Password reset emails
- System alerts and status updates
- Service-related communications

All emails are sent only to users who have registered on our platform or
requested specific notifications. We have implemented bounce and complaint
handling via SNS topics to maintain list hygiene and sender reputation.

We maintain a bounce rate below 5% and complaint rate below 0.1% through:
- Double opt-in for new subscribers
- Easy unsubscribe mechanism in all emails
- Regular list cleaning based on bounce/complaint data
- Authentication with DKIM and SPF
```

Customize this template for your specific use case.

## Monitoring Setup

### CloudWatch Metrics and Alarms

CloudWatch alarms for bounce and complaint rates are managed in CloudFormation (`infrastructure.yaml`):

- **Bounce Rate Alarm**: Triggers when bounce rate exceeds 5%
- **Complaint Rate Alarm**: Triggers when complaint rate exceeds 0.1%

These alarms are automatically created when the CloudFormation stack is deployed.

### View Sending Statistics

```bash
# View current sending statistics
aws ses get-send-statistics --region us-east-2

# Check reputation metrics
aws sesv2 get-account --region us-east-2
```

### Check Alarm Status

```bash
# Check if any alarms are triggered
aws cloudwatch describe-alarms \
    --alarm-names kilo4-ses-high-bounce-rate kilo4-ses-high-complaint-rate \
    --region us-east-2
```

## Ready to Request Production Access?

Once all prerequisites are complete:

1. Verify domain and DKIM are both showing "Success"
2. SPF record is configured
3. Bounce SNS topic is created and configured
4. Complaint SNS topic is created and configured
5. Website is live and legitimate
6. Use case description is prepared

Run the production access request script:

```bash
./scripts/ses/request-production.sh \
    --use-case "Transactional emails for kilo4.com user notifications and system alerts"
```

## Post-Approval Steps

After AWS approves production access:

### 1. Verify Production Status

```bash
# Check account status
aws sesv2 get-account --region us-east-2 | \
    jq '.ProductionAccessEnabled'
```

Expected: `true`

### 2. Verify Increased Limits

```bash
# Check new sending quota
aws ses get-send-quota --region us-east-2
```

Expected output shows higher limits:
```json
{
    "Max24HourSend": 50000.0,
    "MaxSendRate": 14.0,
    "SentLast24Hours": 0.0
}
```

### 3. Test Sending to Unverified Address

```bash
# Send to any email address (no longer restricted to verified addresses)
python3 scripts/ses/test-email.py \
    --from noreply@kilo4.com \
    --to any-recipient@example.com \
    --subject "Production Test" \
    --body "Testing production access"
```

### 4. Monitor Reputation Metrics

Set up regular monitoring:

```bash
# Weekly reputation check (add to cron)
aws sesv2 get-account --region us-east-2 | \
    jq '.SendingEnabled, .ProductionAccessEnabled'
```

### 5. Request Higher Limits (if needed)

If you need more than 50,000/day or 14/second:

1. Go to AWS Support Center
2. Create case: Service Limit Increase
3. Select: SES Sending Limits
4. Specify desired limits and justification

## Important Reminders

- **Bounce rate**: Keep below 5% to avoid account suspension
- **Complaint rate**: Keep below 0.1% to maintain reputation
- **List hygiene**: Remove addresses that hard bounce
- **Authentication**: Always use DKIM and SPF
- **Monitoring**: Regularly check reputation dashboard
- **Compliance**: Follow CAN-SPAM and GDPR requirements

## Additional Resources

- [SES Production Access FAQ](https://docs.aws.amazon.com/ses/latest/dg/request-production-access.html)
- [SES Reputation Dashboard](https://docs.aws.amazon.com/ses/latest/dg/reputation-dashboard-dg.html)
- [Handling Bounces and Complaints](https://docs.aws.amazon.com/ses/latest/dg/monitor-sending-activity.html)
- [SES Best Practices](https://docs.aws.amazon.com/ses/latest/dg/best-practices.html)
