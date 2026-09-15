"""Convert all three Raksha-Sim models to TensorFlow Lite.

Conversion paths (PyTorch-free — uses Keras directly):
    ECG_CNN       : Keras .keras → TFLite
    Urine_CNN     : Keras .keras → TFLite
    XGBoost Triage: exact rule table + Dart (export_triage_rules.py)

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
#  3. XGBoost Triage -> NOT TFLite (PRD §0). Exact rule table + Dart instead.
# =========================================================================== #
def convert_triage() -> Path:
    """The old Keras surrogate was (a) an approximation and (b) fitted to the
    dummy booster in models/, not the trained ./triage_xgboost.json."""
    import subprocess
    import sys
    from config import get_config
    out = MODELS_DIR / "triage_rules.json"
    subprocess.run([sys.executable, str(BASE_DIR / "export_triage_rules.py"),
                    "--model", str(get_config().triage.model_path), "--out", str(out)],
                   check=True)
    return out


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

