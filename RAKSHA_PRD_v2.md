# RAKSHA — Team PRD & Task Assignment
### Architecture: ESP32-Hub | Version 2.0 | October 2026

---

## 1. THE LOCKED ARCHITECTURE

> This is the single source of truth. Every line of code must follow this.

```
Phone App (Flutter)
   │
   │  Step 1 — User taps a sensor card
   │  BLE Write → "REQ_TEMP" / "REQ_ECG" / "REQ_SPO2" / "REQ_URINE" / "REQ_STETH"
   ▼
ESP32
   │  Step 2 — ESP32 activates the sensor
   │  Step 3 — Sensor records reading, reports back to ESP32
   │  Step 4 — ESP32 sends framed packet back over BLE
   │  BLE Notify → "TEMP|{body_temp_c:36.7}|CRC"
   ▼
Phone App
   │  (User sees reading displayed on the card)
   │  (Repeat Steps 1–4 for all 5 sensors)
   │
   │  Step 5 — User speaks into phone mic
   │  Step 6 — On-device Vosk runs → produces transcript/keywords
   │  Step 7 — Phone sends voice keywords directly to ESP32 over BLE
   │  BLE Write → "VOICE_KW:fever,chest pain,dizzy"
   ▼
ESP32
   │  Step 8 — ESP32 stores voice keywords (already has all 5 sensor readings)
   │  Step 9 — ESP32 assembles full JSON packet (sensors + voice)
   │  WiFi HTTP POST → http://<PI_IP>:8000/run_triage
   ▼
Raspberry Pi
   │  Step 10 — Pi receives full packet, runs XGBoost AI triage model
   │  Step 11 — Pi sends result back as HTTP response to ESP32
   │  HTTP 200 → {"triage":"Red","confidence":0.87,"symptoms":["fever"]}
   ▼
ESP32
   │  Step 12 — ESP32 forwards result to Phone over BLE
   │  BLE Notify → "TRIAGE|{triage:Red,...}|CRC"
   ▼
Phone App
   (Displays triage result screen)
```

### Key Rules (Non-Negotiable)
- **Phone ↔ ESP32 = BLE only** (bidirectional)
- **ESP32 ↔ Pi = WiFi HTTP** (ESP32 POSTs, Pi responds)
- **Pi NEVER talks to the phone** — not even indirectly
- **Vosk runs on the phone** — only extracted keywords are sent to ESP32
- **ESP32 is the hub** — holds all data, aggregates, sends to Pi
- **Pi is the silent AI node** — receives one POST, runs AI, returns result

---

## 2. CURRENT STATE — What Is Done vs What Needs Work

### ✅ DONE — Do Not Touch

| File | What It Does | Status |
|---|---|---|
| `firmware latest.cpp` | ESP32 handles all 5 sensors (REQ_* commands, state machine, CRC framing) | ✅ Complete |
| `raspi_port/triage_integrator.py` | Full XGBoost triage pipeline | ✅ Complete |
| `raspi_port/triage_engine.py` | `analyze_patient()` wrapper | ✅ Complete |
| `raspi_port/ecg_processor.py` | ECG CNN arrhythmia detection | ✅ Needs one fix (see A4) |
| `raspi_port/urine_processor.py` | Urine color classifier | ✅ Complete |
| `raspi_port/voice_processor.py` | Symptom keyword extractor (NLP) | ✅ Complete |
| `raspi_port/hardware_reader.py` | Serial reader + `send_raw_command()` | ✅ Complete |
| `raspi_port/firmware_additions.cpp` | All ESP32 additions: WiFi, VOICE_KW, SEND_TRIAGE, sendTriageToPi(), globals | ✅ Written — needs MERGING |
| `raspi_port/setup_pi.sh` | Pi environment setup | ✅ Complete |
| `raspi_port/start_pi.sh` | Pi server start | ✅ Complete |
| `main.py` (Render) | Cloud backend | ✅ Live |
| `simulator.py` | Cloud backend simulator | ✅ Complete |

### ❌ WRONG — Needs Fixing (Architecture Mismatch)

| File | Problem | Fix |
|---|---|---|
| `raspi_port/raspi_api.py` | Has `/read/*` and `/voice_keywords` endpoints. Pi should NOT handle sensor reads or voice relay. Phone talks to ESP32 directly. These endpoints are dead code. | **Anirudh** strips these out |
| `raspi_port/firmware_additions.cpp` comments | Some comments still say "phone talks to Pi" — wrong. Code is correct, comments need updating. | **Archie** fixes comments |

### 🔧 NEW — Needs Building

| Gap | Who |
|---|---|
| ESP32 BLE stack: receive BLE commands from phone | **Shashwat** |
| ESP32 BLE stack: send framed packets back to phone | **Shashwat** |
| Merge `firmware_additions.cpp` into `firmware latest.cpp` | **Shashwat** |
| Strip `raspi_api.py` to only `POST /run_triage` | **Anirudh** |
| Fix ECG model input shape (20 samples vs 160) | **Anirudh** |
| Safe defaults when sensors missing in triage | **Anirudh** |
| Lock triage output JSON schema | **Anirudh** |
| Flutter: BLE connection + sensor trigger per card | **You** |
| Flutter: Parse BLE sensor readings, display on cards | **You** |
| Flutter: Vosk integration + send keywords to ESP32 via BLE | **You** |
| Flutter: Parse BLE TRIAGE packet, display result | **You** |
| Integration test: ESP32 → Pi → triage | **Anushka** |
| Pi error handling (malformed POST, timeout) | **Anushka** |
| Fix wrong comments in firmware_additions.cpp | **Archie** |
| README update | **Archie** |
| Wiring table | **Archie** |

---

## 3. INDIVIDUAL TASK CARDS

---

### 🧠 ANIRUDH — AI & Raspberry Pi Backend

---

#### Task A1 — Strip `raspi_api.py` to Only `/run_triage`
**File:** `raspi_port/raspi_api.py`

Delete entirely:
- `GET /read/temperature`, `/read/urine`, `/read/ecg`, `/read/spo2`, `/read/steth`
- `POST /voice_keywords`
- `GET /triage_result`
- The `hardware_reader` import and `esp32 = ESP32Reader(...)` instance
- `VoiceKeywordsRequest` model
- `startup_event` / `shutdown_event` (no serial port to manage)
- `_latest_triage` global and `_triage_lock` (no polling needed — ESP32 gets result synchronously)

Keep only:
- `POST /run_triage` — receives full packet from ESP32, runs AI, returns triage JSON
- `GET /` — health check, returns `{"status": "Raksha Pi AI Triage Node is live!"}`
- `GET /ping` — just returns `{"api": "ok"}` (remove ESP32 serial check)
- `FullVitalsPacket` Pydantic model

**Acceptance:** File is ~60 lines. No serial, no hardware, no `/read/*` routes.

---

#### Task A2 — Harden `triage_integrator.py` (Safe Fallbacks)
**File:** `raspi_port/triage_integrator.py`

If any sensor key is missing from the packet, use these safe defaults:
- Missing ECG → HR = 75, samples = `[0]*20`
- Missing SpO2 → 98.0%
- Missing temperature → 37.0°C
- Missing urine → RGB = (255, 234, 112)
- Missing stethoscope → skip it
- Missing voice keywords → empty symptom list

Log a warning (`logger.warning(...)`) for each missing sensor.

**Acceptance:** `POST /run_triage` with body `{}` returns valid triage JSON, not HTTP 500.

---

#### Task A3 — Lock Triage Output Schema
**File:** `raspi_port/triage_engine.py`

Guarantee this **exact** structure always returns — ESP32 parses it with ArduinoJson:
```json
{
  "triage": "Red",
  "confidence": 0.87,
  "ecg_result": "Normal Sinus Rhythm",
  "symptoms": ["fever", "chest pain"]
}
```

Rules:
- `triage` → always one of `"Green"`, `"Yellow"`, `"Red"` (capitalised)
- `confidence` → always float 0.0–1.0
- `ecg_result` → always string, never null
- `symptoms` → always list, never null (empty list `[]` if none)

Write `tests/test_triage_schema.py`:
- Test 1: `analyze_patient({})` — all 4 keys present
- Test 2: `analyze_patient(full_packet)` — all 4 keys present, triage in valid set

**Acceptance:** `pytest tests/test_triage_schema.py` passes green.

---

#### Task A4 — Fix ECG Model Input Shape
**File:** `raspi_port/ecg_processor.py`

The CNN's FC layer expects 160 samples but ESP32 sends 20. Add padding:
```python
def process_ecg(raw_ecg: list, fs=360) -> str:
    if not raw_ecg or len(raw_ecg) < 10:
        return "Normal Sinus Rhythm"
    # Pad to 160 samples
    if len(raw_ecg) < 160:
        raw_ecg = list(raw_ecg) + [0] * (160 - len(raw_ecg))
    # ... rest of existing code unchanged
```

**Acceptance:** `process_ecg([1850, 1880, 1905, 1870, 1845, 1860, 1890, 1910, 1885, 1860, 1840, 1870, 1900, 1940, 2100, 2350, 2600, 2950, 3400, 3750])` returns a string without throwing any error.

---

### 👩‍💻 ANUSHKA — Integration & Reliability

---

#### Task B1 — End-to-End Pi Integration Test
**File:** Create `tests/test_pi_e2e.py`

Simulate what the ESP32 does:
```python
from fastapi.testclient import TestClient
from raspi_port.raspi_api import app

client = TestClient(app)

FULL_PACKET = {
    "ecg": {"heart_rate_bpm": 72, "samples": [1850,1880,1905,1870,1845,1860,1890,1910,1885,1860,1840,1870,1900,1940,2100,2350,2600,2950,3400,3750]},
    "urine_sensor": {"red": 3300, "green": 3250, "blue": 3400},
    "stethoscope": {"rms": 220, "min": 1500, "max": 2600, "samples": 50},
    "temperature": {"body_temp_c": 36.6},
    "pulse_oximeter": {"heart_rate_bpm": 72, "spo2_percent": 98},
    "voice_keywords": ["fever", "dizzy"],
    "step_3_bp": {"systolic": 120, "diastolic": 80}
}

def test_full_packet():
    r = client.post("/run_triage", json=FULL_PACKET)
    assert r.status_code == 200
    body = r.json()
    assert "triage" in body
    assert "confidence" in body
    assert "ecg_result" in body
    assert "symptoms" in body
    assert body["triage"] in ["Green", "Yellow", "Red"]

def test_empty_packet():
    r = client.post("/run_triage", json={})
    assert r.status_code == 200  # safe fallbacks must work

def test_health():
    r = client.get("/")
    assert r.status_code == 200
```

**Acceptance:** `pytest tests/test_pi_e2e.py -v` — all 3 tests pass.

---

#### Task B2 — Pi Error Handling: Malformed ESP32 POST
**File:** `raspi_port/raspi_api.py`

Wrap `run_triage()` with structured error responses:
- If Pydantic raises `ValidationError` (bad field types) → HTTP 422 + `{"error": "invalid_packet", "detail": "..."}`
- If triage engine raises an exception → HTTP 500 + `{"error": "triage_failed", "detail": "..."}`
- Always log the full traceback to console for debugging

**Acceptance:** `POST /run_triage` with `{"ecg": "not_a_dict"}` returns HTTP 422, not a server crash.

---

#### Task B3 — Pi Triage Timeout
**File:** `raspi_port/raspi_api.py`

Wrap `analyze_patient()` with a 12-second timeout using `concurrent.futures`:
```python
import concurrent.futures
with concurrent.futures.ThreadPoolExecutor(max_workers=1) as ex:
    future = ex.submit(analyze_patient, sensor_packet)
    try:
        result = future.result(timeout=12)
    except concurrent.futures.TimeoutError:
        raise HTTPException(status_code=504, detail="Triage timeout")
```

**Acceptance:** A simulated 15-second hang returns HTTP 504 within ~13 seconds.

---

### 👨‍💻 SHASHWAT — ESP32 Firmware (Hardware)

> Most critical work for the demo.

---

#### Task C1 — Merge `firmware_additions.cpp` into `firmware latest.cpp`

Follow the section markers in `raspi_port/firmware_additions.cpp` in order:

**1. Add at top of file (after existing #include lines):**
```cpp
#include <WiFi.h>
#include <HTTPClient.h>
#include <ArduinoJson.h>   // Library Manager: "ArduinoJson" by Benoit Blanchon v7.x
```

**2. Add near the #define block:**
```cpp
const char* WIFI_SSID     = "YOUR_SSID";
const char* WIFI_PASSWORD = "YOUR_PASSWORD";
const char* PI_BASE_URL   = "http://192.168.X.X:8000";  // actual Pi LAN IP
```

**3. Add globals** (copy Section B from firmware_additions.cpp)

**4. Add `connectWiFi()` function** (copy Section C). Call at END of `setup()`.

**5. Add `sendTriageToPi()` function** (copy Section F). Add BEFORE `loop()`.

**6. In `handleIncomingCommand()`, add before final `else { Unknown command }`:**
```cpp
else if (cmd.startsWith("VOICE_KW:")) {
    String kw = cmd.substring(9);
    kw.toCharArray(g_voiceKeywords, sizeof(g_voiceKeywords));
    Serial.println("[VOICE] Stored: " + String(g_voiceKeywords));
}
else if (cmd == "SEND_TRIAGE") {
    sendTriageToPi();
}
```

**7. Store readings** after each `sendPacket()` in each step function:
- `stepTempSequence()` → `g_tempC = (float)tempC; g_tempReady = true;`
- `stepUrineSequence()` → `g_urineR = r; g_urineG = g; g_urineB = b; g_urineReady = true;`
- `stepEcgSequence()` → `g_ecgHR = bpm; memcpy(g_ecgSamples, ecgSamples, sizeof(ecgSamples)); g_ecgReady = true;`
- `stepSpo2Sequence()` case 2 → `g_spo2Hr = (int)heartRateValue; g_spo2Pct = (float)spo2Value; g_spo2Ready = true;`
- `stepStethSequence()` → `g_stethRms = rms; g_stethMin = minVal; g_stethMax = maxVal; g_stethReady = true;`

**Acceptance:** Compiles, boots, Serial shows `[WiFi] Connected!`

---

#### Task C2 — Add BLE Stack (Phone ↔ ESP32)
**File:** `firmware latest.cpp`

Use Nordic UART Service (NUS) UUIDs:
- Service: `6E400001-B5A3-F393-E0A9-E50E24DCCA9E`
- RX Char (phone writes): `6E400002-B5A3-F393-E0A9-E50E24DCCA9E`
- TX Char (ESP32 notifies): `6E400003-B5A3-F393-E0A9-E50E24DCCA9E`

**Add at top:**
```cpp
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
```

**When BLE RX receives data:**
- Extract the string
- Call the EXISTING `handleIncomingCommand(cmd)` — do NOT duplicate logic

**When `sendPacket()` is called (for any sensor):**
- ALSO notify the BLE TX characteristic with the same `fullPacket` string
- Existing `Serial.println(fullPacket)` stays for USB debug

**Add to `setup()`:**
```cpp
BLEDevice::init("Raksha-ESP32");
// ... full BLE setup
```

**Important:** Keep `serviceSerialInput()` in `loop()` for USB Serial debug. BLE and Serial must both work simultaneously.

**Acceptance:**
- Phone BLE scanner discovers "Raksha-ESP32"
- Write `"PING\n"` over BLE → receive `"PONG"` notify

---

#### Task C3 — Hardware Test: Full Flow via Serial Monitor
Without any phone, using just Serial monitor:
1. `REQ_TEMP` → `TEMP|{body_temp_c:36.7}|CRC` + `g_tempReady = true` logged
2. `REQ_ECG` → `ECG|{...}|CRC` + `g_ecgReady = true`
3. `REQ_SPO2` → `SPO2|{...}|CRC` + `g_spo2Ready = true`
4. `REQ_URINE` → `URINE|{...}|CRC` + `g_urineReady = true`
5. `REQ_STETH` → `STETH|{...}|CRC` + `g_stethReady = true`
6. `VOICE_KW:fever,dizzy` → `[VOICE] Stored: fever,dizzy`
7. `SEND_TRIAGE` → `[TRIAGE] POSTing to Pi:...` then `TRIAGE|{...}|CRC`

**Acceptance:** All 7 steps confirmed in Serial monitor screenshot with Pi running.

---

### 👩‍💻 ARCHIE — Docs & Wiring (Light Work)

---

#### Task D1 — Fix Wrong Comments in `firmware_additions.cpp`
**File:** `raspi_port/firmware_additions.cpp`

Find and fix every comment that says phone talks to Pi. Specifically:

Line ~10: `// Voice keywords forwarded from mobile via Pi`
→ Fix to: `// Voice keywords received directly from Phone over BLE`

The MOBILE SIDE section at the bottom (lines ~283–303):
Replace the entire section with:
```
MOBILE SIDE — What the Flutter app does
========================================
1. Sensor reading (per card tap):
   BLE Write → "REQ_TEMP\n" (or ECG, SPO2, URINE, STETH)
   BLE Notify ← "TEMP|{body_temp_c:36.7}|CRC"
   → Display reading on the card.

2. Voice (after Vosk runs on phone):
   BLE Write → "VOICE_KW:fever,chest pain\n"
   No reply — ESP32 stores internally.

3. Triage trigger (after all 5 readings + voice done):
   BLE Write → "SEND_TRIAGE\n"
   BLE Notify ← "TRIAGE|{triage:Red,confidence:0.87,...}|CRC"
   → Navigate to triage result screen.
```

---

#### Task D2 — Update `README.md`
**File:** `README.md`

Add section **"Architecture v2.0 (ESP32-Hub)"** with:
- Flow diagram (copy from Section 1 of this PRD)
- Pi API endpoints (only valid ones):

| Method | Endpoint | Called By | Description |
|---|---|---|---|
| GET | `/` | Anyone | Health check |
| POST | `/run_triage` | ESP32 (WiFi) | Full vitals → returns AI triage |
| GET | `/ping` | Debugging | Pi alive check |

- BLE UUIDs used by ESP32 (from Task C2)
- Pi setup: `cd raspi_port && ./setup_pi.sh && ./start_pi.sh`

---

#### Task D3 — Wiring Table
**File:** Create `raspi_port/WIRING.md`

| Sensor | Signal | ESP32 GPIO | Direction | Notes |
|---|---|---|---|---|
| MLX90614 (temp) | SDA | 21 | I2C | Shared with MAX30102 |
| MLX90614 (temp) | SCL | 22 | I2C | Shared with MAX30102 |
| MAX30102 (SpO2) | SDA | 21 | I2C | Shared with MLX90614 |
| MAX30102 (SpO2) | SCL | 22 | I2C | Shared with MAX30102 |
| MAX30102 (SpO2) | INT | 16 | Input | Interrupt pin |
| MAX4466 (steth) | OUT | 35 | ADC Input | ADC1_CH7, input-only |
| AD8232 (ECG) | OUTPUT | 34 | ADC Input | ADC1_CH6, input-only |
| AD8232 (ECG) | LO+ | 32 | Input | Leads-off detect |
| AD8232 (ECG) | LO- | 33 | Input | Leads-off detect |
| TCS3200 (urine) | S0 | 13 | Output | Frequency scaling |
| TCS3200 (urine) | S1 | 17 | Output | Frequency scaling |
| TCS3200 (urine) | S2 | 18 | Output | Color filter select |
| TCS3200 (urine) | S3 | 19 | Output | Color filter select |
| TCS3200 (urine) | OUT | 23 | Input | Frequency output |

Cross-check each row against physical hardware, mark any discrepancies.

---

### 👨‍💻 YOU (Project Owner) — Flutter Mobile App

---

#### Task E1 — BLE Connection & Discovery
- Scan for ESP32 by service UUID `6E400001-B5A3-F393-E0A9-E50E24DCCA9E`
- Connect, subscribe to TX (Notify) characteristic
- Show BLE connection status indicator (green = connected, red = disconnected)
- Auto-reconnect on disconnect
- **Package:** `flutter_blue_plus`

---

#### Task E2 — Sensor Card → BLE → Display Reading
For each of the 5 cards when user taps "Read":
1. Write command to RX characteristic (with `\n`):
   - Temperature → `"REQ_TEMP\n"`
   - ECG → `"REQ_ECG\n"`
   - SpO2 → `"REQ_SPO2\n"`
   - Urine → `"REQ_URINE\n"`
   - Stethoscope → `"REQ_STETH\n"`
2. Listen on TX Notify for response
3. Split on `|`, parse middle JSON
4. Display value on card

**Parse these responses:**
```
TEMP|{"body_temp_c":36.7}|CRC       → "36.7 °C"
ECG|{"heart_rate_bpm":78,...}|CRC   → "78 BPM"
SPO2|{"spo2_percent":98,...}|CRC    → "98%"
URINE|{"red":3300,"green":...}|CRC  → color swatch
STETH|{"rms":220,...}|CRC           → "RMS: 220"
```

---

#### Task E3 — Vosk + Voice → BLE Keywords
1. Run on-device Vosk → get transcript string
2. Match transcript against your keyword list (port English keywords from `voice_processor.py` to Dart)
3. Build command: `"VOICE_KW:fever,dizzy\n"` (CSV, no spaces after commas)
4. Write to BLE RX
5. No reply expected

---

#### Task E4 — Trigger Triage + Display Result
1. After all 5 readings confirmed + voice done → write `"SEND_TRIAGE\n"` to BLE RX
2. Listen on TX Notify for packet starting with `"TRIAGE|"`
3. Split on `|`, decode middle JSON
4. Navigate to triage result screen showing:
   - Full-screen color background (🟢 Green / 🟡 Yellow / 🔴 Red)
   - Confidence percentage
   - Symptoms list
   - ECG result

**Expected BLE packet:**
```
TRIAGE|{"triage":"Red","confidence":0.87,"ecg_result":"Normal Sinus Rhythm","symptoms":["fever","dizzy"]}|CRC
```

---

## 4. API CONTRACT — The Only Pi Endpoint That Matters

### `POST /run_triage`
**Called by:** ESP32 via WiFi HTTP POST

**Request:**
```json
{
  "ecg": {"heart_rate_bpm": 78, "samples": [1850,1880,...]},
  "urine_sensor": {"red": 3300, "green": 3250, "blue": 3400},
  "stethoscope": {"rms": 220, "min": 1500, "max": 2600, "samples": 50},
  "temperature": {"body_temp_c": 36.6},
  "pulse_oximeter": {"heart_rate_bpm": 72, "spo2_percent": 98.0},
  "voice_keywords": ["fever", "chest pain"],
  "step_3_bp": {"systolic": 120, "diastolic": 80}
}
```

**Response (always this exact shape):**
```json
{
  "triage": "Red",
  "confidence": 0.87,
  "ecg_result": "Normal Sinus Rhythm",
  "symptoms": ["fever", "chest pain"]
}
```

---

## 5. BLE PROTOCOL REFERENCE

### Phone → ESP32 (Write to RX)

| Command | Description | Response? |
|---|---|---|
| `REQ_TEMP\n` | Read temperature | Yes — `TEMP\|{...}\|CRC` |
| `REQ_ECG\n` | Read ECG | Yes — `ECG\|{...}\|CRC` |
| `REQ_SPO2\n` | Read SpO2 | Yes — `SPO2\|{...}\|CRC` |
| `REQ_URINE\n` | Read urine color | Yes — `URINE\|{...}\|CRC` |
| `REQ_STETH\n` | Read stethoscope | Yes — `STETH\|{...}\|CRC` |
| `VOICE_KW:kw1,kw2\n` | Send Vosk keywords | No |
| `SEND_TRIAGE\n` | Trigger Pi AI | Yes — `TRIAGE\|{...}\|CRC` |
| `PING\n` | Liveness | Yes — `PONG` |

### ESP32 → Phone (Notify on TX)
All responses: `<CODE>|<JSON>|<CRC8_hex>\n`

---

## 6. PRIORITY ORDER

```
🔴 CRITICAL (demo breaks without these):
  Shashwat C1 — Merge firmware additions
  Shashwat C2 — BLE stack on ESP32
  Anirudh  A1 — Strip raspi_api.py to /run_triage only
  Anirudh  A2 — Safe fallbacks in triage
  You      E1 — BLE connection in Flutter
  You      E2 — Sensor card → BLE → display
  You      E4 — Triage trigger + result display

🟡 HIGH (full flow):
  Anirudh  A3 — Lock output schema + pytest
  Anirudh  A4 — Fix ECG model shape
  You      E3 — Vosk → BLE keywords
  Shashwat C3 — End-to-end serial test
  Anushka  B1 — E2E integration test

🟢 MEDIUM (robustness):
  Anushka  B2 — Malformed POST handling
  Anushka  B3 — Pi timeout handling

⚪ LOW (polish):
  Archie   D1 — Fix wrong comments
  Archie   D2 — README update
  Archie   D3 — Wiring table
```

---

## 7. BRANCH RULES
- **Working branch:** `feature/esp32-hub-architecture`
- **Main is frozen** — no direct pushes
- Each person: `feature/esp32-hub-architecture/<name>`
- PR → `feature/esp32-hub-architecture` → owner reviews + merges
