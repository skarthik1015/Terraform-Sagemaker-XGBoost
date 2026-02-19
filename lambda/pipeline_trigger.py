# Lambda function to automatically start sagemaker pipeline when new training data is uploaded

import os
import json
import boto3
import logging
from datetime import datetime

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Initialize client
sagemaker_client = boto3.client('sagemaker')
#s3 = boto3.client('s3')

def is_pipeline_running(pipeline_name: str) -> bool:
    try:
        response = sagemaker_client.list_pipeline_executions(
            PipelineName = pipeline_name,
            SortBy = "CreationTime",
            SortOrder = "Descending",
            MaxResults = 5
        )

        active_statuses = {"Executing", "Stopping"}

        for execution in response.get("PipelineExecutionSummaries", []):
            status = execution.get("PipelineExecutionStatus", "")
            if status in active_statuses:
                logger.info(
                    f"Found active execution: {execution['PipelineExecutionArn']} "
                    f"(status: {status})"
                )
                return True

        return False
    
    except Exception as e:
        logger.warning(f"Could not check pipeline execution status: {e}. Proceeding anyway.")
        return False


def handler(event, context):

    """
    Lambda handler function
    
    Event structure from EventBridge:
    {
        "detail": {
            "bucket": {"name": "bucket-name"},
            "object": {"key": "data/train/new-data.csv"}
        }
    }
    """

    pipeline_name = os.environ.get('PIPELINE_NAME')

    if not pipeline_name:
        return{
            'statusCode': 500,
            'body': json.dumps({'error': 'PIPELINE_NAME environment variable not set'})
        }
    
    try:
        # extract s3 event details
        bucket_name = event['detail']['bucket']['name']
        object_key = event['detail']['object']['key']
                
        logger.info(f"Triggered by S3 upload: s3://{bucket_name}/{object_key}")

        #deduplications
        if is_pipeline_running(pipeline_name):
            logger.info(
                f"Pipeline '{pipeline_name}' is already running. "
                f"Skipping new execution trigger."
            )
            return {
                "statusCode": 200,
                "body": json.dumps({
                    "message": "Skipped - pipeline already executing",
                    "pipeline_name": pipeline_name,
                    "trigger": {"bucket": bucket_name, "key": object_key}
                })
            }

        timestamp = datetime.utcnow().strftime('%Y%m%d-%H%M%S')
        execution_name = f"auto-trigger-{timestamp}"

        logger.info(f"Starting pipeline execution: {execution_name}")

        # Start Pipeline Execution
        response = sagemaker_client.start_pipeline_execution(
            PipelineName = pipeline_name,
            PipelineExecutionDisplayName = execution_name,
            PipelineExecutionDescription = f" Auto Triggered by S3 upload at s3://{bucket_name}/{object_key}",
            PipelineParameters = [
                {
                    'Name' : 'InstanceType',
                    'Value': 'ml.m5.large'
                }
            ]
        )

        execution_arn = response['PipelineExecutionArn']

        print("Pipeline execution started successfully!")
        print(f"Execution Arn: {execution_arn}")

        return {                                                #?????
            'statusCode': 200,
            'body': json.dumps({
                'message': 'Pipeline execution started',
                'pipeline_name': pipeline_name,
                'execution_arn': execution_arn,
                'trigger': {
                    'bucket': bucket_name,
                    'key': object_key
                }
            })
        }

    except KeyError as e:
        error_msg = f"Invalid event structure: {str(e)}"
        print(f"{error_msg}")
        return{
            'statusCode' : 400,
            'body' : json.dumps({'error' : error_msg})
        }
    
    except Exception as e:
        error_msg = f"Error starting pipelinel: {str(e)}"
        print(f"{error_msg}")
        return{
            'statusCode' : 500,
            'body' : json.dumps({'error' : error_msg})
        }
