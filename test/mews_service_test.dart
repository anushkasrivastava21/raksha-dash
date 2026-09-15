import 'package:flutter_test/flutter_test.dart';
import 'package:raksha_app/services/mews_service.dart';

void main() {
  group('mewsOverride — 14 required cases', () {
    // #  | HR  | SpO2 | Temp | status | override | why
    final cases = <Map<String, dynamic>>[
      {'n': 1, 'hr': 75.0, 'spo2': 98.0, 'temp': 37.0, 'status': 'NONE', 'override': false, 'why': 'normal baseline'},
      {'n': 2, 'hr': 39.0, 'spo2': 98.0, 'temp': 37.0, 'status': 'RED', 'override': true, 'why': 'HR just below lower bound'},
      {'n': 3, 'hr': 40.0, 'spo2': 98.0, 'temp': 37.0, 'status': 'NONE', 'override': false, 'why': 'HR boundary, exactly 40 (not <40)'},
      {'n': 4, 'hr': 131.0, 'spo2': 98.0, 'temp': 37.0, 'status': 'RED', 'override': true, 'why': 'HR just above upper bound'},
      {'n': 5, 'hr': 130.0, 'spo2': 98.0, 'temp': 37.0, 'status': 'NONE', 'override': false, 'why': 'HR boundary, exactly 130 (not >130)'},
      {'n': 6, 'hr': 75.0, 'spo2': 89.0, 'temp': 37.0, 'status': 'RED', 'override': true, 'why': 'SpO2 just below bound'},
      {'n': 7, 'hr': 75.0, 'spo2': 90.0, 'temp': 37.0, 'status': 'NONE', 'override': false, 'why': 'SpO2 boundary, exactly 90 (not <90)'},
      {'n': 8, 'hr': 75.0, 'spo2': 98.0, 'temp': 39.1, 'status': 'YELLOW', 'override': true, 'why': 'temp just above bound, alone'},
      {'n': 9, 'hr': 75.0, 'spo2': 98.0, 'temp': 34.9, 'status': 'YELLOW', 'override': true, 'why': 'temp just below bound, alone'},
      {'n': 10, 'hr': 75.0, 'spo2': 98.0, 'temp': 39.0, 'status': 'NONE', 'override': false, 'why': 'temp boundary, exactly 39.0 (not >39.0)'},
      {'n': 11, 'hr': 75.0, 'spo2': 98.0, 'temp': 35.0, 'status': 'NONE', 'override': false, 'why': 'temp boundary, exactly 35.0 (not <35.0)'},
      {
        'n': 12,
        'hr': 30.0,
        'spo2': 85.0,
        'temp': 40.0,
        'status': 'RED',
        'override': true,
        'why': 'HR + SpO2 both violate (RED), temp also violates but must NOT downgrade to YELLOW',
      },
      {
        'n': 13,
        'hr': 75.0,
        'spo2': 85.0,
        'temp': 40.0,
        'status': 'RED',
        'override': true,
        'why': 'SpO2 alone triggers RED; temp still does not downgrade even when RED came from SpO2, not HR',
      },
      {
        'n': 14,
        'hr': 0.0,
        'spo2': 0.0,
        'temp': 0.0,
        'status': 'RED',
        'override': true,
        'why': 'disconnected-sensor / all-zero packet must NOT read as normal',
      },
    ];

    for (final c in cases) {
      test('#${c['n']} — ${c['why']}', () {
        final result = mewsOverride(VitalsSnapshot(
          heartRate: c['hr'] as double,
          spo2: c['spo2'] as double,
          temperature: c['temp'] as double,
        ));
        expect(result.status, c['status']);
        expect(result.override, c['override']);
      });
    }

    test('#12 reason-string order: HR → SpO2 → Temp', () {
      final result = mewsOverride(const VitalsSnapshot(heartRate: 30, spo2: 85, temperature: 40));
      final hrIdx = result.reason.indexOf('Critical Heart Rate');
      final spo2Idx = result.reason.indexOf('Critical SpO2');
      final tempIdx = result.reason.indexOf('Abnormal Temperature');
      expect(hrIdx, greaterThanOrEqualTo(0));
      expect(spo2Idx, greaterThan(hrIdx));
      expect(tempIdx, greaterThan(spo2Idx));
    });

    test('#14 reason-string order: HR → SpO2 → Temp (all-zero packet)', () {
      final result = mewsOverride(const VitalsSnapshot(heartRate: 0, spo2: 0, temperature: 0));
      final hrIdx = result.reason.indexOf('Critical Heart Rate');
      final spo2Idx = result.reason.indexOf('Critical SpO2');
      final tempIdx = result.reason.indexOf('Abnormal Temperature');
      expect(hrIdx, greaterThanOrEqualTo(0));
      expect(spo2Idx, greaterThan(hrIdx));
      expect(tempIdx, greaterThan(spo2Idx));
    });
  });

  group('MewsResult.displayColor', () {
    test('RED -> "RED"', () {
      const result = MewsResult(override: true, status: 'RED', reason: 'x');
      expect(result.displayColor, 'RED');
    });

    test('YELLOW -> "YELLOW"', () {
      const result = MewsResult(override: true, status: 'YELLOW', reason: 'x');
      expect(result.displayColor, 'YELLOW');
    });

    test('NONE -> null', () {
      const result = MewsResult(override: false, status: 'NONE', reason: 'x');
      expect(result.displayColor, isNull);
    });
  });

  group('offline-safety sanity check', () {
    test('mewsOverride takes only 3 raw doubles, no I/O, no async', () {
      // Compile-time guarantee: this call has no await and needs no setup/mocks.
      final result = mewsOverride(const VitalsSnapshot(heartRate: 75, spo2: 98, temperature: 37));
      expect(result, isA<MewsResult>());
    });
  });
}
