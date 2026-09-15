"""Audio conditioning -> ASR -> symptom extraction.

Nothing in this module imports torch or transformers. The heavy work is
delegated to a configurable ASR backend (Vosk by default) and to a
model-free lexicon matcher.
"""
from __future__ import annotations

import logging
from fractions import Fraction
from typing import List, Optional

import numpy as np
import scipy.io.wavfile as wav
from scipy.signal import resample_poly

import symptom_extractor
from asr_backends import get_asr_backend
from config import get_config
from symptom_extractor import Symptom

log = logging.getLogger(__name__)
CFG = get_config().audio

_INT16_MAX = 32768.0
_ner = None


def warmup() -> None:
    """Load the ASR model and lexicon at boot, not on the first patient."""
    get_asr_backend()
    symptom_extractor.extract("warmup")


# --------------------------------------------------------------------------- #
# Conditioning: everything stays int16 until the backend asks otherwise.
# --------------------------------------------------------------------------- #
def _to_mono_int16(audio: np.ndarray) -> np.ndarray:
    if audio.ndim > 1:
        audio = audio.mean(axis=1)
    if audio.dtype == np.int16:
        return np.ascontiguousarray(audio)
    if audio.dtype == np.int32:
        return (audio >> 16).astype(np.int16)
    if audio.dtype == np.uint8:
        return ((audio.astype(np.int16) - 128) << 8).astype(np.int16)
    return np.clip(audio * _INT16_MAX, -_INT16_MAX, _INT16_MAX - 1).astype(np.int16)


def _resample_int16(audio: np.ndarray, src_rate: int) -> np.ndarray:
    if src_rate == CFG.target_sample_rate:
        return audio
    ratio = Fraction(CFG.target_sample_rate, int(src_rate)).limit_denominator(1000)
    resampled = resample_poly(audio.astype(np.float32), ratio.numerator, ratio.denominator)
    np.clip(resampled, -_INT16_MAX, _INT16_MAX - 1, out=resampled)
    return resampled.astype(np.int16)


def _normalise_gain(audio: np.ndarray) -> Optional[np.ndarray]:
    """Peak-normalise in int16 space. Returns None for silent packets."""
    peak = int(np.abs(audio.astype(np.int32)).max(initial=0))
    if peak < CFG.silence_threshold * _INT16_MAX or peak == 0:
        return None
    gain = (_INT16_MAX - 1) / peak
    if gain <= 1.05:                      # already loud enough, skip the copy
        return audio
    scaled = audio.astype(np.float32)
    scaled *= gain
    return scaled.astype(np.int16)


def transcribe(audio_file_path: str) -> str:
    """WAV file -> plain transcript. Returns '' on any failure."""
    backend = get_asr_backend()
    if backend is None:
        return ""
    try:
        src_rate, raw = wav.read(audio_file_path, mmap=True)
        max_samples = int(CFG.max_seconds * src_rate)
        if raw.shape[0] > max_samples:
            log.info("Truncating audio to %.0fs", CFG.max_seconds)
            raw = raw[:max_samples]

        audio = _to_mono_int16(raw)
        del raw
        audio = _resample_int16(audio, src_rate)
        conditioned = _normalise_gain(audio)
        if conditioned is None:
            log.warning("Near-silent audio packet; skipping ASR.")
            return ""

        text = backend.transcribe(conditioned, CFG.target_sample_rate).strip()
        log.info("[%s] transcript: %s", backend.name, text or "<empty>")
        return text
    except Exception as exc:                               # noqa: BLE001
        log.error("Transcription failed (%s); degrading to no audio.", exc)
        return ""


# --------------------------------------------------------------------------- #
# Public API
# --------------------------------------------------------------------------- #
def extract_symptoms_detailed(audio_file_path: Optional[str]) -> List[Symptom]:
    """Full result including severity tier - used by the triage escalation rule."""
    if not audio_file_path:
        return []
    try:
        transcript = transcribe(audio_file_path)
        if not transcript:
            return []
        found = symptom_extractor.extract(transcript)
        if CFG.symptom_backend == "ner":
            found = _merge_ner(transcript, found)
        log.info("Symptoms: %s", [(s.canonical, s.tier) for s in found])
        return found
    except Exception as exc:                               # noqa: BLE001
        log.error("Symptom extraction failed (%s); degrading to no symptoms.", exc)
        return []


def extract_symptoms(audio_file_path: Optional[str]) -> List[str]:
    """Backwards-compatible contract: a flat list of canonical symptom names."""
    return symptom_extractor.names(extract_symptoms_detailed(audio_file_path))


def _merge_ner(transcript: str, found: List[Symptom]) -> List[Symptom]:
    """Optional biomedical-NER augmentation. Dev machines only - do not enable
    on the phone build, the model alone is ~420 MB."""
    global _ner
    try:
        from transformers import pipeline
    except ImportError:
        log.warning("symptom_backend='ner' requested but transformers is absent.")
        return found

    if _ner is None:
        _ner = pipeline("token-classification", model=CFG.ner_model, device=CFG.device)

    known = {s.canonical for s in found}
    for entity in _ner(transcript):
        if CFG.entity_tag in entity.get("entity", ""):
            word = entity["word"].strip().lower()
            if word and word not in known:
                known.add(word)
                found.append(Symptom(word, "minor", word))
    return found
