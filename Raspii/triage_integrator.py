"""Central orchestrator: unpack payload -> sub-processors -> XGBoost inference."""
from __future__ import annotations

import logging
import math
from typing import Any, Dict, List, Optional, Sequence

import numpy as np
import xgboost as xgb

from config import get_config
from ecg_processor import process_ecg
from urine_processor import process_urine
from voice_processor import extract_symptoms

logger = logging.getLogger(__name__)
log = logger  # backwards-compatible alias
_CFG = get_config()
CFG, ECG_CFG, AUDIO_CFG = _CFG.triage, _CFG.ecg, _CFG.audio

_FEATURES = list(CFG.feature_order)
_booster: Optional[xgb.Booster] = None
_booster_ready: Optional[bool] = None



def _get_booster() -> Optional[xgb.Booster]:
    """Raw Booster instead of XGBClassifier: no sklearn/pandas round-trip."""
    global _booster, _booster_ready
    if _booster_ready is not None:
        return _booster if _booster_ready else None
    try:
        booster = xgb.Booster()
        booster.load_model(str(CFG.model_path))
        _booster, _booster_ready = booster, True
        log.info("Loaded triage model from %s", CFG.model_path)
    except Exception as exc:                              # noqa: BLE001
        log.error("Triage model unavailable at %s (%s); using fallback prior.",
                  CFG.model_path, exc)
        _booster_ready = False
    return _booster


# --------------------------------------------------------------------------- #
# Payload parsing
# --------------------------------------------------------------------------- #
def _section(packet: Dict[str, Any], key: str) -> Dict[str, Any]:
    value = packet.get(key)
    return value if isinstance(value, dict) else {}


def _num_or_none(source: Dict[str, Any], key: str) -> Optional[float]:
    """Finite float for ``source[key]``, or None if missing / None / wrong type."""
    value = source.get(key)
    if value is None or isinstance(value, bool):
        return None
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    return number if math.isfinite(number) else None


def _num(source: Dict[str, Any], key: str, default: float) -> float:
    number = _num_or_none(source, key)
    return default if number is None else number


def _number_list(value: Any, min_len: int = 0) -> Optional[List[float]]:
    """Clean list of finite numbers, or None if value is not a usable sequence."""
    if not isinstance(value, (list, tuple)):
        return None
    out: List[float] = []
    for item in value:
        if isinstance(item, bool) or not isinstance(item, (int, float)) or not math.isfinite(item):
            return None
        out.append(float(item))
    return out if len(out) >= min_len else None


def record_live_audio(
    duration: Optional[float] = None,
    sample_rate: Optional[int] = None,
    output_file: Optional[str] = None,
) -> Optional[str]:
    """Capture from the USB mic. ``sounddevice`` is imported here, not at module
    load, so headless servers without PortAudio can still run triage."""
    duration = duration or AUDIO_CFG.record_seconds
    sample_rate = sample_rate or AUDIO_CFG.target_sample_rate
    path = str(output_file or AUDIO_CFG.recording_path)
    try:
        import sounddevice as sd
        import scipy.io.wavfile as wav

        log.info("Recording %.1fs of patient audio...", duration)
        frames = sd.rec(int(duration * sample_rate), samplerate=sample_rate,
                        channels=AUDIO_CFG.record_channels, dtype=AUDIO_CFG.record_dtype)
        sd.wait()
        wav.write(path, sample_rate, frames)
        log.info("Recording saved to %s", path)
        return path
    except Exception as exc:                              # noqa: BLE001
        log.error("Live capture unavailable (%s); continuing without audio.", exc)
        return None


def parse_sensor_packet(sensor_packet: Any) -> Dict[str, Any]:
    """Extract the 4 model features plus the two qualitative signals.

    Tolerant of a missing or partial packet: any absent / None / wrong-typed
    field falls back to a configured default and logs a warning.
    """
    if not isinstance(sensor_packet, dict):
        logger.warning("Packet is not a dict (%s), treating as empty", type(sensor_packet).__name__)
        sensor_packet = {}

    # --- Voice ------------------------------------------------------------ #
    audio_path = sensor_packet.get("step_1_audio")
    if not isinstance(audio_path, str) or not audio_path:
        audio_path = None
    elif audio_path == AUDIO_CFG.record_trigger:
        audio_path = record_live_audio()
    symptoms: List[str] = extract_symptoms(audio_path) if audio_path else []

    keywords = sensor_packet.get("voice_keywords")
    if isinstance(keywords, (list, tuple)):
        for word in keywords:
            if isinstance(word, str) and word.strip() and word not in symptoms:
                symptoms.append(word)
    elif audio_path is None:
        logger.warning("Missing voice_keywords in packet, using default")

    # --- ECG -------------------------------------------------------------- #
    ecg = _section(sensor_packet, "ecg")
    ecg_hr = _num_or_none(ecg, "heart_rate_bpm")
    samples = _number_list(ecg.get("samples"), 1) or _number_list(sensor_packet.get("step_2_ecg"), 1)

    # --- Pulse oximetry --------------------------------------------------- #
    pox = _section(sensor_packet, "pulse_oximeter")
    if pox:
        spo2 = _num_or_none(pox, "spo2_percent")
        if ecg_hr is None:
            ecg_hr = _num_or_none(pox, "heart_rate_bpm")
    else:
        spo2 = _num_or_none(_section(sensor_packet, "step_4_pulse_oximetry"), "spo2")
    if spo2 is None:
        logger.warning("Missing pulse_oximeter/spo2_percent in packet, using default")
        spo2 = CFG.default_spo2

    # --- ECG fallbacks (HR / samples), CNN skipped when no waveform -------- #
    if samples is None:
        logger.warning("Missing ecg in packet, using default")
        samples = [0.0] * 20
        ecg_result = ECG_CFG.label_normal            # skip the CNN call
    else:
        ecg_result = process_ecg(samples)
    if ecg_hr is None:
        if ecg:
            logger.warning("Missing ecg/heart_rate_bpm in packet, using default")
        ecg_hr = CFG.default_hr_bpm

    # --- Urine colorimeter ------------------------------------------------ #
    urine = _section(sensor_packet, "urine_sensor")
    default_r, default_g, default_b = _CFG.urine.default_rgb
    rgb: Optional[List[float]] = None
    if urine:
        parts = [_num_or_none(urine, k) for k in ("red", "green", "blue")]
        if all(p is not None for p in parts):
            rgb = parts  # type: ignore[assignment]
    else:
        rgb = _number_list(sensor_packet.get("urine_rgb"), 3)
    if rgb is None:
        logger.warning("Missing urine_sensor in packet, using default")
        rgb = [default_r, default_g, default_b]

    # --- Temperature ------------------------------------------------------ #
    temperature_section = _section(sensor_packet, "temperature")
    temperature = (
        _num_or_none(temperature_section, "body_temp_c")
        if temperature_section
        else _num_or_none(sensor_packet, "step_5_ir_temperature")
    )
    if temperature is None:
        logger.warning("Missing temperature/body_temp_c in packet, using default")
        temperature = CFG.default_temp_c

    # --- Stethoscope: no analysis is run in this pipeline; skip if absent -- #
    if not _section(sensor_packet, "stethoscope"):
        logger.warning("Missing stethoscope in packet, skipping stethoscope analysis")

    # step_3_bp is not consumed by this pipeline, so a missing/odd value cannot crash it.

    return {
        "ecg_hr": ecg_hr,
        "spo2": spo2,
        "temperature": temperature,
        "urine_severity": process_urine(rgb),
        "ecg_result": ecg_result,
        "symptoms": symptoms,
    }


# --------------------------------------------------------------------------- #
# Inference
# --------------------------------------------------------------------------- #
def _base_probabilities(parsed: Dict[str, Any]) -> np.ndarray:
    booster = _get_booster()
    if booster is None:
        return np.asarray(CFG.fallback_probs, dtype=np.float32)
    row = np.fromiter((parsed[name] for name in _FEATURES), dtype=np.float32, count=len(_FEATURES))
    matrix = xgb.DMatrix(row.reshape(1, -1), feature_names=_FEATURES)
    return np.asarray(booster.predict(matrix)[0], dtype=np.float32)


def _escalate(probs: np.ndarray, symptoms: Sequence[str], ecg_result: str) -> np.ndarray:
    """Rule layer on top of the model: reported symptoms or a detected
    arrhythmia push the patient towards Red. Operates in place."""
    arrhythmia = ecg_result == ECG_CFG.label_arrhythmia
    if not symptoms and not arrhythmia:
        return probs
    green, yellow, red = CFG.class_labels.index("Green"), \
        CFG.class_labels.index("Yellow"), CFG.class_labels.index("Red")
    probs[red] += CFG.arrhythmia_red_boost if arrhythmia else CFG.symptom_red_boost
    probs[yellow] += CFG.symptom_yellow_boost
    probs[green] *= CFG.symptom_green_decay
    total = float(probs.sum())
    if total > 0:
        probs /= total
    return probs


def predict_final_triage(sensor_packet: Dict[str, Any]) -> Dict[str, Any]:
    """Run the full pipeline and return the locked output payload."""
    parsed = parse_sensor_packet(sensor_packet)
    probs = _escalate(_base_probabilities(parsed), parsed["symptoms"], parsed["ecg_result"])
    index = int(np.argmax(probs))
    return {
        "triage_color": CFG.class_labels[index],
        "confidence_score": round(float(probs[index]), CFG.confidence_decimals),
        "symptom_list": parsed["symptoms"],
        "ecg_result": parsed["ecg_result"],
    }
