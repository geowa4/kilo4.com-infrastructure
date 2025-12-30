#!/bin/bash
set -euo pipefail

#####################################################################
# teardown.sh
# Tears down all kilo4 infrastructure resources
# Region: us-east-2
# Idempotent: Yes - gracefully handles missing resources
#
# Usage: ./teardown.sh [--force]
#   --force: Skip confirmation prompt
#####################################################################

# Parse command line arguments
FORCE=false
if [ "$#" -gt 0 ] && [ "$1" = "--force" ]; then
    FORCE=true
fi

# Configuration Variables
REGION="us-east-2"
STACK_NAME="kilo4-Infrastructure"

#####################################################################
# Helper Functions
#####################################################################

log_info() {
    echo "[INFO]  $(date '+%Y-%m-%d %H:%M:%S') $*" >&2
}

log_warn() {
    echo "[WARN]  $(date '+%Y-%m-%d %H:%M:%S') $*" >&2
}

log_error() {
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') $*" >&2
}

log_success() {
    echo "[OK]    $(date '+%Y-%m-%d %H:%M:%S') $*" >&2
}

handle_error() {
    log_error "Script failed at line $1"
    exit 1
}

trap 'handle_error $LINENO' ERR

usage() {
    echo "Usage: $0 [--force]"
    echo ""
    echo "Tears down all kilo4 infrastructure resources:"
    echo "  - State Manager associations"
    echo "  - Patch Manager resources (windows, baselines, SNS)"
    echo "  - S3 bucket contents"
    echo "  - CloudFormation stack (VPC, EC2, IAM, S3, SNS, CloudWatch)"
    echo ""
    echo "Options:"
    echo "  --force  Skip confirmation prompt"
    echo ""
    echo "WARNING: This operation cannot be undone!"
    exit 1
}

# Show usage if help requested
if [ "$#" -gt 0 ] && { [ "$1" = "-h" ] || [ "$1" = "--help" ]; }; then
    usage
fi

#####################################################################
# Teardown Functions
#####################################################################

check_prerequisites() {
    log_info "Checking prerequisites..."

    # Check AWS CLI installed
    if ! command -v aws &> /dev/null; then
        log_error "AWS CLI is not installed"
        exit 1
    fi

    # Check AWS credentials
    if ! aws sts get-caller-identity --region "$REGION" &> /dev/null; then
        log_error "AWS credentials not configured or expired"
        exit 1
    fi

    log_success "Prerequisites validated"
}

confirm_teardown() {
    if [[ "$FORCE" == "true" ]]; then
        log_warn "Running in --force mode, skipping confirmation"
        return 0
    fi

    echo ""
    echo "=============================================="
    echo "  WARNING: Infrastructure Teardown"
    echo "=============================================="
    echo ""
    echo "This will DELETE ALL kilo4 infrastructure resources:"
    echo ""
    echo "  - CloudFormation stack (VPC, EC2, IAM)"
    echo "  - S3 bucket and all playbooks"
    echo "  - State Manager associations"
    echo "  - Patch Manager configuration"
    echo "  - SNS topics and CloudWatch alarms"
    echo ""
    echo "Region: $REGION"
    echo "Stack:  $STACK_NAME"
    echo ""
    echo "This operation CANNOT be undone!"
    echo ""

    read -p "Are you sure you want to continue? (type 'yes' to confirm): " confirm
    if [[ "$confirm" != "yes" ]]; then
        log_info "Teardown cancelled by user"
        exit 0
    fi

    echo ""
}

delete_state_manager_associations() {
    log_info "Deleting State Manager associations..."

    local associations
    associations=$(aws ssm list-associations \
        --region "$REGION" \
        --query "Associations[?starts_with(AssociationName, 'kilo4-')].AssociationId" \
        --output text 2>/dev/null || echo "")

    if [[ -z "$associations" || "$associations" == "None" ]]; then
        log_info "No State Manager associations found"
        return 0
    fi

    for assoc_id in $associations; do
        log_info "Deleting association: $assoc_id"
        aws ssm delete-association \
            --association-id "$assoc_id" \
            --region "$REGION" 2>/dev/null || true
    done

    log_success "State Manager associations deleted"
}

delete_patch_manager_resources() {
    log_info "Deleting Patch Manager resources..."

    # Delete maintenance window
    local window_id
    window_id=$(aws ssm describe-maintenance-windows \
        --region "$REGION" \
        --filters "Key=Name,Values=kilo4-PatchWindow-Sunday" \
        --query "WindowIdentities[0].WindowId" \
        --output text 2>/dev/null || echo "None")

    if [[ -n "$window_id" && "$window_id" != "None" ]]; then
        log_info "Deleting maintenance window: $window_id"
        aws ssm delete-maintenance-window \
            --window-id "$window_id" \
            --region "$REGION" 2>/dev/null || true
    else
        log_info "No maintenance window found"
    fi

    # Delete custom patch baseline
    local baseline_id
    baseline_id=$(aws ssm describe-patch-baselines \
        --region "$REGION" \
        --filters "Key=OWNER,Values=Self" \
        --query "BaselineIdentities[?starts_with(BaselineName, 'kilo4-')].BaselineId | [0]" \
        --output text 2>/dev/null || echo "None")

    if [[ -n "$baseline_id" && "$baseline_id" != "None" ]]; then
        log_info "Deregistering patch baseline from patch group"
        aws ssm deregister-patch-baseline-for-patch-group \
            --baseline-id "$baseline_id" \
            --patch-group "AmazonLinux2023" \
            --region "$REGION" 2>/dev/null || true

        log_info "Deleting patch baseline: $baseline_id"
        aws ssm delete-patch-baseline \
            --baseline-id "$baseline_id" \
            --region "$REGION" 2>/dev/null || true
    else
        log_info "No custom patch baseline found"
    fi

    # Delete SNS notification topic (created by configure-patch-manager.sh)
    local topic_arn
    topic_arn=$(aws sns list-topics \
        --region "$REGION" \
        --query "Topics[?contains(TopicArn, 'kilo4-patch-notifications')].TopicArn | [0]" \
        --output text 2>/dev/null || echo "None")

    if [[ -n "$topic_arn" && "$topic_arn" != "None" ]]; then
        log_info "Deleting SNS topic: $topic_arn"
        aws sns delete-topic \
            --topic-arn "$topic_arn" \
            --region "$REGION" 2>/dev/null || true
    else
        log_info "No patch notification SNS topic found"
    fi

    # Delete IAM role for SNS notifications (created by configure-patch-manager.sh)
    local role_name="kilo4-SSM-SNS-NotificationRole"
    if aws iam get-role --role-name "$role_name" --region "$REGION" &>/dev/null; then
        log_info "Deleting IAM role: $role_name"

        # First, detach inline policies
        aws iam delete-role-policy \
            --role-name "$role_name" \
            --policy-name "SNSPublishPolicy" 2>/dev/null || true

        # Delete role
        aws iam delete-role \
            --role-name "$role_name" 2>/dev/null || true
    else
        log_info "No SNS notification IAM role found"
    fi

    log_success "Patch Manager resources deleted"
}

empty_s3_bucket() {
    log_info "Emptying S3 bucket..."

    local bucket_name
    bucket_name=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --query "Stacks[0].Outputs[?OutputKey=='AnsiblePlaybooksBucketName'].OutputValue" \
        --output text 2>/dev/null || echo "")

    if [[ -z "$bucket_name" || "$bucket_name" == "None" ]]; then
        log_info "No S3 bucket found in stack outputs"
        return 0
    fi

    log_info "Deleting all objects from bucket: $bucket_name"

    # Delete all object versions (handles versioned buckets)
    aws s3api list-object-versions \
        --bucket "$bucket_name" \
        --query 'Versions[].{Key:Key,VersionId:VersionId}' \
        --output json 2>/dev/null | \
    jq -r '.[] | "\(.Key)\t\(.VersionId)"' | \
    while IFS=$'\t' read -r key version; do
        if [[ -n "$key" ]]; then
            aws s3api delete-object \
                --bucket "$bucket_name" \
                --key "$key" \
                --version-id "$version" 2>/dev/null || true
        fi
    done

    # Delete delete markers (if bucket is versioned)
    aws s3api list-object-versions \
        --bucket "$bucket_name" \
        --query 'DeleteMarkers[].{Key:Key,VersionId:VersionId}' \
        --output json 2>/dev/null | \
    jq -r '.[] | "\(.Key)\t\(.VersionId)"' | \
    while IFS=$'\t' read -r key version; do
        if [[ -n "$key" ]]; then
            aws s3api delete-object \
                --bucket "$bucket_name" \
                --key "$key" \
                --version-id "$version" 2>/dev/null || true
        fi
    done

    log_success "S3 bucket emptied (bucket will be deleted with CloudFormation stack)"
}

delete_cloudformation_stack() {
    log_info "Deleting CloudFormation stack..."

    # Check if stack exists
    local stack_status
    stack_status=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --query "Stacks[0].StackStatus" \
        --output text 2>/dev/null || echo "DOES_NOT_EXIST")

    if [[ "$stack_status" == "DOES_NOT_EXIST" ]]; then
        log_info "CloudFormation stack does not exist"
        return 0
    fi

    log_info "Deleting stack: $STACK_NAME (status: $stack_status)"
    aws cloudformation delete-stack \
        --stack-name "$STACK_NAME" \
        --region "$REGION"

    log_info "Waiting for stack deletion to complete (this may take several minutes)..."
    aws cloudformation wait stack-delete-complete \
        --stack-name "$STACK_NAME" \
        --region "$REGION"

    log_success "CloudFormation stack deleted"
}

print_teardown_summary() {
    log_success "Teardown complete!"
    echo ""
    echo "=============================================="
    echo "  Teardown Summary"
    echo "=============================================="
    echo ""
    echo "The following resources have been deleted:"
    echo "  ✓ State Manager associations"
    echo "  ✓ Patch Manager resources"
    echo "  ✓ S3 bucket and contents"
    echo "  ✓ CloudFormation stack and all resources:"
    echo "    - VPC and networking"
    echo "    - EC2 instance"
    echo "    - IAM roles"
    echo "    - SNS topics"
    echo "    - CloudWatch alarms"
    echo ""
    echo "Note: SES domain verifications (if configured) were NOT deleted."
    echo "To remove SES identities manually:"
    echo "  aws ses delete-identity --identity kilo4.com --region $REGION"
    echo ""
}

#####################################################################
# Main
#####################################################################

main() {
    echo "=============================================="
    echo "  kilo4 Infrastructure Teardown"
    echo "=============================================="
    echo ""

    check_prerequisites
    confirm_teardown

    log_info "Starting teardown process..."
    echo ""

    delete_state_manager_associations
    delete_patch_manager_resources
    empty_s3_bucket
    delete_cloudformation_stack

    print_teardown_summary
}

main
