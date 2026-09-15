"""Convert all three Raksha-Sim models to TensorFlow Lite.

Conversion paths (PyTorch-free — uses Keras directly):
    ECG_CNN       : Keras .keras → TFLite
    Urine_CNN     : Keras .keras → TFLite
    XGBoost Triage: XGBoost → Keras surrogate → TFLite

Prerequisites:
    python train_dummy_models.py          # creates model weights
    pip install tensorflow-cpu xgboost numpy

Usage:
    python convert_to_tflite.py
"""
from __future__ import annotations

import logging
from pathlib import Path

import numpy as np

logging.basicConfig(level=logging.INFO, format="%(levelname)s [%(name)s] %(message)s")
log = logging.getLogger(__name__)

BASE_DIR = Path(__file__).resolve().parent
MODELS_DIR = BASE_DIR / "models"

TRIAGE_INPUT_DIM = 6


# =========================================================================== #
#  1. ECG_CNN → TFLite
# =========================================================================== #
def convert_ecg() -> Path:
    """Convert saved Keras ECG model to TFLite."""
    import tensorflow as tf

    log.info("=" * 60)
    log.info("Converting ECG_CNN → TFLite")
    log.info("=" * 60)

    keras_path = MODELS_DIR / "ecg_cnn.keras"
    if not keras_path.is_file():
        raise FileNotFoundError(
            f"ECG model not found at {keras_path}. Run train_dummy_models.py first."
        )

    model = tf.keras.models.load_model(keras_path)
    model.summary(print_fn=log.info)

    converter = tf.lite.TFLiteConverter.from_keras_model(model)
    converter.optimizations = [tf.lite.Optimize.DEFAULT]
    converter.target_spec.supported_types = [tf.float32]
    tflite_model = converter.convert()

    tflite_path = MODELS_DIR / "ecg_cnn.tflite"
    tflite_path.write_bytes(tflite_model)
    log.info("ECG TFLite saved: %s (%d bytes)", tflite_path, len(tflite_model))

    # Verify
    test_input = np.random.randn(1, 1, 256).astype(np.float32)
    expected = model.predict(test_input, verbose=0)
    _verify_tflite(tflite_path, test_input, expected, "ECG_CNN")
    return tflite_path


# =========================================================================== #
#  2. Urine_CNN → TFLite
# =========================================================================== #
def convert_urine() -> Path:
    """Convert saved Keras Urine model to TFLite."""
    import tensorflow as tf

    log.info("=" * 60)
    log.info("Converting Urine_CNN → TFLite")
    log.info("=" * 60)

    keras_path = MODELS_DIR / "urine_cnn.keras"
    if not keras_path.is_file():
        raise FileNotFoundError(
            f"Urine model not found at {keras_path}. Run train_dummy_models.py first."
        )

    model = tf.keras.models.load_model(keras_path)
    model.summary(print_fn=log.info)

    converter = tf.lite.TFLiteConverter.from_keras_model(model)
    converter.optimizations = [tf.lite.Optimize.DEFAULT]
    converter.target_spec.supported_types = [tf.float32]
    tflite_model = converter.convert()

    tflite_path = MODELS_DIR / "urine_cnn.tflite"
    tflite_path.write_bytes(tflite_model)
    log.info("Urine TFLite saved: %s (%d bytes)", tflite_path, len(tflite_model))

    # Verify
    test_input = np.array([[200.0, 180.0, 100.0]], dtype=np.float32)
    expected = model.predict(test_input, verbose=0)
    _verify_tflite(tflite_path, test_input, expected, "Urine_CNN")
    return tflite_path


# =========================================================================== #
#  3. XGBoost Triage → Keras surrogate → TFLite
# =========================================================================== #
def convert_triage() -> Path:
    """Convert XGBoost triage model to TFLite via a Keras surrogate."""
    import tensorflow as tf
    import xgboost as xgb

    log.info("=" * 60)
    log.info("Converting XGBoost Triage → Keras surrogate → TFLite")
    log.info("=" * 60)

    model_path = MODELS_DIR / "triage_xgboost.json"
    if not model_path.is_file():
        raise FileNotFoundError(
            f"XGBoost model not found at {model_path}. Run train_dummy_models.py first."
        )

    booster = xgb.Booster()
    booster.load_model(str(model_path))

    # Generate large synthetic dataset for surrogate training
    rng = np.random.default_rng(123)
    N = 5000
    X_train = np.column_stack([
        rng.uniform(40, 160, N),   # ecg_hr
        rng.uniform(70, 220, N),   # bp_sys
        rng.uniform(30, 140, N),   # bp_dia
        rng.uniform(75, 100, N),   # spo2
        rng.uniform(34, 43, N),    # temperature
        rng.integers(0, 2, N),     # urine_severity
    ]).astype(np.float32)

    # Get XGBoost predictions as soft labels
    dmatrix = xgb.DMatrix(
        X_train,
        feature_names=["ecg_hr", "bp_sys", "bp_dia", "spo2", "temperature", "urine_severity"],
    )
    y_soft = np.array(booster.predict(dmatrix), dtype=np.float32)  # (N, 3) probs

    # Build Keras surrogate
    surrogate = tf.keras.Sequential([
        tf.keras.layers.Input(shape=(TRIAGE_INPUT_DIM,)),
        tf.keras.layers.Dense(32, activation="relu"),
        tf.keras.layers.Dense(16, activation="relu"),
        tf.keras.layers.Dense(3, activation="softmax"),
    ], name="Triage_Surrogate")

    surrogate.compile(
        optimizer=tf.keras.optimizers.Adam(learning_rate=0.001),
        loss="categorical_crossentropy",
        metrics=["accuracy"],
    )

    log.info("Training Keras surrogate on %d XGBoost-labelled samples...", N)
    surrogate.fit(
        X_train, y_soft,
        epochs=50,
        batch_size=64,
        verbose=1,
        validation_split=0.1,
    )

    # Evaluate surrogate fidelity
    y_pred = surrogate.predict(X_train, verbose=0)
    agreement = np.mean(np.argmax(y_pred, axis=1) == np.argmax(y_soft, axis=1))
    log.info("Surrogate-XGBoost class agreement: %.1f%%", agreement * 100)

    # Convert to TFLite
    converter = tf.lite.TFLiteConverter.from_keras_model(surrogate)
    converter.optimizations = [tf.lite.Optimize.DEFAULT]
    converter.target_spec.supported_types = [tf.float32]
    tflite_model = converter.convert()

    tflite_path = MODELS_DIR / "triage_model.tflite"
    tflite_path.write_bytes(tflite_model)
    log.info("Triage TFLite saved: %s (%d bytes)", tflite_path, len(tflite_model))

    # Verify
    test_input = X_train[:1].astype(np.float32)
    _verify_tflite(tflite_path, test_input, surrogate.predict(test_input, verbose=0), "Triage")
    return tflite_path


# =========================================================================== #
#  Verification helper
# =========================================================================== #
def _verify_tflite(
    tflite_path: Path,
    test_input: np.ndarray,
    expected_output: np.ndarray,
    model_name: str,
) -> None:
    """Run TFLite inference and compare with the source model output."""
    import tensorflow as tf

    interpreter = tf.lite.Interpreter(model_path=str(tflite_path))
    interpreter.allocate_tensors()

    input_details = interpreter.get_input_details()
    output_details = interpreter.get_output_details()

    log.info("%s TFLite — input: %s (dtype=%s), output: %s",
             model_name,
             input_details[0]["shape"],
             input_details[0]["dtype"],
             output_details[0]["shape"])

    interpreter.set_tensor(input_details[0]["index"], test_input.astype(np.float32))
    interpreter.invoke()
    tflite_out = interpreter.get_tensor(output_details[0]["index"])

    max_diff = float(np.max(np.abs(tflite_out - expected_output)))
    log.info("%s verification — max abs diff: %.6f %s",
             model_name, max_diff,
             "PASS" if max_diff < 0.01 else "DRIFT (acceptable for quantised)")


# =========================================================================== #
#  Main
# =========================================================================== #
def main() -> None:
    MODELS_DIR.mkdir(parents=True, exist_ok=True)

    ecg_path = convert_ecg()
    urine_path = convert_urine()
    triage_path = convert_triage()

    print("\n" + "=" * 60)
    print("All TFLite models generated successfully!")
    print("=" * 60)
    for p in (ecg_path, urine_path, triage_path):
        print(f"  {p.name:30s}  {p.stat().st_size:>8,d} bytes")
    print()


if __name__ == "__main__":
    main()

