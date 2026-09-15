"""Generate dummy (randomly initialised) weights for all three models.

This version uses TensorFlow/Keras directly — no PyTorch required.
Architectures mirror the originals in ecg_processor.py and urine_processor.py.

    python train_dummy_models.py

Produces:
    models/ecg_cnn.keras
    models/urine_cnn.keras
    models/triage_xgboost.json
"""
from __future__ import annotations

import logging
from pathlib import Path

import numpy as np

logging.basicConfig(level=logging.INFO, format="%(levelname)s [%(name)s] %(message)s")
log = logging.getLogger(__name__)

BASE_DIR = Path(__file__).resolve().parent
MODELS_DIR = BASE_DIR / "models"

# Fixed input length for TFLite (original uses AdaptiveAvgPool which is dynamic)
ECG_INPUT_LENGTH = 256


# --------------------------------------------------------------------------- #
# 1. ECG_CNN  — equivalent Keras architecture
# --------------------------------------------------------------------------- #
def _create_ecg_model() -> Path:
    """Build and save a Keras ECG model matching the PyTorch ECG_CNN."""
    import tensorflow as tf

    # PyTorch original:
    #   Conv1d(1, 16, kernel_size=5, stride=2)
    #   ReLU
    #   AdaptiveAvgPool1d(78)
    #   Linear(16*78, 2)
    #
    # Keras equivalent with fixed input length:
    model = tf.keras.Sequential([
        tf.keras.layers.Input(shape=(1, ECG_INPUT_LENGTH)),  # (batch, channels=1, length=256)
        tf.keras.layers.Permute((2, 1)),                     # → (batch, 256, 1) for Conv1D
        tf.keras.layers.Conv1D(16, kernel_size=5, strides=2, activation="relu",
                               padding="valid"),             # → (batch, 126, 16)
        tf.keras.layers.GlobalAveragePooling1D(),            # → (batch, 16)
        # The original uses AdaptiveAvgPool1d(78) → flatten → Linear(16*78, 2)
        # GlobalAveragePooling is simpler and produces (batch, 16)
        tf.keras.layers.Dense(128, activation="relu"),       # intermediate layer
        tf.keras.layers.Dense(2),                            # logits: [normal, arrhythmia]
    ], name="ECG_CNN")

    model.compile(optimizer="adam", loss="sparse_categorical_crossentropy")
    model.summary(print_fn=log.info)

    path = MODELS_DIR / "ecg_cnn.keras"
    model.save(path)
    log.info("ECG_CNN saved to %s (%d bytes)", path, path.stat().st_size)
    return path


# --------------------------------------------------------------------------- #
# 2. Urine_CNN  — equivalent Keras architecture
# --------------------------------------------------------------------------- #
def _create_urine_model() -> Path:
    """Build and save a Keras Urine model matching the PyTorch Urine_CNN."""
    import tensorflow as tf

    # PyTorch original:
    #   Linear(3, 16) → ReLU → Linear(16, 2)
    model = tf.keras.Sequential([
        tf.keras.layers.Input(shape=(3,)),
        tf.keras.layers.Dense(16, activation="relu"),
        tf.keras.layers.Dense(2),  # logits: [normal, abnormal]
    ], name="Urine_CNN")

    model.compile(optimizer="adam", loss="sparse_categorical_crossentropy")
    model.summary(print_fn=log.info)

    path = MODELS_DIR / "urine_cnn.keras"
    model.save(path)
    log.info("Urine_CNN saved to %s (%d bytes)", path, path.stat().st_size)
    return path


# --------------------------------------------------------------------------- #
# 3. XGBoost triage booster
# --------------------------------------------------------------------------- #
def _create_xgboost_model() -> Path:
    """Train a small XGBoost 3-class classifier on synthetic vital-sign data."""
    import xgboost as xgb

    rng = np.random.default_rng(42)
    N = 500

    # 6 features: ecg_hr, bp_sys, bp_dia, spo2, temperature, urine_severity
    X = np.column_stack([
        rng.uniform(50, 140, N),     # ecg_hr  (bpm)
        rng.uniform(80, 200, N),     # bp_sys  (mmHg)
        rng.uniform(40, 130, N),     # bp_dia  (mmHg)
        rng.uniform(80, 100, N),     # spo2    (%)
        rng.uniform(35, 42, N),      # temperature (C)
        rng.integers(0, 2, N),       # urine_severity (0 or 1)
    ]).astype(np.float32)

    # Synthetic labelling heuristic
    # 0=Green (normal), 1=Yellow (caution), 2=Red (emergency)
    labels = np.zeros(N, dtype=np.int32)
    labels[(X[:, 3] < 92) | (X[:, 4] > 39.5)] = 2            # low SpO2 or high fever
    mask_bp = (X[:, 1] > 160) | (X[:, 2] > 100)
    labels[mask_bp] = np.maximum(labels[mask_bp], 1)          # high BP -> Yellow+
    mask_hr = (X[:, 0] > 110) | (X[:, 0] < 55)
    labels[mask_hr] = np.maximum(labels[mask_hr], 1)          # abnormal HR -> Yellow+

    dtrain = xgb.DMatrix(
        X, label=labels,
        feature_names=["ecg_hr", "bp_sys", "bp_dia", "spo2", "temperature", "urine_severity"],
    )
    params = {
        "objective": "multi:softprob",
        "num_class": 3,
        "max_depth": 4,
        "eta": 0.3,
        "eval_metric": "mlogloss",
        "nthread": 2,
        "seed": 42,
    }
    booster = xgb.train(params, dtrain, num_boost_round=30)
    path = MODELS_DIR / "triage_xgboost.DUMMY.json"
    booster.save_model(str(path))
    log.info("XGBoost triage model saved to %s (%d bytes)", path, path.stat().st_size)
    return path


# --------------------------------------------------------------------------- #
# Main
# --------------------------------------------------------------------------- #
def main() -> None:
    MODELS_DIR.mkdir(parents=True, exist_ok=True)
    _create_ecg_model()
    _create_urine_model()
    # The trained triage booster is ./triage_xgboost.json. A dummy is only made
    # on request, under a name that can never be mistaken for the real one.
    import sys
    if "--with-dummy-triage" in sys.argv:
        _create_xgboost_model()
    log.info("All models created in %s", MODELS_DIR)


if __name__ == "__main__":
    main()

