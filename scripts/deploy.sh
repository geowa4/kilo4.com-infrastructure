#!/bin/bash
set -euo pipefail

#####################################################################
# deploy.sh
# Master deployment script for kilo4 infrastructure
# Region: us-east-2
# Idempotent: Yes - checks for existing resources
#
# Usage: ./deploy.sh [EMAIL_ADDRESS]
#        EMAIL_ADDRESS=email@example.com ./deploy.sh
#   EMAIL_ADDRESS: Email for patch notifications (optional, skips patch manager if not provided)
#                  Can be set via environment variable or command line argument
#####################################################################

# Parse command line arguments
# Use environment variable if set, otherwise use command line argument
EMAIL_ADDRESS="${EMAIL_ADDRESS:-${1:-}}"

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Configuration Variables
REGION="us-east-2"
STACK_NAME="kilo4-Infrastructure"
TEMPLATE_FILE="$PROJECT_ROOT/infrastructure.yaml"
SSM_WAIT_TIMEOUT=300  # 5 minutes
SSM_WAIT_INTERVAL=15  # seconds

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
    echo "Usage: $0 [EMAIL_ADDRESS]"
    echo "       EMAIL_ADDRESS=email@example.com $0"
    echo ""
    echo "Deploys the complete kilo4 infrastructure:"
    echo "  1. CloudFormation stack (VPC, EC2, IAM, S3, SNS)"
    echo "  2. Ansible playbooks upload to S3"
    echo "  3. System hardening via Ansible"
    echo "  4. Base packages installation"
    echo "  5. State Manager association for scheduled hardening"
    echo "  6. Patch Manager configuration (if email provided)"
    echo ""
    echo "Arguments:"
    echo "  EMAIL_ADDRESS  Optional email for patch notifications"
    echo "                 Can be set via environment variable or command line argument"
    echo ""
    echo "Examples:"
    echo "  $0 admin@kilo4.com"
    echo "  EMAIL_ADDRESS=admin@kilo4.com $0"
    exit 1
}

# Show usage if help requested
if [ "$#" -gt 0 ] && { [ "$1" = "-h" ] || [ "$1" = "--help" ]; }; then
    usage
fi

#####################################################################
# Deployment Functions
#####################################################################

check_prerequisites() {
    log_info "Checking prerequisites..."

    # Check AWS CLI installed
    if ! command -v aws &> /dev/null; then
        log_error "AWS CLI is not installed"
        log_error "Install with: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
        exit 1
    fi

    # Check AWS credentials
    if ! aws sts get-caller-identity --region "$REGION" &> /dev/null; then
        log_error "AWS credentials not configured or expired"
        log_error "Configure with: aws configure"
        exit 1
    fi

    # Check jq installed (needed for JSON parsing)
    if ! command -v jq &> /dev/null; then
        log_error "jq is not installed"
        log_error "Install with: brew install jq (macOS) or apt-get install jq (Linux)"
        exit 1
    fi

    # Check curl installed (for IP detection)
    if ! command -v curl &> /dev/null; then
        log_error "curl is not installed"
        exit 1
    fi

    # Check template file exists
    if [[ ! -f "$TEMPLATE_FILE" ]]; then
        log_error "CloudFormation template not found: $TEMPLATE_FILE"
        exit 1
    fi

    # Check playbooks directory exists
    if [[ ! -d "$PROJECT_ROOT/playbooks" ]]; then
        log_error "Playbooks directory not found: $PROJECT_ROOT/playbooks"
        exit 1
    fi

    log_success "Prerequisites validated"
}

deploy_or_update_stack() {
    log_info "Checking if CloudFormation stack exists..."

    local stack_status
    stack_status=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --query "Stacks[0].StackStatus" \
        --output text 2>/dev/null || echo "DOES_NOT_EXIST")

    if [[ "$stack_status" == "DOES_NOT_EXIST" ]]; then
        log_info "Stack does not exist. Creating new stack..."
        create_new_stack
    else
        log_info "Stack exists with status: $stack_status. Updating..."
        "$SCRIPT_DIR/infra/update-stack.sh"
        log_success "Stack update completed"
    fi
}

create_new_stack() {
    local current_ip
    current_ip=$(curl -s ipinfo.io/ip)

    if [[ -z "$current_ip" ]]; then
        log_error "Failed to fetch public IP"
        log_error "Please specify IP manually or check internet connection"
        exit 1
    fi

    log_info "Creating stack with SSH access from $current_ip/32"

    aws cloudformation create-stack \
        --stack-name "$STACK_NAME" \
        --template-body file://"$TEMPLATE_FILE" \
        --parameters ParameterKey=SSHAllowedIP,ParameterValue="${current_ip}/32" \
        --capabilities CAPABILITY_NAMED_IAM \
        --region "$REGION"

    log_info "Waiting for stack creation to complete (this may take several minutes)..."
    aws cloudformation wait stack-create-complete \
        --stack-name "$STACK_NAME" \
        --region "$REGION"

    log_success "Stack created successfully"
}

wait_for_ssm_agent() {
    log_info "Waiting for EC2 instance to register with SSM..."

    local instance_id
    instance_id=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue" \
        --output text)

    if [[ -z "$instance_id" || "$instance_id" == "None" ]]; then
        log_error "Could not retrieve instance ID from stack outputs"
        exit 1
    fi

    local elapsed=0
    while [[ $elapsed -lt $SSM_WAIT_TIMEOUT ]]; do
        local ping_status
        ping_status=$(aws ssm describe-instance-information \
            --filters "Key=InstanceIds,Values=$instance_id" \
            --region "$REGION" \
            --query "InstanceInformationList[0].PingStatus" \
            --output text 2>/dev/null || echo "None")

        if [[ "$ping_status" == "Online" ]]; then
            log_success "SSM Agent is online for instance $instance_id"
            return 0
        fi

        log_info "Waiting for SSM Agent... ($elapsed/${SSM_WAIT_TIMEOUT}s)"
        sleep "$SSM_WAIT_INTERVAL"
        elapsed=$((elapsed + SSM_WAIT_INTERVAL))
    done

    log_error "Timeout waiting for SSM Agent registration"
    log_error "Instance $instance_id did not appear in SSM within ${SSM_WAIT_TIMEOUT}s"
    log_error ""
    log_error "Troubleshooting steps:"
    log_error "  1. Verify instance is running:"
    log_error "     aws ec2 describe-instances --instance-ids $instance_id --region $REGION"
    log_error "  2. Check instance console output for errors:"
    log_error "     aws ec2 get-console-output --instance-id $instance_id --region $REGION"
    log_error "  3. Verify IAM role has AmazonSSMManagedInstanceCore permissions"
    exit 1
}

upload_playbooks() {
    log_info "Uploading Ansible playbooks to S3..."
    "$SCRIPT_DIR/infra/upload-playbooks.sh"
    log_success "Playbooks uploaded"
}

run_hardening_playbook() {
    log_info "Running system hardening playbook..."
    "$SCRIPT_DIR/infra/run-ansible-playbook.sh" "$PROJECT_ROOT/playbooks/hardening.yml"
    log_success "Hardening playbook executed"
}

run_base_packages_playbook() {
    log_info "Running base packages playbook..."
    "$SCRIPT_DIR/infra/run-ansible-playbook.sh" "$PROJECT_ROOT/playbooks/base-packages.yml"
    log_success "Base packages playbook executed"
}

create_state_manager_association() {
    log_info "Creating State Manager association for scheduled hardening..."
    "$SCRIPT_DIR/infra/create-ansible-association.sh" hardening.yml
    log_success "State Manager association created"
}

configure_patch_manager() {
    local email="$1"

    if [[ -z "$email" ]]; then
        log_warn "Email address not provided. Skipping Patch Manager configuration."
        log_warn "Run ./scripts/configure-patch-manager.sh EMAIL later to set up patching."
        return 0
    fi

    log_info "Configuring Patch Manager..."
    "$SCRIPT_DIR/infra/configure-patch-manager.sh" "$email"
    log_success "Patch Manager configured"
}

print_deployment_summary() {
    log_success "Deployment complete!"
    echo ""
    echo "=============================================="
    echo "  Deployment Summary"
    echo "=============================================="
    echo ""

    # Get instance public IP
    local public_ip
    public_ip=$(aws ec2 describe-instances \
        --filters "Name=tag:Name,Values=kilo4-Instance" "Name=instance-state-name,Values=running" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' \
        --output text \
        --region "$REGION" 2>/dev/null || echo "N/A")

    echo "Instance Public IP: $public_ip"
    echo ""

    if [[ "$public_ip" != "N/A" ]]; then
        echo "SSH Command:"
        echo "  ssh ec2-user@$public_ip"
        echo ""
    fi

    echo "Stack Outputs:"
    aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --query 'Stacks[0].Outputs' \
        --output table 2>/dev/null || echo "  (Unable to retrieve outputs)"

    echo ""
    echo "=============================================="
    echo "  Next Steps"
    echo "=============================================="
    echo ""
    echo "1. Verify SSH access:"
    echo "   ssh ec2-user@$public_ip"
    echo ""
    echo "2. Configure SES for email sending (optional):"
    echo "   ./scripts/verify-ses-domain.sh kilo4.com"
    echo "   See docs/ses-setup.md for details"
    echo ""
    echo "3. Monitor patch compliance in AWS Console:"
    echo "   Systems Manager > Patch Manager > Compliance"
    echo ""
    echo "4. View deployed resources:"
    echo "   aws cloudformation describe-stack-resources --stack-name $STACK_NAME --region $REGION"
    echo ""
}

#####################################################################
# Main
#####################################################################

main() {
    echo "=============================================="
    echo "  kilo4 Infrastructure Deployment"
    echo "=============================================="
    echo ""
    echo "Region: $REGION"
    echo "Stack:  $STACK_NAME"
    echo ""

    check_prerequisites
    deploy_or_update_stack
    wait_for_ssm_agent
    upload_playbooks
    run_hardening_playbook
    run_base_packages_playbook
    create_state_manager_association
    configure_patch_manager "$EMAIL_ADDRESS"
    print_deployment_summary
}

main
