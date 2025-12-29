#!/bin/bash
set -euo pipefail

#####################################################################
# create-ansible-association.sh
# Creates an SSM State Manager association for scheduled Ansible playbook execution
# Region: us-east-2
# Idempotent: Yes - checks for existing association
#
# Usage: ./create-ansible-association.sh <playbook-name.yml>
#   playbook-name.yml: Name of the playbook in S3 bucket (e.g., hardening.yml)
#####################################################################

# Parse command line arguments
PLAYBOOK_NAME="${1:-}"

# Configuration Variables
REGION="us-east-2"
STACK_NAME="kilo4-Infrastructure"
TARGET_TAG="Name=kilo4-Instance"
SCHEDULE="rate(1 day)"

#####################################################################
# Helper Functions
#####################################################################

log_info() {
    echo "[INFO]  $(date '+%Y-%m-%d %H:%M:%S') $*"
}

log_warn() {
    echo "[WARN]  $(date '+%Y-%m-%d %H:%M:%S') $*" >&2
}

log_error() {
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') $*" >&2
}

log_success() {
    echo "[OK]    $(date '+%Y-%m-%d %H:%M:%S') $*"
}

handle_error() {
    log_error "Script failed at line $1"
    exit 1
}

trap 'handle_error $LINENO' ERR

#####################################################################
# Prerequisites Check
#####################################################################

check_prerequisites() {
    log_info "Checking prerequisites..."

    if [[ -z "$PLAYBOOK_NAME" ]]; then
        log_error "Playbook name is required"
        log_error "Usage: $0 PLAYBOOK_NAME"
        log_error "Example: $0 hardening.yml"
        exit 1
    fi

    if ! command -v aws &> /dev/null; then
        log_error "AWS CLI is not installed"
        exit 1
    fi

    if ! aws sts get-caller-identity --region "$REGION" &> /dev/null; then
        log_error "AWS credentials not configured or expired"
        exit 1
    fi

    log_success "Prerequisites validated"
}

#####################################################################
# Get S3 Bucket Name
#####################################################################

get_bucket_name() {
    log_info "Getting S3 bucket name from CloudFormation stack: $STACK_NAME"

    local bucket_name
    bucket_name=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --query "Stacks[0].Outputs[?OutputKey=='AnsiblePlaybooksBucketName'].OutputValue" \
        --output text 2>/dev/null)

    if [[ -z "$bucket_name" || "$bucket_name" == "None" ]]; then
        log_error "Could not retrieve bucket name from stack outputs"
        exit 1
    fi

    echo "$bucket_name"
}

#####################################################################
# Generate Association Name
#####################################################################

generate_association_name() {
    local playbook="$1"
    local basename
    basename=$(basename "$playbook" .yml)
    basename=$(basename "$basename" .yaml)
    echo "kilo4-${basename}-Playbook"
}

#####################################################################
# Check for Existing Association
#####################################################################

check_existing_association() {
    local association_name="$1"

    log_info "Checking for existing association: $association_name"

    local existing_id
    existing_id=$(aws ssm list-associations \
        --association-filter-list "key=Name,value=$association_name" \
        --region "$REGION" \
        --query "Associations[0].AssociationId" \
        --output text 2>/dev/null)

    if [[ -n "$existing_id" && "$existing_id" != "None" ]]; then
        log_warn "Association already exists with ID: $existing_id"
        return 0
    fi

    return 1
}

#####################################################################
# Create State Manager Association
#####################################################################

create_association() {
    local bucket_name="$1"
    local association_name="$2"

    log_info "Creating State Manager association: $association_name"
    log_info "Playbook: $PLAYBOOK_NAME"
    log_info "Schedule: $SCHEDULE"
    log_info "Target: tag:$TARGET_TAG"

    local association_id
    association_id=$(aws ssm create-association \
        --name "AWS-ApplyAnsiblePlaybooks" \
        --targets "Key=tag:$TARGET_TAG,Values=" \
        --parameters '{
            "SourceType": ["S3"],
            "SourceInfo": ["{\"path\":\"https://s3.amazonaws.com/'"$bucket_name"'/playbooks/\"}"],
            "InstallDependencies": ["True"],
            "PlaybookFile": ["'"$PLAYBOOK_NAME"'"],
            "ExtraVariables": ["SSM=True"],
            "Verbose": ["-v"]
        }' \
        --association-name "$association_name" \
        --schedule-expression "$SCHEDULE" \
        --apply-only-at-cron-interval false \
        --region "$REGION" \
        --query 'AssociationDescription.AssociationId' \
        --output text)

    log_success "Association created with ID: $association_id"

    echo "$association_id"
}

#####################################################################
# Verify Association
#####################################################################

verify_association() {
    local association_id="$1"

    log_info "Verifying association details..."

    local association_info
    association_info=$(aws ssm describe-association \
        --association-id "$association_id" \
        --region "$REGION" \
        --output json)

    local status
    status=$(echo "$association_info" | jq -r '.AssociationDescription.Status.Name')

    echo ""
    echo "=============================================="
    echo "  State Manager Association Details"
    echo "=============================================="
    echo ""
    echo "Association ID:   $association_id"
    echo "Status:           $status"
    echo "Schedule:         $SCHEDULE"
    echo "Playbook:         $PLAYBOOK_NAME"
    echo ""
    echo "=============================================="
    echo ""

    if [[ "$status" == "Pending" || "$status" == "Success" ]]; then
        log_success "Association is active and will run on schedule"
    else
        log_warn "Association status: $status"
    fi
}

#####################################################################
# Display Next Execution Time
#####################################################################

display_next_execution() {
    local association_name="$1"

    log_info "Checking next execution time..."

    local next_execution
    next_execution=$(aws ssm describe-association \
        --name "AWS-ApplyAnsiblePlaybooks" \
        --association-id "$(aws ssm list-associations \
            --association-filter-list "key=Name,value=$association_name" \
            --region "$REGION" \
            --query "Associations[0].AssociationId" \
            --output text)" \
        --region "$REGION" \
        --query 'AssociationDescription.Overview.AssociationStatusAggregatedCount' \
        --output json 2>/dev/null || echo "{}")

    echo "To view association execution history:"
    echo "aws ssm list-association-versions --association-id ASSOCIATION_ID --region $REGION"
    echo ""
    echo "To manually run the association now:"
    echo "aws ssm start-associations-once --association-ids ASSOCIATION_ID --region $REGION"
    echo ""
}

#####################################################################
# Main Function
#####################################################################

main() {
    echo ""
    log_info "Starting State Manager association creation"
    echo ""

    check_prerequisites

    local bucket_name
    bucket_name=$(get_bucket_name)
    log_success "S3 bucket: $bucket_name"

    local association_name
    association_name=$(generate_association_name "$PLAYBOOK_NAME")

    # Check if association already exists
    if check_existing_association "$association_name"; then
        log_warn "Association already exists. Use AWS Console or CLI to update if needed."
        exit 0
    fi

    local association_id
    association_id=$(create_association "$bucket_name" "$association_name")

    verify_association "$association_id"
    display_next_execution "$association_name"

    log_success "State Manager association creation complete!"
    echo ""
}

main "$@"
