terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  default = "us-east-1"
}
variable "github_org" {
  type        = string
  description = "Github username or org (e.g. skarthik1015). No default — must be explicit."
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
}
variable "s3_bucket_name" {
  default = "terraform-sagemaker-firstbucket"
}
variable "tfstate_bucket_name" {
  default = "terraform-sagemaker-firstbucket-tfstate"
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# -----------------------------------------------------------------------
# CHANGE: Switched from data source to resource block.
# The data source required the provider to already exist, causing a
# "couldn't find resource" error on first bootstrap apply.
# Using a resource block lets Terraform create it if missing, or manage
# the existing one after import.
# CHANGE: Added lifecycle prevent_destroy so it can never be accidentally
# deleted by a terraform destroy — losing it would break all CI/CD auth.
# CHANGE: Updated thumbprint to the real value from AWS console:
# 2b18947a6a9fc7764fd8b5fb18a863b0c6dac24f
# -----------------------------------------------------------------------
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

  # CHANGE: Fixed JSON key "version" -> "Version" (capital V).
  # AWS IAM silently accepted it before but the policy version field
  # must be capitalised per the IAM policy language spec.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        # CHANGE: Was referencing aws_iam_openid_connect_provider.github_org.arn
        # (wrong resource name). Fixed to match the resource name above.
        Federated = aws_iam_openid_connect_provider.github.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
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

  tags = {
    Purpose = "GitHub Actions CI/CD for Iris MLOps"
  }
}

resource "aws_iam_role_policy" "github_actions_policy" {
  name = "github-actions-iris-mlops-policy"
  role = aws_iam_role.github_actions_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [

      # -----------------------------------------------------------------
      # S3 — unchanged, was already correct
      # -----------------------------------------------------------------
      {
        Sid    = "S3"
        Effect = "Allow"
        Action = [
          "s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket",
          "s3:GetBucketVersioning", "s3:PutBucketVersioning",
          "s3:GetEncryptionConfiguration", "s3:PutEncryptionConfiguration",
          "s3:GetLifecycleConfiguration", "s3:PutLifecycleConfiguration",
          "s3:GetBucketNotification", "s3:PutBucketNotification",
          "s3:GetBucketLocation",
          # CHANGE: Added — Terraform calls GetBucketTagging when refreshing
          # aws_s3_bucket_lifecycle_configuration and bucket data sources.
          "s3:GetBucketTagging", "s3:PutBucketTagging",
          # CHANGE: Added — needed for aws_s3_bucket_server_side_encryption_configuration refresh
          "s3:GetBucketPolicy", "s3:PutBucketPolicy"
        ]
        Resource = [
          "arn:aws:s3:::${var.s3_bucket_name}",
          "arn:aws:s3:::${var.s3_bucket_name}/*",
          "arn:aws:s3:::${var.tfstate_bucket_name}",
          "arn:aws:s3:::${var.tfstate_bucket_name}/*"
        ]
      },

      # -----------------------------------------------------------------
      # DynamoDB — unchanged, was already correct
      # -----------------------------------------------------------------
      {
        Sid    = "DynamoDB"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem", "dynamodb:PutItem",
          "dynamodb:DeleteItem", "dynamodb:DescribeTable"
        ]
        Resource = "arn:aws:dynamodb:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:table/terraform-state-locks"
      },

      # -----------------------------------------------------------------
      # SageMaker — added missing read/list actions Terraform calls
      # during state refresh of aws_sagemaker_pipeline and model registry
      # -----------------------------------------------------------------
      {
        Sid    = "SageMaker"
        Effect = "Allow"
        Action = [
          "sagemaker:CreatePipeline", "sagemaker:UpdatePipeline", "sagemaker:DeletePipeline",
          "sagemaker:DescribePipeline", "sagemaker:StartPipelineExecution",
          "sagemaker:ListPipelineExecutions", "sagemaker:DescribePipelineExecution",
          "sagemaker:ListPipelineExecutionSteps",
          # CHANGE: Added — Terraform refreshes pipeline definition via this
          "sagemaker:DescribePipelineDefinitionForExecution",
          "sagemaker:CreateModelPackageGroup", "sagemaker:DescribeModelPackageGroup",
          "sagemaker:DeleteModelPackageGroup", "sagemaker:PutModelPackageGroupPolicy",
          "sagemaker:GetModelPackageGroupPolicy", "sagemaker:ListModelPackages",
          "sagemaker:DescribeModelPackage", "sagemaker:UpdateModelPackage",
          "sagemaker:CreateModel", "sagemaker:DescribeModel", "sagemaker:DeleteModel",
          "sagemaker:CreateEndpointConfig", "sagemaker:DescribeEndpointConfig",
          "sagemaker:DeleteEndpointConfig", "sagemaker:CreateEndpoint",
          "sagemaker:DescribeEndpoint", "sagemaker:DeleteEndpoint",
          "sagemaker:UpdateEndpoint",
          "sagemaker:ListTags", "sagemaker:AddTags", "sagemaker:DeleteTags",
          # CHANGE: Added — needed for data.aws_sagemaker_prebuilt_ecr_image lookup
          "sagemaker:DescribeImageVersion"
        ]
        Resource = "*"
      },

      # -----------------------------------------------------------------
      # IAM — added missing actions for role policy refresh
      # -----------------------------------------------------------------
      {
        Sid    = "IAM"
        Effect = "Allow"
        Action = [
          "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:PassRole",
          "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:GetRolePolicy",
          "iam:ListRolePolicies", "iam:AttachRolePolicy", "iam:DetachRolePolicy",
          "iam:ListAttachedRolePolicies", "iam:TagRole", "iam:UntagRole",
          "iam:ListInstanceProfilesForRole",
          # CHANGE: Added — Terraform calls these when refreshing inline policies
          # on aws_iam_role resources (eventbridge, lambda, sns roles)
          "iam:ListRoleTags",
          "iam:CreateOpenIDConnectProvider", "iam:GetOpenIDConnectProvider",
          # CHANGE: Added — needed to update the OIDC provider thumbprint if it changes
          "iam:UpdateOpenIDConnectProviderThumbprint",
          "iam:TagOpenIDConnectProvider"
        ]
        Resource = [
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.pipeline_name}-*",
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/github-actions-iris-mlops",
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/token.actions.githubusercontent.com"
        ]
      },

      # -----------------------------------------------------------------
      # IAM read for the pre-existing SageMaker execution role
      # -----------------------------------------------------------------
      {
        Sid    = "IAMReadExisting"
        Effect = "Allow"
        Action = [
          "iam:GetRole", "iam:ListRolePolicies", "iam:GetRolePolicy",
          "iam:ListAttachedRolePolicies", "iam:ListRoleTags"
        ]
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/sagemaker-execution-role"
      },

      # -----------------------------------------------------------------
      # Lambda — CHANGE: Added missing actions that caused the 403 errors:
      #   lambda:ListVersionsByFunction — Terraform calls this every time it
      #     refreshes aws_lambda_function resource state.
      #   lambda:GetFunctionCodeSigningConfig — called during refresh
      #   lambda:GetRuntimeManagementConfig — called during refresh
      #   lambda:ListFunctionEventInvokeConfigs — called during refresh
      # -----------------------------------------------------------------
      {
        Sid    = "Lambda"
        Effect = "Allow"
        Action = [
          "lambda:CreateFunction", "lambda:UpdateFunctionCode",
          "lambda:UpdateFunctionConfiguration", "lambda:DeleteFunction",
          "lambda:GetFunction", "lambda:GetFunctionConfiguration",
          "lambda:AddPermission", "lambda:RemovePermission",
          "lambda:TagResource", "lambda:ListTags", "lambda:GetPolicy",
          # CHANGE: These were missing — all called by Terraform during refresh
          "lambda:ListVersionsByFunction",
          "lambda:GetFunctionCodeSigningConfig",
          "lambda:GetRuntimeManagementConfig",
          "lambda:ListFunctionEventInvokeConfigs",
          "lambda:GetFunctionConcurrency"
        ]
        Resource = "arn:aws:lambda:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:function:${var.pipeline_name}-*"
      },

      # -----------------------------------------------------------------
      # EventBridge — unchanged, was already correct
      # -----------------------------------------------------------------
      {
        Sid    = "EventBridge"
        Effect = "Allow"
        Action = [
          "events:PutRule", "events:DeleteRule", "events:DescribeRule",
          "events:PutTargets", "events:RemoveTargets", "events:ListTargetsByRule",
          "events:TagResource", "events:ListTagsForResource",
          # CHANGE: Added — Terraform calls this when refreshing event targets
          "events:ListRuleNamesByTarget"
        ]
        Resource = "arn:aws:events:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:rule/${var.pipeline_name}-*"
      },

      # -----------------------------------------------------------------
      # SNS — CHANGE: Added missing actions that caused the 403 errors:
      #   sns:ListTagsForResource — Terraform calls this every time it
      #     refreshes aws_sns_topic resource state (to read tags).
      #   sns:GetTopicAttributes — needed for aws_sns_topic_policy refresh
      # -----------------------------------------------------------------
      {
        Sid    = "SNS"
        Effect = "Allow"
        Action = [
          "sns:CreateTopic", "sns:DeleteTopic",
          "sns:GetTopicAttributes", "sns:SetTopicAttributes",
          "sns:Subscribe", "sns:Unsubscribe", "sns:ListSubscriptionsByTopic",
          "sns:TagResource", "sns:UntagResource",
          "sns:GetSubscriptionAttributes",
          # CHANGE: This was the direct cause of the latest 403 error
          "sns:ListTagsForResource",
          # CHANGE: Added — needed for aws_sns_topic_policy CRUD
          "sns:GetDataProtectionPolicy", "sns:PutDataProtectionPolicy"
        ]
        Resource = "arn:aws:sns:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:${var.pipeline_name}-*"
      },

      # -----------------------------------------------------------------
      # CloudWatch / Logs — CHANGE: Added missing log tag actions.
      # logs:ListTagsForResource replaces the deprecated ListTagsLogGroup.
      # -----------------------------------------------------------------
      {
        Sid    = "CloudWatch"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup", "logs:DeleteLogGroup", "logs:DescribeLogGroups",
          # CHANGE: logs:ListTagsLogGroup is deprecated — added the replacement
          "logs:ListTagsLogGroup", "logs:ListTagsForResource",
          "logs:PutRetentionPolicy", "logs:TagLogGroup", "logs:TagResource",
          "cloudwatch:PutMetricAlarm", "cloudwatch:DeleteAlarms",
          "cloudwatch:DescribeAlarms", "cloudwatch:ListTagsForResource",
          "cloudwatch:TagResource"
        ]
        Resource = "*"
      },

      # -----------------------------------------------------------------
      # ECR — unchanged, was already correct
      # -----------------------------------------------------------------
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

# -----------------------------------------------------------------
# Outputs
# CHANGE: Added all Variables (non-sensitive) to next_steps output
# so you can copy-paste them directly into GitHub settings.
# -----------------------------------------------------------------
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
      AWS_REGION   = ${data.aws_region.current.id}

    Variables (non-sensitive):
      AWS_ACCOUNT_ID       = ${data.aws_caller_identity.current.account_id}
      ML_S3_BUCKET         = ${var.s3_bucket_name}
      PIPELINE_NAME        = ${var.pipeline_name}
      MODEL_PACKAGE_GROUP  = iris-classification-models
      SAGEMAKER_ROLE_NAME  = sagemaker-execution-role

    Then push your code and watch GitHub Actions run.
  EOT
}
