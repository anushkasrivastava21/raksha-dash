import sys
import os
import concurrent.futures
import traceback
import logging
from fastapi import FastAPI, HTTPException, Request
from pydantic import BaseModel, Field
from fastapi.responses import JSONResponse
from fastapi.exceptions import RequestValidationError
from typing import Optional, List, Dict, Any

# Ensure we can import from the root directory where triage_engine lives
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from triage_engine import analyze_patient

app = FastAPI()
logger = logging.getLogger("uvicorn.error")

class FullVitalsPacket(BaseModel):
    ecg: Optional[Dict[str, Any]] = None
    urine_sensor: Optional[Dict[str, Any]] = None
    stethoscope: Optional[Dict[str, Any]] = None
    temperature: Optional[Dict[str, Any]] = None
    pulse_oximeter: Optional[Dict[str, Any]] = None
    voice_keywords: Optional[List[str]] = None
    step_3_bp: Optional[Dict[str, Any]] = None

# TASK B2: Malformed ESP32 POST (Pydantic ValidationError)
@app.exception_handler(RequestValidationError)
async def validation_exception_handler(request: Request, exc: RequestValidationError):
    return JSONResponse(
        status_code=422,
        content={"error": "invalid_packet", "detail": str(exc.errors())}
    )

@app.post("/run_triage")
def run_triage(packet: FullVitalsPacket):
    try:
        # Convert Pydantic model to dictionary, stripping None values so 
        # Anirudh's safe fallbacks can kick in for missing keys.
        sensor_packet = {k: v for k, v in packet.model_dump().items() if v is not None}
        
        # TASK B3: Pi Triage Timeout (12 seconds)
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as ex:
            future = ex.submit(analyze_patient, sensor_packet)
            try:
                result = future.result(timeout=12)
                return result
            except concurrent.futures.TimeoutError:
                raise HTTPException(status_code=504, detail="Triage timeout")
                
    except HTTPException:
        raise
    except Exception as e:
        # TASK B2: Pi Error Handling (Internal crash)
        logger.error("Triage engine crashed:")
        logger.error(traceback.format_exc())
        return JSONResponse(
            status_code=500,
            content={"error": "triage_failed", "detail": str(e)}
        )

@app.get("/")
def health_check():
    return {"status": "Raksha Pi AI Triage Node is live!"}

@app.get("/ping")
def ping():
    return {"api": "ok"}
