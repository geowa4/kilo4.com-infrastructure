#!/bin/bash
# Update CloudFormation stack with current public IP
# Usage: ./update-stack.sh

set -euo pipefail

# Get script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

REGION="us-east-2"
STACK_NAME="kilo4-Infrastructure"
TEMPLATE_FILE="$PROJECT_ROOT/infrastructure.yaml"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

usage() {
    echo "Usage: $0"
    echo ""
    echo "This script will:"
    echo "  1. Fetch your current public IP address"
    echo "  2. Update the CloudFormation stack with the new IP"
    echo "  3. Wait for the update to complete"
    echo "  4. Display stack outputs"
    echo ""
    echo "The script automatically determines your IP using ipinfo.io"
    exit 1
}

if [ "$#" -gt 0 ] && { [ "$1" = "-h" ] || [ "$1" = "--help" ]; }; then
    usage
fi

echo "CloudFormation Stack Update"
echo "Stack: $STACK_NAME"
echo "Region: $REGION"
echo "========================================"
echo ""

# Step 1: Fetch current public IP
echo -e "${YELLOW}Step 1: Fetching current public IP...${NC}"

CURRENT_IP=$(curl -s ipinfo.io/ip)

if [ -z "$CURRENT_IP" ]; then
    echo -e "${RED}✗ Failed to fetch public IP${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Current IP: $CURRENT_IP${NC}"
echo ""

# Step 2: Validate template
echo -e "${YELLOW}Step 2: Validating CloudFormation template...${NC}"
echo "  Template file: $TEMPLATE_FILE"

if [[ ! -f "$TEMPLATE_FILE" ]]; then
    echo -e "${RED}✗ Template file not found: $TEMPLATE_FILE${NC}"
    exit 1
fi

VALIDATION_RESULT=$(aws cloudformation validate-template \
    --template-body file://"$TEMPLATE_FILE" \
    --region "$REGION" 2>&1)

VALIDATION_EXIT_CODE=$?
if [ $VALIDATION_EXIT_CODE -eq 0 ]; then
    echo -e "${GREEN}✓ Template is valid${NC}"
else
    echo -e "${RED}✗ Template validation failed (exit code: $VALIDATION_EXIT_CODE)${NC}"
    echo "$VALIDATION_RESULT"
    exit 1
fi

echo ""

# Step 3: Update stack
echo -e "${YELLOW}Step 3: Updating CloudFormation stack...${NC}"
echo "  SSH Allowed IP: ${CURRENT_IP}/32"
echo "  Template: $TEMPLATE_FILE"
echo "  Stack: $STACK_NAME"
echo "  Region: $REGION"
echo ""

# Temporarily disable set -e so we can capture and handle the exit code
set +e
UPDATE_RESULT=$(aws cloudformation update-stack \
    --stack-name "$STACK_NAME" \
    --template-body file://"$TEMPLATE_FILE" \
    --parameters ParameterKey=SSHAllowedIP,ParameterValue="${CURRENT_IP}/32" \
    --capabilities CAPABILITY_NAMED_IAM \
    --region "$REGION" 2>&1)

UPDATE_EXIT_CODE=$?
set -e
echo "  Update command exit code: $UPDATE_EXIT_CODE"

if [ $UPDATE_EXIT_CODE -eq 0 ]; then
    echo -e "${GREEN}✓ Stack update initiated${NC}"
    STACK_ID=$(echo "$UPDATE_RESULT" | jq -r '.StackId' 2>/dev/null || echo "")
    if [ -n "$STACK_ID" ]; then
        echo "  Stack ID: $STACK_ID"
    fi
    echo ""
else
    # Check if it's a "no updates" error
    if echo "$UPDATE_RESULT" | grep -q "No updates are to be performed"; then
        echo -e "${BLUE}ℹ No updates needed - stack is already up to date${NC}"
        echo ""

        # Still show outputs
        echo "=================================================="
        echo -e "${YELLOW}Current Stack Outputs:${NC}"
        echo ""

        aws cloudformation describe-stacks \
            --stack-name "$STACK_NAME" \
            --region "$REGION" \
            --query 'Stacks[0].Outputs' \
            --output table

        exit 0
    else
        echo -e "${RED}✗ Stack update failed${NC}"
        echo "$UPDATE_RESULT"
        exit 1
    fi
fi

# Step 4: Wait for update to complete
echo "=================================================="
echo -e "${YELLOW}Step 4: Waiting for stack update to complete...${NC}"
echo "(This may take several minutes)"
echo ""

WAIT_RESULT=$(aws cloudformation wait stack-update-complete \
    --stack-name "$STACK_NAME" \
    --region "$REGION" 2>&1)

WAIT_EXIT_CODE=$?

if [ $WAIT_EXIT_CODE -eq 0 ]; then
    echo -e "${GREEN}✓ Stack update completed successfully${NC}"
else
    echo -e "${RED}✗ Stack update failed or timed out${NC}"
    echo "$WAIT_RESULT"

    # Show stack events for troubleshooting
    echo ""
    echo "Recent stack events:"
    aws cloudformation describe-stack-events \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --max-items 10 \
        --query 'StackEvents[*].[Timestamp,ResourceStatus,ResourceType,LogicalResourceId,ResourceStatusReason]' \
        --output table

    exit 1
fi

echo ""

# Step 5: Display stack outputs
echo "=================================================="
echo -e "${YELLOW}Step 5: Stack Outputs:${NC}"
echo ""

aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --region "$REGION" \
    --query 'Stacks[0].Outputs' \
    --output table

echo ""
echo "=================================================="
echo -e "${GREEN}Stack update complete!${NC}"
echo ""
echo "SSH access is now allowed from: ${CURRENT_IP}/32"
echo ""
