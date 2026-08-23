import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/vital_test_type.dart';
import 'pi_service.dart';
import 'render_service.dart';

/// Central API Hub for all Raspberry Pi & ESP hardware communication and AI triage.
class RaspiApiService {
  static final PiService _piService = PiService();
  static final RenderService _renderService = RenderService();

  /// Wakes RasPi + ESP from sleep and initiates a new patient session.
  static Future<bool> initSession({String? patientId}) async {
    debugPrint('🔌 [RaspiApiService] Initializing hardware session (RasPi + ESP)...');
    try {
      final res = await _piService.initSession(patientId: patientId);
      debugPrint('🔌 [RaspiApiService] Session init result: ${res.success}');
      return res.success;
    } catch (e) {
      debugPrint('❌ [RaspiApiService] Error during initSession: $e');
      return false;
    }
  }

  /// Triggers a specific test's hardware handshake on the Raspberry Pi / ESP.
  static Future<TriggerResult> triggerTest(VitalTestType type) async {
    debugPrint('🚀 [RaspiApiService] Triggering hardware test for: $type');
    try {
      switch (type) {
        case VitalTestType.spo2:
          return await _piService.triggerSpo2();
        case VitalTestType.hr:
          return await _piService.triggerEcg();
        case VitalTestType.temp:
          return await _piService.triggerTemp();
        case VitalTestType.urine:
          return await _piService.triggerUrine();
        case VitalTestType.stethoscope:
          return await _piService.triggerStethoscope();
        case VitalTestType.voice:
          return await _piService.triggerStethoscope();
      }
    } catch (e) {
      debugPrint('❌ [RaspiApiService] Error triggering test $type: $e');
      return const TriggerResult(success: false);
    }
  }

  /// Commands the Pi to finalize sensor aggregation and returns the final AI triage result.
  static Future<VitalsModel?> getTriageResult({String? patientId}) async {
    debugPrint('🧠 [RaspiApiService] Executing AI triage calculation on RasPi/Cloud...');
    try {
      // 1. Tell Pi to finalize local triage aggregation
      await _piService.finalizeTriage(patientId: patientId);

      // 2. Fetch computed AI triage payload from cloud/Pi
      final vitals = await _renderService.fetchFinalTriageData(patientId: patientId);
      if (vitals != null) {
        debugPrint('✅ [RaspiApiService] AI Triage computation received: ${vitals.triage} (${vitals.confidence * 100}%)');
        return vitals;
      }

      // ── DEMO_FALLBACK ───────────────────────────────────────────────────
      // If both finalizeTriage and fetchFinalTriageData fail (Pi endpoints
      // don't exist yet, or backend unreachable), return a realistic demo
      // VitalsModel so the triage result screen is demoable.
      // Remove this fallback once real /finalize_triage and GET /patients
      // return live data reliably.
      // ─────────────────────────────────────────────────────────────────────
      debugPrint('⚠️ [RaspiApiService] Live triage fetch failed. Using DEMO_FALLBACK VitalsModel.');
      return VitalsModel(
        patientId: patientId ?? 'PT-DEMO-${DateTime.now().millisecondsSinceEpoch.toString().substring(8)}',
        timestamp: DateTime.now().toIso8601String(),
        stethoscopeStatus: 'clean',
        ecgHr: 76.0,
        spo2: 97.0,
        temperature: 37.1,
        urineRgb: [255.0, 255.0, 0.0],
        patientSpeechText: 'Demo: No live sensor data available.',
        triage: 'GREEN',
        confidence: 0.94,
      );
    } catch (e) {
      debugPrint('❌ [RaspiApiService] Error getting triage result: $e');
      // DEMO_FALLBACK on exception — same realistic defaults
      return VitalsModel(
        patientId: patientId ?? 'PT-DEMO-ERR',
        timestamp: DateTime.now().toIso8601String(),
        stethoscopeStatus: 'clean',
        ecgHr: 76.0,
        spo2: 97.0,
        temperature: 37.1,
        urineRgb: [255.0, 255.0, 0.0],
        patientSpeechText: 'Demo: Backend unreachable.',
        triage: 'GREEN',
        confidence: 0.94,
      );
    }
  }
}
