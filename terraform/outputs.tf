output "s3_bucket_name" {
  description = "Name of s3 bucket for ML artifacts"
  value = data.aws_s3_bucket.ml_bucket.bucket
}

output "s3_bucket_arn" {
  description = "ARN of s3 bucket"
  value = data.aws_s3_bucket.ml_bucket.arn
}

output "sagemaker_execution_role_arn" {
  value = data.aws_iam_role.sagemaker_execution_role.arn
}

output "sagemaker_execution_role_name" {
  value = data.aws_iam_role.sagemaker_execution_role.name
}

output "pipeline_name" {
  value = aws_sagemaker_pipeline.ml_pipeline.pipeline_name
}

output "pipeline_arn" {
  value = aws_sagemaker_pipeline.ml_pipeline.arn
}

output "pipeline_id" {
  value = aws_sagemaker_pipeline.ml_pipeline.id
}


# Model Registry Outputs
output "model_package_group_name" {
  description = "Name of the model package group (registry)"
  value = aws_sagemaker_model_package_group.model_registry.model_package_group_name
}

output "model_package_group_arn" {
  description = "ARN of the model package group"
  value = aws_sagemaker_model_package_group.model_registry.arn
}

# Lambda Outputs (if enabled)
output "lambda_function_name" {
  description = "Name of the Lambda function for pipeline triggering"
  value = var.enable_auto_trigger ? aws_lambda_function.pipeline_trigger[0].function_name : null
}

output "lambda_function_arn" {
  description = "ARN of the Lambda function"
  value       = var.enable_auto_trigger ? aws_lambda_function.pipeline_trigger[0].arn : null
}

# EventBridge Outputs (if enabled)
output "eventbridge_s3_rule_name" {
  description = "EventBridge rule watching S3 training data uploads"
  value       = var.enable_auto_trigger ? aws_cloudwatch_event_rule.s3_upload_trigger[0].name : null
}

output "eventbridge_rule_arn" {
  description = "ARN of the EventBridge rule"
  value       = var.enable_auto_trigger ? aws_cloudwatch_event_rule.s3_upload_trigger[0].arn : null
}

output "sns_topic_arn" {
  description = "ARN of the SNS topic for notifications"
  value       = aws_sns_topic.pipeline_notifications.arn
}  

# Endpoint Outputs (if enabled)
output "endpoint_name" {
  description = "Name of the SageMaker endpoint"
  value = (var.enable_endpoint && var.model_data_url != "") ? aws_sagemaker_endpoint.model_endpoint[0].name : null
}

output "find_best_model_command" {
  description = "Run this after pipeline completes to find the best model artifact path"
  value       = <<-EOT

    Step 1 - Find the tuning job name from the pipeline execution:
      aws sagemaker list-pipeline-execution-steps \
        --pipeline-execution-arn <execution-arn> \
        --query 'PipelineExecutionSteps[?StepName==`TuneXGBoostModel`].Metadata.TuningJob.Arn' \
        --output text | xargs -I{} basename {}

    Step 2 - Find the best training job from the tuning job:
      aws sagemaker list-training-jobs-for-hyper-parameter-tuning-job \
        --hyper-parameter-tuning-job-name <tuning-job-name> \
        --sort-by FinalObjectiveMetricValue \
        --sort-order Ascending \
        --query 'TrainingJobSummaries[0].TrainingJobName' \
        --output text

    Step 3 - Get the model artifact S3 path:
      aws sagemaker describe-training-job \
        --training-job-name <best-training-job-name> \
        --query 'ModelArtifacts.S3ModelArtifacts' \
        --output text

    Step 4 - Set model_data_url in terraform.tfvars and run:
      terraform apply
  EOT
}

output "pipeline_start_command" {
  description = "CLI command to manually start the pipeline"
  value       = "aws sagemaker start-pipeline-execution --pipeline-name ${aws_sagemaker_pipeline.ml_pipeline.pipeline_name} --region ${var.aws_region}"
}

output "pipeline_console_url" {
  description = "AWS Console direct link to the pipeline"
  value       = "https://${var.aws_region}.console.aws.amazon.com/sagemaker/home?region=${var.aws_region}#/pipelines/${aws_sagemaker_pipeline.ml_pipeline.pipeline_name}"
}

output "model_registry_console_url" {
  description = "AWS Console direct link to the model registry"
  value       = "https://${var.aws_region}.console.aws.amazon.com/sagemaker/home?region=${var.aws_region}#/model-packages/${aws_sagemaker_model_package_group.model_registry.model_package_group_name}"
}

output "setup_complete_message" {
  description = "Deployment summary and next steps"
  value       = <<-EOT

    =====================================================
    Terraform Infrastructure Deployed Successfully!
    =====================================================

    Resources Managed:
      - S3 Bucket (existing):  ${data.aws_s3_bucket.ml_bucket.bucket}
      - IAM Role  (existing):  ${data.aws_iam_role.sagemaker_execution_role.name}
      - Pipeline  (new):       ${aws_sagemaker_pipeline.ml_pipeline.pipeline_name}
      - Model Registry (new):  ${aws_sagemaker_model_package_group.model_registry.model_package_group_name}
      - Lambda Trigger (new):  ${var.enable_auto_trigger ? aws_lambda_function.pipeline_trigger[0].function_name : "disabled"}
      - SNS Alerts (new):      ${aws_sns_topic.pipeline_notifications.arn}

    =====================================================
    PHASE 1 - Run the Pipeline
    =====================================================
    Option A (auto): Upload training data to trigger automatically:
      aws s3 cp ml/split_data/iris_train.csv s3://${data.aws_s3_bucket.ml_bucket.bucket}/data/train/iris.csv

    Option B (manual): Start directly:
      aws sagemaker start-pipeline-execution --pipeline-name ${aws_sagemaker_pipeline.ml_pipeline.pipeline_name}

    =====================================================
    PHASE 2 - Deploy Endpoint (after pipeline succeeds)
    =====================================================
    1. Run: terraform output find_best_model_command
    2. Follow the 4 steps shown to get the model S3 path
    3. Add to terraform.tfvars:
         model_data_url = "s3://terraform-sagemaker-firstbucket/model-artifacts/<job>/output/model.tar.gz"
    4. Run: terraform apply

    =====================================================
    Console:
      Pipeline:  ${var.aws_region}.console.aws.amazon.com/sagemaker/home#/pipelines/${aws_sagemaker_pipeline.ml_pipeline.pipeline_name}
      Registry:  ${var.aws_region}.console.aws.amazon.com/sagemaker/home#/model-packages/${aws_sagemaker_model_package_group.model_registry.model_package_group_name}
    =====================================================
  EOT
}
