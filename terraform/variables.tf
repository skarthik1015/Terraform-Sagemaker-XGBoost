variable "aws_region" {
    description = "AWS region for resources"
    type = string
    default = "us-east-1"
}

variable "environment" {
    description = "Environment Name (dev, staging, prod)"
    type = string
    default = "dev"
}

variable "owner" {
  description = "Project Owner/ Team"
  type = string
  default = "karthik"
}

variable "s3_bucket_name" {
    description = "Name of Existing S3 bucket for ML Artifacts"
    type = string
    default = "terraform-sagemaker-firstbucket"    
}

variable "sagemaker_role_name" {
  description = "Name of Existing Sagemaker IAM Execution Role"
  type = string
  default = "sagemaker-execution-role"
}

variable "pipeline_name" {
  description = "Sagemaker Pipeline Name"
  type = string
  default = "iris-xgboost-pipeline-tf"
}

variable "model_package_group_name" {
  description = "Model registry group name"
  type = string
  default = "iris-classification-models"
}

variable "enable_auto_trigger" {
  description = "Enable automatic pipeline triggering on s3 uploads"
  type = bool
  default = true
}

variable "accuracy_threshold" {
  description = "Min accuracy for model registration"
  type = number
  default = 0.90
}

variable "max_tuning_jobs" {
  description = "Maximum hyperparameter tuning jobs"
  type = number
  default = 9
}

variable "parallel_tuning_jobs" {
  description = "Parallel hyperparamter tuning jobs"
  type = number
  default = 3
}

variable "endpoint_instance_type" {
  description = "Instance type for model endpoint"
  type = string
  default = "ml.t2.medium"
}

variable "enable_endpoint" {
  description = "Whether to create an Inference endpoint"
  type = bool
  default = false
}

variable "notification_email" {
  description = "Email address to receive pipeline success/failure alerts"
  type = string
  default = "" # Set in terraform.tfvars
}