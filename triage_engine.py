"""Public entry point consumed by local_server / frontend clients."""
from __future__ import annotations

from typing import Any, Dict

from triage_integrator import predict_final_triage


def analyze_patient(sensor_packet: Dict[str, Any]) -> Dict[str, Any]:
    """Assess one ESP32 packet and return the locked output schema."""
    result = predict_final_triage(sensor_packet)
    return {
        "triage": result["triage_color"],
        "confidence": result["confidence_score"],
        "ecg_result": result["ecg_result"],
        "symptoms": result["symptom_list"],
    }


if __name__ == "__main__":
    # The demo payload now comes from the remote dataset, not a literal in this file.
    from dataset_loader import fetch_payloads

    for packet in fetch_payloads():
        print(packet.get("device_id"), "->", analyze_patient(packet))
