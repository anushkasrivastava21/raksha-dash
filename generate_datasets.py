"""
Generate synthetic training datasets for all three Raksha-Sim ML models.

Datasets created:
    data/triage_training_data.csv   — 1000 samples, 4 features + triage label
    data/ecg_training_data.npz      — 500 normal + 500 arrhythmia ECG waveforms
    data/urine_training_data.csv    — 500 normal + 500 abnormal RGB samples

Usage:
    python generate_datasets.py
"""
from __future__ import annotations

import csv
import math
import os
import random
from pathlib import Path

import numpy as np

os.environ.setdefault("OPENBLAS_NUM_THREADS", "1")
os.environ.setdefault("OMP_NUM_THREADS", "1")

BASE_DIR = Path(__file__).resolve().parent
DATA_DIR = BASE_DIR / "data"
SEED = 42


# ============================================================================ #
# 1. Triage Dataset — 1000 samples, 4 features → Green / Yellow / Red
# ============================================================================ #
def generate_triage_dataset(n: int = 1000) -> Path:
    """Generate triage training data with clinically meaningful distributions.

    Features: ecg_hr, spo2, temperature, urine_severity
    Label:    0 = Green, 1 = Yellow, 2 = Red

    The labelling logic mirrors published clinical guidelines:
      - Red: HR>120 OR SpO2<90 OR Temp>39.5 OR (SpO2<93 AND HR>100)
      - Yellow: HR>100 OR SpO2<95 OR Temp>38.5 OR urine_severity==1
      - Green: everything else (stable vitals)
    """
    rng = np.random.default_rng(SEED)
    rows = []

    for _ in range(n):
        ecg_hr = float(rng.normal(80, 20))
        ecg_hr = max(40.0, min(180.0, ecg_hr))
        spo2 = float(rng.normal(96, 3))
        spo2 = max(70.0, min(100.0, spo2))
        temperature = float(rng.normal(37.0, 0.8))
        temperature = max(35.0, min(42.0, temperature))
        urine_severity = int(rng.choice([0, 1], p=[0.75, 0.25]))

        # Deterministic labelling based on clinical severity rules
        if (ecg_hr > 120 or spo2 < 90 or temperature > 39.5
                or (spo2 < 93 and ecg_hr > 100)):
            label = 2  # Red
        elif (ecg_hr > 100 or spo2 < 95 or temperature > 38.5
              or urine_severity == 1):
            label = 1 
        else:
            label = 0  

        rows.append([round(ecg_hr, 1), round(spo2, 1),
                     round(temperature, 2), urine_severity, label])

    out_path = DATA_DIR / "triage_training_data.csv"
    with open(out_path, "w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(["ecg_hr", "spo2", "temperature", "urine_severity", "label"])
        writer.writerows(rows)


    labels = [r[4] for r in rows]
    dist = {lbl: labels.count(lbl) for lbl in [0, 1, 2]}
    print(f"Triage dataset: {len(rows)} samples -> {out_path}")
    print(f"  Class distribution: Green={dist[0]}, Yellow={dist[1]}, Red={dist[2]}")
    return out_path


# ============================================================================ #
# 2. ECG Dataset — 500 normal + 500 arrhythmia waveforms
# ============================================================================ #
def _synthetic_normal_ecg(length: int, rng: np.random.Generator) -> np.ndarray:
    """Generate a synthetic normal sinus rhythm ECG signal.
    """Generate normal sinus rhythm with physiological variation."""
    cycle = float(rng.uniform(45, 55))
    noise_amp = float(rng.uniform(5, 20))
    p_amp = float(rng.uniform(70, 95))
    r_amp = float(rng.uniform(1600, 2000))
    t_amp = float(rng.uniform(130, 180))

    Models the P-QRS-T complex with physiological variability:
      - P wave: small positive deflection
      - QRS complex: sharp R-peak with Q and S deflections
      - T wave: broad positive deflection
    """
    signal = np.zeros(length, dtype=np.float32)
    # Cycle length varies slightly (heart rate variability)
    cycle_len = int(rng.integers(45, 55))
    samples = []
    for i in range(length):
        phase = (i % cycle) / cycle
        val = 1850.0
        if 0.10 <= phase < 0.20:
            val += p_amp * math.sin((phase - 0.10) * math.pi / 0.10)
        elif 0.28 <= phase < 0.32:
            val -= 60.0
        elif 0.32 <= phase < 0.40:
            val += r_amp * math.sin((phase - 0.32) * math.pi / 0.08)
        elif 0.40 <= phase < 0.44:
            val -= 120.0
        elif 0.55 <= phase < 0.70:
            val += t_amp * math.sin((phase - 0.55) * math.pi / 0.15)
        val += float(rng.normal(0, noise_amp))
        samples.append(val)
    return np.array(samples, dtype=np.float32)

    for start in range(0, length - cycle_len, cycle_len):
        t = np.arange(cycle_len, dtype=np.float32) / cycle_len

        # P wave (phase 0.10–0.20)
        p_mask = (t >= 0.10) & (t < 0.20)
        signal[start:start + cycle_len][p_mask] += (
            rng.uniform(60, 100) * np.sin((t[p_mask] - 0.10) * math.pi / 0.10)
        )

        # Q dip (phase 0.28–0.32)
        q_mask = (t >= 0.28) & (t < 0.32)
        signal[start:start + cycle_len][q_mask] -= rng.uniform(40, 80)

        # R peak (phase 0.32–0.40)
        r_mask = (t >= 0.32) & (t < 0.40)
        signal[start:start + cycle_len][r_mask] += (
            rng.uniform(1500, 2000) * np.sin((t[r_mask] - 0.32) * math.pi / 0.08)
        )

        # S dip (phase 0.40–0.44)
        s_mask = (t >= 0.40) & (t < 0.44)
        signal[start:start + cycle_len][s_mask] -= rng.uniform(80, 150)

        # T wave (phase 0.55–0.70)
        t_mask = (t >= 0.55) & (t < 0.70)
        signal[start:start + cycle_len][t_mask] += (
            rng.uniform(100, 200) * np.sin((t[t_mask] - 0.55) * math.pi / 0.15)
        )

    # Add baseline wander + noise
    baseline = 30 * np.sin(2 * math.pi * np.arange(length) / length * rng.uniform(0.5, 2))
    noise = rng.normal(0, 15, length)
    signal += baseline.astype(np.float32) + noise.astype(np.float32)
    return signal


def _synthetic_arrhythmic_ecg(length: int, rng: np.random.Generator) -> np.ndarray:
    """Generate a synthetic arrhythmic ECG signal.
    """Generate irregular arrhythmic waveform with erratic ectopic spikes."""
    samples = []
    for i in range(length):
        val = 1850.0 + float(rng.uniform(600, 1000)) * math.sin(i * 0.25) * math.cos(i * 0.08)
        if i % int(rng.integers(14, 20)) == 0:
            val += float(rng.uniform(1200, 1600))
        val += float(rng.normal(0, 25))
        samples.append(val)
    return np.array(samples, dtype=np.float32)

    Characteristics that distinguish it from normal:
      - Irregular R-R intervals (varying cycle lengths)
      - Premature ectopic beats (random extra spikes)
      - Absent or inverted P waves
      - Higher baseline noise
    """
    signal = np.zeros(length, dtype=np.float32)
    pos = 0

    while pos < length - 30:
        # Irregular R-R interval (hallmark of arrhythmia)
        cycle_len = int(rng.integers(25, 70))
        end = min(pos + cycle_len, length)
        seg_len = end - pos
        t = np.arange(seg_len, dtype=np.float32) / max(cycle_len, 1)

        # Randomly omit P wave (common in atrial fibrillation)
        if rng.random() > 0.6:
            p_mask = (t >= 0.08) & (t < 0.18)
            signal[pos:end][p_mask] += rng.uniform(-30, 50) * np.sin(
                (t[p_mask] - 0.08) * math.pi / 0.10
            )

        # R peak with variable amplitude
        r_mask = (t >= 0.30) & (t < 0.42)
        signal[pos:end][r_mask] += (
            rng.uniform(800, 2200) * np.sin((t[r_mask] - 0.30) * math.pi / 0.12)
        )

        # Premature ectopic beat (PVC) — extra spike at random position
        if rng.random() > 0.65:
            spike_pos = int(rng.integers(0, max(seg_len - 3, 1)))
            spike_end = min(spike_pos + 3, seg_len)
            signal[pos + spike_pos:pos + spike_end] += rng.uniform(800, 1500)

        pos = end

    # Higher noise floor + irregular baseline
    baseline = 50 * np.sin(2 * math.pi * np.arange(length) / length * rng.uniform(1, 4))
    noise = rng.normal(0, 35, length)
    signal += baseline.astype(np.float32) + noise.astype(np.float32)
    return signal


def generate_ecg_dataset(n_per_class: int = 500) -> Path:
    """Generate synthetic ECG waveforms for training the arrhythmia classifier."""
    rng = np.random.default_rng(SEED + 1)
    signal_length = 200  # Matches the adaptive pooling input expectation

    signals = []
    labels = []

    for _ in range(n_per_class):
        sig = _synthetic_normal_ecg(signal_length, rng)
        signals.append(sig)
        labels.append(0)  # Normal

    for _ in range(n_per_class):
        sig = _synthetic_arrhythmic_ecg(signal_length, rng)
        signals.append(sig)
        labels.append(1)  # Arrhythmia

    signals_arr = np.stack(signals)
    labels_arr = np.array(labels, dtype=np.int64)

    out_path = DATA_DIR / "ecg_training_data.npz"
    np.savez(out_path, signals=signals_arr, labels=labels_arr)

    print(f"ECG dataset: {len(labels)} samples ({n_per_class} normal + "
          f"{n_per_class} arrhythmia) -> {out_path}")
    print(f"  Signal shape: {signals_arr.shape}, dtype: {signals_arr.dtype}")
    return out_path


# ============================================================================ #
# 3. Urine Dataset — 500 normal + 500 abnormal RGB samples
# ============================================================================ #
def generate_urine_dataset(n_per_class: int = 500) -> Path:
    """Generate synthetic urine colorimeter RGB readings.

    Normal urine: pale yellow to light amber
      - R: 180–255, G: 180–240, B: 80–160 (high luma, balanced channels)

    Abnormal urine:
      - Dark amber (dehydration): low overall luma (R<130, G<100, B<50)
      - Hematuria (blood): high red dominance (R/mean(G,B) > 1.35)
    """
    rng = np.random.default_rng(SEED + 2)
    rows = []

    # Normal samples: pale yellow to light amber
    for _ in range(n_per_class):
        r = float(rng.uniform(180, 255))
        g = float(rng.uniform(180, 240))
        b = float(rng.uniform(80, 160))
        rows.append([round(r, 1), round(g, 1), round(b, 1), 0])

    # Abnormal samples: mix of dark amber and hematuria
    for i in range(n_per_class):
        if i < n_per_class // 2:
            # Dark amber / concentrated (low luma)
            r = float(rng.uniform(60, 130))
            g = float(rng.uniform(40, 100))
            b = float(rng.uniform(10, 50))
        else:
            # Hematuria (high red ratio)
            r = float(rng.uniform(200, 255))
            g = float(rng.uniform(60, 120))
            b = float(rng.uniform(50, 110))
        rows.append([round(r, 1), round(g, 1), round(b, 1), 1])

    # Shuffle to avoid ordering bias
    rng.shuffle(rows)

    out_path = DATA_DIR / "urine_training_data.csv"
    with open(out_path, "w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(["red", "green", "blue", "severity"])
        writer.writerows(rows)

    labels = [r[3] for r in rows]
    print(f"Urine dataset: {len(rows)} samples ({n_per_class} normal + "
          f"{n_per_class} abnormal) -> {out_path}")
    print(f"  Normal: {labels.count(0)}, Abnormal: {labels.count(1)}")
    return out_path


# ============================================================================ #
# Main
# ============================================================================ #
def main():
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    print("=" * 70)
    print("SYNTHETIC DATASET GENERATOR FOR RAKSHA-SIM")
    print("=" * 70)
    print()

    generate_triage_dataset(1000)
    print()
    generate_ecg_dataset(500)
    print()
    generate_urine_dataset(500)

    print()
    print("=" * 70)
    print("All datasets generated successfully!")
    print("=" * 70)


if __name__ == "__main__":
    main()

