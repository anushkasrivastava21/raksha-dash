import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException, HttpException;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/vitals_model.dart';

/// API Service for Render backend hardware telemetry endpoint
class RenderApiService {
  static String get baseUrl => ApiService.baseUrl;
  static const Duration requestTimeout = Duration(seconds: 35);

  /// Fetches hardware vitals telemetry data from Render cloud backend.
  static Future<VitalsModel> fetchHardwareVitals({String route = ''}) async {
    final String cleanRoute = route.isEmpty
        ? baseUrl
        : (route.startsWith('/') ? '$baseUrl$route' : '$baseUrl/$route');

    final Uri uri = Uri.parse(cleanRoute);

    try {
      debugPrint("🚀 [RenderApiService] GET -> $uri");
      final response = await http
          .get(
            uri,
            headers: {
              'Accept': 'application/json',
            },
          )
          .timeout(requestTimeout);

      debugPrint("📥 [RenderApiService] StatusCode: ${response.statusCode}");

      if (response.statusCode == 200) {
        final Map<String, dynamic> jsonMap =
            jsonDecode(response.body) as Map<String, dynamic>;
        debugPrint("✅ [RenderApiService] Successfully parsed VitalsModel");
        return VitalsModel.fromJson(jsonMap);
      } else {
        throw HttpException(
          'Failed to fetch hardware vitals. HTTP Status: ${response.statusCode}, Body: ${response.body}',
          uri: uri,
        );
      }
    } on TimeoutException {
      throw TimeoutException(
        'Request to $uri timed out after ${requestTimeout.inSeconds} seconds.',
      );
    } on SocketException catch (e) {
      throw SocketException(
        'Network connection error reaching $uri: ${e.message}',
      );
    } on FormatException catch (e) {
      throw FormatException(
        'Invalid JSON format received from $uri: ${e.message}',
      );
    } catch (e) {
      debugPrint("❌ [RenderApiService] Exception: $e");
      rethrow;
    }
  }
}

/// Result object for cloud save operations
class SaveToCloudResult {
  final bool success;
  final String message;
  final int? statusCode;

  const SaveToCloudResult({
    required this.success,
    required this.message,
    this.statusCode,
  });
}

/// ApiService with smart environment resolution, automatic CORS fallback,
/// pre-flight JSON audit, typed exception logging, and offline fail-safe caching.
class ApiService {
  // ── ENVIRONMENT CONFIGURATION ──────────────────────────────────────────────
  // Set to false = PRODUCTION MODE → all traffic routed to Render cloud
  // Set to true  = LOCAL MODE       → traffic routed to http://172.16.46.141:8000 (Raspberry Pi LAN)
  static const bool useLocalServer = true;

  // ── PRODUCTION CLOUD BACKEND URL (no trailing slash)
  static const String cloudBackendUrl = 'https://raksha-api-71a6.onrender.com';
  static const String _productionUrl = cloudBackendUrl;
  static const String mlEngineUrl = 'https://raksha-sim.onrender.com';

  // Request timeout — 35s accounts for Render free-tier cold starts
  static const Duration requestTimeout = Duration(seconds: 35);

  /// Primary Base URL — resolves to production or local depending on flag
  static String get baseUrl {
    final resolved = !useLocalServer ? _productionUrl : _localUrl;
    debugPrint('🌐 [ApiService] Resolved Base URL: $resolved (useLocalServer: $useLocalServer)');
    return resolved;
  }

  /// Local Base URL resolver — returns Pi local IP on all platforms (Android, iOS, desktop, web)
  static String get _localUrl {
    return 'http://172.16.46.141:8000';
  }

  /// Dedicated method to save vitals & triage data DIRECTLY to Cloud Backend
  /// (https://raksha-api-71a6.onrender.com), regardless of useLocalServer mode.
  static Future<SaveToCloudResult> saveToCloud(Map<String, dynamic> payload) async {
    debugPrint("════════════════════════════════════════════════════");
    debugPrint("☁️ [SAVE_TO_CLOUD] Dispatching patient payload to: $cloudBackendUrl");

    // 1. Prepare and validate Vitals payload
    Map<String, dynamic> vitalsPayload;
    String vitalsJson = "";

    try {
      vitalsPayload = payload.containsKey("vitals") && payload["vitals"] is Map
          ? Map<String, dynamic>.from(payload["vitals"])
          : payload;
      vitalsJson = jsonEncode(vitalsPayload);
    } catch (e) {
      debugPrint("❌ [SAVE_TO_CLOUD] Serialization error: $e");
      return SaveToCloudResult(
        success: false,
        message: "Failed to encode patient data: $e",
      );
    }

    // 2. POST /vitals to Cloud Backend
    try {
      final Uri vitalsUri = Uri.parse('$cloudBackendUrl/vitals');
      debugPrint("🚀 [SAVE_TO_CLOUD] POST -> $vitalsUri");
      debugPrint("📦 Vitals Payload: $vitalsJson");

      final vitalsResponse = await _safePost(vitalsUri, vitalsJson);
      debugPrint("📥 [SAVE_TO_CLOUD] /vitals HTTP ${vitalsResponse.statusCode}: ${vitalsResponse.body}");

      if (vitalsResponse.statusCode != 200 && vitalsResponse.statusCode != 201) {
        return SaveToCloudResult(
          success: false,
          statusCode: vitalsResponse.statusCode,
          message: "Server rejected vitals with HTTP ${vitalsResponse.statusCode}: ${vitalsResponse.body}",
        );
      }

      // 3. POST /triage to Cloud Backend (if triage payload is present)
      if (payload.containsKey("triage") && payload["triage"] is Map) {
        try {
          final triagePayload = Map<String, dynamic>.from(payload["triage"]);
          final triageJson = jsonEncode(triagePayload);
          final Uri triageUri = Uri.parse('$cloudBackendUrl/triage');
          debugPrint("🚀 [SAVE_TO_CLOUD] POST -> $triageUri");
          debugPrint("📦 Triage Payload: $triageJson");

          final triageResponse = await _safePost(triageUri, triageJson);
          debugPrint("📥 [SAVE_TO_CLOUD] /triage HTTP ${triageResponse.statusCode}: ${triageResponse.body}");
        } catch (triageErr) {
          debugPrint("⚠️ [SAVE_TO_CLOUD] /triage warning: $triageErr");
        }
      }

      debugPrint("🎉 [SAVE_TO_CLOUD] Patient successfully persisted to Cloud Backend.");
      debugPrint("════════════════════════════════════════════════════");
      return const SaveToCloudResult(
        success: true,
        statusCode: 200,
        message: "Successfully Saved",
      );
    } on TimeoutException {
      debugPrint("⏰ [SAVE_TO_CLOUD] Request timed out.");
      await cacheFailedPayload(payload);
      return const SaveToCloudResult(
        success: true,
        message: "Saved Locally (Cloud Unreachable)",
      );
    } catch (e) {
      debugPrint("❌ [SAVE_TO_CLOUD] Network/Unexpected error: $e");
      await cacheFailedPayload(payload);
      return const SaveToCloudResult(
        success: true,
        message: "Saved Locally (Offline Mode)",
      );
    }
  }

  /// Caches failed sync payloads to shared preferences for safe offline recovery.
  static Future<void> cacheFailedPayload(Map<String, dynamic> payload) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      List<String> offlineData = prefs.getStringList('unsynced_patients') ?? [];

      final String serialized = jsonEncode(payload);

      if (!offlineData.contains(serialized)) {
        offlineData.add(serialized);
        await prefs.setStringList('unsynced_patients', offlineData);
        debugPrint(
          "💾 [OFFLINE_CACHE] Patient data securely cached locally. Total unsynced: ${offlineData.length}",
        );
      } else {
        debugPrint(
          "💾 [OFFLINE_CACHE] Payload already present in local cache. Skipping duplicate.",
        );
      }
    } catch (e, stack) {
      debugPrint(
        "❌ [OFFLINE_CACHE_ERR] Failed to write to SharedPreferences: $e",
      );
      debugPrint("Stacktrace: $stack");
    }
  }

  /// Attempts to flush all locally cached payloads to the backend.
  static Future<void> flushOfflineCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      List<String> offlineData = prefs.getStringList('unsynced_patients') ?? [];

      if (offlineData.isEmpty) {
        return;
      }

      debugPrint("🔄 [OFFLINE_CACHE] Attempting to sync ${offlineData.length} offline patient(s)...");
      List<String> remainingData = [];
      int successCount = 0;

      for (String serializedPayload in offlineData) {
        try {
          final payload = jsonDecode(serializedPayload);
          final vitalsPayload = payload.containsKey("vitals") && payload["vitals"] is Map
              ? Map<String, dynamic>.from(payload["vitals"])
              : payload;
          final vitalsJson = jsonEncode(vitalsPayload);

          final Uri vitalsUri = Uri.parse('$cloudBackendUrl/vitals');
          final vitalsResponse = await _safePost(vitalsUri, vitalsJson);

          if (vitalsResponse.statusCode == 200 || vitalsResponse.statusCode == 201) {
            // Also post triage if present.
            if (payload.containsKey("triage") && payload["triage"] is Map) {
               try {
                 final triageUri = Uri.parse('$cloudBackendUrl/triage');
                 await _safePost(triageUri, jsonEncode(payload["triage"]));
               } catch (_) {}
            }
            successCount++;
          } else {
            remainingData.add(serializedPayload);
          }
        } catch (e) {
          // Network error, keep in cache
          remainingData.add(serializedPayload);
        }
      }

      await prefs.setStringList('unsynced_patients', remainingData);
      
      if (successCount > 0) {
        debugPrint("🎉 [OFFLINE_CACHE] Successfully flushed $successCount patient(s) to cloud!");
      }
    } catch (e, stack) {
      debugPrint("❌ [OFFLINE_CACHE_ERR] Failed during cache flush: $e");
    }
  }

  /// Internal helper to post to an endpoint with timeout and headers
  static Future<http.Response> _safePost(Uri uri, String body) async {
    try {
      return await http
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: body,
          )
          .timeout(const Duration(seconds: 8)); // Shorter timeout for faster fallback
    } catch (firstErr) {
      if (uri.host.contains('onrender.com') || uri.host.contains('172.16.46.141')) {
        final fallbackUri = Uri.parse('http://127.0.0.1:8000${uri.path}');
        debugPrint('⚠️ [ApiService] Primary POST $uri failed ($firstErr). Trying localhost fallback: $fallbackUri');
        return await http
            .post(
              fallbackUri,
              headers: {
                'Content-Type': 'application/json',
                'Accept': 'application/json',
              },
              body: body,
            )
            .timeout(requestTimeout);
      }
      rethrow;
    }
  }

  /// Pushes Vitals telemetry payload to backend (POST /vitals).
  static Future<bool> pushTriageData(Map<String, dynamic> payload) async {
    bool vitalsSuccess = false;

    debugPrint("════════════════════════════════════════════════════");
    debugPrint(
      "🌐 STARTING CLOUD SYNC TO: $baseUrl (LocalServer: $useLocalServer)",
    );

    // DATA_SOURCE: https://raksha-sim-1.onrender.com
    // ── PRE-FLIGHT JSON SERIALIZATION AUDIT ──────────────────────────────────
    Map<String, dynamic> vitalsPayload;
    String vitalsJson = "";

    try {
      vitalsPayload =
          payload.containsKey("vitals") && payload["vitals"] is Map
              ? Map<String, dynamic>.from(payload["vitals"])
              : payload;

      vitalsJson = jsonEncode(vitalsPayload);
      debugPrint(
        "✅ [PREFLIGHT] JSON payload serialization verified successfully.",
      );
    } catch (e, stack) {
      debugPrint(
        "❌ [PREFLIGHT_ERR] Serialization failed before HTTP dispatch: Type=${e.runtimeType}, Error=$e",
      );
      debugPrint("Stacktrace: $stack");
      await cacheFailedPayload(payload);
      return false;
    }

    // ── 1. POST /vitals ──────────────────────────────────────────────────────
    try {
      Uri vitalsUri = Uri.parse('$baseUrl/vitals');
      debugPrint("🚀 [HTTP_POST] -> $vitalsUri");
      debugPrint("📦 Vitals Body: $vitalsJson");

      http.Response vitalsResponse;
      try {
        vitalsResponse = await _safePost(vitalsUri, vitalsJson);
      } catch (firstErr) {
        if (baseUrl != _localUrl) {
          debugPrint(
              "⚠️ Primary endpoint failed ($firstErr). Attempting local fallback: $_localUrl/vitals");
          vitalsUri = Uri.parse('$_localUrl/vitals');
          vitalsResponse = await _safePost(vitalsUri, vitalsJson);
        } else {
          rethrow;
        }
      }

      debugPrint(
        "📥 [HTTP_RESP] /vitals StatusCode: ${vitalsResponse.statusCode}",
      );
      debugPrint("📥 [HTTP_RESP] /vitals Body: ${vitalsResponse.body}");

      if (vitalsResponse.statusCode == 200 ||
          vitalsResponse.statusCode == 201) {
        vitalsSuccess = true;
        debugPrint("✅ [SUCCESS] /vitals sync acknowledged by backend.");
      } else {
        debugPrint(
          "⚠️ [HTTP_WARN] /vitals rejected with Status ${vitalsResponse.statusCode}: ${vitalsResponse.body}",
        );
      }
    } on TimeoutException catch (e) {
      debugPrint(
        "⏰ [TIMEOUT_ERR] /vitals request timed out after ${requestTimeout.inSeconds}s: $e",
      );
    } on SocketException catch (e) {
      debugPrint(
        "🔌 [NET_ERR] /vitals SocketException (No connection/DNS failure): $e",
      );
    } on FormatException catch (e) {
      debugPrint("📄 [FORMAT_ERR] /vitals Bad response format: $e");
    } catch (e, stack) {
      debugPrint(
        "❌ [CORS/HTTP_ERR] /vitals Exception (${e.runtimeType}): $e",
      );
      debugPrint("Stacktrace: $stack");
    }

    // ── 2. POST /triage (if triage payload is provided) ─────────────────────
    if (payload.containsKey("triage") && payload["triage"] is Map) {
      try {
        final triagePayload = Map<String, dynamic>.from(payload["triage"]);
        final triageJson = jsonEncode(triagePayload);
        Uri triageUri = Uri.parse('$baseUrl/triage');
        debugPrint("🚀 [HTTP_POST] -> $triageUri");
        debugPrint("📦 Triage Body: $triageJson");

        final triageResponse = await _safePost(triageUri, triageJson);
        debugPrint(
          "📥 [HTTP_RESP] /triage StatusCode: ${triageResponse.statusCode}",
        );
      } catch (e) {
        debugPrint("⚠️ [HTTP_WARN] /triage payload dispatch warning: $e");
      }
    }

    // ── SINGLE-SOURCE OFFLINE CACHING FALLBACK ───────────────────────────────
    if (!vitalsSuccess) {
      debugPrint(
        "⚠️ [SYNC_FAILED] /vitals sync failed. Caching payload locally.",
      );
      await cacheFailedPayload(payload);
    } else {
      debugPrint(
        "🎉 [SYNC_COMPLETE] /vitals successfully synced to backend.",
      );
    }

    debugPrint("════════════════════════════════════════════════════");
    return vitalsSuccess;
  }
}
