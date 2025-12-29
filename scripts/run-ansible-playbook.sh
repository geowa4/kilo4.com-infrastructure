#!/bin/bash
set -euo pipefail

#####################################################################
# run-ansible-playbook.sh
# Executes an Ansible playbook on EC2 instances via SSM Run Command
# Region: us-east-2
#
# Usage: ./run-ansible-playbook.sh <playbook-name.yml> [instance-id]
#   playbook-name.yml: Name of the playbook in S3 bucket (e.g., hardening.yml)
#   instance-id: Optional EC2 instance ID (defaults to tag:Name=kilo4-Instance)
#####################################################################

# Parse command line arguments
PLAYBOOK_NAME="${1:-}"
INSTANCE_ID="${2:-}"

# Configuration Variables
REGION="us-east-2"
STACK_NAME="kilo4-Infrastructure"
TARGET_TAG="Name=kilo4-Instance"
TIMEOUT_SECONDS=600

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
        log_error "Usage: $0 PLAYBOOK_NAME [INSTANCE_ID]"
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
# Get S3 Bucket Name and Instance ID
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

get_instance_id() {
    if [[ -n "$INSTANCE_ID" ]]; then
        echo "$INSTANCE_ID"
        return
    fi

    log_info "Resolving instance ID from tag: $TARGET_TAG"

    local instance_id
    instance_id=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue" \
        --output text 2>/dev/null)

    if [[ -z "$instance_id" || "$instance_id" == "None" ]]; then
        log_error "Could not retrieve instance ID from stack outputs"
        exit 1
    fi

    echo "$instance_id"
}

#####################################################################
# Execute Ansible Playbook via SSM
#####################################################################

execute_playbook() {
    local bucket_name="$1"
    local instance_id="$2"

    log_info "Executing playbook: $PLAYBOOK_NAME"
    log_info "Target instance: $instance_id"
    log_info "S3 source: s3://$bucket_name/playbooks/"

    # Send SSM command
    local command_id
    command_id=$(aws ssm send-command \
        --document-name "AWS-ApplyAnsiblePlaybooks" \
        --instance-ids "$instance_id" \
        --parameters '{
            "SourceType": ["S3"],
            "SourceInfo": ["{\"path\":\"https://s3.amazonaws.com/'"$bucket_name"'/playbooks/\"}"],
            "InstallDependencies": ["True"],
            "PlaybookFile": ["'"$PLAYBOOK_NAME"'"],
            "ExtraVariables": ["SSM=True"],
            "Verbose": ["-v"]
        }' \
        --timeout-seconds "$TIMEOUT_SECONDS" \
        --region "$REGION" \
        --query 'Command.CommandId' \
        --output text)

    log_success "Command sent with ID: $command_id"

    echo "$command_id"
}

#####################################################################
# Wait for Command Completion
#####################################################################

wait_for_completion() {
    local command_id="$1"
    local instance_id="$2"

    log_info "Waiting for command to complete (timeout: ${TIMEOUT_SECONDS}s)..."

    # Wait for command execution
    if aws ssm wait command-executed \
        --command-id "$command_id" \
        --instance-id "$instance_id" \
        --region "$REGION" 2>/dev/null; then
        log_success "Command completed"
    else
        log_warn "Wait command timed out or failed, checking status..."
    fi
}

#####################################################################
# Display Command Output
#####################################################################

display_output() {
    local command_id="$1"
    local instance_id="$2"

    log_info "Retrieving command output..."

    local invocation
    invocation=$(aws ssm get-command-invocation \
        --command-id "$command_id" \
        --instance-id "$instance_id" \
        --region "$REGION" \
        --output json)

    local status
    status=$(echo "$invocation" | jq -r '.Status')

    echo ""
    echo "=============================================="
    echo "  Command Execution Results"
    echo "=============================================="
    echo ""
    echo "Status: $status"
    echo ""

    if [[ "$status" == "Success" ]]; then
        log_success "Playbook execution succeeded"
    else
        log_error "Playbook execution status: $status"
    fi

    echo ""
    echo "Standard Output:"
    echo "----------------------------------------------"
    echo "$invocation" | jq -r '.StandardOutputContent'
    echo ""

    local stderr
    stderr=$(echo "$invocation" | jq -r '.StandardErrorContent')
    if [[ -n "$stderr" && "$stderr" != "null" ]]; then
        echo "Standard Error:"
        echo "----------------------------------------------"
        echo "$stderr"
        echo ""
    fi

    echo "=============================================="
    echo ""

    # Return exit code based on status
    if [[ "$status" != "Success" ]]; then
        exit 1
    fi
}

#####################################################################
# Main Function
#####################################################################

main() {
    echo ""
    log_info "Starting Ansible playbook execution via SSM Run Command"
    echo ""

    check_prerequisites

    local bucket_name
    bucket_name=$(get_bucket_name)

    local instance_id
    instance_id=$(get_instance_id)

    local command_id
    command_id=$(execute_playbook "$bucket_name" "$instance_id")

    wait_for_completion "$command_id" "$instance_id"
    display_output "$command_id" "$instance_id"

    log_success "Playbook execution complete!"
    echo ""
}

main "$@"
