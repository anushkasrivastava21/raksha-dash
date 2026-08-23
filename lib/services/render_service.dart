import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/vitals_model.dart';

export '../models/vitals_model.dart';

/// Cloud fetcher service — fetches the latest triage result for a patient
/// from the Render cloud backend using GET /patients.
class RenderService {
  /// Active production backend (matches ApiService._productionUrl).
  static const String defaultCloudUrl = 'https://raksha-api-7ie6.onrender.com';
  static const Duration requestTimeout = Duration(seconds: 35);

  final String cloudUrl;
  final http.Client _client;

  RenderService({
    this.cloudUrl = defaultCloudUrl,
    http.Client? client,
  }) : _client = client ?? http.Client();

  /// Fetches the latest triage payload from GET /patients and returns the
  /// most recent triage row for the given [patientId] as a [VitalsModel].
  ///
  /// Backend response shape:
  /// ```json
  /// {
  ///   "vitals": [ { "patient_id": "...", "ecg_hr": ..., ... } ],
  ///   "triage_results": [ { "patient_id": "...", "triage": "...", "confidence": ... } ]
  /// }
  /// ```
  Future<VitalsModel?> fetchFinalTriageData({String? patientId}) async {
    try {
      final String endpoint = '$cloudUrl/patients';
      final uri = Uri.parse(endpoint);
      debugPrint('🚀 [RenderService] Requesting patients list -> $uri');

      final response = await _client.get(
        uri,
        headers: {
          'Accept': 'application/json',
        },
      ).timeout(requestTimeout);

      debugPrint(
        '📥 [RenderService] Response Status: ${response.statusCode}',
      );
      debugPrint('📥 [RenderService] Body: ${response.body}');

      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        if (decoded is! Map<String, dynamic>) {
          debugPrint('⚠️ [RenderService] Unexpected JSON shape from /patients.');
          return null;
        }

        // Extract latest triage result for this patient
        final List<dynamic> triageResults =
            (decoded['triage_results'] as List<dynamic>?) ?? [];
        final List<dynamic> vitals =
            (decoded['vitals'] as List<dynamic>?) ?? [];

        // Find latest triage row (list is already ordered by timestamp desc)
        Map<String, dynamic>? latestTriage;
        for (final t in triageResults) {
          if (t is Map<String, dynamic>) {
            if (patientId == null || patientId.isEmpty || t['patient_id'] == patientId) {
              latestTriage = t;
              break; // first match is the latest (desc order)
            }
          }
        }

        // Find matching vitals row
        Map<String, dynamic>? latestVitals;
        for (final v in vitals) {
          if (v is Map<String, dynamic>) {
            if (patientId == null || patientId.isEmpty || v['patient_id'] == patientId) {
              latestVitals = v;
              break;
            }
          }
        }

        if (latestTriage == null) {
          debugPrint(
            '⚠️ [RenderService] No triage result found for patient: $patientId',
          );
          return null;
        }

        // Merge vitals + triage into a flat map for VitalsModel.fromJson
        final merged = <String, dynamic>{
          ...?latestVitals,
          ...latestTriage,
        };

        final vitalsModel = VitalsModel.fromJson(merged);
        debugPrint(
          '✅ [RenderService] Triage fetched: ${vitalsModel.triage} '
          '(${(vitalsModel.confidence * 100).toStringAsFixed(0)}%) '
          'for patient: ${vitalsModel.patientId}',
        );
        return vitalsModel;
      } else {
        debugPrint(
          '⚠️ [RenderService] Backend returned error ${response.statusCode}: ${response.body}',
        );
        return null;
      }
    } on TimeoutException catch (e) {
      debugPrint(
        '⏰ [RenderService] Timeout fetching triage data (${requestTimeout.inSeconds}s): $e',
      );
      return null;
    } on SocketException catch (e) {
      debugPrint(
        '🔌 [RenderService] Network/Socket error: $e',
      );
      return null;
    } on FormatException catch (e) {
      debugPrint('📄 [RenderService] Failed to parse JSON response: $e');
      return null;
    } catch (e, stack) {
      debugPrint(
        '❌ [RenderService] Unexpected exception: $e\n$stack',
      );
      return null;
    }
  }
}

