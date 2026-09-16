import 'package:flutter_test/flutter_test.dart';
import 'package:raksha_app/services/keyword_extractor.dart';

void main() {
  group('KeywordExtractor', () {
    test('extractSymptoms handles empty transcript', () {
      final result = KeywordExtractor.extractSymptoms("");
      expect(result, isEmpty);
    });

    test('extractSymptoms extracts English keywords', () {
      final result = KeywordExtractor.extractSymptoms("The patient has severe chest pain and a high temperature.");
      expect(result, containsAll(["chest pain", "fever"]));
      expect(result.length, 2);
    });

    test('extractSymptoms extracts Hindi keywords and returns standard English tags', () {
      final result = KeywordExtractor.extractSymptoms("Mujhe chakkar aana aur bukhar mehsoos ho raha hai.");
      expect(result, containsAll(["dizzy", "fever"]));
      expect(result.length, 2);
    });

    test('extractSymptoms handles mixed case and deduplicates synonyms', () {
      // "seene mein dard" and "chest pain" both map to "chest pain"
      final result = KeywordExtractor.extractSymptoms("Patient says CHEST PAIN, also seene MEIN dard.");
      expect(result, ["chest pain"]);
    });

    test('extractSymptoms respects English prefix negation ("no chest pain")', () {
      final result = KeywordExtractor.extractSymptoms("The patient reports high fever, but has no chest pain.");
      expect(result, ["fever"]);
      expect(result, isNot(contains("chest pain")));
    });

    test('extractSymptoms respects Hindi suffix negation ("seene mein dard nahi hai")', () {
      final result = KeywordExtractor.extractSymptoms("Bukhar hai lekin seene mein dard nahi hai.");
      expect(result, ["fever"]);
      expect(result, isNot(contains("chest pain")));
    });
  });
}
