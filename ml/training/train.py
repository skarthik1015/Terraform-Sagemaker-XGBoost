# Training & Tuning XGBoost

import argparse
import os
import pandas as pd
import xgboost as xgb

from sklearn.metrics import accuracy_score, classification_report


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--data-dir", type=str, default="/opt/ml/input/data/train")
    parser.add_argument("--model-dir", type=str, default="/opt/ml/model")
    parser.add_argument("--num_round", type=int, default=50)
    parser.add_argument("--max_depth", type=int, default=3)
    parser.add_argument("--eta", type=float, default=0.1)
    
    # hyperparameters from estimator
    parser.add_argument("--validation-dir", type=str, default=None)
    parser.add_argument("--num_class", type=int, default=3)
    parser.add_argument("--objective", type=str, default="multi:softprob")

    args = parser.parse_args()

    #loading dataset
    data_path = os.path.join(args.data_dir, os.listdir(args.data_dir)[0])
    print(f"Loading training data from: {data_path}")

    df = pd.read_csv(data_path, header=None)
    df.columns = ["Species", "SepalLength", "SepalWidth", "PetalLength", "PetalWidth"]

    print(f"Training data shape: {df.shape}")
    print(f"Class distribution:\n {df['Species'].value_counts()}")

    #dropping "id" cause its not a feature
    if "Id" in df.columns:
        df = df.drop(columns = ["Id"])

    # ensures labels are int
    df["Species"] = df["Species"].astype(int)

    #split features and target
    # No train_test_split - use ALL data for training
    # The pipeline provides pre-split data, so we train on the entire training set
    X_train = df.drop("Species", axis=1)
    y_train = df["Species"]

    dtrain = xgb.DMatrix(X_train, label = y_train)

    evals = []
    dval = None

    validation_dir = os.environ.get('SM_CHANNEL_VALIDATION', args.validation_dir)
    print(f"Checking validation dir: {validation_dir}")

    #claude
    if validation_dir:
        if os.path.exists(validation_dir):
            val_files = os.listdir(validation_dir)
            print(f"Files in validation dir: {val_files}")
            
            if val_files:
                val_path = os.path.join(validation_dir, val_files[0])
                print(f"Loading validation data from: {val_path}")
                
                df_val = pd.read_csv(val_path, header=None)
                df_val.columns = ["Species", "SepalLength", "SepalWidth", "PetalLength", "PetalWidth"]
                df_val["Species"] = df_val["Species"].astype(int)

                X_val = df_val.drop("Species", axis=1)
                y_val = df_val["Species"]

                dval = xgb.DMatrix(X_val, label=y_val)
                evals = [(dval, 'validation')]
                
                print(f"Validation Samples: {len(X_val)}")
                print(f"Validation class distribution:\n{df_val['Species'].value_counts()}")
            else:
                print(f"WARNING: No files found in {validation_dir}")
        else:
            print(f"WARNING: Validation directory does not exist: {validation_dir}")
    else:
        print(f"WARNING: No validation directory provided")
    
    print(f"{'='*60}\n")

    #XGBoost Parameters
    params = {
        "objective": args.objective,
        "num_class": args.num_class,
        "max_depth": args.max_depth,
        "eta": args.eta,
        "eval_metric": "mlogloss"
    }

    print(f"Training with parameters: {params}")
    print(f"Number of rounds: {args.num_round}\n")

    evals_result = {}

    #model
    model = xgb.train(
        params = params,
        dtrain = dtrain,
        num_boost_round = args.num_round,
        evals = evals,
        evals_result = evals_result,
        verbose_eval = True #printing progress every 10 rounds
    )


    # Claude - CRITICAL: Print metrics for SageMaker tuner
    if evals and dval is not None:
        print(f"\n{'='*60}")
        print("VALIDATION METRICS")
        print(f"{'='*60}")
        
        # Get predictions
        y_pred = model.predict(dval)
        y_pred_labels = y_pred.argmax(axis=1)
        
        # Calculate metrics
        val_accuracy = accuracy_score(y_val, y_pred_labels)
        
        # Extract mlogloss from evals_result dictionary
        final_mlogloss = evals_result['validation']['mlogloss'][-1]
        
        # CRITICAL: Print in format SageMaker expects
        print(f"validation:mlogloss={final_mlogloss};")
        print(f"validation:accuracy={val_accuracy}")
        
        print(f"\nValidation Accuracy: {val_accuracy:.6f}")
        print(f"Validation MLogloss: {final_mlogloss:.6f}")
        print(f"\nClassification Report:")
        print(classification_report(y_val, y_pred_labels))
        print(f"{'='*60}\n")
    else:
        print(f"\n WARNING: No validation metrics computed!")
        print(f"   evals is empty: {len(evals) == 0}")
        print(f"   dval is None: {dval is None}\n")

    #saving model
    os.makedirs(args.model_dir, exist_ok=True)
    model_path = os.path.join(args.model_dir, "model.bst")
    model.save_model(model_path)

    print(f"Model saved to {model_path}")

