// PLACEHOLDER scaffold for the triage rule-table.
// Blocked on Anirudh's real decision boundaries (target: Hour 14-16 per
// master timeline). Not demo-ready.

class TriageInputs {
  final String? ecgResult; // label set TBD from Anirudh's model output
  final String? urineResult; // label set TBD
  final List<String> symptomKeywords;

  const TriageInputs({
    this.ecgResult,
    this.urineResult,
    required this.symptomKeywords,
  });
}

class TriageResult {
  final String triageColor; // "Green" | "Yellow" | "Red" -- matches MewsResult.displayColor casing
  final double confidence; // 0.0-1.0

  const TriageResult(this.triageColor, this.confidence);
}

/// PLACEHOLDER -- replace once Anirudh hands off real decision boundaries.
TriageResult evaluateTriage(TriageInputs inputs) {
  // TODO(anushka): replace with real rule table.
  return const TriageResult("Green", 0.5);
}
