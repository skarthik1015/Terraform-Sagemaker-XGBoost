# Terraform SageMaker XGBoost — MLOps Pipeline

An end-to-end MLOps pipeline that trains, tunes, evaluates, and deploys an XGBoost classifier on AWS SageMaker — fully automated through Terraform and GitHub Actions.

Pushing to `main` is the only deployment action required. Everything else — infrastructure provisioning, hyperparameter tuning, model evaluation, quality gating, and model registration — runs automatically.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         GitHub Actions                          │
│                                                                 │
│  Push to main ──► Generate pipeline JSON ──► Terraform apply   │
│                                                    │            │
│                                          Start SageMaker        │
│                                          Pipeline Execution     │
└────────────────────────────────────────────────────────────────-┘
                                                 │
                    ┌────────────────────────────▼──────────────────────────┐
                    │                  SageMaker Pipeline                   │
                    │                                                        │
                    │  ┌──────────────┐  ┌──────────────┐  ┌────────────┐  │
                    │  │ Hyperparameter│  │  Evaluation  │  │ Conditional│  │
                    │  │   Tuning     │─►│  (test set)  │─►│ Registration│  │
                    │  │  (9 jobs)    │  │              │  │ (≥90% acc) │  │
                    │  └──────────────┘  └──────────────┘  └────────────┘  │
                    └────────────────────────────────────────────────────────┘

                    ┌───────────────────────────────────────────────────────┐
                    │            Event-Driven Auto-Trigger                  │
                    │                                                        │
                    │  S3 Upload ──► EventBridge ──► Lambda ──► Pipeline   │
                    └───────────────────────────────────────────────────────┘
```

---

## Tech Stack

| Layer | Technology |
|---|---|
| Infrastructure | Terraform 1.7, AWS Provider 6.x |
| CI/CD | GitHub Actions, OIDC (keyless auth) |
| ML Training | AWS SageMaker, XGBoost 1.7 |
| Hyperparameter Tuning | SageMaker Automatic Model Tuning (Bayesian) |
| Model Registry | SageMaker Model Registry |
| Serverless Trigger | AWS Lambda (Python 3.11) |
| Event Routing | Amazon EventBridge |
| Notifications | Amazon SNS |
| State Backend | S3 |
| Python | 3.11, pandas, scikit-learn, boto3, sagemaker SDK |

---

## Repository Structure

```
.
├── .github/
│   └── workflows/
│       ├── deploy.yml          # Main branch: terraform apply + start pipeline
│       └── pr.yml              # Pull requests: terraform plan + PR comment
│
├── bootstrap/                  # One-time setup (run locally once, never from CI)
│   └── oidc.tf                 # GitHub OIDC provider + github-actions IAM role
│
├── terraform/                  # All AWS infrastructure
│   ├── main.tf                 # Provider config, S3 backend, shared data sources
│   ├── variables.tf            # All input variables with descriptions
│   ├── terraform.tfvars        # Your values (gitignored)
│   ├── sagemaker_pipeline.tf   # SageMaker pipeline + Model Registry
│   ├── lambda_eventbridge.tf   # Lambda trigger + EventBridge rules + SNS
│   ├── iam.tf                  # Lambda, EventBridge, and SNS IAM roles
│   ├── endpoint.tf             # SageMaker real-time inference endpoint
│   └── outputs.tf              # Console links, ARNs, helper commands
│
├── ml/
│   ├── training/
│   │   ├── train.py            # XGBoost training script (runs inside SageMaker)
│   │   └── evaluate.py         # Evaluation script (accuracy, F1, confusion matrix)
│   ├── prepare_data.py         # Splits iris.csv → train/validation/test CSVs
│   ├── pipeline_terraform.py   # Generates pipeline_definition.json for Terraform
│   ├── pipeline_definition.json # Auto-generated — do not edit manually
│   └── split_data/             # Local CSV splits (gitignored)
│
├── lambda/
│   └── pipeline_trigger.py     # Lambda handler: dedup check + start pipeline
│
├── data/
│   └── raw/
│       └── iris.csv            # Source dataset
│
├── deploy.sh                   # Local deployment helper (see commands below)
└── requirements.txt            # Python dependencies
```

---

## How the Pipeline Works

### 1. GitOps Trigger (Push to `main`)

Every push to `main` that touches a `.tf`, `.tfvars`, `ml/*.py`, or `lambda/*.py` file triggers `deploy.yml`:

1. **OIDC Authentication** — GitHub mints a short-lived JWT, AWS validates it against the OIDC provider and issues temporary credentials for the `github-actions-iris-mlops` role. No stored access keys.
2. **Generate `pipeline_definition.json`** — `pipeline_terraform.py` runs *before* Terraform, producing a stable JSON snapshot of the SageMaker pipeline graph.
3. **Terraform Apply** — All infrastructure is converged to match the code.
4. **Start Pipeline** — `aws sagemaker start-pipeline-execution` launches the ML training run.

### 2. SageMaker Pipeline Steps

| Step | Type | What Happens |
|---|---|---|
| `TfTunedXGBoostModel` | Tuning | Runs up to 9 training jobs (3 parallel). Bayesian optimiser searches `max_depth`, `eta`, `num_round` to minimise `validation:mlogloss`. |
| `TF_EvaluateXGBoostModel` | Processing | Loads the best model. Runs it against the held-out test set. Writes `evaluation.json` (accuracy, F1, confusion matrix) to S3. |
| `CheckAccuracyThreshold` | Condition | Reads accuracy from `evaluation.json`. If ≥ 90%, registers the model in the Model Registry with `PendingManualApproval`. Otherwise, does nothing. |

### 3. Event-Driven Trigger (S3 Upload)

Uploading a new CSV to `s3://<bucket>/data/train/` automatically starts a pipeline run:

```
S3 Object Created
      │
      ▼
EventBridge Rule (filters on data/train/ prefix)
      │
      ▼
Lambda (checks for active execution — deduplication)
      │
      ▼
start-pipeline-execution
```

---

## Setup

### Prerequisites

- AWS CLI configured (`aws configure`)
- Terraform >= 1.7
- Python 3.11
- An existing S3 bucket and SageMaker execution IAM role

### Step 1 — Bootstrap (one time only)

Creates the GitHub OIDC provider and `github-actions-iris-mlops` IAM role in your AWS account.

```bash
cd bootstrap
terraform init
terraform apply
```

When prompted, enter:
- `github_org` → your GitHub username (e.g. `skarthik1015`)
- `github_repo` → `Terraform-Sagemaker-XGBoost`
- `pipeline_name` → `iris-xgboost-pipeline-tf`

The output will show the exact secrets and variables to add to GitHub.

### Step 2 — Add GitHub Secrets and Variables

Go to your repo → **Settings → Secrets and variables → Actions**

**Secrets:**

| Name | Value |
|---|---|
| `AWS_ROLE_ARN` | `arn:aws:iam::<account-id>:role/github-actions-iris-mlops` |
| `AWS_REGION` | `us-east-1` |

**Variables:**

| Name | Value |
|---|---|
| `AWS_ACCOUNT_ID` | your 12-digit account ID |
| `ML_S3_BUCKET` | `terraform-sagemaker-firstbucket` |
| `PIPELINE_NAME` | `iris-xgboost-pipeline-tf` |
| `MODEL_PACKAGE_GROUP` | `iris-classification-models` |
| `SAGEMAKER_ROLE_NAME` | `sagemaker-execution-role` |

### Step 3 — Configure `terraform/terraform.tfvars`

```hcl
aws_region               = "us-east-1"
environment              = "dev"
owner                    = "your-name"
s3_bucket_name           = "your-s3-bucket"
sagemaker_role_name      = "sagemaker-execution-role"
pipeline_name            = "iris-xgboost-pipeline-tf"
model_package_group_name = "iris-classification-models"
enable_auto_trigger      = true
enable_endpoint          = false   # set true only after Phase 2
accuracy_threshold       = 0.90
max_tuning_jobs          = 9
parallel_tuning_jobs     = 3
notification_email       = ""      # optional: "you@example.com"
model_data_url           = ""      # set in Phase 2
```

### Step 4 — Prepare and Upload Data

```bash
cd ml
python3 prepare_data.py   # creates split_data/iris_train/val/test.csv and uploads to S3
```

### Step 5 — Deploy

Push to `main` to trigger the full CI/CD pipeline:

```bash
git add .
git commit -m "initial deploy"
git push origin main
```

Watch the run at: **GitHub → Actions → Deploy MLOps Pipeline**

---

## Phase 2 — Deploy the Inference Endpoint

After the SageMaker pipeline completes successfully:

```bash
# Find the best model artifact
terraform -chdir=terraform output find_best_model_command
# Follow the 4 steps shown in the output

# Then set in terraform/terraform.tfvars:
# model_data_url  = "s3://your-bucket/model-artifacts/<job-name>/output/model.tar.gz"
# enable_endpoint = true

# Approve the model in the registry
LATEST=$(aws sagemaker list-model-packages \
  --model-package-group-name iris-classification-models \
  --sort-by CreationTime --sort-order Descending \
  --query 'ModelPackageSummaryList[0].ModelPackageArn' \
  --output text)
aws sagemaker update-model-package \
  --model-package-arn $LATEST \
  --model-approval-status Approved

# Deploy endpoint
git add terraform/terraform.tfvars
git commit -m "deploy endpoint"
git push origin main
```

---

## Running Inferences

The endpoint accepts four comma-separated features: `SepalLength, SepalWidth, PetalLength, PetalWidth`

**AWS CLI:**
```bash
aws sagemaker-runtime invoke-endpoint \
  --endpoint-name iris-xgboost-pipeline-tf-endpoint \
  --content-type "text/csv" \
  --body "6.4,3.2,4.5,1.5" \
  --cli-binary-format raw-in-base64-out \
  /tmp/response.json && cat /tmp/response.json

# Output: [[0.02, 0.96, 0.02]]
# → Iris-versicolor (index 1, highest probability)
```

**Python (boto3):**
```python
import boto3, json

client = boto3.client('sagemaker-runtime', region_name='us-east-1')

response = client.invoke_endpoint(
    EndpointName='iris-xgboost-pipeline-tf-endpoint',
    ContentType='text/csv',
    Body='6.4,3.2,4.5,1.5'
)

probabilities = json.loads(response['Body'].read())[0]
class_names = ['Iris-setosa', 'Iris-versicolor', 'Iris-virginica']
predicted = class_names[probabilities.index(max(probabilities))]
print(f'Predicted: {predicted} ({max(probabilities):.1%} confidence)')
```

**Class label mapping:**

| Label | Class |
|---|---|
| 0 | Iris-setosa |
| 1 | Iris-versicolor |
| 2 | Iris-virginica |

---

## `deploy.sh` — Local Helper Commands

```bash
./deploy.sh backend    # Create S3 Terraform state backend
./deploy.sh init       # Check prereqs, generate pipeline JSON, terraform init
./deploy.sh plan       # terraform plan only
./deploy.sh apply      # Generate pipeline JSON + terraform apply
./deploy.sh upload     # Upload data splits to S3 (triggers pipeline automatically)
./deploy.sh start      # Manually trigger a pipeline execution
./deploy.sh endpoint   # Find best model, approve it, deploy endpoint
./deploy.sh test       # Send a test prediction to the endpoint
./deploy.sh destroy    # Destroy all Terraform-managed resources
./deploy.sh full       # Run everything: backend + init + apply + upload
```

**Important:** When running Terraform locally, always generate `pipeline_definition.json` first:
```bash
cd ml && python3 pipeline_terraform.py && cd ../terraform
terraform apply
```

---

## Hyperparameter Tuning Configuration

| Hyperparameter | Type | Search Range |
|---|---|---|
| `max_depth` | Integer | 3 – 10 |
| `eta` (learning rate) | Continuous | 0.01 – 0.3 |
| `num_round` | Integer | 30 – 150 |

- **Strategy:** Bayesian (learns from previous runs to converge faster than grid search)
- **Objective:** Minimise `validation:mlogloss`
- **Max jobs:** 9 (configurable via `max_tuning_jobs`)
- **Parallel jobs:** 3 (configurable via `parallel_tuning_jobs`)

---

## Terraform Variables Reference

| Variable | Default | Description |
|---|---|---|
| `aws_region` | `us-east-1` | AWS region |
| `environment` | `dev` | Environment tag |
| `s3_bucket_name` | — | Existing S3 bucket for artifacts |
| `sagemaker_role_name` | `sagemaker-execution-role` | Existing SageMaker IAM role |
| `pipeline_name` | `tf-iris-xgboost-pipeline` | SageMaker pipeline name |
| `model_package_group_name` | `iris-classification-models` | Model Registry group |
| `enable_auto_trigger` | `true` | Auto-start pipeline on S3 upload |
| `accuracy_threshold` | `0.90` | Minimum accuracy for model registration |
| `max_tuning_jobs` | `9` | Max hyperparameter tuning jobs |
| `parallel_tuning_jobs` | `3` | Parallel tuning jobs |
| `endpoint_instance_type` | `ml.t2.medium` | Inference endpoint instance |
| `enable_endpoint` | `false` | Create real-time endpoint |
| `notification_email` | `""` | Email for SNS pipeline alerts |
| `model_data_url` | `""` | S3 URI of model artifact (Phase 2) |

---

## Production Practices

- **Keyless auth** — GitHub Actions authenticates via OIDC. No AWS access keys stored anywhere.
- **Least privilege** — The CI/CD IAM role is scoped to only the exact API calls Terraform needs for this project's resources.
- **Remote state** — Terraform state stored in S3. Never committed to Git.
- **PR previews** — `pr.yml` runs `terraform plan` on every PR and posts the full plan as a comment before merge.
- **Stratified data splits** — 60/20/20 train/validation/test split with stratification to preserve class balance.
- **Quality gate** — Models that don't reach 90% accuracy on the held-out test set are never registered.
- **Model governance** — Every passing model is versioned in the Model Registry with `PendingManualApproval` — a human approves before production deployment.
- **Deduplication** — Lambda checks for active pipeline executions before starting a new one, preventing race conditions from rapid S3 uploads.
- **Observability** — CloudWatch alarms on endpoint errors and latency. EventBridge routes pipeline success/failure to SNS email alerts.
- **Data capture** — Endpoint captures 100% of inputs and outputs to S3 for future model drift monitoring.
- **S3 lifecycle** — Model artifacts expire after 90 days, evaluation results after 60 days.

---

## Monitoring & Useful Commands

```bash
# Check pipeline execution status
aws sagemaker describe-pipeline-execution \
  --pipeline-execution-arn <arn>

# List all pipeline executions
aws sagemaker list-pipeline-executions \
  --pipeline-name iris-xgboost-pipeline-tf

# Check what models are in the registry
aws sagemaker list-model-packages \
  --model-package-group-name iris-classification-models \
  --sort-by CreationTime --sort-order Descending

# View endpoint status
aws sagemaker describe-endpoint \
  --endpoint-name iris-xgboost-pipeline-tf-endpoint

# Tail Lambda logs
aws logs tail /aws/lambda/iris-xgboost-pipeline-tf-trigger --follow
```

**AWS Console links** (after deploy, `terraform output` shows direct URLs):
- SageMaker Pipeline executions
- Model Registry
- Lambda function
- CloudWatch alarms

---

## Dataset

The [Iris dataset](https://archive.ics.uci.edu/dataset/53/iris) — 150 samples, 3 classes, 4 features.

| Feature | Description |
|---|---|
| SepalLength | Sepal length in cm |
| SepalWidth | Sepal width in cm |
| PetalLength | Petal length in cm |
| PetalWidth | Petal width in cm |

| Label | Class |
|---|---|
| 0 | Iris-setosa |
| 1 | Iris-versicolor |
| 2 | Iris-virginica |