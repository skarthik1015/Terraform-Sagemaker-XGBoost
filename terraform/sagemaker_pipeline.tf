# Sagemaker Pipeline and Model Registry Config

# Generating pipeline definition before Terraform applies
resource "null_resource" "generate_pipeline_definition" {
  triggers = {
    # Regenerating if any python files change
    train_py = filemd5("${path.module}/../ml/training/train.py")
    evaluate_py = filemd5("${path.module}/../ml/training/evaluate.py")
    pipeline_py = filemd5("${path.module}/../ml/pipeline_terraform.py")

    # also triggering on infra changes
    role_arn = data.aws_iam_role.sagemaker_execution_role.arn
    bucket = data.aws_s3_bucket.ml_bucket.bucket
  }

    provisioner "local-exec" {
        command = <<-EOT
            cd ${path.module}/../ml
            export SAGEMAKER_ROLE_ARN="${data.aws_iam_role.sagemaker_execution_role.arn}"
            export S3_BUCKET="${data.aws_s3_bucket.ml_bucket.bucket}"
            export MODEL_PACKAGE_GROUP="${aws_sagemaker_model_package_group.model_registry.model_package_group_name}"
            export PIPELINE_NAME="${var.pipeline_name}"
            python3 pipeline_terraform.py
        EOT
    }

    depends_on = [
      aws_sagemaker_model_package_group.model_registry
    ]
}

# Model Registry
resource "aws_sagemaker_model_package_group" "model_registry" {
  model_package_group_name = var.model_package_group_name
  model_package_group_description = "Model Registry for Iris classification model with version control and approval workflow"
  
  tags = {
    Purpose = "Model versioning and governance"
  }
}

# Claude
# Model Package Group Policy for cross-account/cross-team access
resource "aws_sagemaker_model_package_group_policy" "model_registry_policy" {
  model_package_group_name = aws_sagemaker_model_package_group.model_registry.model_package_group_name

  resource_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowAccountAccess"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action = [
          "sagemaker:DescribeModelPackage",
          "sagemaker:DescribeModelPackageGroup",
          "sagemaker:ListModelPackages",
          "sagemaker:UpdateModelPackage",
          "sagemaker:CreateModel"
        ]
        Resource = aws_sagemaker_model_package_group.model_registry.arn
      }
    ]
  })
}


# Sagemaker Pipeline
resource "aws_sagemaker_pipeline" "ml_pipeline" {
  pipeline_name = var.pipeline_name
  pipeline_display_name = "iris-classification-mlops-terraform"
  role_arn = data.aws_iam_role.sagemaker_execution_role.arn

  pipeline_definition = file("${path.module}/../ml/pipeline_definition.json")

  # Pipeline must be recreated if definition changes
  depends_on = [ null_resource.generate_pipeline_definition ] 

  tags = {
    Description = "Tuning-Evaluation-ConditionalRegistration-Endpoint"
    Version = "2.0"
  } 
}
