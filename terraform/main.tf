terraform {
  required_version = ">=1.3"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source = "hashicorp/random"
      version = "~> 3.0"
    }
    archive = {
      source = "hashicorp/archive"
      version = "~> 2.0"
    }

    null = {
      source = "hashicorp/null"
      version = "~> 3.0"
    }
  }

  # Remote State backend
  # This keeps your terraform.tfstate safe in S3 with DynamoDB locking
  # so it won't get corrupted if you run terraform from multiple places.
  backend "s3" {
    bucket = "terraform-sagemaker-firstbucket-tfstate"
    key = "iris-mlops/terraform.tfstate"
    region = "us-east-1"
    use_lockfile = true 
    encrypt = true
  }

}



# Configure the AWS Provider
provider "aws" {
  region = var.aws_region
  
  default_tags {
    tags = {
      Project = "iris-classification-mlops"
      ManagedBy = "Terraform"
      Environment = var.environment
      Owner = var.owner
    }
  }
}

# Data Sources
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_s3_bucket" "ml_bucket" {
  bucket = var.s3_bucket_name
}
data "aws_iam_role" "sagemaker_execution_role" {
  name = var.sagemaker_role_name
}

# SSE encryption for existing bucket
resource "aws_s3_bucket_server_side_encryption_configuration" "ml_bucket_sse" {
  bucket = data.aws_s3_bucket.ml_bucket.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

# S3 lifecycle rules to auto-expire old artifacts
resource "aws_s3_bucket_lifecycle_configuration" "ml_artifacts_lifecycle" {
  bucket = data.aws_s3_bucket.ml_bucket.id

  rule {
    id = "expire-old-model-artifacts"
    status = "Enabled"

    filter {
      prefix = "model-artifacts/"
    }

    expiration {
      days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  rule {
    id = "expire-old-evaluation-results"
    status = "Enabled"

    filter {
      prefix = "evaluation-results/"
    }

    expiration {
      days = 60
    }
  }
}

# Enable Eventbridge notifications
resource "aws_s3_bucket_notification" "ml_bucket_notification" {
  bucket = data.aws_s3_bucket.ml_bucket.id
  eventbridge = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate_encryption" {
  bucket = "terraform-sagemaker-firstbucket-tfstate"

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}


# # Blocking public access
# resource "aws_s3_bucket_public_access_block" "ml_bucket_notification" {
#   bucket = aws_s3_bucket.ml_bucket.id

#     block_public_acls       = true
#     block_public_policy     = true
#     ignore_public_acls      = true
#     restrict_public_buckets = true
# }


# # Upload initial dataset
# resource "aws_s3_object" "iris_dataset" {
#   bucket = aws_s3_bucket.ml_bucket.bucket
#   key = "data/raw/iris.csv"
#   source = "${path.module}/../data/raw/iris.csv"
#   etag = filemd5("${path.module}/../data/raw/iris.csv")

#   tags = {
#     Purpose = "Initial RAW Dataset"
#   }
# }

# # VPC Optional (for more secure deployment)
# resource "aws_vpc" "ml_vpc" {
#   count = var.create_vpc ? 1 : 0
#   cidr_block = "10.0.0.0/16"
  
#   enable_dns_hostnames = true
#   enable_dns_support = true

#   tags = {
#     Name = "ml_vpc"
#   }

# }