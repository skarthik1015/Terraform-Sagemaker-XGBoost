import os
import json
import sagemaker
from sagemaker.image_uris import retrieve
from sagemaker.estimator import Estimator
from sagemaker.processing import ScriptProcessor, ProcessingInput, ProcessingOutput
from sagemaker.workflow.steps import TuningStep, ProcessingStep
from sagemaker.workflow.pipeline import Pipeline
from sagemaker.workflow.parameters import ParameterInteger, ParameterString
from sagemaker.tuner import HyperparameterTuner, IntegerParameter, ContinuousParameter
from sagemaker.workflow.conditions import ConditionGreaterThanOrEqualTo
from sagemaker.workflow.condition_step import ConditionStep
from sagemaker.workflow.functions import JsonGet
from sagemaker.workflow.properties import PropertyFile
from sagemaker.workflow.step_collections import RegisterModel


role = os.environ.get(
    "SAGEMAKER_ROLE_ARN",
    "arn:aws:iam::941377155192:role/sagemaker-execution-role"
)
bucket = os.environ.get(
    "S3_BUCKET",
    "terraform-sagemaker-firstbucket"
)

session = sagemaker.Session(default_bucket=bucket)
region = session.boto_region_name

model_package_group_name = os.environ.get(
    "MODEL_PACKAGE_GROUP",
    "iris-classification-models"
)
pipeline_name = os.environ.get(
    "PIPELINE_NAME",
    "iris-xgboost-pipeline-tf"
)

MODEL_ARTIFACTS_PREFIX = "model-artifacts"

print(f"Generating Pipeline definition with: ")
print(f" Region: {region}")
print(f" Role: {role}")
print(f" Bucket: {bucket}")
print(f" Model Package Group: {model_package_group_name}")

# Pipeline Parameters
num_round_param = ParameterInteger(
    name="NumRound",
    default_value=50
)

instance_type_param = ParameterString(
    name="InstanceType",
    default_value="ml.m5.large"
)

# XGBoost Image
xgb_image = retrieve(
    framework="xgboost",
    region=region,
    version="1.7-1"
)

# Training Estimator
estimator = Estimator(
    image_uri= xgb_image,
    role= role,
    instance_count=1,
    instance_type= instance_type_param,
    output_path=f"s3://{bucket}/{MODEL_ARTIFACTS_PREFIX}",
    sagemaker_session=session,
    entry_point="train.py",
    source_dir="training",
    hyperparameters={
        "objective" : "multi:softprob",
        "num_class" : 3,
    },
    volume_size=5,
    max_run=3600
)

# Hyperparameter Ranges
hyperparam_ranges = {
    "max_depth" : IntegerParameter(3,10),
    "eta" : ContinuousParameter(0.01, 0.3),
    "num_round" : IntegerParameter(30,150)
}

metric_definitions = [
    { "Name" : "validation:mlogloss" , "Regex" : r"validation:mlogloss=([\d\.]+)" }
] 

# Hyperparameter Tuner
tuner = HyperparameterTuner(
    estimator=estimator,
    hyperparameter_ranges= hyperparam_ranges,
    objective_metric_name="validation:mlogloss",
    objective_type="Minimize",
    metric_definitions=metric_definitions,
    max_jobs=9,
    max_parallel_jobs=3
)

# Tuning Step
tuning_step = TuningStep(
    name="TfTunedXGBoostModel",
    tuner=tuner,
    inputs={
        "train" : f"s3://{bucket}/data/train/",
        "validation" : f"s3://{bucket}/data/validation/"
    }
)

# Script Processor
script_processor = ScriptProcessor(
    image_uri= xgb_image,
    command= ["python3"],
    role=role,
    instance_count=1,
    instance_type=instance_type_param,
    sagemaker_session=session
)

# Property file for Condition Step
evaluation_report = PropertyFile(
    name="EvaluationReport",
    output_name="evaluation",
    path="evaluation.json"
)

# Evaluation Step
evaluation_step = ProcessingStep(
    name="TF_EvaluateXGBoostModel",
    processor= script_processor,
    inputs= [
        ProcessingInput(
            source=tuning_step.get_top_model_s3_uri(top_k=0, s3_bucket=bucket, prefix= MODEL_ARTIFACTS_PREFIX),
            destination="/opt/ml/processing/model"
        ),
        ProcessingInput(
            source=f"s3://{bucket}/data/test/",
            destination="/opt/ml/processing/test"
        )
    ],
    outputs=[
        ProcessingOutput(
            output_name="evaluation",
            source="/opt/ml/processing/evaluation/",
            destination=f"s3://{bucket}/evaluation-results/"
        )
    ],
    code="training/evaluate.py",
    property_files=[evaluation_report]
)


# Model Registration Step
register_step = RegisterModel(
    name="RegisterBestModel",
    estimator=estimator,
    model_data=tuning_step.get_top_model_s3_uri(top_k=0, s3_bucket=bucket, prefix=MODEL_ARTIFACTS_PREFIX),
    content_types=["text/csv"],
    response_types=["text/csv"],
    inference_instances=["ml.m5.large", "ml.t2.medium"],
    transform_instances=["ml.m5.large"],
    model_package_group_name=model_package_group_name,
    approval_status="PendingManualApproval"
)

# Condition for registration
accuracy_condition = ConditionGreaterThanOrEqualTo(
    left=JsonGet(
        step_name=evaluation_step.name,
        property_file=evaluation_report,
        json_path="accuracy"
    ),
    right=0.90
)

# Conditional Step
condition_step = ConditionStep(
    name = "CheckAccuracyThreshold",
    conditions= [accuracy_condition],
    if_steps = [register_step],
    else_steps = []
)

# Pipeline Definition
pipeline = Pipeline(
    name=pipeline_name,
    parameters=[num_round_param, instance_type_param],
    steps=[tuning_step, evaluation_step, condition_step],
    sagemaker_session=session
)

if __name__ == "__main__":
    print("\n Generating Pipeline definition: ")
    try:
        definition = pipeline.definition()
        definition_dict = json.loads(definition)

        output_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "pipeline_definition.json")

        with open(output_path, "w") as f:
            json.dump(definition_dict, f, indent=2)

        print(f"pipeline_definition.json written to: {output_path}")
        print(f"\nTo create/update pipeline: cd terraform && terraform apply")

    except Exception as e:
        print(f" Error: {e}")
        raise


