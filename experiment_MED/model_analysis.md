# Raksha-Sim Model Analysis & TFLite Pipeline Guide

## Overview

Raksha-Sim is a multi-sensor medical triage system designed for mobile/embedded
deployment. The pipeline processes five types of sensor input and produces a
colour-coded triage classification (Green / Yellow / Red).

---

## Models

### 1. ECG_CNN — Arrhythmia Classifier

| Property | Value |
|----------|-------|
| **Source file** | `ecg_processor.py` |
| **Framework** | PyTorch (original) → TFLite |
| **Architecture** | Conv1D(1→16, k=5, s=2) → ReLU → AdaptiveAvgPool1D(78) → Linear(1248→2) |
| **Input** | `float32 (1, 1, 256)` — single-channel ECG signal, 256 samples |
| **Output** | `float32 (1, 2)` — logits for [Normal, Arrhythmia] |
| **Pre-processing** | Butterworth bandpass (0.5–45 Hz) → zero-mean → peak normalisation |
| **TFLite file** | `models/ecg_cnn.tflite` |
| **Size** | ~15–50 KB |

**Signal flow:**
```
Raw ADC samples → bandpass filter → normalise → reshape (1,1,256) → Conv1D → Pool → FC → argmax
                                                                                           ↓
                                                                            "Normal Sinus Rhythm" or
                                                                            "Arrhythmia Detected"
```

---

### 2. Urine_CNN — Colorimetric Severity Classifier

| Property | Value |
|----------|-------|
| **Source file** | `urine_processor.py` |
| **Framework** | PyTorch (original) → TFLite |
| **Architecture** | Linear(3→16) → ReLU → Linear(16→2) |
| **Input** | `float32 (1, 3)` — normalised R, G, B values (0–255) |
| **Output** | `float32 (1, 2)` — logits for [Normal, Abnormal] |
| **Pre-processing** | ADC-to-RGB scaling (÷ 4095 × 255 if raw ADC) |
| **TFLite file** | `models/urine_cnn.tflite` |
| **Size** | ~2–5 KB |

**Signal flow:**
```
Raw ADC (R, G, B) → normalise to 0-255 → [R, G, B] tensor → Linear → ReLU → Linear → argmax
                                                                                         ↓
                                                                         severity 0 (normal) or 1 (abnormal)
```

---

### 3. Triage Model — Multi-Class Vital-Sign Classifier

| Property | Value |
|----------|-------|
| **Source file** | `triage_integrator.py` |
| **Original framework** | XGBoost Booster |
| **TFLite conversion** | XGBoost → Keras surrogate (Dense 32→16→3) → TFLite |
| **Input** | `float32 (1, 6)` — 6 vital-sign features |
| **Output** | `float32 (1, 3)` — probabilities for [Green, Yellow, Red] |
| **TFLite file** | `models/triage_model.tflite` |
| **Size** | ~5–20 KB |

**Feature vector (order matters):**

| Index | Feature | Unit | Typical Range |
|-------|---------|------|---------------|
| 0 | `ecg_hr` | bpm | 40–160 |
| 1 | `bp_sys` | mmHg | 70–220 |
| 2 | `bp_dia` | mmHg | 30–140 |
| 3 | `spo2` | % | 75–100 |
| 4 | `temperature` | °C | 34–43 |
| 5 | `urine_severity` | 0/1 | 0 or 1 |

---

## Non-Model Components (Python only, not TFLite)

### Symptom Extraction (`symptom_extractor.py`)
- **Method:** Lexicon gazetteer + regex + negation detection + fuzzy matching
- **Input:** Plain text transcript from ASR
- **Output:** List of `Symptom(canonical, tier, matched, negated, fuzzy)`
- **Tiers:** critical / moderate / minor

### ASR Backends (`asr_backends.py`, `voice_processor.py`)
- Vosk (default), WhisperCpp, Faster-Whisper, Transformers
- **Input:** 16 kHz mono int16 PCM audio
- **Output:** Plain text transcript

### Escalation Rules (`triage_integrator.py`)
Post-model rule layer that boosts Red probability based on:
- Critical symptoms: +0.45
- Moderate symptoms: +0.18
- Minor symptoms: +0.05
- Arrhythmia detected: +0.45
- Cap at 0.60

---

## Full Pipeline Flow

```
ESP32 Sensor Packet
├── Audio WAV ──→ ASR (Vosk) ──→ Symptom Extraction ──→ symptom list + tier
├── ECG samples ──→ bandpass ──→ normalise ──→ [ECG TFLite] ──→ Normal/Arrhythmia
├── Urine RGB ──→ normalise ──→ [Urine TFLite] ──→ severity (0/1)
├── Heart Rate, BP sys/dia, SpO2, Temperature (passthrough)
│
│   ┌─────────────────────────────────────────┐
│   │  Feature vector (6 floats):             │
│   │  [hr, bp_sys, bp_dia, spo2, temp, sev]  │
│   └────────────────┬────────────────────────┘
│                    ↓
│            [Triage TFLite]
│                    ↓
│          base probs [G, Y, R]
│                    ↓
│         Symptom + ECG escalation
│                    ↓
│          final probs [G, Y, R]
│                    ↓
│       argmax → Triage Color + Confidence
└──→ Output: { triage_color, confidence, ecg_result, symptoms }
```

---

## How to Run

### Step 1: Generate dummy model weights
```bash
python train_dummy_models.py
```
Creates: `models/ecg_cnn.pt`, `models/urine_cnn.pt`, `models/triage_xgboost.json`

### Step 2: Convert all models to TFLite
```bash
python convert_to_tflite.py
```
Creates: `models/ecg_cnn.tflite`, `models/urine_cnn.tflite`, `models/triage_model.tflite`

### Step 3: Run the TFLite pipeline on random data
```bash
# Default: 10 random patients
python run_tflite_pipeline.py

# Specify number of patients
python run_tflite_pipeline.py --num_patients 50

# Continuous stream (Ctrl+C to stop)
python run_tflite_pipeline.py --continuous --interval 1.0

# Machine-readable JSON output
python run_tflite_pipeline.py --num_patients 20 --json

# Reproducible (seeded) run
python run_tflite_pipeline.py --seed 42
```

### Dependencies
```
pip install numpy scipy torch xgboost tensorflow onnx onnx-tf
```

---

## File Inventory

| File | Purpose |
|------|---------|
| `train_dummy_models.py` | Generate dummy weights for all 3 models |
| `convert_to_tflite.py` | Convert PyTorch + XGBoost → TFLite |
| `run_tflite_pipeline.py` | Standalone TFLite runner with random data |
| `models/ecg_cnn.tflite` | ECG arrhythmia classifier |
| `models/urine_cnn.tflite` | Urine colorimetric classifier |
| `models/triage_model.tflite` | Vital-sign triage classifier |
| `model_analysis.md` | This file — architecture documentation |

