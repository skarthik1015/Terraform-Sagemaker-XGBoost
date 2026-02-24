# IAM Roles & Policies for Sagemaker MLOps

# Lambda Execution Role
resource "aws_iam_role" "lambda_execution_role" {
  count = var.enable_auto_trigger ? 1 : 0
  name = "${var.pipeline_name}-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
        {
            Effect = "Allow"
            Principal = {
                Service = "lambda.amazonaws.com"
            }
            Action = "sts:AssumeRole"
        }
    ]
  })

  tags = {
    Name = "Lambda Pipeline Trigger Role"
  }
}

# Lambda Policy to start sagemaker pipeline
resource "aws_iam_role_policy" "lambda_sagemaker_policy" {
  count = var.enable_auto_trigger ? 1 : 0
  name_prefix = "${var.pipeline_name}-lambda-sagemaker-policy"
  role = aws_iam_role.lambda_execution_role[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
        {
            Effect = "Allow"
            Action = [
                "sagemaker:StartPipelineExecution",
                "sagemaker:DescribePipeline",
                "sagemaker:ListPipelineExecutions",
                "sagemaker:DescribePipelineExecution"
            ]
            Resource = [
                "arn:aws:sagemaker:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:pipeline/${var.pipeline_name}",
                "arn:aws:sagemaker:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:pipeline/${var.pipeline_name}/*"
            ]
        },
        {
            Effect = "Allow"
            Action = [
                "logs:CreateLogGroup",
                "logs:CreateLogStream",
                "logs:PutLogEvents"
            ]
            Resource = "arn:aws:logs:*:*:*"
        }
    ]
  })
}

# Eventbridge Role
resource "aws_iam_role" "eventbridge_role" {
  count = var.enable_auto_trigger ? 1 : 0
  name = "${var.pipeline_name}-eventbridge-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
        {
            Effect = "Allow"
            Principal = {
                Service = "events.amazonaws.com"
            }
            Action = "sts:AssumeRole"
        }
    ]
  })
}

# Eventbridge Policy to invoke lambda
resource "aws_iam_role_policy" "eventbridge_lambda_policy" {
  count = var.enable_auto_trigger ? 1 : 0
  name_prefix = "${var.pipeline_name}-eventbridge-lambda-policy"
  role = aws_iam_role.eventbridge_role[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
        {
            Effect = "Allow"
            Action = [
                "lambda:InvokeFunction"
            ]
            Resource = aws_lambda_function.pipeline_trigger[0].arn
        }
    ]
  })
}

# EventBridge role for SNS Publishing
resource "aws_iam_role" "eventbridge_sns_role" {
  name = "${var.pipeline_name}-eventbridge-sns-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
        {
            Effect = "Allow"
            Principal = { Service = "events.amazonaws.com"}
            Action = "sts:AssumeRole"
        }
    ]
  })
}

resource "aws_iam_role_policy" "eventbridge_sns_policy" {
  name_prefix = "${var.pipeline_name}-eventbridge-sns-policy"
  role = aws_iam_role.eventbridge_sns_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
        {
            Effect = "Allow"
            Action = ["sns:Publish"]
            Resource = aws_sns_topic.pipeline_notifications.arn
        }
    ]
  })
}