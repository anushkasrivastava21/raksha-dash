"""ASR transcription + clinical symptom extraction (CPU only, lazily loaded)."""
from __future__ import annotations

import json
import logging
import re
from fractions import Fraction
from functools import lru_cache
from typing import List, Optional, Tuple

import numpy as np
import scipy.io.wavfile as wav
from scipy.signal import resample_poly

from config import get_config

log = logging.getLogger(__name__)
CFG = get_config().audio

# Integer PCM -> float32 scale factors, avoids a chain of dtype if/elif blocks.
_PCM_SCALE = {
    np.dtype(np.int16): (1.0 / 32768.0, 0.0),
    np.dtype(np.int32): (1.0 / 2147483648.0, 0.0),
    np.dtype(np.uint8): (1.0 / 128.0, -128.0),
}


# --------------------------------------------------------------------------- #
# Lazy model loading - transformers is imported only on first real audio packet.
# --------------------------------------------------------------------------- #
@lru_cache(maxsize=1)
def _pipelines() -> Tuple[object, object]:
    import torch
    from transformers import pipeline

    torch.set_num_threads(CFG.torch_threads)      # bound RSS on small devices
    log.info("Loading ASR=%s NER=%s on %s", CFG.asr_model, CFG.ner_model, CFG.device)
    asr = pipeline("automatic-speech-recognition", model=CFG.asr_model, device=CFG.device)
    ner = pipeline("token-classification", model=CFG.ner_model, device=CFG.device)
    return asr, ner


@lru_cache(maxsize=1)
def _keyword_matcher() -> Optional[re.Pattern]:
    """One compiled alternation instead of 325 substring scans per transcript."""
    try:
        data = json.loads(CFG.keyword_file.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        log.error("Clinical lexicon unreadable at %s: %s", CFG.keyword_file, exc)
        return None
    terms = {t.strip().lower() for t in (*data.get("english", ()), *data.get("hinglish", ())) if t}
    if not terms:
        return None
    # Longest-first so "chest pain" wins over "pain".
    alternation = "|".join(re.escape(t) for t in sorted(terms, key=len, reverse=True))
    return re.compile(rf"\b(?:{alternation})\b")


def warmup() -> None:
    """Optional: pay the model-load cost at boot rather than on the first patient."""
    _pipelines()
    _keyword_matcher()


# --------------------------------------------------------------------------- #
# Audio conditioning
# --------------------------------------------------------------------------- #
def _to_mono_float32(audio: np.ndarray) -> np.ndarray:
    if audio.ndim > 1:
        audio = audio.mean(axis=1)
    scale, offset = _PCM_SCALE.get(audio.dtype, (None, None))
    if scale is None:
        return np.asarray(audio, dtype=np.float32)
    out = audio.astype(np.float32)
    if offset:
        out += offset
    out *= scale
    return out


def _resample(audio: np.ndarray, src_rate: int) -> np.ndarray:
    if src_rate == CFG.target_sample_rate:
        return audio
    ratio = Fraction(CFG.target_sample_rate, int(src_rate)).limit_denominator(1000)
    return resample_poly(audio, ratio.numerator, ratio.denominator).astype(np.float32, copy=False)


def _condense(text: str) -> str:
    """Collapse whitespace, drop ASR filler repeats, cap length before tokenising."""
    text = re.sub(r"\s+", " ", text).strip().lower()
    text = re.sub(r"\b(\w+)(?: \1\b)+", r"\1", text)      # "pain pain pain" -> "pain"
    return text[: CFG.max_transcript_chars]


# --------------------------------------------------------------------------- #
# Public API
# --------------------------------------------------------------------------- #
def extract_symptoms(audio_file_path: Optional[str]) -> List[str]:
    """Return de-duplicated clinical symptom strings. Never raises."""
    if not audio_file_path:
        return []
    try:
        src_rate, raw = wav.read(audio_file_path, mmap=True)
        max_samples = int(CFG.max_seconds * src_rate)
        if raw.shape[0] > max_samples:                    # bound memory + ASR tokens
            log.info("Truncating audio to %.0fs", CFG.max_seconds)
            raw = raw[:max_samples]

        audio = _to_mono_float32(raw)
        del raw

        peak = float(np.abs(audio).max(initial=0.0))
        if peak < CFG.silence_threshold:
            log.warning("Near-silent audio packet; skipping ASR.")
            return []
        audio /= peak                                     # in place, no second buffer
        audio = _resample(audio, src_rate)

        asr, ner = _pipelines()
        result = asr(
            {"sampling_rate": CFG.target_sample_rate, "raw": audio},
            generate_kwargs={"task": CFG.asr_task, "language": CFG.asr_language},
        )
        del audio
        transcript = _condense(result.get("text", ""))
        if not transcript:
            return []
        log.info("Transcript: %s", transcript)

        found: List[str] = []
        seen = set()
        for ent in ner(transcript):
            if CFG.entity_tag in ent.get("entity", ""):
                word = ent["word"].strip()
                if word and word.lower() not in seen:
                    seen.add(word.lower())
                    found.append(word)

        matcher = _keyword_matcher()
        if matcher is not None:
            for match in matcher.findall(transcript):
                if match not in seen:
                    seen.add(match)
                    found.append(match)

        log.info("Extracted symptoms: %s", found)
        return found
    except Exception as exc:                              # noqa: BLE001
        log.error("Symptom extraction failed (%s); degrading to no symptoms.", exc)
        return []
