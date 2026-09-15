# Raksha-Sim — refactored pipeline
# Raksha-Sim — Multi-Modal Clinical Triage System

## Layout
    config.py                    single source of truth for every threshold/path/URL
    raksha_config.example.json   copy to raksha_config.json to override defaults
    .env.example                 env vars (RAKSHA_<SECTION>_<KEY>) override the JSON file
    dataset_loader.py            fetches mock ESP32 payloads over HTTP (+ disk cache)
    ecg_processor.py             bandpass + arrhythmia CNN, length-agnostic
    urine_processor.py           colorimeter -> severity (CNN, or documented rule fallback)
    voice_processor.py           lazy Whisper/NER, 16 kHz resample, token-capped transcripts
    triage_integrator.py         orchestration + XGBoost Booster inference
    triage_engine.py             public analyze_patient() entry point
    test_pipeline.py             terminal-only E2E test against the remote dataset
    data/clinical_keywords.json  bilingual fallback lexicon (was a 325-item literal)
    data/mock_payloads.sample.json  host this at RAKSHA_DATASET_URL
```text
config.py                    Single source of truth for thresholds, features, and paths
triage_integrator.py         Orchestrator: extracts features -> XGBoost -> clinical escalation
triage_engine.py             Public entry point: analyze_patient(sensor_packet)
run_offline.py               Offline test runner for VS Code with synthetic patient cases
generate_datasets.py         Generates synthetic training datasets (>500 samples each)
train_models.py              Trains XGBoost, ECG CNN, and Urine CNN models
ecg_processor.py             Butterworth bandpass filter + 1D CNN arrhythmia classification
urine_processor.py           Colorimeter RGB -> clinical severity (Urine CNN + rule fallback)
voice_processor.py           Lazy Whisper ASR + Biomedical NER for symptom extraction
dataset_loader.py            Fetches remote ESP32 mock payloads (+ disk cache)
test_pipeline.py             E2E integration test against dataset endpoint
data/
  ├── triage_training_data.csv  Synthetic triage data (1,000 samples, 4 features)
  ├── ecg_training_data.npz     Synthetic ECG waveforms (1,000 samples: 500 normal, 500 arrhythmia)
  ├── urine_training_data.csv   Synthetic urine RGB (1,000 samples: 500 normal, 500 abnormal)
  └── clinical_keywords.json    Bilingual clinical lexicon (English + Hinglish fallback)
models/
  ├── ecg_cnn.pt                Trained PyTorch 1D CNN for arrhythmia detection
  └── urine_cnn.pt              Trained PyTorch MLP for urine colorimeter severity
triage_xgboost.json          Trained XGBoost 3-class booster (4 vital features)
```

## Run
    .venv\Scripts\Activate.ps1                  # Windows dev
    export RAKSHA_DATASET_URL=https://.../esp32_payloads.json
    python test_pipeline.py --limit 5
## AI & ML Models Used

## Required before clinical use
`models/ecg_cnn.pt` and `models/urine_cnn.pt` do not exist yet. Until they do,
ECG reports "Undetermined" and urine falls back to documented colour rules.
1. **XGBoost Triage Booster** (`triage_xgboost.json`):
   - **Input Features (4)**: `ecg_hr` (Heart Rate), `spo2` (Oxygen Saturation), `temperature` (Body Temp), `urine_severity` (Urine Score)
   - **Output**: Multi-class probability over `[Green, Yellow, Red]` triage levels.
   - **Training Data**: `data/triage_training_data.csv` (1,000 samples, 98.5% test accuracy).

2. **ECG Arrhythmia 1D CNN** (`models/ecg_cnn.pt`):
   - **Architecture**: `Conv1d(1->16, k=5, s=2) -> ReLU -> AdaptiveAvgPool1d(78) -> Linear(1248, 2)`
   - **Input**: Filtered 1D raw ECG signal of variable length.
   - **Output**: Binary classification (`Normal Sinus Rhythm` vs `Arrhythmia Detected`).
   - **Training Data**: `data/ecg_training_data.npz` (1,000 synthetic waveforms, 100% test accuracy).

3. **Urine Colorimeter Classifier** (`models/urine_cnn.pt`):
   - **Architecture**: `Linear(3->16) -> ReLU -> Linear(16->2)`
   - **Input**: Normalized RGB sensor counts `[R, G, B]`.
   - **Output**: Binary severity class (`0 = Normal`, `1 = Abnormal`).
   - **Training Data**: `data/urine_training_data.csv` (1,000 samples, 100% test accuracy).

4. **Whisper ASR Speech-to-Text** (`openai/whisper-tiny`):
   - Transcribes patient voice recordings into clinical text.
   - Pre-trained on 680,000 hours of multilingual audio.

5. **Biomedical NER** (`d4data/biomedical-ner-all`):
   - Token-classification BERT extracting symptom entities from transcripts.
   - Combined with fallback regex matching against `clinical_keywords.json` (326 terms).

## Quick Run (VS Code / Offline)
```powershell
python run_offline.py
```
