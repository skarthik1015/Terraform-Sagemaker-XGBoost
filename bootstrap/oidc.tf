# bootstrap/oidc.tf
# -----------------------------------------------------------------------
# ONE-TIME BOOTSTRAP — run from bootstrap/ directory only.
# Has its own terraform state, separate from terraform/.
#
# Usage (first time):
#   cd bootstrap
#   terraform init
#   terraform apply \
#     -var="github_org=skarthik1015" \
#     -var="github_repo=Terraform-Sagemaker-XGBoost" \
#     -var="pipeline_name=iris-xgboost-pipeline-tf"
#
# If pipeline_name ever changes, re-run apply with the new name.
# The IAM policy patterns will update automatically.
# -----------------------------------------------------------------------

terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
  # Bootstrap uses local state — it's a one-time human-run operation,
  # not part of the automated CI/CD apply cycle.
  # Commit bootstrap/terraform.tfstate to the repo so the team shares it,
  # OR store it in S3 by uncommenting the backend block below.
  #
  # backend "s3" {
  #   bucket = "terraform-sagemaker-firstbucket-tfstate"
  #   key    = "bootstrap/terraform.tfstate"
  #   region = "us-east-1"
  # }
}

provider "aws" {
  region = var.aws_region
}

# -----------------------------------------------------------------------
# Variables — NO defaults on pipeline_name or github_org/repo.
# Forcing explicit values prevents the "wrong default silently used" bug
# that caused all the 403 AccessDenied errors in GitHub Actions.
# -----------------------------------------------------------------------

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "github_org" {
  type        = string
  description = "GitHub username or org (e.g. skarthik1015). No default — must be explicit."
}

variable "github_repo" {
  type        = string
  description = "Repo name without org prefix (e.g. Terraform-Sagemaker-XGBoost). No default — must be explicit."
}

variable "pipeline_name" {
  type        = string
  description = <<-DESC
    SageMaker pipeline name. No default — must be passed explicitly.
    Must match the pipeline_name in terraform/terraform.tfvars exactly.
    This value is embedded into IAM resource ARN patterns, so a mismatch
    causes 403 AccessDenied errors in every GitHub Actions run.
    Current value: iris-xgboost-pipeline-tf
  DESC
  # NO DEFAULT — if you forget to pass -var="pipeline_name=..." terraform
  # will prompt you rather than silently using a wrong value.
}

variable "s3_bucket_name" {
  type    = string
  default = "terraform-sagemaker-firstbucket"
}

variable "tfstate_bucket_name" {
  type    = string
  default = "terraform-sagemaker-firstbucket-tfstate"
}

# -----------------------------------------------------------------------

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# GitHub OIDC Provider
# Use data source to read existing provider rather than managing it as a resource.
# This avoids the destroy/recreate cycle that caused the EntityAlreadyExists error.
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  thumbprint_list = ["2b18947a6a9fc7764fd8b5fb18a863b0c6dac24f"]
  client_id_list  = ["sts.amazonaws.com"]

  tags = {
    Purpose   = "GitHub Actions OIDC"
    ManagedBy = "Terraform"
  }

  lifecycle {
    prevent_destroy = true
  }
}

# IAM Role for GitHub Actions
resource "aws_iam_role" "github_actions_role" {
  name = "github-actions-iris-mlops"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_org}/${var.github_repo}:*"
        }
      }
    }]
  })

  tags = { Purpose = "GitHub Actions CI/CD for Iris MLOps" }
}

resource "aws_iam_role_policy" "github_actions_policy" {
  name = "github-actions-iris-mlops-policy"
  role = aws_iam_role.github_actions_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3"
        Effect = "Allow"
        Action = [
          "s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket",
          "s3:GetBucketVersioning", "s3:PutBucketVersioning",
          "s3:GetEncryptionConfiguration", "s3:PutEncryptionConfiguration",
          "s3:GetLifecycleConfiguration", "s3:PutLifecycleConfiguration",
          "s3:GetBucketNotification", "s3:PutBucketNotification",
          "s3:GetBucketLocation", "s3:GetBucketPolicy", "s3:PutBucketPolicy"
        ]
        Resource = [
          "arn:aws:s3:::${var.s3_bucket_name}",
          "arn:aws:s3:::${var.s3_bucket_name}/*",
          "arn:aws:s3:::${var.tfstate_bucket_name}",
          "arn:aws:s3:::${var.tfstate_bucket_name}/*"
        ]
      },
      {
        Sid    = "SageMaker"
        Effect = "Allow"
        Action = [
          "sagemaker:CreatePipeline", "sagemaker:UpdatePipeline", "sagemaker:DeletePipeline",
          "sagemaker:DescribePipeline", "sagemaker:StartPipelineExecution",
          "sagemaker:ListPipelineExecutions", "sagemaker:DescribePipelineExecution",
          "sagemaker:ListPipelineExecutionSteps",
          "sagemaker:CreateModelPackageGroup", "sagemaker:DescribeModelPackageGroup",
          "sagemaker:DeleteModelPackageGroup", "sagemaker:PutModelPackageGroupPolicy",
          "sagemaker:GetModelPackageGroupPolicy", "sagemaker:ListModelPackages",
          "sagemaker:DescribeModelPackage", "sagemaker:UpdateModelPackage",
          "sagemaker:CreateModel", "sagemaker:DescribeModel", "sagemaker:DeleteModel",
          "sagemaker:CreateEndpointConfig", "sagemaker:DescribeEndpointConfig",
          "sagemaker:DeleteEndpointConfig", "sagemaker:CreateEndpoint",
          "sagemaker:DescribeEndpoint", "sagemaker:DeleteEndpoint",
          "sagemaker:UpdateEndpoint", "sagemaker:ListTags", "sagemaker:AddTags"
        ]
        Resource = "*"
      },
      {
        Sid    = "IAM"
        Effect = "Allow"
        Action = [
          "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:PassRole",
          "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:GetRolePolicy",
          "iam:ListRolePolicies", "iam:AttachRolePolicy", "iam:DetachRolePolicy",
          "iam:ListAttachedRolePolicies", "iam:TagRole", "iam:UntagRole",
          "iam:ListInstanceProfilesForRole", "iam:CreateOpenIDConnectProvider",
          "iam:GetOpenIDConnectProvider"
        ]
        Resource = [
          # var.pipeline_name is required (no default) so this pattern
          # always reflects the real pipeline name — no silent mismatch possible.
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.pipeline_name}-*",
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/github-actions-iris-mlops",
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/token.actions.githubusercontent.com"
        ]
      },
      {
        Sid    = "IAMReadExisting"
        Effect = "Allow"
        Action = ["iam:GetRole", "iam:ListRolePolicies", "iam:GetRolePolicy"]
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/sagemaker-execution-role"
      },
      {
        Sid    = "Lambda"
        Effect = "Allow"
        Action = [
          "lambda:CreateFunction", "lambda:UpdateFunctionCode", "lambda:UpdateFunctionConfiguration",
          "lambda:DeleteFunction", "lambda:GetFunction", "lambda:GetFunctionConfiguration",
          "lambda:AddPermission", "lambda:RemovePermission", "lambda:TagResource",
          "lambda:ListTags", "lambda:GetPolicy"
        ]
        Resource = "arn:aws:lambda:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:function:${var.pipeline_name}-*"
      },
      {
        Sid    = "EventBridge"
        Effect = "Allow"
        Action = [
          "events:PutRule", "events:DeleteRule", "events:DescribeRule",
          "events:PutTargets", "events:RemoveTargets", "events:ListTargetsByRule",
          "events:TagResource", "events:ListTagsForResource"
        ]
        Resource = "arn:aws:events:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:rule/${var.pipeline_name}-*"
      },
      {
        Sid    = "SNS"
        Effect = "Allow"
        Action = [
          "sns:CreateTopic", "sns:DeleteTopic", "sns:GetTopicAttributes", "sns:SetTopicAttributes",
          "sns:Subscribe", "sns:Unsubscribe", "sns:ListSubscriptionsByTopic",
          "sns:TagResource", "sns:GetSubscriptionAttributes"
        ]
        Resource = "arn:aws:sns:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:${var.pipeline_name}-*"
      },
      {
        Sid    = "CloudWatch"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup", "logs:DeleteLogGroup", "logs:DescribeLogGroups",
          "logs:ListTagsLogGroup", "logs:PutRetentionPolicy", "logs:TagLogGroup",
          "cloudwatch:PutMetricAlarm", "cloudwatch:DeleteAlarms",
          "cloudwatch:DescribeAlarms", "cloudwatch:ListTagsForResource", "cloudwatch:TagResource"
        ]
        Resource = "*"
      },
      {
        Sid    = "ECR"
        Effect = "Allow"
        Action = [
          "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer",
          "ecr:DescribeRepositories", "ecr:GetAuthorizationToken"
        ]
        Resource = "*"
      }
    ]
  })
}

# -----------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------
output "github_actions_role_arn" {
  description = "Add as GitHub Secret: AWS_ROLE_ARN"
  value       = aws_iam_role.github_actions_role.arn
}

output "next_steps" {
  value = <<-EOT
    Bootstrap complete!
    GitHub repo → Settings → Secrets and variables → Actions

    Secrets (sensitive):
      AWS_ROLE_ARN = ${aws_iam_role.github_actions_role.arn}
      AWS_REGION   = ${data.aws_region.current.name}

    Variables (non-sensitive):
      AWS_ACCOUNT_ID      = ${data.aws_caller_identity.current.account_id}
      ML_S3_BUCKET        = ${var.s3_bucket_name}
      PIPELINE_NAME       = ${var.pipeline_name}
      MODEL_PACKAGE_GROUP = iris-classification-models
      SAGEMAKER_ROLE_NAME = sagemaker-execution-role
  EOT
}
