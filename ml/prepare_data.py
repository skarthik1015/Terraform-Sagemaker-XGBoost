# Data Prep - Splits Iris.csv into Train(60%), Validation (20%) & Test(20%)

import pandas as pd
from sklearn.model_selection import train_test_split
import os
import boto3

def prepare_three_way_split():  
    

    input_file = os.path.join("data", "raw", "iris.csv") #path to original iris.csv
    output_dir = "split_data" #directory to save files
    
    train_ratio = 0.6 # training ratio - default 60%
    val_ratio = 0.2 # validation ratio - default 20%
    test_ratio = 0.2 # test ratio - default 20%
    random_state = 42
    
    # validating split ratios
    if abs(train_ratio + val_ratio + test_ratio - 1.0) > 0.001:
        raise ValueError("Ratios must sum up to 1")

    os.makedirs(output_dir, exist_ok=True)

    #loading data
    try:
        df = pd.read_csv(input_file)
    except FileNotFoundError:
        print(f"Dataset {input_file} not found")
        return 
    
    print(f"Total Samples: {len(df)}")
    print(f"Total Columns: {len(df.columns)}")

    # Checking for Species
    if 'Species' not in df.columns:
        raise ValueError("'Species' Column not found")
    
    #print class distribution
    print(f" Original Class Distribution:  {df['Species'].value_counts().sort_index()}")

    # dropping Id cause container expects only label and features
    if "Id" in df.columns:
        df = df.drop(columns="Id")
        
     # Convert Species to numeric labels
    label_mapping = {
        "Iris-setosa": 0,
        "Iris-versicolor": 1,
        "Iris-virginica": 2
    }

    df["Species"] = df["Species"].map(label_mapping)

    if df["Species"].isnull().any():
        raise ValueError("Label mapping failed. Unexpected Species values found.")

    # Reorder columns: label first
    cols = ["Species"] + [col for col in df.columns if col != "Species"]
    df = df[cols]

    print("Label distribution:")
    print(df["Species"].value_counts().sort_index())

    # Splitting Dataset - Separating Test Set - MUST BE UNSEEN
    train_val_df, test_df = train_test_split(
        df,
        test_size= test_ratio,
        random_state= random_state,
        stratify=df["Species"]
    )

    val_ratio_adjusted = val_ratio / (train_ratio + val_ratio)

    # Splitting train_val_df into Train and Validation sets
    train_df, val_df = train_test_split(
        train_val_df,
        test_size= val_ratio_adjusted,
        random_state= random_state,
        stratify= train_val_df["Species"]
    )

    #printing split data sizes
    print(f" Training Split: {len(train_df)} samples")
    print(f" Validation Split: {len(val_df)} samples")
    print(f" Test Split: {len(test_df)} samples")
    print(f" Total Samples: { len(train_df) + len(val_df) + len(test_df)} samples")


    # saving datasets
    train_path = os.path.join(output_dir, "iris_train.csv")
    val_path = os.path.join(output_dir, "iris_validation.csv")
    test_path = os.path.join(output_dir, "iris_test.csv")


    # saving without header as per container expectations
    train_df.to_csv(train_path, index = False, header = False)
    val_df.to_csv(val_path, index = False, header = False)
    test_df.to_csv(test_path, index = False, header = False)

    print(f"Files saved at {output_dir}")
    print(f" Training Dataset at {train_path}")
    print(f" Validation Dataset at {val_path}")
    print(f" Test Dataset at {test_path}")

    # Verify class distributions in splits
    print(f"Training set: {len(train_df)} samples: ")
    print(train_df['Species'].value_counts().sort_index())

    print(f"Validation set: {len(val_df)} samples: ")
    print(val_df['Species'].value_counts().sort_index())

    print(f"Test set: {len(test_df)} samples: ")
    print(test_df['Species'].value_counts().sort_index())


    # Uploading files to S3
    s3 = boto3.client("s3")
    bucket = os.environ.get("S3_BUCKET", "terraform-sagemaker-firstbucket")

    s3.upload_file(train_path, bucket, "data/train/iris.csv")
    s3.upload_file(val_path, bucket, "data/validation/iris.csv")
    s3.upload_file(test_path, bucket, "data/test/iris.csv")

    print("Uploaded files to S3.")

if __name__ == "__main__":
    prepare_three_way_split()