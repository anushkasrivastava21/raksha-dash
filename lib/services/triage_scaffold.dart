// XGBoost Triage Rule Table (Range-based Fallback)
// Built using aggregate boundaries from Anirudh's 'triage_rules_export.csv'.
// Note: This uses standard boundary ranges since the full decision tree
// was not provided. Values outside these bounds trigger Yellow/Red.

class TriageInputs {
  final double? ecgHr; // Heart Rate (BPM)
  final double? spo2; // SpO2 (%)
  final double? temperature; // Temperature (°C)
  final double? urineSeverity; // Urine Severity (1.0 = Normal)
  final List<String> symptomKeywords;

  const TriageInputs({
    this.ecgHr,
    this.spo2,
    this.temperature,
    this.urineSeverity,
    required this.symptomKeywords,
  });
}

class TriageResult {
  final String triageColor; // "GREEN" | "YELLOW" | "RED"
  final double confidence; // 0.0-1.0

  const TriageResult(this.triageColor, this.confidence);
}

/// Evaluates triage using XGBoost decision boundaries.
TriageResult evaluateTriage(TriageInputs inputs) {
  // Extreme critical thresholds (Red)
  if ((inputs.ecgHr != null && (inputs.ecgHr! < 50 || inputs.ecgHr! > 140)) ||
      (inputs.spo2 != null && inputs.spo2! < 85) ||
      (inputs.temperature != null && (inputs.temperature! < 34.0 || inputs.temperature! > 40.0))) {
    return const TriageResult("RED", 0.95);
  }

  // Warning thresholds based on provided min/max ranges (Yellow)
  // ecg_hr normal range: 72.2 to 120.4
  // spo2 normal range: 89.9 to 98.6
  // temperature normal range: 35.72 to 38.51
  // urine_severity normal: 1.0
  bool isYellow = false;

  if (inputs.ecgHr != null && (inputs.ecgHr! < 72.2 || inputs.ecgHr! > 120.4)) {
    isYellow = true;
  }
  if (inputs.spo2 != null && (inputs.spo2! < 89.9 || inputs.spo2! > 98.6)) {
    isYellow = true;
  }
  if (inputs.temperature != null && (inputs.temperature! < 35.72 || inputs.temperature! > 38.51)) {
    isYellow = true;
  }
  if (inputs.urineSeverity != null && inputs.urineSeverity! > 1.0) {
    isYellow = true;
  }
  if (inputs.symptomKeywords.isNotEmpty) {
    isYellow = true;
  }

  if (isYellow) {
    return const TriageResult("YELLOW", 0.85);
  }

  // All within normal bounds (Green)
  return const TriageResult("GREEN", 0.95);
}
