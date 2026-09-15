// Direct Dart port of the backend's mews_check.py :: check_mews().
// Source resolved against mews_check.py + schemas.py, 2026-09-15.
//
// Deliberately does NOT replicate the Python source's nested/flat `or`
// fallback bug — this function takes clean flat doubles only, which is
// all the on-device pipeline ever produces.

class VitalsSnapshot {
  final double heartRate; // bpm
  final double spo2; // percent, 0-100
  final double temperature; // Celsius

  const VitalsSnapshot({
    required this.heartRate,
    required this.spo2,
    required this.temperature,
  });
}

class MewsResult {
  final bool override;
  final String status; // "RED" | "YELLOW" | "NONE" -- matches Python literally
  final String reason;

  const MewsResult({
    required this.override,
    required this.status,
    required this.reason,
  });

  /// Display-cased triage color ("RED" | "YELLOW"), or null if no override.
  /// This is the ONLY place raw "RED"/"YELLOW" casing should ever be
  /// converted -- nothing downstream should re-implement this mapping.
  String? get displayColor {
    switch (status) {
      case "RED":
        return "RED";
      case "YELLOW":
        return "YELLOW";
      default:
        return null;
    }
  }
}

/// Bounds are strict (< / >), matching the Python source exactly. RED
/// always takes priority over YELLOW; check order (HR, then SpO2, then
/// temperature) matches the Python source and is what makes that
/// priority deterministic.
MewsResult mewsOverride(VitalsSnapshot v) {
  final reasons = <String>[];
  String status = "NONE";

  if (v.heartRate < 40 || v.heartRate > 130) {
    reasons.add("Critical Heart Rate (${v.heartRate} bpm)");
    status = "RED";
  }

  if (v.spo2 < 90) {
    reasons.add("Critical SpO2 (${v.spo2}%)");
    status = "RED";
  }

  if (v.temperature > 39.0 || v.temperature < 35.0) {
    reasons.add("Abnormal Temperature (${v.temperature}°C)");
    if (status != "RED") {
      status = "YELLOW";
    }
  }

  if (reasons.isNotEmpty) {
    return MewsResult(override: true, status: status, reason: reasons.join(" | "));
  }

  return const MewsResult(
    override: false,
    status: "NONE",
    reason: "Vitals within normal range",
  );
}
