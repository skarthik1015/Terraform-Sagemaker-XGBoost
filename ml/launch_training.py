import sagemaker
from sagemaker.estimator import Estimator
from sagemaker import image_uris

#creating sagemaker session
session = sagemaker.Session()
region = session.boto_region_name

# IAM role arn created via terraform
role = "arn:aws:iam::941377155192:role/sagemaker-execution-role"

# Getting official sagemaker XGBoost image
image_uri = image_uris.retrieve(
    framework = "xgboost",
    region = region,
    version = "1.7-1"
)

estimator = Estimator(
    image_uri = image_uri,
    role = role,
    instance_count = 1,
    instance_type = "ml.m5.large",
    volume_size = 5,
    max_run = 3600,
    output_path = "s3://terraform-sagemaker-firstbucket/model-artifacts/",
    sagemaker_session = session,
    entry_point = "train.py",
    source_dir = "training",
    hyperparameters = {
        "num_round": 50
    }
)

# Launching the training job
estimator.fit(
    {
        "train": "s3://terraform-sagemaker-firstbucket/data/train/"
    }
)