# Raksha — Communication Flow (Mobile App)

Source: Flutter app in `lib/`. The app uses two channels: **BLE** (phone ↔ ESP32 sensor rig) and **HTTP** (phone ↔ backend).

```
 ┌────────────┐  BLE: REQ_* command (write RX)   ┌──────────────┐
 │  Flutter   │ ───────────────────────────────▶ │ ESP32 rig    │
 │  app       │ ◀─────────────────────────────── │ (sensors)    │
 │            │  BLE: chunked SENSOR|json|CRC8   └──────────────┘
 │            │       (notify TX)
 │            │
 │            │  HTTP POST /vitals, /triage      ┌──────────────┐
 │            │ ───────────────────────────────▶ │ Backend      │
 └────────────┘                                  └──────────────┘
```

## 1. Phone ↔ ESP32 (BLE) — `lib/services/ble_service.dart`

### Connect
1. Scan for service UUID `6fa41660-6244-4aa0-aee4-06d9377ad51b` and device name `ESP32_VitalsRig_01` (15 s timeout).
2. Connect; on Android request MTU 512.
3. Discover services and bind two characteristics:
   - **RX** `bf9dace6-017f-4793-abf9-5d117db16e55` — phone **writes** commands.
   - **TX** `41d5a28d-de2a-4ab4-aa6e-31ab8472925c` — ESP32 **notifies** data; the app subscribes.

### Per-test exchange (`lib/screens/telemetry_sync_screen.dart`)
1. User taps a test → `DynamicTestLoaderScreen` opens.
2. Phone writes a UTF-8 command to RX:

   | Test | Command |
   |---|---|
   | SpO2 | `REQ_SPO2` |
   | ECG / HR | `REQ_ECG` |
   | Temperature | `REQ_TEMP` |
   | Urine | `REQ_URINE` |
   | Stethoscope | `REQ_STETH` |
   | Voice | `REQ_VOICE` |

3. ESP32 reads the sensor and replies on TX in chunks.
   - Chunk byte 0 = header: high 4 bits = total chunks, low 4 bits = chunk index.
   - Remaining bytes = payload fragment.
4. App reassembles the chunks into `SENSOR_CODE | {json} | CRC8hex`.
   - CRC-8 (poly `0x07`) is checked over the JSON. A bad CRC or missing chunk drops the packet.
5. The test screen accepts only the expected sensor code (e.g. `SPO2`/`MAX30102`), then:
   - `TriageProvider.updateFromBleJson()` stores the values,
   - `TriageState.markCompleted()` ticks the test,
   - navigates to the dashboard.
6. **Timeout fallback:** if no valid packet arrives within 15 s, baseline demo values are injected (`applySpo2TempData()`, `applyEcgData()`, `applyUrineData()`, `applyStethData()`) and the test is marked complete anyway.

## 2. Phone ↔ Backend (HTTP) — `lib/services/api_service.dart`

After all tests are done, **Execute Triage** builds the payload via `TriageProvider.generateJsonPayload()` and opens `TriageResultScreen`, which saves it:

1. `POST https://raksha-api-71a6.onrender.com/vitals` with:
   `patient_id, timestamp, stethoscope_status, ecg_hr, spo2, temperature, urine_rgb, patient_speech_text`
2. `POST .../triage` with `patient_id, timestamp, triage, confidence`.
3. Each POST has an 8 s timeout. On failure, retry once against `http://127.0.0.1:8000`.
4. If everything fails, the payload is cached in `SharedPreferences` (`unsynced_patients`) and the UI reports "Saved Locally".

`ApiService.pushTriageData()` is a separate path that uses `baseUrl`. With `useLocalServer = true` this resolves to the Raspberry Pi address `http://172.16.46.141:8000`.

## 3. Not wired up

- **No AI inference in the app.** `generateTriageJsonPayload()` returns `RED` if any test is abnormal, else `GREEN`, with hard-coded confidence (0.88 / 0.96). The XGBoost / TFLite / Dart evaluator work in `experiment_MED/` is not imported by `lib/`.
- **`ApiService.mlEngineUrl`** (`https://raksha-sim.onrender.com`) is defined but never called. The Python `triage_engine.analyze_patient()` is only reached by terminal scripts.
- **Dead code:** `RenderApiService.fetchHardwareVitals` has no callers. The Pi URL in `AppConfig.hardwareBaseUrl` is a leftover of the pre-BLE architecture.
- **Demo fallback hides failures:** a sensor timeout is recorded as a completed test with default values.
