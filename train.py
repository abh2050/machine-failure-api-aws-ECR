"""Train the machine failure classifier and export it to ONNX.

Usage: python train.py
Outputs: model/model.onnx and model/metadata.json
"""

from __future__ import annotations

import hashlib
import io
import json
import urllib.request
import zipfile
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
import onnxruntime as ort
import pandas as pd
import sklearn
from skl2onnx import to_onnx
from sklearn.ensemble import GradientBoostingClassifier
from sklearn.metrics import average_precision_score, precision_recall_curve, precision_score, recall_score
from sklearn.model_selection import train_test_split

from features import FEATURE_ORDER, build_matrix

DATA_URL = "https://archive.ics.uci.edu/static/public/601/ai4i+2020+predictive+maintenance+dataset.zip"
DATA_PATH = Path("data/ai4i2020.csv")
MODEL_DIR = Path("model")
RECALL_TARGET = 0.90
PARITY_TOLERANCE = 1e-3
SEED = 42

COLUMN_MAP = {
    "Type": "type",
    "Air temperature [K]": "air_temp_k",
    "Process temperature [K]": "process_temp_k",
    "Rotational speed [rpm]": "rotational_speed_rpm",
    "Torque [Nm]": "torque_nm",
    "Tool wear [min]": "tool_wear_min",
}
LABEL = "Machine failure"


def load_dataset() -> pd.DataFrame:
    if not DATA_PATH.exists():
        DATA_PATH.parent.mkdir(parents=True, exist_ok=True)
        with urllib.request.urlopen(DATA_URL, timeout=60) as resp:
            archive = zipfile.ZipFile(io.BytesIO(resp.read()))
        csv_name = next(n for n in archive.namelist() if n.endswith(".csv"))
        DATA_PATH.write_bytes(archive.read(csv_name))
    return pd.read_csv(DATA_PATH)


def split(X: np.ndarray, y: np.ndarray):
    """Stratified 70/15/15 train, validation, test split."""
    X_train, X_rest, y_train, y_rest = train_test_split(X, y, test_size=0.30, stratify=y, random_state=SEED)
    X_val, X_test, y_val, y_test = train_test_split(X_rest, y_rest, test_size=0.50, stratify=y_rest, random_state=SEED)
    return X_train, X_val, X_test, y_train, y_val, y_test


def tune_threshold(y_true: np.ndarray, scores: np.ndarray, recall_target: float) -> float:
    """Return the highest threshold whose recall meets the target, which maximizes precision."""
    _, recall, thresholds = precision_recall_curve(y_true, scores)
    # recall has one more entry than thresholds; recall[i] belongs to thresholds[i].
    eligible = thresholds[recall[:-1] >= recall_target]
    if eligible.size == 0:
        raise RuntimeError(f"no threshold reaches recall {recall_target} on the validation split")
    return float(eligible.max())


def export_onnx(model: GradientBoostingClassifier, sample: np.ndarray) -> bytes:
    onx = to_onnx(model, sample[:1], options={id(model): {"zipmap": False}}, target_opset={"": 17, "ai.onnx.ml": 3})
    return onx.SerializeToString()


def onnx_probabilities(onnx_bytes: bytes, X: np.ndarray) -> np.ndarray:
    session = ort.InferenceSession(onnx_bytes, providers=["CPUExecutionProvider"])
    input_name = session.get_inputs()[0].name
    _, probabilities = session.run(None, {input_name: X.astype(np.float32)})
    return probabilities[:, 1]


def main() -> None:
    df = load_dataset().rename(columns=COLUMN_MAP)
    X = build_matrix({name: df[name].to_numpy() for name in COLUMN_MAP.values()})
    y = df[LABEL].to_numpy().astype(int)
    print(f"rows={len(y)} failures={y.sum()} failure_rate={y.mean():.4f}")

    X_train, X_val, X_test, y_train, y_val, y_test = split(X, y)
    print(f"train={len(y_train)} val={len(y_val)} test={len(y_test)}")

    model = GradientBoostingClassifier(random_state=SEED)
    model.fit(X_train, y_train)

    threshold = tune_threshold(y_val, model.predict_proba(X_val)[:, 1], RECALL_TARGET)

    test_scores = model.predict_proba(X_test)[:, 1]
    test_pred = (test_scores >= threshold).astype(int)
    metrics = {
        "pr_auc": round(float(average_precision_score(y_test, test_scores)), 4),
        "recall": round(float(recall_score(y_test, test_pred)), 4),
        "precision": round(float(precision_score(y_test, test_pred, zero_division=0)), 4),
    }
    print(f"threshold={threshold:.4f} test={metrics}")

    onnx_bytes = export_onnx(model, X_train)
    parity = float(np.max(np.abs(onnx_probabilities(onnx_bytes, X_test) - test_scores)))
    print(f"onnx_parity_max_abs_diff={parity:.2e}")
    assert parity < PARITY_TOLERANCE, f"ONNX parity failed: {parity} >= {PARITY_TOLERANCE}"

    version = f"{datetime.now(timezone.utc):%Y%m%d}-{hashlib.sha256(onnx_bytes).hexdigest()[:8]}"
    metadata = {
        "version": version,
        "feature_order": list(FEATURE_ORDER),
        "threshold": threshold,
        "recall_target": RECALL_TARGET,
        "test_metrics": metrics,
        "parity_max_abs_diff": parity,
        "sklearn_version": sklearn.__version__,
    }

    MODEL_DIR.mkdir(exist_ok=True)
    (MODEL_DIR / "model.onnx").write_bytes(onnx_bytes)
    (MODEL_DIR / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(f"wrote {MODEL_DIR / 'model.onnx'} and {MODEL_DIR / 'metadata.json'} version={version}")


if __name__ == "__main__":
    main()
