"""Locked triage output schema: analyze_patient must always return 4 typed keys."""
import json

try:
    from raspi_port.triage_engine import analyze_patient
except ImportError:  # flat layout (no raspi_port package)
    from triage_engine import analyze_patient

KEYS = {"triage", "confidence", "ecg_result", "symptoms"}

# Full packet from PRD v2.0 section 4 / Task B1.
FULL_PACKET = {
    "ecg": {
        "heart_rate_bpm": 72,
        "samples": [1850, 1880, 1905, 1870, 1845, 1860, 1890, 1910, 1885, 1860,
                    1840, 1870, 1900, 1940, 2100, 2350, 2600, 2950, 3400, 3750],
    },
    "urine_sensor": {"red": 3300, "green": 3250, "blue": 3400},
    "stethoscope": {"rms": 220, "min": 1500, "max": 2600, "samples": 50},
    "temperature": {"body_temp_c": 36.6},
    "pulse_oximeter": {"heart_rate_bpm": 72, "spo2_percent": 98},
    "voice_keywords": ["fever", "dizzy"],
    "step_3_bp": {"systolic": 120, "diastolic": 80},
}


def _assert_schema(result):
    assert set(result) == KEYS
    assert isinstance(result["triage"], str)
    assert isinstance(result["confidence"], float)
    assert isinstance(result["ecg_result"], str) and result["ecg_result"]
    assert isinstance(result["symptoms"], list)
    assert all(isinstance(s, str) for s in result["symptoms"])


def test_empty_packet():
    result = analyze_patient({})
    _assert_schema(result)
    assert result["triage"] in {"Green", "Yellow", "Red"}


def test_full_packet():
    result = analyze_patient(FULL_PACKET)
    _assert_schema(result)
    assert result["triage"] in {"Green", "Yellow", "Red"}
    assert 0.0 <= result["confidence"] <= 1.0


def test_json_serialisable():
    for packet in ({}, FULL_PACKET):
        result = analyze_patient(packet)
        assert json.loads(json.dumps(result)) == result
