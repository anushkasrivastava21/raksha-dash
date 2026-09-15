// DATA_SOURCE: https://raksha-sim-1.onrender.com
/// Strongly typed model representing complete patient vitals and triage results.
class VitalsModel {
  final String patientId;
  final String timestamp;
  final String stethoscopeStatus;
  final double ecgHr;
  final double spo2;
  final double temperature;
  final List<double> urineRgb;
  final String patientSpeechText;
  final String triage;
  final double confidence;

  VitalsModel({
    required this.patientId,
    required this.timestamp,
    required this.stethoscopeStatus,
    required this.ecgHr,
    required this.spo2,
    required this.temperature,
    required this.urineRgb,
    required this.patientSpeechText,
    required this.triage,
    required this.confidence,
  });

  /// Factory constructor to decode full JSON payload returned from cloud server.
  factory VitalsModel.fromJson(Map<String, dynamic> json) {
    final Map<String, dynamic> data =
        json.containsKey('vitals') && json['vitals'] is Map<String, dynamic>
            ? Map<String, dynamic>.from(json['vitals'])
            : json;

    double toDouble(dynamic val, double fallback) {
      if (val == null) return fallback;
      if (val is num) return val.toDouble();
      if (val is String) return double.tryParse(val) ?? fallback;
      return fallback;
    }

    List<double> parsedRgb;
    if ((data.containsKey('urine_r') || json.containsKey('urine_r')) &&
        (data['urine_r'] != null || json['urine_r'] != null)) {
      final r = toDouble(data['urine_r'] ?? json['urine_r'], 255.0);
      final g = toDouble(data['urine_g'] ?? json['urine_g'], 255.0);
      final b = toDouble(data['urine_b'] ?? json['urine_b'], 0.0);
      parsedRgb = [r, g, b];
    } else {
      final dynamic rawRgb = data['urine_rgb'] ?? json['urine_rgb'];
      if (rawRgb is List) {
        parsedRgb = rawRgb.map((e) => toDouble(e, 0.0)).toList();
      } else {
        parsedRgb = [255.0, 255.0, 0.0];
      }
    }

    return VitalsModel(
      patientId: (data['patient_id'] ?? json['patient_id'] ?? '').toString(),
      timestamp: (data['timestamp'] ??
              json['timestamp'] ??
              DateTime.now().toIso8601String())
          .toString(),
      stethoscopeStatus:
          (data['stethoscope_status'] ?? json['stethoscope_status'] ?? 'clean')
              .toString(),
      ecgHr: toDouble(data['ecg_hr'] ?? json['ecg_hr'], 72.0),
      spo2: toDouble(data['spo2'] ?? json['spo2'], 98.0),
      temperature: toDouble(data['temperature'] ?? json['temperature'], 36.8),
      urineRgb: parsedRgb,
      patientSpeechText:
          (data['patient_speech_text'] ?? json['patient_speech_text'] ?? '')
              .toString(),
      triage: (json['triage'] ?? data['triage'] ?? 'GREEN').toString(),
      confidence: toDouble(json['confidence'] ?? data['confidence'], 0.95),
    );
  }

  /// Serializes VitalsModel back to JSON format.
  Map<String, dynamic> toJson() {
    return {
      'patient_id': patientId,
      'timestamp': timestamp,
      'stethoscope_status': stethoscopeStatus,
      'ecg_hr': ecgHr,
      'spo2': spo2,
      'temperature': temperature,
      'urine_rgb': urineRgb,
      'patient_speech_text': patientSpeechText,
      'triage': triage,
      'confidence': confidence,
    };
  }
}
