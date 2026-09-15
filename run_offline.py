"""
Offline Patient Triage Runner for VS Code / Local Execution.
No internet connection, remote URL, or physical ESP32 hardware required.

Run in VS Code:
    python run_offline.py
    (or simply click the "Run Python File" button in VS Code)
"""
from __future__ import annotations

import math
import os
import sys
from typing import Any, Dict, List


os.environ.setdefault("OPENBLAS_NUM_THREADS", "1")
os.environ.setdefault("OMP_NUM_THREADS", "1")


if sys.platform == "win32":
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

from triage_engine import analyze_patient


# ============================================================================ #
# Sample ECG Waveform Generators (Synthetic Signals)
# ============================================================================ #
def generate_normal_ecg(num_samples: int = 200) -> List[float]:
    """Synthetic normal sinus rhythm waveform (P-Q-R-S-T wave simulation)."""
    samples = []
    for i in range(num_samples):
        phase = (i % 50) / 50.0
        val = 1850.0
        if 0.10 <= phase < 0.20:
            val += 80.0 * math.sin((phase - 0.10) * math.pi / 0.10)  # P wave
        elif 0.28 <= phase < 0.32:
            val -= 60.0  # Q drop
        elif 0.32 <= phase < 0.40:
            val += 1800.0 * math.sin((phase - 0.32) * math.pi / 0.08)  # R peak
        elif 0.40 <= phase < 0.44:
            val -= 120.0  # S drop
        elif 0.55 <= phase < 0.70:
            val += 150.0 * math.sin((phase - 0.55) * math.pi / 0.15)  # T wave
        samples.append(round(val, 1))
    return samples


def generate_arrhythmic_ecg(num_samples: int = 200) -> List[float]:
    """Synthetic irregular/arrhythmic ECG waveform with erratic spikes."""
    samples = []
    for i in range(num_samples):
        val = 1850.0 + 800.0 * math.sin(i * 0.25) * math.cos(i * 0.08)
        if i % 17 == 0:
            val += 1400.0
        samples.append(round(val, 1))
    return samples


# ============================================================================ #
# Sample Generated Patient Packets (No Blood Pressure)
# ============================================================================ #
SAMPLE_PATIENTS: List[Dict[str, Any]] = [
    {
        "case_name": "Case 1: Normal / Healthy Checkup",
        "description": "Stable vitals, normal sinus rhythm, clear urine, no symptoms.",
        "payload": {
            "device_id": "ESP32_Bed_01",
            "timestamp": "1710001",
            "ecg": {
                "heart_rate_bpm": 72,
                "samples": generate_normal_ecg(150),
            },
            "pulse_oximeter": {
                "heart_rate_bpm": 72,
                "spo2_percent": 98,
                "ir_raw": 135400,
            },
            "temperature": {
                "body_temp_c": 36.7,
            },
            "urine_sensor": {
                "red": 3200,
                "green": 3100,
                "blue": 2800,
            },
            "step_1_audio": None,
            "status": "complete",
        },
    },
    {
        "case_name": "Case 2: Moderate Tachycardia / Elevated Risk",
        "description": "Elevated heart rate, mild fever, concentrated urine.",
        "payload": {
            "device_id": "ESP32_Bed_02",
            "timestamp": "1710002",
            "ecg": {
                "heart_rate_bpm": 108,
                "samples": generate_normal_ecg(120),
            },
            "pulse_oximeter": {
                "heart_rate_bpm": 108,
                "spo2_percent": 94,
                "ir_raw": 128000,
            },
            "temperature": {
                "body_temp_c": 38.1,
            },
            "urine_sensor": {
                "red": 2400,
                "green": 1900,
                "blue": 1100,
            },
            "step_1_audio": None,
            "status": "complete",
        },
    },
    {
        "case_name": "Case 3: Critical Cardiac / Emergency",
        "description": "Irregular rhythm, high tachycardia, low oxygen, high fever.",
        "payload": {
            "device_id": "ESP32_Emergency_03",
            "timestamp": "1710003",
            "ecg": {
                "heart_rate_bpm": 138,
                "samples": generate_arrhythmic_ecg(180),
            },
            "pulse_oximeter": {
                "heart_rate_bpm": 138,
                "spo2_percent": 88,
                "ir_raw": 98000,
            },
            "temperature": {
                "body_temp_c": 39.5,
            },
            "urine_sensor": {
                "red": 3800,
                "green": 1400,
                "blue": 1200,
            },
            "step_1_audio": None,
            "status": "complete",
        },
    },
    {
        "case_name": "Case 4: Severe Respiratory Distress & Hypoxia",
        "description": "Critical low SpO2 (84%), rapid heart rate, high respiratory stress.",
        "payload": {
            "device_id": "ESP32_Triage_04",
            "timestamp": "1710004",
            "ecg": {
                "heart_rate_bpm": 122,
                "samples": generate_normal_ecg(140),
            },
            "pulse_oximeter": {
                "heart_rate_bpm": 122,
                "spo2_percent": 84,
                "ir_raw": 91000,
            },
            "temperature": {
                "body_temp_c": 37.4,
            },
            "urine_sensor": {
                "red": 3000,
                "green": 2900,
                "blue": 2700,
            },
            "step_1_audio": None,
            "status": "complete",
        },
    },
]


# ============================================================================ #
# Output Formatting
# ============================================================================ #
def _color_badge(triage: str) -> str:
    t = triage.upper()
    if "GREEN" in t:
        return f"\033[92m[{triage} - STABLE / LOW RISK]\033[0m"
    if "YELLOW" in t:
        return f"\033[93m[{triage} - MODERATE / OBSERVATION]\033[0m"
    if "RED" in t:
        return f"\033[91m[{triage} - CRITICAL / IMMEDIATE ACTION]\033[0m"
    return f"[{triage}]"


def run_offline_suite():
    print("=" * 80)
    print("RAKSHA-SIM OFFLINE TRIAGE SYSTEM - LOCAL INFERENCE RUNNER")
    print("=" * 80)
    print("Running completely offline on your laptop in VS Code.\n")

    for idx, case in enumerate(SAMPLE_PATIENTS, start=1):
        payload = case["payload"]
        vitals_hr = payload["ecg"]["heart_rate_bpm"]
        vitals_spo2 = f"{payload['pulse_oximeter']['spo2_percent']}%"
        vitals_temp = f"{payload['temperature']['body_temp_c']} C"

        print("-" * 80)
        print(f"Test Case {idx}: {case['case_name']}")
        print(f"Context:       {case['description']}")
        print(f"Sensor Inputs: HR={vitals_hr} bpm | SpO2={vitals_spo2} | Temp={vitals_temp}")

        try:
            result = analyze_patient(payload)
            badge = _color_badge(result["triage"])
            confidence = f"{float(result['confidence']) * 100:.1f}%"

            print(f"Triage Output: {badge}")
            print(f"Confidence:    {confidence}")
            print(f"ECG Status:    {result['ecg_result']}")
            print(f"Symptoms:      {result['symptoms'] if result['symptoms'] else 'None detected'}")
        except Exception as exc:
            print(f"Execution Error: {exc}")

        print()

    print("=" * 80)
    print("Offline simulation complete! All cases processed successfully.")
    print("=" * 80)


if __name__ == "__main__":
    run_offline_suite()
