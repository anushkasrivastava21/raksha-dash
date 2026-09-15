import 'package:flutter_test/flutter_test.dart';
import 'package:raksha_app/services/triage_scaffold.dart';

void main() {
  test('evaluateTriage placeholder returns exactly ("Green", 0.5)', () {
    final result = evaluateTriage(const TriageInputs(symptomKeywords: []));
    expect(result.triageColor, "Green");
    expect(result.confidence, 0.5);
  });
}
