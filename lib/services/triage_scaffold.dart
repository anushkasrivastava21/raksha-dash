// XGBoost Triage Rule Table (Range-based Fallback)
// Built using aggregate boundaries from Anirudh's 'triage_rules_export.csv'.
// Note: This uses standard boundary ranges since the full decision tree
// was not provided. Values outside these bounds trigger Yellow/Red.

import 'xgb_triage_model.dart';

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

/// Evaluates triage using the native XGBoost engine.
TriageResult evaluateTriage(TriageInputs inputs) {
  // Extreme critical thresholds (Red) - safety override
  if ((inputs.ecgHr != null && (inputs.ecgHr! < 50 || inputs.ecgHr! > 140)) ||
      (inputs.spo2 != null && inputs.spo2! < 85) ||
      (inputs.temperature != null && (inputs.temperature! < 34.0 || inputs.temperature! > 40.0))) {
    return const TriageResult("RED", 0.95);
  }

  // Construct features array for XGBoost: ['ecg_hr', 'bp_sys', 'bp_dia', 'spo2', 'temperature', 'urine_severity']
  List<double> features = [
    inputs.ecgHr ?? double.nan,
    120.0, // bp_sys default (normal)
    80.0, // bp_dia default (normal)
    inputs.spo2 ?? double.nan,
    inputs.temperature ?? double.nan,
    inputs.urineSeverity ?? double.nan,
  ];

  // Predict using the official generated Dart XGBoost engine
  TriageProbs probs = predictTriage(features);

  String color = probs.label.toUpperCase(); // "GREEN", "YELLOW", "RED"
  double bestProb = probs.probs[probs.argmax];

  // Symptom keyword upgrade logic (since XGBoost doesn't use symptom flags natively)
  if (color == "GREEN" && inputs.symptomKeywords.isNotEmpty) {
    color = "YELLOW";
    // We override confidence slightly lower to indicate a rule-based upgrade
    bestProb = 0.85; 
  }

  return TriageResult(color, bestProb);
}
