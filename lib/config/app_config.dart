/// Global Application Configuration for Raksha
class AppConfig {
  /// Base URL for local Raspberry Pi Hardware Controller (LAN).
  /// Matches ApiService._localUrl — update together if IP changes.
  static const String hardwareBaseUrl = 'http://172.16.46.141:8000';

  // ── SENSOR SPECIFIC HARDWARE TIMEOUTS ──────────────────────────────────
  /// Temperature (MLX90614): 2 seconds
  static const Duration temperatureTimeout = Duration(seconds: 2);

  /// Urine/Color (TCS3200): 3 seconds
  static const Duration urineTimeout = Duration(seconds: 3);

  /// ECG (AD8232): 5 seconds
  static const Duration ecgTimeout = Duration(seconds: 5);

  /// Stethoscope (MAX4466): 5 seconds
  static const Duration stethoscopeTimeout = Duration(seconds: 5);

  /// Pulse Oximeter (MAX30102): Fixed strictly at 12 seconds
  static const Duration pulseOximeterTimeout = Duration(seconds: 12);

  /// Voice recording / auscultation stream: 5 seconds
  static const Duration voiceTimeout = Duration(seconds: 5);
}
