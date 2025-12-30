#!/bin/bash
# Verify email identities in Amazon SES
# Usage: ./verify-ses-identity.sh <email-address> [additional-email-addresses...]

set -euo pipefail

REGION="us-east-2"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

usage() {
    echo "Usage: $0 <email-address> [additional-email-addresses...]"
    echo ""
    echo "Examples:"
    echo "  $0 noreply@kilo4.com"
    echo "  $0 noreply@kilo4.com test@example.com"
    echo ""
    echo "This script will:"
    echo "  1. Request verification for each email address"
    echo "  2. Show verification status"
    echo "  3. Remind you to check email for verification link"
    exit 1
}

if [ $# -eq 0 ]; then
    usage
fi

echo "Amazon SES Email Identity Verification"
echo "Region: $REGION"
echo "========================================"
echo ""

# Verify each email address
for EMAIL in "$@"; do
    echo -e "${YELLOW}Requesting verification for: $EMAIL${NC}"

    if aws ses verify-email-identity \
        --email-address "$EMAIL" \
        --region "$REGION" 2>/dev/null; then
        echo -e "${GREEN}✓ Verification request sent${NC}"
        echo "  Check $EMAIL for a verification link from Amazon SES"
    else
        echo -e "${RED}✗ Failed to request verification${NC}"
        echo "  Error: $(aws ses verify-email-identity --email-address "$EMAIL" --region "$REGION" 2>&1)"
    fi
    echo ""
done

# Wait a moment for API consistency
sleep 2

# Check verification status for all identities
echo "Checking verification status for all identities..."
echo "=================================================="
echo ""

IDENTITIES=$(aws ses list-identities --region "$REGION" --output json | jq -r '.Identities[]')

if [ -z "$IDENTITIES" ]; then
    echo "No identities found"
    exit 0
fi

for IDENTITY in $IDENTITIES; do
    STATUS=$(aws ses get-identity-verification-attributes \
        --identities "$IDENTITY" \
        --region "$REGION" \
        --output json | \
        jq -r ".VerificationAttributes[\"$IDENTITY\"].VerificationStatus")

    if [ "$STATUS" = "Success" ]; then
        echo -e "${GREEN}✓ $IDENTITY - Verified${NC}"
    elif [ "$STATUS" = "Pending" ]; then
        echo -e "${YELLOW}⧗ $IDENTITY - Pending (check email for verification link)${NC}"
    else
        echo -e "${RED}✗ $IDENTITY - $STATUS${NC}"
    fi
done

echo ""
echo "=================================================="
echo "Next steps:"
echo "  1. Check email inbox for verification links"
echo "  2. Click the verification link in each email"
echo "  3. Re-run this script to confirm verification status"
echo "  4. Once verified, test with: python3 scripts/test-ses-email.py"
