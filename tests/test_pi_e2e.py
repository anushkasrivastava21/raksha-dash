from fastapi.testclient import TestClient
import pytest

# NOTE: This imports from raspi_port/raspi_api.py which Anirudh is responsible for in Task A1.
# If that file doesn't exist yet, this test will fail to run.
try:
    from raspi_port.raspi_api import app
    client = TestClient(app)
except ModuleNotFoundError:
    app = None
    client = None

FULL_PACKET = {
    "ecg": {"heart_rate_bpm": 72, "samples": [1850,1880,1905,1870,1845,1860,1890,1910,1885,1860,1840,1870,1900,1940,2100,2350,2600,2950,3400,3750]},
    "urine_sensor": {"red": 3300, "green": 3250, "blue": 3400},
    "stethoscope": {"rms": 220, "min": 1500, "max": 2600, "samples": 50},
    "temperature": {"body_temp_c": 36.6},
    "pulse_oximeter": {"heart_rate_bpm": 72, "spo2_percent": 98},
    "voice_keywords": ["fever", "dizzy"],
    "step_3_bp": {"systolic": 120, "diastolic": 80}
}

@pytest.mark.skipif(client is None, reason="raspi_api not implemented yet by Anirudh")
def test_full_packet():
    r = client.post("/run_triage", json=FULL_PACKET)
    assert r.status_code == 200
    body = r.json()
    assert "triage" in body
    assert "confidence" in body
    assert "ecg_result" in body
    assert "symptoms" in body
    assert body["triage"] in ["Green", "Yellow", "Red"]

@pytest.mark.skipif(client is None, reason="raspi_api not implemented yet by Anirudh")
def test_empty_packet():
    r = client.post("/run_triage", json={})
    assert r.status_code == 200  # safe fallbacks must work

@pytest.mark.skipif(client is None, reason="raspi_api not implemented yet by Anirudh")
def test_health():
    r = client.get("/")
    assert r.status_code == 200
