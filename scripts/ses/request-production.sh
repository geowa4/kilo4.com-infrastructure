#!/bin/bash
# Request Amazon SES production access
# Usage: ./request-ses-production.sh --use-case "description" [--website-url URL] [--contact-email EMAIL]

set -euo pipefail

REGION="us-east-2"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
WEBSITE_URL="https://kilo4.com"
CONTACT_EMAIL="noreply@kilo4.com"
USE_CASE=""

usage() {
    echo "Usage: $0 --use-case \"description\" [options]"
    echo ""
    echo "Required:"
    echo "  --use-case DESCRIPTION    Detailed description of your email use case"
    echo ""
    echo "Optional:"
    echo "  --website-url URL         Website URL (default: https://kilo4.com)"
    echo "  --contact-email EMAIL     Additional contact email (default: noreply@kilo4.com)"
    echo ""
    echo "Example:"
    echo "  $0 --use-case \"Transactional emails for user notifications and system alerts\""
    echo ""
    echo "  $0 --use-case \"Send password reset and account notifications\" \\"
    echo "     --website-url https://kilo4.com \\"
    echo "     --contact-email admin@kilo4.com"
    echo ""
    echo "This script will:"
    echo "  1. Submit production access request to AWS"
    echo "  2. Check current account status"
    echo "  3. Display next steps"
    echo ""
    echo "Prerequisites:"
    echo "  - Domain verified with DKIM"
    echo "  - SPF record configured"
    echo "  - Bounce/complaint handling set up"
    echo "  - Run: docs/ses-production-checklist.md for full checklist"
    exit 1
}

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --use-case)
            USE_CASE="$2"
            shift 2
            ;;
        --website-url)
            WEBSITE_URL="$2"
            shift 2
            ;;
        --contact-email)
            CONTACT_EMAIL="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo -e "${RED}Error: Unknown option $1${NC}"
            echo ""
            usage
            ;;
    esac
done

# Validate required arguments
if [ -z "$USE_CASE" ]; then
    echo -e "${RED}Error: --use-case is required${NC}"
    echo ""
    usage
fi

echo "Amazon SES Production Access Request"
echo "Region: $REGION"
echo "Website: $WEBSITE_URL"
echo "Contact Email: $CONTACT_EMAIL"
echo "========================================"
echo ""

# Step 1: Check current account status
echo -e "${YELLOW}Step 1: Checking current account status...${NC}"
echo ""

CURRENT_STATUS=$(aws sesv2 get-account --region "$REGION" --output json 2>/dev/null || echo "{}")

if [ -n "$CURRENT_STATUS" ] && [ "$CURRENT_STATUS" != "{}" ]; then
    PRODUCTION_ENABLED=$(echo "$CURRENT_STATUS" | jq -r '.ProductionAccessEnabled // false')
    SENDING_ENABLED=$(echo "$CURRENT_STATUS" | jq -r '.SendingEnabled // false')

    echo "Current Account Status:"
    echo "  Production Access: $PRODUCTION_ENABLED"
    echo "  Sending Enabled: $SENDING_ENABLED"
    echo ""

    if [ "$PRODUCTION_ENABLED" = "true" ]; then
        echo -e "${GREEN}✓ Production access is already enabled!${NC}"
        echo ""
        echo "Current sending quota:"
        aws ses get-send-quota --region "$REGION" 2>/dev/null || echo "Unable to retrieve quota"
        echo ""
        exit 0
    fi
else
    echo -e "${YELLOW}⧗ Unable to retrieve current status (continuing anyway)${NC}"
    echo ""
fi

# Step 2: Verify prerequisites
echo -e "${YELLOW}Step 2: Verifying prerequisites...${NC}"
echo ""

# Check domain verification
DOMAIN="kilo4.com"
DOMAIN_STATUS=$(aws ses get-identity-verification-attributes \
    --identities "$DOMAIN" \
    --region "$REGION" \
    --output json 2>/dev/null | \
    jq -r ".VerificationAttributes[\"$DOMAIN\"].VerificationStatus // \"Unknown\"")

if [ "$DOMAIN_STATUS" = "Success" ]; then
    echo -e "  ${GREEN}✓ Domain verified: $DOMAIN${NC}"
else
    echo -e "  ${RED}✗ Domain not verified: $DOMAIN (Status: $DOMAIN_STATUS)${NC}"
    echo ""
    echo -e "${RED}ERROR: Domain must be verified before requesting production access${NC}"
    echo "Run: ./scripts/verify-ses-domain.sh $DOMAIN"
    exit 1
fi

# Check DKIM
DKIM_STATUS=$(aws ses get-identity-dkim-attributes \
    --identities "$DOMAIN" \
    --region "$REGION" \
    --output json 2>/dev/null | \
    jq -r ".DkimAttributes[\"$DOMAIN\"].DkimVerificationStatus // \"Unknown\"")

if [ "$DKIM_STATUS" = "Success" ]; then
    echo -e "  ${GREEN}✓ DKIM verified: $DOMAIN${NC}"
else
    echo -e "  ${YELLOW}⚠ DKIM status: $DKIM_STATUS${NC}"
    echo -e "  ${YELLOW}  (DKIM is recommended but not strictly required)${NC}"
fi

echo ""

# Step 3: Submit production access request
echo "=================================================="
echo -e "${YELLOW}Step 3: Submitting production access request...${NC}"
echo ""

# Use sesv2 API to request production access
REQUEST_RESULT=$(aws sesv2 put-account-details \
    --production-access-enabled \
    --mail-type TRANSACTIONAL \
    --website-url "$WEBSITE_URL" \
    --use-case-description "$USE_CASE" \
    --additional-contact-email-addresses "$CONTACT_EMAIL" \
    --contact-language EN \
    --region "$REGION" \
    --output json 2>&1)

REQUEST_EXIT_CODE=$?

if [ $REQUEST_EXIT_CODE -eq 0 ]; then
    echo -e "${GREEN}✓ Production access request submitted successfully${NC}"
    echo ""
    echo "Request Details:"
    echo "  Mail Type: TRANSACTIONAL"
    echo "  Website: $WEBSITE_URL"
    echo "  Contact Email: $CONTACT_EMAIL"
    echo "  Use Case: $USE_CASE"
    echo ""
else
    # Check if it's already under review
    if echo "$REQUEST_RESULT" | grep -q "AlreadyExistsException\|request is already being processed"; then
        echo -e "${YELLOW}⧗ Production access request is already under review${NC}"
        echo ""
    else
        echo -e "${RED}✗ Failed to submit production access request${NC}"
        echo ""
        echo "Error details:"
        echo "$REQUEST_RESULT"
        echo ""
        exit 1
    fi
fi

# Step 4: Check request status
echo "=================================================="
echo -e "${YELLOW}Step 4: Checking request status...${NC}"
echo ""

# Wait a moment for API consistency
sleep 2

NEW_STATUS=$(aws sesv2 get-account --region "$REGION" --output json 2>/dev/null || echo "{}")

if [ -n "$NEW_STATUS" ] && [ "$NEW_STATUS" != "{}" ]; then
    REVIEW_DETAILS=$(echo "$NEW_STATUS" | jq -r '.Details // empty')

    if [ -n "$REVIEW_DETAILS" ]; then
        echo "Review Details:"
        echo "$REVIEW_DETAILS" | jq -r '
            "  Review Status: " + (.ReviewDetails.Status // "Unknown"),
            "  Case ID: " + (.ReviewDetails.CaseId // "N/A")'
        echo ""
    fi
fi

# Display current quota (still sandbox limits until approved)
echo "Current Sending Quota (Sandbox):"
QUOTA=$(aws ses get-send-quota --region "$REGION" --output json 2>/dev/null)

if [ -n "$QUOTA" ]; then
    echo "$QUOTA" | jq -r '
        "  Max 24h Send: " + (.Max24HourSend | tostring),
        "  Max Send Rate: " + (.MaxSendRate | tostring) + "/second",
        "  Sent Last 24h: " + (.SentLast24Hours | tostring)'
    echo ""
fi

echo "=================================================="
echo -e "${GREEN}Next steps:${NC}"
echo ""
echo "  1. AWS will review your request (typically 24-72 hours)"
echo "  2. You may receive email requests for additional information"
echo "  3. Check your email (including spam folder) for updates"
echo "  4. Monitor request status:"
echo ""
echo "     aws sesv2 get-account --region $REGION | jq '.ProductionAccessEnabled'"
echo ""
echo "  5. Once approved, verify new limits:"
echo ""
echo "     aws ses get-send-quota --region $REGION"
echo ""
echo "Expected Production Limits:"
echo "  • Daily sending: 50,000 emails"
echo "  • Rate limit: 14 emails/second"
echo "  • No recipient restrictions"
echo ""
echo "For higher limits, submit a support request after approval."
echo ""
echo "To check request status at any time:"
echo "  aws sesv2 get-account --region $REGION"
echo ""
