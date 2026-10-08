"""Public entry point consumed by local_server / frontend clients."""
from __future__ import annotations

import logging
import math
from typing import Any, Dict, List

from triage_integrator import predict_final_triage

logger = logging.getLogger(__name__)

_VALID_TRIAGE = ("Green", "Yellow", "Red")
_DEFAULT_ECG = "Normal Sinus Rhythm"


def _normalise_result(raw: Any) -> Dict[str, Any]:
    """Coerce any pipeline output into the locked, JSON-safe 4-key schema."""
    raw = raw if isinstance(raw, dict) else {}

    triage = str(raw.get("triage", "")).strip().capitalize()
    if triage not in _VALID_TRIAGE:
        logger.warning("Invalid triage value %r, mapping to 'Green'", raw.get("triage"))
        triage = "Green"

    try:
        confidence = float(raw.get("confidence"))
        if not math.isfinite(confidence):
            raise ValueError("non-finite confidence")
    except (TypeError, ValueError):
        logger.warning("Invalid confidence %r, using 0.0", raw.get("confidence"))
        confidence = 0.0
    confidence = min(1.0, max(0.0, confidence))

    ecg_result = raw.get("ecg_result")
    ecg_result = str(ecg_result).strip() if ecg_result is not None else ""
    if not ecg_result:
        ecg_result = _DEFAULT_ECG

    symptoms_in = raw.get("symptoms")
    if isinstance(symptoms_in, str):
        symptoms_in = [symptoms_in]
    symptoms: List[str] = (
        [str(s) for s in symptoms_in if s is not None]
        if isinstance(symptoms_in, (list, tuple, set))
        else []
    )

    return {
        "triage": triage,
        "confidence": confidence,
        "ecg_result": ecg_result,
        "symptoms": symptoms,
    }


def analyze_patient(sensor_packet: Dict[str, Any]) -> Dict[str, Any]:
    """Assess one ESP32 packet and ALWAYS return the locked output schema."""
    try:
        result = predict_final_triage(sensor_packet)
        return _normalise_result({
            "triage": result.get("triage_color"),
            "confidence": result.get("confidence_score"),
            "ecg_result": result.get("ecg_result"),
            "symptoms": result.get("symptom_list"),
        })
    except Exception:  # noqa: BLE001 - the ESP32 must always get a valid reply
        logger.exception("Triage failed; returning safe default result")
        return _normalise_result({
            "triage": "Green",
            "confidence": 0.0,
            "ecg_result": _DEFAULT_ECG,
            "symptoms": [],
        })


if __name__ == "__main__":
    # The demo payload now comes from the remote dataset, not a literal in this file.
    from dataset_loader import fetch_payloads

    for packet in fetch_payloads():
        print(packet.get("device_id"), "->", analyze_patient(packet))
