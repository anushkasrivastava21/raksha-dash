# Raksha-Sim — refactored pipeline

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

## Run
    .venv\Scripts\Activate.ps1                  # Windows dev
    export RAKSHA_DATASET_URL=https://.../esp32_payloads.json
    python test_pipeline.py --limit 5

## Required before clinical use
`models/ecg_cnn.pt` and `models/urine_cnn.pt` do not exist yet. Until they do,
ECG reports "Undetermined" and urine falls back to documented colour rules.

## On-device voice stack
Default backends are chosen for a phone and need no PyTorch:

| Stage | Was | Now | Weights |
|---|---|---|---|
| ASR | `openai/whisper-tiny` under transformers | Vosk `vosk-model-small-en-in-0.4` | 36 MB |
| Symptoms | `d4data/biomedical-ner-all` (DeBERTa) | `symptom_extractor.py` lexicon + negation + fuzzy | 0 MB |

Setup:

    pip install -r requirements-mobile.txt
    mkdir -p models && cd models
    wget https://alphacephei.com/vosk/models/vosk-model-small-en-in-0.4.zip && unzip vosk-model-small-en-in-0.4.zip
    # Hindi-dominant deployments: vosk-model-small-hi-0.22.zip (42 MB)
    export RAKSHA_AUDIO_VOSK_MODEL_DIR=models/vosk-model-small-en-in-0.4

Alternative ASR backends (`RAKSHA_AUDIO_ASR_BACKEND`): `whispercpp`,
`faster_whisper`, `transformers`. See `asr_backends.py`.
