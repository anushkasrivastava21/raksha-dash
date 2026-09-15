"""Central orchestrator: unpack payload -> sub-processors -> XGBoost inference."""
from __future__ import annotations

import logging
from typing import Any, Dict, List, Optional, Sequence

import numpy as np
import xgboost as xgb

from config import get_config
from ecg_processor import process_ecg
from urine_processor import process_urine
from symptom_extractor import Symptom, highest_tier, names as symptom_names
from voice_processor import extract_symptoms_detailed

log = logging.getLogger(__name__)
_CFG = get_config()
CFG, ECG_CFG, AUDIO_CFG = _CFG.triage, _CFG.ecg, _CFG.audio

_FEATURES = list(CFG.feature_order)
_booster: Optional[xgb.Booster] = None
_booster_ready: Optional[bool] = None


# --------------------------------------------------------------------------- #
# Model
# --------------------------------------------------------------------------- #
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


def _num(source: Dict[str, Any], key: str, default: float) -> float:
    try:
        value = source.get(key)
        return default if value is None else float(value)
    except (TypeError, ValueError):
        return default


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


def parse_sensor_packet(sensor_packet: Dict[str, Any]) -> Dict[str, Any]:
    """Extract the 6 model features plus the two qualitative signals."""
    audio_path = sensor_packet.get("step_1_audio")
    if audio_path == AUDIO_CFG.record_trigger:
        audio_path = record_live_audio()
    symptoms: List[Symptom] = extract_symptoms_detailed(audio_path) if audio_path else []

    # --- ECG -------------------------------------------------------------- #
    ecg = _section(sensor_packet, "ecg")
    raw_ecg: Sequence[float] = ecg.get("samples") or sensor_packet.get("step_2_ecg") or []
    ecg_hr = _num(ecg, "heart_rate_bpm", float("nan"))

    # --- Pulse oximetry --------------------------------------------------- #
    pox = _section(sensor_packet, "pulse_oximeter")
    if pox:
        spo2 = _num(pox, "spo2_percent", CFG.default_spo2)
        if np.isnan(ecg_hr):
            ecg_hr = _num(pox, "heart_rate_bpm", CFG.default_hr_bpm)
    else:
        spo2 = _num(_section(sensor_packet, "step_4_pulse_oximetry"), "spo2", CFG.default_spo2)
    if np.isnan(ecg_hr):
        ecg_hr = CFG.default_hr_bpm

    # --- Urine colorimeter ------------------------------------------------ #
    urine = _section(sensor_packet, "urine_sensor")
    if urine:
        default_r, default_g, default_b = _CFG.urine.default_rgb
        rgb = [_num(urine, "red", default_r), _num(urine, "green", default_g),
               _num(urine, "blue", default_b)]
    else:
        rgb = sensor_packet.get("urine_rgb") or list(_CFG.urine.default_rgb)

    # --- Blood pressure & temperature ------------------------------------- #
    bp = _section(sensor_packet, "step_3_bp")
    temperature_section = _section(sensor_packet, "temperature")

    return {
        "ecg_hr": ecg_hr,
        "bp_sys": _num(bp, "systolic", CFG.default_bp_sys),
        "bp_dia": _num(bp, "diastolic", CFG.default_bp_dia),
        "spo2": spo2,
        "temperature": _num(temperature_section, "body_temp_c", CFG.default_temp_c)
        if temperature_section
        else float(sensor_packet.get("step_5_ir_temperature", CFG.default_temp_c)),
        "urine_severity": process_urine(rgb),
        "ecg_result": process_ecg(raw_ecg),
        "symptoms": symptoms,
        "symptom_names": symptom_names(symptoms),
        "symptom_tier": highest_tier(symptoms),
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


def _escalate(probs: np.ndarray, symptoms: Sequence[Symptom], ecg_result: str) -> np.ndarray:
    """Rule layer on top of the model. The push towards Red is weighted by the
    most severe symptom reported, so a cough no longer counts like chest pain.
    Operates in place."""
    arrhythmia = ecg_result == ECG_CFG.label_arrhythmia
    if not symptoms and not arrhythmia:
        return probs

    tier_boost = {
        "critical": CFG.red_boost_critical,
        "moderate": CFG.red_boost_moderate,
        "minor": CFG.red_boost_minor,
    }
    boost = tier_boost.get(highest_tier(list(symptoms)) or "", 0.0)
    if arrhythmia:
        boost = max(boost, CFG.arrhythmia_red_boost)
    boost = min(boost, CFG.red_boost_cap)
    if boost <= 0.0:
        return probs

    green = CFG.class_labels.index("Green")
    yellow = CFG.class_labels.index("Yellow")
    red = CFG.class_labels.index("Red")
    probs[red] += boost
    probs[yellow] += CFG.symptom_yellow_boost
    # Green is suppressed proportionally to how hard we escalated.
    probs[green] *= max(CFG.symptom_green_decay, 1.0 - boost / max(CFG.red_boost_cap, 1e-6))
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
        "symptom_list": parsed["symptom_names"],
        "ecg_result": parsed["ecg_result"],
    }
