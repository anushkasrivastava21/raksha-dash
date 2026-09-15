/// Global Application Configuration for Raksha
class AppConfig {
  /// Base URL for local Raspberry Pi Hardware Controller (LAN).
  /// Matches ApiService._localUrl — update together if IP changes.
  static const String hardwareBaseUrl = 'http://172.16.46.141:8000';

  // ── SENSOR SPECIFIC HARDWARE TIMEOUTS ──────────────────────────────────
  /// Temperature (MLX90614): 15 seconds (account for 5s placement + 5s post-request delay)
  static const Duration temperatureTimeout = Duration(seconds: 15);

  /// Urine/Color (TCS3200): 10 seconds
  static const Duration urineTimeout = Duration(seconds: 10);

  /// ECG (AD8232): 15 seconds
  static const Duration ecgTimeout = Duration(seconds: 15);

  /// Stethoscope (MAX4466): 65 seconds (account for 50 samples * 1s + 5s delay)
  static const Duration stethoscopeTimeout = Duration(seconds: 65);

  /// Pulse Oximeter (MAX30102): Fixed strictly at 15 seconds
  static const Duration pulseOximeterTimeout = Duration(seconds: 15);

  /// Voice recording / auscultation stream: 15 seconds
  static const Duration voiceTimeout = Duration(seconds: 15);
}
