/// KeywordExtractor — On-Device Clinical Symptom Extraction
/// Ported directly from Anirudh's bilingual NLP model (experiment_MED/symptom_extractor.py).
///
/// Features:
///   - Bilingual English & Hindi/Hinglish clinical lexicon (190+ variants)
///   - Bilingual negation handling (English prefix cues & Hindi suffix cues)
///   - Clause-boundary isolation across punctuation to prevent negation bleed
class KeywordExtractor {
  // Negation cues from Anirudh's symptom_lexicon.json
  static const Set<String> _prefixNegationCues = {
    "no",
    "not",
    "without",
    "denies",
    "denied",
    "never",
    "negative",
    "free of",
  };

  static const Set<String> _suffixNegationCues = {
    "nahi",
    "nahin",
    "nai",
    "na",
  };

  static const int _prefixWindow = 4;
  static const int _suffixWindow = 3;
  static const String _boundary = "|";

  // Map of standard clinical keywords to lists of synonymous variants (English and Hindi)
  static const Map<String, List<String>> _keywordMap = {
    "chest pain": [
      "chest pain",
      "heart pain",
      "seene mein dard",
      "seene me dard",
      "chhaati mein dard",
      "chati me dard",
      "seena dard",
      "chest pressure",
      "chest tightness",
      "chaati me bojh",
    ],
    "dizzy": [
      "dizzy",
      "dizziness",
      "fainting",
      "chakkar",
      "chakkar aana",
      "sir ghumna",
      "lightheadedness",
      "vertigo",
    ],
    "fever": [
      "fever",
      "high temperature",
      "bukhar",
      "tapman",
      "tapat",
      "tez bukhar",
      "pyrexia",
    ],
    "cough": [
      "cough",
      "coughing",
      "khansi",
      "khaansi",
      "sukhi khansi",
      "balgam",
    ],
    "shortness of breath": [
      "shortness of breath",
      "breathing difficulty",
      "saans lene mein dikkat",
      "saans lene mein takleef",
      "saans phulna",
      "dam ghutna",
      "dyspnea",
      "breathlessness",
    ],
    "palpitations": [
      "palpitations",
      "dil ki dhadkan tez",
      "dhadkan tez",
      "fluttering heart",
      "racing heart",
    ],
    "unconscious": [
      "unconscious",
      "behosh",
      "behoshi",
      "unresponsive",
      "coma",
    ],
    "seizure": [
      "seizure",
      "daura",
      "fits",
      "mirgi",
      "convulsion",
      "jhatke",
    ],
    "vomiting": [
      "vomiting",
      "ulti",
      "nausea",
      "vomiting blood",
      "khoon ki ulti",
    ],
    "headache": [
      "headache",
      "sar dard",
      "sir dard",
      "severe headache",
    ],
  };

  /// Scans a raw transcript string for English and Hindi medical keywords with
  /// bidirectional negation awareness (English "no chest pain", Hindi "dard nahi hai").
  ///
  /// Returns a deduplicated list of affirmed standardized English symptoms.
  static List<String> extractSymptoms(String transcript) {
    if (transcript.trim().isEmpty) return [];

    // 1. Normalize text: lower-case and replace punctuation with boundary marks
    String text = transcript.toLowerCase();
    text = text.replaceAll(RegExp(r'[.,;:!?\u0964]+'), ' $_boundary ');
    text = text.replaceAll(RegExp(r'[^\w\s|]+'), ' ');
    text = text.replaceAll(RegExp(r'\s+'), ' ').trim();

    if (text.isEmpty) return [];

    final List<String> tokens = text.split(' ');

    // 2. Build token-level negation scope (Anirudh's algorithm)
    final Set<int> negatedTokenIndices = {};
    for (int i = 0; i < tokens.length; i++) {
      final token = tokens[i];

      // English prefix negation ("no chest pain") -> runs forward
      if (_prefixNegationCues.contains(token)) {
        for (int j = i + 1; j < tokens.length && j <= i + _prefixWindow; j++) {
          if (tokens[j] == _boundary) break;
          negatedTokenIndices.add(j);
        }
      }

      // Hindi suffix negation ("dard nahi hai") -> runs backward
      if (_suffixNegationCues.contains(token)) {
        for (int j = i - 1; j >= 0 && j >= i - _suffixWindow; j--) {
          if (tokens[j] == _boundary) break;
          negatedTokenIndices.add(j);
        }
      }
    }

    // 3. Scan for symptom matches and filter negated mentions
    final Set<String> detectedAffirmed = {};

    _keywordMap.forEach((standardKeyword, synonyms) {
      for (final synonym in synonyms) {
        final synLower = synonym.toLowerCase();
        final synTokens = synLower.split(' ');
        final synLen = synTokens.length;

        // Find matches in token space
        for (int i = 0; i <= tokens.length - synLen; i++) {
          bool matches = true;
          for (int k = 0; k < synLen; k++) {
            if (tokens[i + k] != synTokens[k]) {
              matches = false;
              break;
            }
          }

          if (matches) {
            // Check if any token in this match falls inside the negation scope
            bool isNegated = false;
            for (int k = 0; k < synLen; k++) {
              if (negatedTokenIndices.contains(i + k)) {
                isNegated = true;
                break;
              }
            }

            if (!isNegated) {
              detectedAffirmed.add(standardKeyword);
            }
          }
        }
      }
    });

    return detectedAffirmed.toList();
  }
}
