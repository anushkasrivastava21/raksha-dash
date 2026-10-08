"""Raksha Pi AI Triage Node: receives one ESP32 packet, runs triage, replies.

Run:  uvicorn raspi_api:app --host 0.0.0.0 --port 8000
"""
from __future__ import annotations

from typing import Any, Dict, List, Optional

from fastapi import FastAPI
from pydantic import BaseModel

try:  # package layout (raspi_port.raspi_api) or flat layout (run from this dir)
    from .triage_engine import analyze_patient
except ImportError:
    from triage_engine import analyze_patient

app = FastAPI(title="Raksha Pi AI Triage Node")


class FullVitalsPacket(BaseModel):
    """Full ESP32 packet. Every field is optional; a plain {} is valid."""

    ecg: Optional[Dict[str, Any]] = None
    urine_sensor: Optional[Dict[str, Any]] = None
    stethoscope: Optional[Dict[str, Any]] = None
    temperature: Optional[Dict[str, Any]] = None
    pulse_oximeter: Optional[Dict[str, Any]] = None
    voice_keywords: Optional[List[str]] = None
    step_3_bp: Optional[Dict[str, Any]] = None


@app.get("/")
def root() -> Dict[str, str]:
    return {"status": "Raksha Pi AI Triage Node is live!"}


@app.get("/ping")
def ping() -> Dict[str, str]:
    return {"api": "ok"}


@app.post("/run_triage")
def run_triage(packet: FullVitalsPacket) -> Dict[str, Any]:
    return analyze_patient(packet.model_dump(exclude_none=True))
