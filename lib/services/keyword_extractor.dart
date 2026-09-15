class KeywordExtractor {
  // Map of standard English keywords to lists of synonymous phrases (English and Hindi)
  static const Map<String, List<String>> _keywordMap = {
    "chest pain": [
      "chest pain",
      "heart pain",
      "seene mein dard",
      "chhaati mein dard",
      "seena dard"
    ],
    "dizzy": [
      "dizzy",
      "dizziness",
      "fainting",
      "chakkar",
      "chakkar aana"
    ],
    "fever": [
      "fever",
      "high temperature",
      "bukhar",
      "tapman",
      "tapat"
    ],
    "cough": [
      "cough",
      "coughing",
      "khansi",
      "khaansi"
    ],
    "shortness of breath": [
      "shortness of breath",
      "breathing difficulty",
      "saans lene mein dikkat",
      "saans phulna"
    ]
  };

  /// Scans a raw transcript string for English and Hindi medical keywords,
  /// returning a deduplicated list of standardized English keywords.
  static List<String> extractSymptoms(String transcript) {
    if (transcript.isEmpty) return [];

    final normalizedTranscript = transcript.toLowerCase();
    final Set<String> detectedKeywords = {};

    _keywordMap.forEach((standardKeyword, synonyms) {
      for (final synonym in synonyms) {
        if (normalizedTranscript.contains(synonym.toLowerCase())) {
          detectedKeywords.add(standardKeyword);
          break; // Move to the next standard keyword once we find a match
        }
      }
    });

    return detectedKeywords.toList();
  }
}
