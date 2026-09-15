"""Pluggable speech-to-text backends.

Every backend takes 16 kHz mono int16 PCM and returns plain text. Only the
backend actually selected in config gets imported, so a phone build never
needs torch or transformers on disk.

Footprints (approximate, ARM64):
    vosk            vosk wheel ~10 MB + model 36-42 MB   -> no torch
    whispercpp      pywhispercpp ~5 MB + ggml q5_1 31 MB -> no torch
    faster_whisper  ctranslate2 ~30 MB + int8 tiny 39 MB -> no torch
    transformers    torch ~900 MB + whisper-tiny 151 MB  -> dev machines only
"""
from __future__ import annotations

import json
import logging
from functools import lru_cache
from typing import Protocol

import numpy as np

from config import get_config

log = logging.getLogger(__name__)
CFG = get_config().audio


class ASRBackend(Protocol):
    name: str

    def transcribe(self, pcm16: np.ndarray, sample_rate: int) -> str:
        ...


# --------------------------------------------------------------------------- #
class VoskBackend:
    """Kaldi-based, streaming, fully offline. Recommended for the phone build.

    Model zoo (https://alphacephei.com/vosk/models):
        vosk-model-small-en-in-0.4   36 MB  Indian English, handles code-switching
        vosk-model-small-hi-0.22     42 MB  Hindi
    """

    name = "vosk"

    def __init__(self) -> None:
        from vosk import KaldiRecognizer, Model, SetLogLevel

        if not CFG.vosk_model_dir.is_dir():
            raise FileNotFoundError(
                f"Vosk model not found at {CFG.vosk_model_dir}. "
                "Download a small model from https://alphacephei.com/vosk/models and unzip it there."
            )
        SetLogLevel(-1)
        self._model = Model(str(CFG.vosk_model_dir))
        self._recognizer_cls = KaldiRecognizer
        log.info("Vosk model ready: %s", CFG.vosk_model_dir.name)

    def transcribe(self, pcm16: np.ndarray, sample_rate: int) -> str:
        rec = self._recognizer_cls(self._model, float(sample_rate))
        rec.SetWords(True)
        # Feed in chunks so peak memory stays at one buffer, not the whole clip.
        view = pcm16.reshape(-1)
        step = sample_rate  # 1 second
        for start in range(0, view.size, step):
            rec.AcceptWaveform(view[start:start + step].tobytes())
        result = json.loads(rec.FinalResult())

        words = result.get("result") or []
        if not words:
            return result.get("text", "")
        # Drop low-confidence tokens: a hallucinated "dard" must not trigger triage.
        kept = [w["word"] for w in words if w.get("conf", 1.0) >= CFG.vosk_min_word_confidence]
        dropped = len(words) - len(kept)
        if dropped:
            log.info("Dropped %d low-confidence ASR token(s)", dropped)
        return " ".join(kept)


# --------------------------------------------------------------------------- #
class WhisperCppBackend:
    """Quantised GGML Whisper via pywhispercpp. Keeps Whisper's multilingual
    coverage without PyTorch. Use ggml-tiny-q5_1.bin (~31 MB)."""

    name = "whispercpp"

    def __init__(self) -> None:
        from pywhispercpp.model import Model

        if not CFG.whispercpp_model.is_file():
            raise FileNotFoundError(f"GGML model missing: {CFG.whispercpp_model}")
        self._model = Model(str(CFG.whispercpp_model), n_threads=CFG.torch_threads,
                            print_progress=False, print_realtime=False)

    def transcribe(self, pcm16: np.ndarray, sample_rate: int) -> str:
        audio = (pcm16.astype(np.float32) / 32768.0)
        segments = self._model.transcribe(audio, language=CFG.asr_language[:2])
        return " ".join(s.text for s in segments)


# --------------------------------------------------------------------------- #
class FasterWhisperBackend:
    """CTranslate2 int8 Whisper. Heavier than Vosk, better multilingual accuracy."""

    name = "faster_whisper"

    def __init__(self) -> None:
        from faster_whisper import WhisperModel

        self._model = WhisperModel(CFG.faster_whisper_model, device="cpu",
                                   compute_type=CFG.faster_whisper_compute,
                                   cpu_threads=CFG.torch_threads)

    def transcribe(self, pcm16: np.ndarray, sample_rate: int) -> str:
        audio = pcm16.astype(np.float32) / 32768.0
        segments, _ = self._model.transcribe(audio, language=CFG.asr_language[:2],
                                             vad_filter=True)
        return " ".join(s.text for s in segments)


# --------------------------------------------------------------------------- #
class TransformersBackend:
    """Original PyTorch path. Kept for parity testing on the dev laptop only."""

    name = "transformers"

    def __init__(self) -> None:
        import torch
        from transformers import pipeline

        torch.set_num_threads(CFG.torch_threads)
        self._asr = pipeline("automatic-speech-recognition", model=CFG.asr_model,
                             device=CFG.device)

    def transcribe(self, pcm16: np.ndarray, sample_rate: int) -> str:
        audio = pcm16.astype(np.float32) / 32768.0
        out = self._asr({"sampling_rate": sample_rate, "raw": audio},
                        generate_kwargs={"task": CFG.asr_task, "language": CFG.asr_language})
        return out.get("text", "")


_BACKENDS = {
    "vosk": VoskBackend,
    "whispercpp": WhisperCppBackend,
    "faster_whisper": FasterWhisperBackend,
    "transformers": TransformersBackend,
}


@lru_cache(maxsize=1)
def get_asr_backend() -> ASRBackend | None:
    """Instantiate the configured backend once per process."""
    cls = _BACKENDS.get(CFG.asr_backend)
    if cls is None:
        log.error("Unknown asr_backend %r; expected one of %s",
                  CFG.asr_backend, sorted(_BACKENDS))
        return None
    try:
        return cls()
    except Exception as exc:                               # noqa: BLE001
        log.error("ASR backend %r unavailable (%s); voice input disabled.",
                  CFG.asr_backend, exc)
        return None
