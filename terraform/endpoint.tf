resource "random_id" "endpoint_suffix" {
  count = var.enable_endpoint ? 1 : 0
  byte_length = 4
}

data "aws_sagemaker_prebuilt_ecr_image" "xgboost" {
  repository_name = "sagemaker-xgboost"
  image_tag = "1.7-1"
  region = var.aws_region
}

resource "aws_sagemaker_model" "registered_model" {
  count = var.enable_endpoint ? 1 : 0
  name = "${var.pipeline_name}-model-${random_id.endpoint_suffix[0].hex}"
  execution_role_arn = data.aws_iam_role.sagemaker_execution_role.arn

  primary_container {
    image = data.aws_sagemaker_prebuilt_ecr_image.xgboost.registry_path
    model_data_url = var.model_data_url 
  }
    

    lifecycle {
      create_before_destroy = true
    }

    tags = {
        Purpose = "Real-Time Inference"
        CreatedBy = "Terraform"
    }

}

# Endpoint Config
resource "aws_sagemaker_endpoint_configuration" "model_endpoint_config" {
  count = var.enable_endpoint ? 1 : 0
  name = "${var.pipeline_name}-config-${random_id.endpoint_suffix[0].hex}"

  production_variants {
    variant_name = "AllTraffic"
    model_name = aws_sagemaker_model.registered_model[0].name
    initial_instance_count = 1
    instance_type = var.endpoint_instance_type
    initial_variant_weight = 1.0
  }

  data_capture_config {
    enable_capture = true
    initial_sampling_percentage = 100
    destination_s3_uri = "s3://${data.aws_s3_bucket.ml_bucket.bucket}/endpoint-data-capture/"

    capture_options {
      capture_mode = "InputAndOutput"
    }

    capture_content_type_header {
      csv_content_types = ["text/csv"]
      json_content_types = ["application/json"]
    }
  }

  tags = {
    Purpose = "Endpoint configuration"
    CreatedBy = "Terraform"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Sagemaker endpoint
resource "aws_sagemaker_endpoint" "model_endpoint" {
  count = var.enable_endpoint ? 1 : 0
  name = "${var.pipeline_name}-endpoint"
  endpoint_config_name = aws_sagemaker_endpoint_configuration.model_endpoint_config[0].name

  tags = {
    Purpose = "Real Time ML Inference"
    Environment = var.environment
    CreatedBy = "Terraform"
  }
}

# CW Alarms for Endpoint Monitioring
resource "aws_cloudwatch_metric_alarm" "endpoint_invocation_errors" {
  count = var.enable_endpoint ? 1 : 0
  alarm_name = "${var.pipeline_name}-endpoint-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods = 2
  metric_name = "ModelInvocation5XXErrors"
  namespace = "AWS/SageMaker"
  period = 300
  statistic = "Sum"
  threshold = 5
  alarm_description = "Alert when endpoint has too many 5XX errors"
  treat_missing_data = "notBreaching"

  dimensions = {
    EndpointName = aws_sagemaker_endpoint.model_endpoint[0].name
    VariantName = "AllTraffic"
  }

  alarm_actions = [aws_sns_topic.pipeline_notifications.arn]
}

resource "aws_cloudwatch_metric_alarm" "endpoint_invocation_latency" {
  count = var.enable_endpoint ? 1 : 0
  alarm_name = "${var.pipeline_name}-endpoint-latency"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods = 2
  metric_name = "ModelLatency"
  namespace = "AWS/SageMaker"
  period = 300
  statistic = "Average"
  threshold = 5000
  alarm_description = "Alert when endpoint latency is too high"
  treat_missing_data = "notBreaching"

  dimensions = {
    EndpointName = aws_sagemaker_endpoint.model_endpoint[0].name
    VariantName = "AllTraffic"
  }

  alarm_actions = [aws_sns_topic.pipeline_notifications.arn]
}

# variable for model data url
variable "model_data_url" {
  description = <<-DESC
    S3 URI of model.tar.gz from the best tuning job.
    Leave empty on first apply. After pipeline runs, find the value with:
      aws sagemaker list-training-jobs-for-hyper-parameter-tuning-job \
        --hyper-parameter-tuning-job-name <job-name> \
        --sort-by FinalObjectiveMetricValue --sort-order Ascending \
        --query 'TrainingJobSummaries[0].TrainingJobName' --output text
    Then set:
      model_data_url = "s3://terraform-sagemaker-firstbucket/model-artifacts/<job-name>/output/model.tar.gz"
  DESC
  type    = string
  default = ""

  validation {
    condition     = var.model_data_url == "" || can(regex("^s3://", var.model_data_url))
    error_message = "model_data_url must be an S3 URI starting with s3://, or left empty."
  }
}
