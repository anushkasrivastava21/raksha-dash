# Raksha / SwasthaGram — Phone-Edge Pivot: PRD v2 (Updated)

**Supersedes:** Raksha_Phone_Edge_Pivot_PRD.md. Same architecture, same 24-hour goal — this version reflects what's actually true in `raksha-sim` / `raksha-dash` right now, plus decisions locked since v1.

---

## 0. What changed since v1

**Decisions locked (were open in v1):**
- **Speech engine: Vosk**, not `speech_to_text`. Reason: genuinely-offline is a hard requirement (rural, no-connectivity deployment), and `speech_to_text` is only offline *if* the phone happens to have a pre-downloaded language pack — not guaranteed. Vosk is offline unconditionally.
- **NER: confirmed staying cut.** Current backend (`voice_processor.py`) runs Whisper-tiny + `biomedical-ner-all` (BERT) via Python `transformers` — English-only models, Pi-dependent, no phone/TFLite path exists. Keeping the existing hardcoded keyword list (already in the same file, already used as fallback) as primary is correct, not a downgrade.
- **ECG power source: battery/power-bank, not Pi/USB.** The Pi was previously powering the ESP32 over the same USB cable used for data — removing the Pi removes power too, not just the data link. Feed the power bank into the ESP32's `VIN`/5V pin (not raw `3.3V`) so the onboard LDO regulator filters it; add a bulk cap (100–470µF) + ceramic cap (0.1µF) at the power input for extra noise rejection. This also isolates the circuit from mains ground — do not simultaneously plug the ESP32 into a wall-powered laptop via USB while electrodes are on a person, since that reintroduces a ground path and defeats the isolation.

**Repo-verified status (checked directly, not self-reported):**
- `raksha-dash/pubspec.yaml` has `flutter_blue_plus` + `permission_handler` added — Arnav's BLE work has started.
- `mews_service.dart` and `triage_scaffold.dart` — written, tested (21/21 passing), **but not yet committed to `raksha-dash`**. Push these before Review 1 or the work isn't visible/usable by the team.
- Finding 0 (sync-blocking bug) and Finding 2 (MEWS not wired into triage payload) — both have an agreed fix, **neither is applied in `triage_provider.dart` yet**. Still open, not done.
- No `vosk_flutter` or `tflite_flutter` in `pubspec.yaml` yet — expected, this is Hour 4–8+ scope.

---

## 1. PRD — Shashwat (Firmware / BLE / Power)

**Objective:** ESP32 reads all 5 sensors, exposes the same data contract over BLE, and stays reliably + safely powered now that the Pi (which previously provided both data path and power) is gone.

**Requirements:**
- BLE GATT server, one (or few) characteristic(s), same field names/types as the old USB/JSON schema.
- Respect BLE MTU limits — negotiate larger MTU or chunk the packet.
- Keep CRC/checksum validation — drop corrupted packets.
- **New: power the rig from a battery/power-bank into `VIN`/5V**, not raw `3.3V`, and not from a wall-powered laptop USB while electrodes are on a person (ground-loop shock risk). Add bulk + ceramic caps at the power input for ECG noise rejection.
- Confirm packets readable via a generic BLE scanner (nRF Connect) before handoff to Arnav.

**Non-goals:** No changes to sensor calibration or which sensors are read.

**Acceptance criteria (Hour 4):** A phone/scanner app can connect and read a well-formed packet from the ESP32, powered by battery/power-bank, with electrodes safely isolated from mains ground.

**Dependencies:** None upstream. Arnav is blocked on this.

---

## 2. PRD — Arnav (Flutter App — BLE, Inference, Display)

**Objective:** Full on-device pipeline: BLE → parse → TFLite inference → MEWS → triage → display → cache → sync.

**Requirements (unchanged from v1, confirmed still correct):**
- `flutter_blue_plus` scan/connect/read/notify — **in progress**, package already added.
- Parse BLE payload into structured data.
- `tflite_flutter` for ECG CNN + urine CNN (blocked on Anirudh's `.tflite` exports).
- **Vosk** (`vosk_flutter`) for offline speech-to-text — locked decision, not yet integrated. Bundle a **small** Hindi/English Vosk model (not the full ~1GB model) — you're only spotting fixed keywords, not doing open transcription, so the small model's accuracy is sufficient and keeps app size/load time reasonable.
- Run existing keyword-list symptom extraction on the Vosk transcript.
- Feed ECG + urine + symptom keywords into Anushka's Dart triage rule table.
- Run the ported MEWS check synchronously, before any result displays — impossible to bypass.
- Keep existing offline cache + sync-on-reconnect.

**New — flag before building further:** confirm whether health workers will speak English or a regional language during the actual demo/pilot. The current keyword list is English-only; if patients/workers speak Hindi, English keyword matching against a Hindi Vosk transcript will silently catch nothing. Decide now whether this needs a parallel translated keyword list.

**Acceptance criteria (Hour 4):** BLE connection established, raw bytes visible in-app. **Acceptance criteria (Hour 24):** Full chain demoed live at least twice.

**Dependencies:** Shashwat (BLE), Anirudh (`.tflite` files), Anushka (MEWS Dart port — files exist, need pushing; triage rule table).

---

## 3. PRD — Anirudh (AI Models Only)

**Unchanged from v1.**

**Requirements:** Train/tune ECG CNN + urine CNN; export both as `.tflite` as soon as finalized; finalize XGBoost triage logic and hand off feature thresholds/split points to Anushka.

**Non-goals:** No BLE, Flutter, Whisper, or NER work.

**Acceptance criteria (Hour 4):** Current model versions + accuracy numbers documented. **Acceptance criteria (Hour 24):** Final `.tflite` files to Arnav, final XGBoost logic to Anushka, both by Hour 14–16 ideally.

---

## 4. PRD — Anushka (Backend, Integration Glue, MEWS/Triage Port)

**Objective:** Same as v1, with two concrete completion items now identified.

**Requirements:**
- ✅ `/vitals` schema confirmed via live curl test — HTTP 200, `ai_prediction` key present. No server changes needed.
- ✅ MEWS Dart port written, 21/21 tests passing.
- **⚠️ Action needed: push `mews_service.dart` and `triage_scaffold.dart` to `raksha-dash` at `lib/services/`.** They're not in the repo yet — Arnav can't build against them until they're committed.
- **⚠️ Action needed: apply the two agreed patches to `triage_provider.dart`:**
  1. Finding 0 — stop `syncDataToCloud()` from silently blocking sync on out-of-range vitals (the cases MEWS most needs to catch).
  2. Finding 2 — `generateTriageJsonPayload()` must call `mewsOverride()` and use its `displayColor` (title-case `"Red"/"Yellow"/"Green"`) instead of the current uppercase `hasAnyAbnormal ? "RED" : "GREEN"`.
- Once Anirudh hands off XGBoost logic: build the Dart rule table, test against real model outputs.
- Standby for Arnav's integration questions.

**New finding to track:** backend `ml_engine.py`'s own `/predict` endpoint returns `"triage":"GREEN"` (uppercase) — a *third* casing convention alongside the app's title-case MEWS output and whatever the XGBoost rule table ends up using. Worth deciding one canonical casing across the whole stack before it causes a silent comparison bug somewhere (dashboard, logging, anything that string-matches triage color).

**Acceptance criteria (Hour 4):** MEWS Dart port written, tested, **and committed to the repo**. XGBoost port started (blocked on Anirudh).

---

## 5. PRD — Archie (Deck + Absorbed QA/Logistics)

**Unchanged from v1**, plus one addition:

**Add to risk slide:** power-source change (Pi → battery) as a resolved risk, framed positively — battery power is actually *better* for ECG signal quality and patient electrical safety than the previous USB-through-Pi setup, not just a workaround.

**Requirements:** architecture slide (Pi removed, BLE + battery power shown), risk slide (Pi-unavailable resolved, speech-offline reliability, XGBoost→Dart fidelity, casing-convention risk, power-source change), Q&A prep for "why no Pi," shared checklist, later fresh-user QA + MEWS-display check.

**Acceptance criteria (Hour 4):** Updated slides ready.

---

## 6. Timeline — Hour 0–4 status snapshot (verified against repos)

| Who | Task | Status |
|---|---|---|
| Shashwat | BLE GATT + battery power + noise filtering | In progress — power source now resolved |
| Arnav | `flutter_blue_plus` scan/connect | Dependency added, integration in progress |
| Anirudh | Report model status/accuracy | Not yet confirmed with team |
| Anushka | Confirm schema (✅ done) + MEWS port (✅ written, ⚠️ not pushed) | Files need committing + patches need applying |
| Archie | Update slides | Status unconfirmed |
| Speech engine decision | Vosk | ✅ Locked |

**Immediate next actions, in order:**
1. Anushka: push `mews_service.dart` + `triage_scaffold.dart` to `raksha-dash/lib/services/`; apply both `triage_provider.dart` patches; commit.
2. Shashwat: confirm battery-powered BLE packet readable via scanner app.
3. Arnav: confirm raw bytes visible in-app from Shashwat's characteristic.
4. Archie: confirm slide status.
5. Anirudh: report current model numbers to the group.

Hour 4–24 timeline (parsing/inference, core pipeline, hardening, rehearsal, freeze) is unchanged from v1 — no changes needed there yet.

---

## 7. Open risks (updated)

1. **Speech offline reliability** — now Vosk-specific: confirm small-model accuracy is acceptable for keyword-spotting on the actual demo device before Hour 18.
2. **Hindi/regional-language keyword gap** — new, not in v1. English-only keyword list may catch nothing if patients speak Hindi. Needs a decision.
3. **XGBoost→Dart fidelity** — unchanged from v1.
4. **Reduced QA depth** — unchanged from v1.
5. **BLE reliability** — unchanged from v1.
6. **Triage-color casing inconsistency across stack** — new. Backend uppercase, app title-case, no single canonical convention yet decided.
7. **Repo/reality gap** — new, and the reason this PRD exists: verify status by checking the actual repo, not by self-report, before every checkpoint. Two "done" items (Finding 0, Finding 2) were reported complete but aren't in the repo as of this writing.
