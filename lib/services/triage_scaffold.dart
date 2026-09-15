// XGBoost Triage Rule Table (Range-based Fallback)
// Built using aggregate boundaries from Anirudh's 'triage_rules_export.csv'.
// Note: This uses standard boundary ranges since the full decision tree
// was not provided. Values outside these bounds trigger Yellow/Red.

import 'xgboost_rules.dart';

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

  // Construct features map for XGBoost
  Map<String, double> features = {};
  if (inputs.ecgHr != null) features["ecg_hr"] = inputs.ecgHr!;
  if (inputs.spo2 != null) features["spo2"] = inputs.spo2!;
  if (inputs.temperature != null) features["temperature"] = inputs.temperature!;
  if (inputs.urineSeverity != null) features["urine_severity"] = inputs.urineSeverity!;

  // Predict using native Dart XGBoost engine
  List<double> probs = XgbModel.predict(features);

  // Map highest probability to class:
  // 1 -> GREEN (Normal)
  // 0 -> YELLOW (Warning)
  // 2 -> RED (Critical)
  int bestClass = 0;
  double bestProb = probs[0];
  for (int i = 1; i < probs.length; i++) {
    if (probs[i] > bestProb) {
      bestProb = probs[i];
      bestClass = i;
    }
  }

  String color = "YELLOW";
  if (bestClass == 1) color = "GREEN";
  if (bestClass == 2) color = "RED";

  // Symptom keyword upgrade logic (since XGBoost doesn't use symptom flags natively)
  if (color == "GREEN" && inputs.symptomKeywords.isNotEmpty) {
    color = "YELLOW";
    // We override confidence slightly lower to indicate a rule-based upgrade
    bestProb = 0.85; 
  }

  return TriageResult(color, bestProb);
}
