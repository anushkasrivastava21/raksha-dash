"""Standalone TFLite inference pipeline for Raksha-Sim medical triage.

Loads all three TFLite models (ECG, Urine, Triage) and runs them on
randomly generated continuous sensor data — no PyTorch, no XGBoost,
no audio hardware required.

Usage:
    python run_tflite_pipeline.py                     # 10 patients (default)
    python run_tflite_pipeline.py --num_patients 50   # 50 patients
    python run_tflite_pipeline.py --continuous         # runs indefinitely
    python run_tflite_pipeline.py --interval 2.0       # 2s between patients

Prerequisites:
    python train_dummy_models.py
    python convert_to_tflite.py
"""
from __future__ import annotations

import argparse
import json
import logging
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional

import numpy as np

logging.basicConfig(level=logging.INFO, format="%(levelname)s [%(name)s] %(message)s")
log = logging.getLogger("tflite_pipeline")

BASE_DIR = Path(__file__).resolve().parent
MODELS_DIR = BASE_DIR / "models"


# =========================================================================== #
#  Configuration (mirrors config.py defaults, self-contained)
# =========================================================================== #
@dataclass(frozen=True)
class PipelineConfig:
    # ECG
    ecg_tflite: Path = MODELS_DIR / "ecg_cnn.tflite"
    ecg_input_length: int = 256
    ecg_sample_rate: float = 360.0
    ecg_bandpass_low: float = 0.5
    ecg_bandpass_high: float = 45.0
    ecg_filter_order: int = 4
    label_normal: str = "Normal Sinus Rhythm"
    label_arrhythmia: str = "Arrhythmia Detected"
    label_undetermined: str = "Undetermined"

    # Urine
    urine_tflite: Path = MODELS_DIR / "urine_cnn.tflite"
    rgb_max: float = 255.0

    # Triage
    triage_model_json: Path = BASE_DIR / "triage_xgboost.json"   # trained booster
    class_labels: tuple = ("Green", "Yellow", "Red")

    # Escalation rules (from config.py TriageConfig)
    red_boost_critical: float = 0.45
    red_boost_moderate: float = 0.18
    red_boost_minor: float = 0.05
    red_boost_cap: float = 0.60
    symptom_yellow_boost: float = 0.10
    symptom_green_decay: float = 0.10
    arrhythmia_red_boost: float = 0.45

    # Vital-sign defaults
    default_hr: float = 75.0
    default_spo2: float = 98.0
    default_bp_sys: float = 120.0
    default_bp_dia: float = 80.0
    default_temp: float = 37.0

    # Symptom tiers for random generation
    sample_symptoms: tuple = (
        ("chest pain", "critical"),
        ("bleeding", "critical"),
        ("difficulty breathing", "critical"),
        ("seizure", "critical"),
        ("high fever", "moderate"),
        ("vomiting", "moderate"),
        ("persistent cough", "moderate"),
        ("headache", "minor"),
        ("fatigue", "minor"),
        ("runny nose", "minor"),
    )


CFG = PipelineConfig()

# Tier ordering for escalation
TIER_ORDER = {"critical": 3, "moderate": 2, "minor": 1}


# =========================================================================== #
#  TFLite Model Wrapper
# =========================================================================== #
class TFLiteModel:
    """Thin wrapper around TFLite Interpreter for easy inference."""

    def __init__(self, model_path: Path, name: str = "") -> None:
        self.name = name or model_path.stem
        self.path = model_path

        if not model_path.is_file():
            raise FileNotFoundError(
                f"TFLite model not found: {model_path}\n"
                "Run: python train_dummy_models.py && python convert_to_tflite.py"
            )

        # Try tflite_runtime first (lighter), fall back to full tensorflow
        try:
            from tflite_runtime.interpreter import Interpreter
        except ImportError:
            from tensorflow.lite.python.interpreter import Interpreter  # type: ignore[import]

        self._interpreter = Interpreter(model_path=str(model_path))
        self._interpreter.allocate_tensors()
        self._input = self._interpreter.get_input_details()
        self._output = self._interpreter.get_output_details()

        log.info("Loaded TFLite model '%s': input=%s → output=%s",
                 self.name, self._input[0]["shape"], self._output[0]["shape"])

    @property
    def input_shape(self) -> tuple:
        return tuple(self._input[0]["shape"])

    @property
    def output_shape(self) -> tuple:
        return tuple(self._output[0]["shape"])

    def predict(self, data: np.ndarray) -> np.ndarray:
        """Run inference. Input must be float32 and match the expected shape."""
        data = np.asarray(data, dtype=np.float32)
        expected = tuple(self._input[0]["shape"])
        if data.shape != expected:
            raise ValueError(f"{self.name}: expected input shape {expected}, got {data.shape}")
        self._interpreter.set_tensor(self._input[0]["index"], data)
        self._interpreter.invoke()
        return self._interpreter.get_tensor(self._output[0]["index"]).copy()


# =========================================================================== #
#  Signal Processing (self-contained, no dependency on ecg_processor.py)
# =========================================================================== #
def bandpass_filter(signal: np.ndarray, fs: float = CFG.ecg_sample_rate) -> np.ndarray:
    """Butterworth bandpass filter for ECG signal."""
    from scipy.signal import butter, sosfiltfilt

    nyquist = fs / 2.0
    high = min(CFG.ecg_bandpass_high, nyquist * 0.99)
    if high <= CFG.ecg_bandpass_low:
        return signal - signal.mean()
    sos = butter(CFG.ecg_filter_order, [CFG.ecg_bandpass_low, high],
                 btype="bandpass", fs=fs, output="sos")
    padlen = min(3 * (2 * sos.shape[0] + 1), signal.size - 1)
    if padlen < 1:
        return signal - signal.mean()
    return sosfiltfilt(sos, signal, padlen=padlen)


def normalise_ecg(signal: np.ndarray) -> np.ndarray:
    """Zero-mean, unit-peak normalisation."""
    signal = signal - signal.mean()
    peak = float(np.abs(signal).max())
    if peak > 0:
        signal = signal / peak
    return signal


# =========================================================================== #
#  Random Data Generator
# =========================================================================== #
@dataclass
class PatientData:
    """Simulated sensor packet for one patient."""
    patient_id: str
    ecg_signal: np.ndarray       # (256,) raw ECG samples
    heart_rate: float             # bpm
    bp_systolic: float            # mmHg
    bp_diastolic: float           # mmHg
    spo2: float                   # %
    temperature: float            # °C
    urine_rgb: list               # [R, G, B] in 0–255
    symptoms: List[tuple]         # [(name, tier), ...]

    def summary(self) -> str:
        return (f"HR={self.heart_rate:.0f} BP={self.bp_systolic:.0f}/{self.bp_diastolic:.0f} "
                f"SpO2={self.spo2:.0f}% T={self.temperature:.1f}°C "
                f"Urine=({self.urine_rgb[0]:.0f},{self.urine_rgb[1]:.0f},{self.urine_rgb[2]:.0f})")


def generate_ecg_signal(rng: np.random.Generator, length: int = CFG.ecg_input_length,
                        heart_rate: float = 75.0) -> np.ndarray:
    """Generate a synthetic ECG-like waveform with QRS complexes and noise."""
    t = np.linspace(0, length / CFG.ecg_sample_rate, length, dtype=np.float32)
    freq = heart_rate / 60.0

    # P wave + QRS complex + T wave approximation
    signal = (
        0.15 * np.sin(2 * np.pi * freq * t)          # baseline sinus
        + 0.8 * np.exp(-0.5 * ((t % (1/freq) - 0.1) / 0.02) ** 2)  # QRS spike
        + 0.2 * np.sin(2 * np.pi * 2 * freq * t)     # T wave harmonic
    )
    # Add realistic noise
    signal += rng.normal(0, 0.05, length).astype(np.float32)  # Gaussian
    signal += 0.03 * np.sin(2 * np.pi * 50 * t)               # 50Hz power line
    return signal.astype(np.float32)


def generate_patient(rng: np.random.Generator, patient_id: str) -> PatientData:
    """Generate one randomised patient with clinically plausible ranges."""
    # Decide patient severity profile randomly
    severity = rng.choice(["healthy", "mild", "severe"], p=[0.5, 0.3, 0.2])

    if severity == "healthy":
        hr = rng.uniform(60, 100)
        bp_sys = rng.uniform(100, 135)
        bp_dia = rng.uniform(60, 85)
        spo2 = rng.uniform(95, 100)
        temp = rng.uniform(36.0, 37.5)
        urine_rgb = [rng.uniform(200, 255), rng.uniform(200, 240), rng.uniform(80, 150)]
        n_symptoms = 0
    elif severity == "mild":
        hr = rng.uniform(55, 120)
        bp_sys = rng.uniform(90, 160)
        bp_dia = rng.uniform(50, 100)
        spo2 = rng.uniform(90, 98)
        temp = rng.uniform(37.0, 39.0)
        urine_rgb = [rng.uniform(150, 255), rng.uniform(120, 220), rng.uniform(50, 130)]
        n_symptoms = rng.integers(0, 3)
    else:  # severe
        hr = rng.uniform(40, 150)
        bp_sys = rng.uniform(70, 200)
        bp_dia = rng.uniform(35, 130)
        spo2 = rng.uniform(80, 94)
        temp = rng.uniform(38.5, 42.0)
        urine_rgb = [rng.uniform(100, 200), rng.uniform(50, 150), rng.uniform(30, 100)]
        n_symptoms = rng.integers(1, 5)

    # Generate symptoms
    symptoms = []
    if n_symptoms > 0:
        indices = rng.choice(len(CFG.sample_symptoms), size=min(n_symptoms, len(CFG.sample_symptoms)),
                             replace=False)
        symptoms = [CFG.sample_symptoms[i] for i in indices]

    return PatientData(
        patient_id=patient_id,
        ecg_signal=generate_ecg_signal(rng, heart_rate=hr),
        heart_rate=hr,
        bp_systolic=bp_sys,
        bp_diastolic=bp_dia,
        spo2=spo2,
        temperature=temp,
        urine_rgb=urine_rgb,
        symptoms=list(symptoms),
    )


# =========================================================================== #
#  Pipeline Inference
# =========================================================================== #
class RakshaTFLitePipeline:
    """End-to-end TFLite inference pipeline for medical triage."""

    def __init__(self) -> None:
        log.info("Initialising Raksha TFLite Pipeline...")
        self.ecg_model = TFLiteModel(CFG.ecg_tflite, "ECG_CNN")
        self.urine_model = TFLiteModel(CFG.urine_tflite, "Urine_CNN")
        from export_triage_rules import load_rule_model
        if not CFG.triage_model_json.is_file():
            raise FileNotFoundError(f"Trained triage model missing: {CFG.triage_model_json}")
        self.triage_model = load_rule_model(CFG.triage_model_json)   # exact, not a surrogate
        log.info("ECG + urine TFLite and exact XGBoost rule table loaded.\n")

    # ----- ECG inference -------------------------------------------------- #
    def classify_ecg(self, raw_ecg: np.ndarray) -> str:
        """ECG signal → Normal / Arrhythmia / Undetermined."""
        if raw_ecg is None or len(raw_ecg) < 10:
            return CFG.label_undetermined
        try:
            signal = np.asarray(raw_ecg, dtype=np.float32)
            # Resample / pad / truncate to fixed length
            if len(signal) != CFG.ecg_input_length:
                signal = np.interp(
                    np.linspace(0, 1, CFG.ecg_input_length),
                    np.linspace(0, 1, len(signal)),
                    signal,
                ).astype(np.float32)
            # Filter and normalise
            filtered = bandpass_filter(signal).astype(np.float32)
            filtered = normalise_ecg(filtered)
            # Reshape to (1, 1, 256) for Conv1D
            tensor = filtered.reshape(1, 1, -1)
            logits = self.ecg_model.predict(tensor)
            prediction = int(np.argmax(logits, axis=1)[0])
            return CFG.label_arrhythmia if prediction == 1 else CFG.label_normal
        except Exception as exc:
            log.error("ECG classification failed: %s", exc)
            return CFG.label_undetermined

    # ----- Urine inference ------------------------------------------------ #
    def classify_urine(self, rgb: list) -> int:
        """Urine RGB → severity score (0=normal, 1=abnormal)."""
        if not rgb or len(rgb) < 3:
            return 0
        try:
            r, g, b = float(rgb[0]), float(rgb[1]), float(rgb[2])
            # Normalise to 0-255 range if ADC values
            if max(r, g, b) > CFG.rgb_max:
                k = CFG.rgb_max / 4095.0
                r, g, b = r * k, g * k, b * k
            tensor = np.array([[r, g, b]], dtype=np.float32)
            logits = self.urine_model.predict(tensor)
            return int(np.argmax(logits, axis=1)[0])
        except Exception as exc:
            log.error("Urine classification failed: %s", exc)
            return 0

    # ----- Triage inference ----------------------------------------------- #
    def classify_triage(self, features: np.ndarray) -> np.ndarray:
        """6 vital-sign features → 3-class probabilities."""
        return self.triage_model.predict_proba(features.astype(np.float32))

    # ----- Escalation rules (from triage_integrator.py) ------------------- #
    @staticmethod
    def escalate(probs: np.ndarray, symptoms: list, ecg_result: str) -> np.ndarray:
        """Rule layer on top of the model — mirrors triage_integrator._escalate."""
        probs = probs.copy()
        arrhythmia = ecg_result == CFG.label_arrhythmia

        if not symptoms and not arrhythmia:
            return probs

        # Find the highest symptom tier
        tier_boost = {
            "critical": CFG.red_boost_critical,
            "moderate": CFG.red_boost_moderate,
            "minor": CFG.red_boost_minor,
        }
        highest = None
        if symptoms:
            highest = max(symptoms, key=lambda s: TIER_ORDER.get(s[1], 0))[1]

        boost = tier_boost.get(highest or "", 0.0)
        if arrhythmia:
            boost = max(boost, CFG.arrhythmia_red_boost)
        boost = min(boost, CFG.red_boost_cap)

        if boost <= 0.0:
            return probs

        green_idx = CFG.class_labels.index("Green")
        yellow_idx = CFG.class_labels.index("Yellow")
        red_idx = CFG.class_labels.index("Red")

        probs[red_idx] += boost
        probs[yellow_idx] += CFG.symptom_yellow_boost
        probs[green_idx] *= max(CFG.symptom_green_decay,
                                1.0 - boost / max(CFG.red_boost_cap, 1e-6))
        total = float(probs.sum())
        if total > 0:
            probs /= total
        return probs

    # ----- Full pipeline -------------------------------------------------- #
    def triage_patient(self, patient: PatientData) -> Dict[str, Any]:
        """Run the complete triage pipeline on one patient."""
        # 1. ECG classification
        ecg_result = self.classify_ecg(patient.ecg_signal)

        # 2. Urine severity
        urine_severity = self.classify_urine(patient.urine_rgb)

        # 3. Build feature vector for triage
        features = np.array([
            patient.heart_rate,
            patient.bp_systolic,
            patient.bp_diastolic,
            patient.spo2,
            patient.temperature,
            float(urine_severity),
        ], dtype=np.float32)

        # 4. Triage classification
        base_probs = self.classify_triage(features)

        # 5. Symptom escalation
        final_probs = self.escalate(base_probs, patient.symptoms, ecg_result)

        # 6. Final decision
        index = int(np.argmax(final_probs))
        return {
            "patient_id": patient.patient_id,
            "triage_color": CFG.class_labels[index],
            "confidence_score": round(float(final_probs[index]), 2),
            "probabilities": {
                label: round(float(p), 4)
                for label, p in zip(CFG.class_labels, final_probs)
            },
            "ecg_result": ecg_result,
            "urine_severity": "Abnormal" if urine_severity == 1 else "Normal",
            "symptom_list": [s[0] for s in patient.symptoms],
            "vitals": {
                "heart_rate_bpm": round(patient.heart_rate, 1),
                "bp_systolic": round(patient.bp_systolic, 1),
                "bp_diastolic": round(patient.bp_diastolic, 1),
                "spo2_percent": round(patient.spo2, 1),
                "temperature_c": round(patient.temperature, 1),
            },
        }


# =========================================================================== #
#  Display
# =========================================================================== #
TRIAGE_COLORS = {"Green": "\033[92m", "Yellow": "\033[93m", "Red": "\033[91m"}
RESET = "\033[0m"
BOLD = "\033[1m"


def print_header() -> None:
    print(f"\n{'=' * 90}")
    print(f"{BOLD}  RAKSHA-SIM  TFLite Medical Triage Pipeline{RESET}")
    print(f"  Models: ECG_CNN + Urine_CNN + Triage (all TFLite)")
    print(f"{'=' * 90}\n")


def print_result(result: Dict[str, Any], patient: PatientData) -> None:
    color_code = TRIAGE_COLORS.get(result["triage_color"], "")
    print(f"+{'-' * 75}")
    print(f"| Patient: {BOLD}{result['patient_id']}{RESET}")
    print(f"| Vitals:  {patient.summary()}")
    print(f"| ECG:     {result['ecg_result']}")
    print(f"| Urine:   {result['urine_severity']}")
    if result["symptom_list"]:
        print(f"| Symptoms: {', '.join(result['symptom_list'])}")
    else:
        print(f"| Symptoms: (none reported)")
    probs_str = " | ".join(
        f"{label}: {p:.2%}" for label, p in result["probabilities"].items()
    )
    print(f"| Probs:   {probs_str}")
    print(f"| {color_code}{BOLD}>> TRIAGE: {result['triage_color']}  "
          f"(confidence: {result['confidence_score']:.0%}){RESET}")
    print(f"+{'-' * 75}\n")


def print_summary(results: List[Dict[str, Any]]) -> None:
    counts = {"Green": 0, "Yellow": 0, "Red": 0}
    for r in results:
        counts[r["triage_color"]] += 1
    total = len(results)
    print(f"\n{'=' * 90}")
    print(f"{BOLD}  SUMMARY  ({total} patients){RESET}")
    print(f"{'=' * 90}")
    for label in ("Green", "Yellow", "Red"):
        c = counts[label]
        bar = "#" * int(40 * c / max(total, 1))
        color = TRIAGE_COLORS.get(label, "")
        print(f"  {color}{label:8s}{RESET} {bar} {c}/{total} ({100*c/max(total,1):.0f}%)")
    print()


# =========================================================================== #
#  Main
# =========================================================================== #
def main() -> int:
    parser = argparse.ArgumentParser(
        description="Raksha-Sim TFLite Pipeline — run medical triage on random continuous data"
    )
    parser.add_argument("--num_patients", type=int, default=10,
                        help="Number of patients to generate (default: 10)")
    parser.add_argument("--continuous", action="store_true",
                        help="Run indefinitely (Ctrl+C to stop)")
    parser.add_argument("--interval", type=float, default=0.5,
                        help="Seconds between patients in continuous mode (default: 0.5)")
    parser.add_argument("--seed", type=int, default=None,
                        help="Random seed for reproducibility")
    parser.add_argument("--json", action="store_true",
                        help="Output results as JSON lines (machine-readable)")
    args = parser.parse_args()

    rng = np.random.default_rng(args.seed)

    try:
        pipeline = RakshaTFLitePipeline()
    except FileNotFoundError as exc:
        log.error(str(exc))
        return 1

    print_header()
    results: List[Dict[str, Any]] = []
    patient_num = 0

    try:
        while True:
            patient_num += 1
            if not args.continuous and patient_num > args.num_patients:
                break

            patient_id = f"PAT-{patient_num:04d}"
            patient = generate_patient(rng, patient_id)
            result = pipeline.triage_patient(patient)
            results.append(result)

            if args.json:
                print(json.dumps(result, default=str))
            else:
                print_result(result, patient)

            if args.continuous:
                time.sleep(args.interval)

    except KeyboardInterrupt:
        print(f"\n\nStopped after {patient_num - 1} patients.")

    if not args.json and results:
        print_summary(results)

    return 0


if __name__ == "__main__":
    sys.exit(main())

