import 'package:flutter_test/flutter_test.dart';
import 'package:raksha_app/services/triage_scaffold.dart';

void main() {
  group('Triage Scaffold Range Logic', () {
    test('All within normal bounds returns Green', () {
      final result = evaluateTriage(const TriageInputs(
        ecgHr: 80.0,
        spo2: 95.0,
        temperature: 37.0,
        urineSeverity: 1.0,
        symptomKeywords: [],
      ));
      expect(result.triageColor, "GREEN");
    });

    test('Heart rate slightly above bounds returns Yellow', () {
      final result = evaluateTriage(const TriageInputs(
        ecgHr: 121.0, // max is 120.4
        spo2: 95.0,
        temperature: 37.0,
        symptomKeywords: [],
      ));
      expect(result.triageColor, "YELLOW");
    });

    test('SpO2 extremely low returns Red', () {
      final result = evaluateTriage(const TriageInputs(
        ecgHr: 80.0,
        spo2: 80.0, // critical threshold < 85
        temperature: 37.0,
        symptomKeywords: [],
      ));
      expect(result.triageColor, "RED");
    });

    test('Symptom keywords present returns Yellow', () {
      final result = evaluateTriage(const TriageInputs(
        ecgHr: 80.0,
        spo2: 95.0,
        temperature: 37.0,
        symptomKeywords: ["chest pain"],
      ));
      expect(result.triageColor, "YELLOW");
    });
  });
}
