import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Adjust the package name to match pubspec.yaml if it differs.
import 'package:raksha_app/triage/xgb_triage_model.dart';

void main() {
  final fixture = jsonDecode(
      File('test/fixtures/triage_parity_vectors.json').readAsStringSync());

  test('fixture was generated from the same model as the Dart tables', () {
    expect(fixture['source_model_sha256'], kTriageModelSha256);
  });

  test('Dart triage == XGBoost booster.predict on every fixture row', () {
    final rows = fixture['vectors'] as List;
    expect(rows, isNotEmpty);
    for (final row in rows) {
      final x = [
        for (final v in row['x'] as List) v == null ? double.nan : (v as num).toDouble()
      ];
      final out = predictTriage(x);
      final want = [for (final v in row['proba'] as List) (v as num).toDouble()];
      for (var i = 0; i < 3; i++) {
        expect(out.probs[i], closeTo(want[i], 1e-5), reason: 'row $x class $i');
      }
      expect(out.label, row['label'], reason: 'row $x');
    }
  });
}
