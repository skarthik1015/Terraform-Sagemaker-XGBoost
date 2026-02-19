terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0"}
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  default = "us-east-1"
}
variable "github_org" {
  type = string
  description = "Github username or org"
}

variable "github_repo" {
  type = string
  description = "Repo name without org/ prefix"
}

variable "pipeline_name" {
  default = "tf-sagemaker-iris-pipeline"
}

variable "s3_bucket_name" {
  default = "terraform-sagemaker-firstbucket"
}

variable "tfstate_bucket_name" {
  default = "terraform-sagemaker-firstbucket-tfstate"
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# GitHub OIDC Provider
resource "aws_iam_openid_connect_provider" "github_org" {
  url = "https://token.actions.githubusercontent.com"
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
  client_id_list = ["sts.amazonaws.com"]
  tags = {
    Purpose = "Github Actions OIDC"
    ManagedBy = "Terraform"
  }
}

# IAM Role for Github Actions
resource "aws_iam_role" "github_actions_role" {
  name = "github-actions-iris-mlops"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"

    Statement = [{
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github_org.arn 
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
    Purpose = "Github Actions CI/CD for Iris MLOps"
  }
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
          "s3:GetBucketNotification", "s3:PutBucketNotification", "s3:GetBucketLocation"
        ]
        Resource = [
          "arn:aws:s3:::${var.s3_bucket_name}",
          "arn:aws:s3:::${var.s3_bucket_name}/*",
          "arn:aws:s3:::${var.tfstate_bucket_name}",
          "arn:aws:s3:::${var.tfstate_bucket_name}/*"
        ]
      },
      {
        Sid      = "DynamoDB"
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem", "dynamodb:DescribeTable"]
        Resource = "arn:aws:dynamodb:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:table/terraform-state-locks"
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
        Action = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:DescribeRepositories", "ecr:GetAuthorizationToken"]
        Resource = "*"
      }
    ]
  })
}

# Outputs - copy these values into GitHub Secrets / Variables
output "github_actions_role_arn" {
  description = "Add as GitHub Secret: AWS_ROLE_ARN"
  value       = aws_iam_role.github_actions_role.arn
}

output "next_steps" {
  value = <<-EOT
    Bootstrap complete!
    GitHub repo → Settings → Secrets and variables → Actions

    Add Secrets:
      AWS_ROLE_ARN   = ${aws_iam_role.github_actions_role.arn}
      AWS_REGION     = ${data.aws_region.current.name}

    Add Variable (not Secret):
      AWS_ACCOUNT_ID = ${data.aws_caller_identity.current.account_id}

    Then push your code and watch GitHub Actions run.
  EOT
}
