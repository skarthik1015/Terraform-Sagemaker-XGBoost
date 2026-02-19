#!/bin/bash
# deploy.sh - Local deployment helper script
#
# Assumes the repo is organized as:
#   terraform/   ← all .tf files
#   ml/          ← pipeline_terraform.py, prepare_data.py, etc.
#   ml/training/ ← train.py, evaluate.py (run inside SageMaker containers)
#   lambda/      ← pipeline_trigger.py
#   data/raw/    ← iris.csv
#
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

ok()   { echo -e "${GREEN}  [OK]  $1${NC}"; }
err()  { echo -e "${RED}  [ERR] $1${NC}"; exit 1; }
info() { echo -e "${YELLOW}  [INFO] $1${NC}"; }
step() { echo -e "\n${BLUE}==> $1${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# -----------------------------------------------------------------------
check_prerequisites() {
    step "Checking prerequisites"
    command -v terraform &>/dev/null || err "Terraform not installed"
    ok "Terraform: $(terraform version -json | python3 -c 'import sys,json; print(json.load(sys.stdin)["terraform_version"])')"

    command -v aws &>/dev/null || err "AWS CLI not installed"
    ok "AWS CLI: $(aws --version 2>&1 | cut -d' ' -f1)"

    command -v python3 &>/dev/null || err "Python3 not installed"
    ok "Python: $(python3 --version)"

    aws sts get-caller-identity &>/dev/null || err "AWS credentials not configured. Run: aws configure"
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    ok "AWS Account: $ACCOUNT_ID"

    python3 -c "import sagemaker" 2>/dev/null || {
        info "Installing Python dependencies..."
        pip3 install -r "$SCRIPT_DIR/requirements.txt" --quiet
    }
    ok "Python dependencies ready"
}

# -----------------------------------------------------------------------
# One-time setup of Terraform remote state backend.
# Run ONCE before the very first terraform init. Safe to re-run.
# -----------------------------------------------------------------------
setup_state_backend() {
    step "Setting up Terraform remote state backend"

    REGION=${TF_VAR_aws_region:-us-east-1}
    STATE_BUCKET="terraform-sagemaker-firstbucket-tfstate"
    LOCK_TABLE="terraform-state-locks"

    info "Creating state bucket: $STATE_BUCKET (if not exists)"
    aws s3api create-bucket \
        --bucket "$STATE_BUCKET" \
        --region "$REGION" \
        --create-bucket-configuration LocationConstraint="$REGION" 2>/dev/null || true

    aws s3api put-bucket-versioning \
        --bucket "$STATE_BUCKET" \
        --versioning-configuration Status=Enabled

    aws s3api put-bucket-encryption \
        --bucket "$STATE_BUCKET" \
        --server-side-encryption-configuration \
        '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

    info "Creating DynamoDB lock table: $LOCK_TABLE (if not exists)"
    aws dynamodb create-table \
        --table-name "$LOCK_TABLE" \
        --attribute-definitions AttributeName=LockID,AttributeType=S \
        --key-schema AttributeName=LockID,KeyType=HASH \
        --billing-mode PAY_PER_REQUEST \
        --region "$REGION" 2>/dev/null || true

    ok "State backend ready"
    info "Now run: ./deploy.sh init"
}

# -----------------------------------------------------------------------
# Generate pipeline_definition.json before terraform does anything.
# FIX: was calling python3 pipeline.py - that script directly calls
# pipeline.upsert() and does NOT generate pipeline_definition.json.
# Only pipeline_terraform.py generates the JSON file Terraform needs.
# -----------------------------------------------------------------------
generate_pipeline() {
    step "Generating pipeline_definition.json"

    pushd "$SCRIPT_DIR/ml" > /dev/null

    export SAGEMAKER_ROLE_ARN="${SAGEMAKER_ROLE_ARN:-arn:aws:iam::941377155192:role/sagemaker-execution-role}"
    export S3_BUCKET="${S3_BUCKET:-terraform-sagemaker-firstbucket}"
    export MODEL_PACKAGE_GROUP="${MODEL_PACKAGE_GROUP:-iris-classification-models}"
    export PIPELINE_NAME="${PIPELINE_NAME:-iris-xgboost-pipeline-tf}"

    # FIX: was python3 pipeline.py - corrected to pipeline_terraform.py
    python3 pipeline_terraform.py

    [[ -f pipeline_definition.json ]] || err "pipeline_definition.json was not created"
    ok "pipeline_definition.json generated ($(wc -c < pipeline_definition.json) bytes)"

    popd > /dev/null
}

# -----------------------------------------------------------------------
prepare_data() {
    step "Preparing data splits"
    pushd "$SCRIPT_DIR/ml" > /dev/null

    if [[ -f prepare_data.py ]]; then
        python3 prepare_data.py
        ok "Data splits created"
    else
        info "prepare_data.py not found, skipping"
    fi

    popd > /dev/null
}

# -----------------------------------------------------------------------
init_terraform() {
    step "Initializing Terraform"
    # FIX: All terraform commands now use -chdir=terraform/ so they run
    # against the terraform/ directory, not the repo root.
    terraform -chdir="$SCRIPT_DIR/terraform" init
    ok "Terraform initialized"
}

# -----------------------------------------------------------------------
plan_terraform() {
    step "Terraform plan"
    [[ -f "$SCRIPT_DIR/ml/pipeline_definition.json" ]] || {
        info "pipeline_definition.json missing. Generating now..."
        generate_pipeline
    }
    terraform -chdir="$SCRIPT_DIR/terraform" plan
}

# -----------------------------------------------------------------------
apply_terraform() {
    step "Applying Terraform"
    generate_pipeline

    terraform -chdir="$SCRIPT_DIR/terraform" apply -auto-approve
    ok "Infrastructure deployed"
    terraform -chdir="$SCRIPT_DIR/terraform" output setup_complete_message
}

# -----------------------------------------------------------------------
# Uploads val and test data first (non-watched prefixes), then uploads
# train data last to trigger the pipeline exactly once via EventBridge.
# -----------------------------------------------------------------------
upload_data() {
    step "Uploading data splits to S3"

    BUCKET=$(terraform -chdir="$SCRIPT_DIR/terraform" output -raw s3_bucket_name 2>/dev/null) \
        || err "Run terraform apply first"

    SPLIT_DIR="$SCRIPT_DIR/ml/split_data"
    [[ -d "$SPLIT_DIR" ]] || err "split_data/ not found. Run: ./deploy.sh data"

    info "Uploading validation data..."
    aws s3 cp "$SPLIT_DIR/iris_validation.csv" "s3://$BUCKET/data/validation/iris.csv"
    ok "Validation data uploaded"

    info "Uploading test data..."
    aws s3 cp "$SPLIT_DIR/iris_test.csv" "s3://$BUCKET/data/test/iris.csv"
    ok "Test data uploaded"

    info "Uploading training data (this will trigger the pipeline)..."
    aws s3 cp "$SPLIT_DIR/iris_train.csv" "s3://$BUCKET/data/train/iris.csv"
    ok "Training data uploaded - pipeline should start automatically"
}

# -----------------------------------------------------------------------
start_pipeline() {
    step "Starting pipeline manually"

    PIPELINE=$(terraform -chdir="$SCRIPT_DIR/terraform" output -raw pipeline_name 2>/dev/null) \
        || err "Run terraform apply first"
    REGION=$(terraform -chdir="$SCRIPT_DIR/terraform" output -raw aws_region 2>/dev/null || echo "us-east-1")

    ARN=$(aws sagemaker start-pipeline-execution \
        --pipeline-name "$PIPELINE" \
        --pipeline-execution-display-name "manual-$(date +%Y%m%d-%H%M%S)" \
        --query PipelineExecutionArn --output text)
    ok "Pipeline started"
    info "Execution ARN: $ARN"
    info "Monitor: aws sagemaker describe-pipeline-execution --pipeline-execution-arn $ARN"
}

# -----------------------------------------------------------------------
deploy_endpoint() {
    step "Deploying endpoint (Phase 2)"

    BUCKET=$(terraform -chdir="$SCRIPT_DIR/terraform" output -raw s3_bucket_name 2>/dev/null) \
        || err "Run terraform apply first"

    info "Finding the best model artifact path..."
    echo ""
    echo "Run this command to get the model S3 path:"
    echo ""
    terraform -chdir="$SCRIPT_DIR/terraform" output find_best_model_command
    echo ""
    read -rp "Paste the model S3 URI here (s3://...): " MODEL_URI

    [[ "$MODEL_URI" == s3://* ]] || err "Invalid S3 URI. Must start with s3://"

    TFVARS="$SCRIPT_DIR/terraform/terraform.tfvars"
    if grep -q "^model_data_url" "$TFVARS"; then
        sed -i.bak "s|^model_data_url.*|model_data_url = \"$MODEL_URI\"|" "$TFVARS"
    else
        echo "model_data_url = \"$MODEL_URI\"" >> "$TFVARS"
    fi

    sed -i.bak "s|^enable_endpoint.*|enable_endpoint = true|" "$TFVARS"

    info "Approving model in registry..."
    LATEST_VERSION=$(aws sagemaker list-model-packages \
        --model-package-group-name "iris-classification-models" \
        --sort-by CreationTime --sort-order Descending \
        --query 'ModelPackageSummaryList[0].ModelPackageArn' \
        --output text)
    aws sagemaker update-model-package \
        --model-package-arn "$LATEST_VERSION" \
        --model-approval-status Approved
    ok "Model approved in registry"

    info "Applying Terraform to create endpoint..."
    terraform -chdir="$SCRIPT_DIR/terraform" apply -auto-approve
    ok "Endpoint deployed"
}

# -----------------------------------------------------------------------
test_endpoint() {
    step "Testing inference endpoint"

    ENDPOINT=$(terraform -chdir="$SCRIPT_DIR/terraform" output -raw endpoint_name 2>/dev/null) \
        || err "Endpoint not deployed yet"

    info "Endpoint: $ENDPOINT"
    info "Sending test prediction (Iris-versicolor: 6.4,3.2,4.5,1.5)..."

    RESULT=$(aws sagemaker-runtime invoke-endpoint \
        --endpoint-name "$ENDPOINT" \
        --content-type "text/csv" \
        --body "6.4,3.2,4.5,1.5" \
        --cli-binary-format raw-in-base64-out \
        /tmp/endpoint_response.json \
        --query 'HTTPStatusCode' --output text)

    if [[ "$RESULT" == "200" ]]; then
        ok "Prediction received (HTTP $RESULT)"
        info "Raw response: $(cat /tmp/endpoint_response.json)"
    else
        err "Endpoint returned HTTP $RESULT"
    fi
}

# -----------------------------------------------------------------------
full_deploy() {
    step "Full deployment"
    check_prerequisites
    setup_state_backend
    prepare_data
    generate_pipeline
    init_terraform
    apply_terraform
    upload_data

    echo ""
    ok "Phase 1 complete - pipeline is running!"
    info "Once it finishes, run: ./deploy.sh endpoint"
}

destroy_all() {
    step "Destroying all Terraform-managed resources"
    echo -e "${RED}WARNING: This will destroy the pipeline, Lambda, EventBridge rules, etc.${NC}"
    echo "The existing S3 bucket and IAM role are imported (not destroyed)."
    read -rp "Type 'destroy' to confirm: " confirm
    [[ "$confirm" == "destroy" ]] || { info "Cancelled"; exit 0; }

    terraform -chdir="$SCRIPT_DIR/terraform" destroy -auto-approve
    ok "Infrastructure destroyed"
}

# -----------------------------------------------------------------------
case "${1:-help}" in
    prereqs)  check_prerequisites ;;
    backend)  setup_state_backend ;;
    data)     prepare_data ;;
    pipeline) generate_pipeline ;;
    init)     check_prerequisites && generate_pipeline && init_terraform ;;
    plan)     check_prerequisites && plan_terraform ;;
    apply)    check_prerequisites && apply_terraform ;;
    upload)   upload_data ;;
    start)    start_pipeline ;;
    endpoint) deploy_endpoint ;;
    test)     test_endpoint ;;
    destroy)  destroy_all ;;
    full)     full_deploy ;;
    *)
        echo ""
        echo "Usage: ./deploy.sh <command>"
        echo ""
        echo "First-time setup (run in order):"
        echo "  backend   Create S3 + DynamoDB Terraform state backend"
        echo "  init      Check prereqs, generate pipeline JSON, terraform init"
        echo "  apply     Generate pipeline JSON + terraform apply"
        echo "  upload    Upload data splits to S3 (triggers pipeline automatically)"
        echo ""
        echo "Or run everything at once:"
        echo "  full      backend + data + pipeline + init + apply + upload"
        echo ""
        echo "After pipeline runs:"
        echo "  endpoint  Find best model, approve it, deploy endpoint"
        echo "  test      Send a test prediction to the endpoint"
        echo ""
        echo "Other:"
        echo "  start     Manually trigger a pipeline execution"
        echo "  plan      terraform plan only"
        echo "  destroy   Destroy all Terraform-managed resources"
        echo ""
        exit 1
        ;;
esac
