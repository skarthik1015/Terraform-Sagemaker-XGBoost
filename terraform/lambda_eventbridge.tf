# Lambda and Eventbridge conifg for automated pipeline triggering

resource "aws_sns_topic" "pipeline_notifications" {
  name = "${var.pipeline_name}-notifications"
  tags = { Purpose = "ML pipeline execution alerts" }
}

resource "aws_sns_topic_policy" "pipeline_notifications_policy" {
  arn = aws_sns_topic.pipeline_notifications.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = ["sagemaker.amazonaws.com", "events.amazonaws.com"] }
        Action    = "SNS:Publish"
        Resource  = aws_sns_topic.pipeline_notifications.arn
      }
    ]
  })
}

resource "aws_sns_topic_subscription" "email_subscription" {
  count     = var.notification_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.pipeline_notifications.arn
  protocol  = "email"
  endpoint  = var.notification_email
}

data "archive_file" "lambda_zip" {
  count = var.enable_auto_trigger ? 1 : 0
  type = "zip"
  source_file = "${path.module}/../lambda/pipeline_trigger.py"
  output_path = "${path.module}/../lambda/pipeline_trigger.zip"
}

# Lambda function
resource "aws_lambda_function" "pipeline_trigger" {
  count = var.enable_auto_trigger ? 1 : 0
  filename = data.archive_file.lambda_zip[0].output_path
  function_name = "${var.pipeline_name}-trigger"
  role = aws_iam_role.lambda_execution_role[0].arn
  handler = "pipeline_trigger.handler"
  source_code_hash = data.archive_file.lambda_zip[0].output_base64sha256
  runtime = "python3.11"
  timeout = 60
  memory_size = 128

  environment {
    variables = {
      PIPELINE_NAME = var.pipeline_name
    }
  }

  tags = {
    Name = "Sagemaker Pipeline Trigger"
    Purpose = "Automatically start ML pipeline on s3 events"
  }

  depends_on = [aws_sagemaker_pipeline.ml_pipeline]
}

# Cloudwatch Log group for Lambda
resource "aws_cloudwatch_log_group" "lambda_logs" {
  count = var.enable_auto_trigger ? 1 : 0
  name = "/aws/lambda/${aws_lambda_function.pipeline_trigger[0].function_name}"
  retention_in_days = 14
  
  tags = {
    Purpose = "Lambda execution logs"
  }
}

# Eventbridge rule - trigger on s3 uploads to training data
resource "aws_cloudwatch_event_rule" "s3_upload_trigger" {
  count = var.enable_auto_trigger ? 1 : 0
  name = "${var.pipeline_name}-s3-trigger"
  description = "Trigger Sagemaker pipeline when new training data is uploaded"

  event_pattern = jsonencode({
    source = ["aws.s3"]
    detail-type = ["Object Created"]
    detail = {
        bucket = {name = [data.aws_s3_bucket.ml_bucket.bucket]}
        object = {key = [{prefix = "data/train/"}]}
    }
  })    

  tags = {
    Purpose = "Automated ML Pipeline triggering"
  }
}

# Eventbridge Target - Invoking Lambda
resource "aws_cloudwatch_event_target" "lambda_target" {
  count = var.enable_auto_trigger ? 1 : 0
  rule = aws_cloudwatch_event_rule.s3_upload_trigger[0].name
  target_id = "TriggerLambda"
  arn = aws_lambda_function.pipeline_trigger[0].arn
}

# Permission for Eventbridge to invoke Lambda
resource "aws_lambda_permission" "allow_eventbridge" {
  count = var.enable_auto_trigger ? 1 : 0
  statement_id = "AllowExecutionFromEventBridge"
  action = "lambda:InvokeFunction"
  function_name = aws_lambda_function.pipeline_trigger[0].function_name
  principal = "events.amazonaws.com"
  source_arn = aws_cloudwatch_event_rule.s3_upload_trigger[0].arn
}

resource "aws_cloudwatch_event_rule" "pipeline_failure_alert" {
  name = "${var.pipeline_name}-failure-alert"
  description = "Alert when sagemaker pipeline execution fails"

  event_pattern = jsonencode({
    source = ["aws.sagemaker"]
    detail-type = ["SageMaker Model Building Pipeline Execution Status Change"]
    detail = {
        pipelineArn = [aws_sagemaker_pipeline.ml_pipeline.arn]
        currentPipelineExecutionStatus = ["Failed", "Stopped"]
    }
  })

  depends_on = [ aws_sagemaker_pipeline.ml_pipeline ]

}

resource "aws_cloudwatch_event_target" "pipeline_failure_sns" {
  rule = aws_cloudwatch_event_rule.pipeline_failure_alert.name
  target_id = "PipelineFailureSNS"
  arn = aws_sns_topic.pipeline_notifications.arn
  role_arn = aws_iam_role.eventbridge_sns_role.arn
}


resource "aws_cloudwatch_event_rule" "pipeline_success_alert" {
  name        = "${var.pipeline_name}-success-alert"
  description = "Alert when SageMaker pipeline execution succeeds"

  event_pattern = jsonencode({
    source      = ["aws.sagemaker"]
    detail-type = ["SageMaker Model Building Pipeline Execution Status Change"]
    detail = {
      pipelineArn = [aws_sagemaker_pipeline.ml_pipeline.arn]
      currentPipelineExecutionStatus = ["Succeeded"]
    }
  })

  depends_on = [aws_sagemaker_pipeline.ml_pipeline]
}

resource "aws_cloudwatch_event_target" "pipeline_success_sns" {
  rule      = aws_cloudwatch_event_rule.pipeline_success_alert.name
  target_id = "PipelineSuccessSNS"
  arn       = aws_sns_topic.pipeline_notifications.arn
  role_arn  = aws_iam_role.eventbridge_sns_role.arn
}
