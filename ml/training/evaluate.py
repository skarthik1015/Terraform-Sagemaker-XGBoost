# Testing XGBoost on unseen test data

import json
import os
import pandas as pd
import xgboost as xgb
import tarfile

from sklearn.metrics import accuracy_score, classification_report, confusion_matrix

if __name__ == "__main__":
    
    # sagemaker processing paths
    model_dir = "/opt/ml/processing/model"
    test_data_dir = "/opt/ml/processing/test"
    output_dir = "/opt/ml/processing/evaluation"

    # extracting the model saved as model.tar.gz
    model_tar_path = os.path.join(model_dir, "model.tar.gz")
    if os.path.exists(model_tar_path):
        print(f"Extracting Model from: {model_tar_path}")

        with tarfile.open(model_tar_path, "r:gz") as tar:
            tar.extractall(path=model_dir)
        print(f"Model extracted successfully to {model_dir}")
    else:
        print(f"Model not found at {model_tar_path}")

    #paths
    model_path = os.path.join(model_dir, "model.bst")
    test_data_path = os.path.join(test_data_dir, "iris.csv")
    output_path = os.path.join(output_dir, "evaluation.json")

    #loading test data
    df = pd.read_csv(test_data_path, header= None)
    df.columns = ["Species", "SepalLength", "SepalWidth", "PetalLength", "PetalWidth"]
    print(f"Test data shape: {df.shape}")

    #Dropping Id
    if "Id" in df.columns:
        df = df.drop(columns = ["Id"])

    # ensure labels are int
    df['Species'] = df['Species'].astype(int)

    #splitting features
    X = df.drop("Species", axis = 1)
    y = df["Species"]

    #loading trained model
    model = xgb.Booster()
    model.load_model(model_path)

    #running predictions
    dtest = xgb.DMatrix(X)
    predictions = model.predict(dtest)
    preds_labels = predictions.argmax(axis=1)

    class_names = [
    "Iris-setosa",
    "Iris-versicolor",
    "Iris-virginica"
    ]

    #metrics
    accuracy = accuracy_score(y, preds_labels)
    conf_matrix = confusion_matrix(y, preds_labels)
    class_report = classification_report(y, preds_labels, target_names= class_names, output_dict=True)

    #claude metrics
    metrics = {
        "accuracy": float(accuracy),  
        "confusion_matrix": conf_matrix.tolist(), 
        "per_class_metrics": {  
            class_name: {
                "precision": class_report[class_name]["precision"],
                "recall": class_report[class_name]["recall"],
                "f1-score": class_report[class_name]["f1-score"],
                "support": int(class_report[class_name]["support"])
            }
            for class_name in class_names
        },
        "macro_avg": {  
            "precision": class_report["macro avg"]["precision"],
            "recall": class_report["macro avg"]["recall"],
            "f1-score": class_report["macro avg"]["f1-score"]
        }
    }

    #saving metrics
    os.makedirs(output_dir, exist_ok=True)

    with open(output_path, "w") as f:
        json.dump(metrics,f, indent=2)

    print(f"Evaluation Metrics are saved at {output_path}")

    # Claude output formatting
    print("\n" + "="*60)
    print("📈 EVALUATION RESULTS")
    print("="*60)
    print(f"\n🎯 Overall Accuracy: {accuracy:.4f} ({accuracy*100:.2f}%)")
    
    print(f"\n📊 Per-Class Performance:")
    for class_name in class_names:
        print(f"\n{class_name}:")
        print(f"  Precision: {class_report[class_name]['precision']:.4f}")
        print(f"  Recall:    {class_report[class_name]['recall']:.4f}")
        print(f"  F1-Score:  {class_report[class_name]['f1-score']:.4f}")
        print(f"  Support:   {int(class_report[class_name]['support'])} samples")
    
    print(f"\n🔢 Confusion Matrix:")
    print(conf_matrix)
    
    print(f"\n✅ Evaluation metrics saved to: {output_path}")
    print("="*60 + "\n")

    # ✨ NEW: Also print metrics as JSON for easy parsing
    print("\n📄 Full metrics (JSON):")
    print(json.dumps(metrics, indent=2))



    




