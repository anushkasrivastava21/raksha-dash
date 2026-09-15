import 'package:flutter/material.dart';
import '../services/api_service.dart';

// ──────────────────────────────────────────────────────────────────────────────
// ENUMS
// ──────────────────────────────────────────────────────────────────────────────

/// Shared scan-status enum used by every test step.
enum ScanStatus {
  /// Screen just loaded — no measurement taken yet.
  initial,

  /// Measurement taken and within safe clinical thresholds.
  clean,

  /// Measurement taken and outside safe clinical thresholds.
  abnormal,
}

// ──────────────────────────────────────────────────────────────────────────────
// DATA MODELS
// ──────────────────────────────────────────────────────────────────────────────

/// Stethoscope auscultation result.
class StethResult {
  final double heartRate; // BPM
  final String lungSound; // e.g. "Clear", "Wheezing", "Crackles"

  const StethResult({required this.heartRate, required this.lungSound});
}

/// 12-lead ECG result.
class EcgResult {
  final double heartRate; // BPM
  final String rhythm; // e.g. "Normal Sinus", "Atrial Fibrillation"
  final double qtInterval; // ms

  const EcgResult({
    required this.heartRate,
    required this.rhythm,
    required this.qtInterval,
  });
}

/// SpO2 + Temperature result.
class Spo2TempResult {
  final int spo2; // %
  final int heartRate; // BPM
  final double temperature; // °C

  const Spo2TempResult({
    required this.spo2,
    required this.heartRate,
    required this.temperature,
  });
}

/// Urine strip analysis result.
class UrineResult {
  final String color; // e.g. "Yellow", "Red", "Dark Brown"
  final double ph;
  final String protein; // "Negative", "Trace", "Positive"
  final String glucose; // "Negative", "Trace", "Positive"
  final List<double>? rawRgb;

  const UrineResult({
    required this.color,
    required this.ph,
    required this.protein,
    required this.glucose,
    this.rawRgb,
  });
}

/// Patient registration data captured at Step 1 (Registration).
class PatientInfo {
  final String id;
  final String name;
  final int age;
  final String gender;
  final String phone;
  final String? village;

  const PatientInfo({
    required this.id,
    required this.name,
    required this.age,
    required this.gender,
    required this.phone,
    this.village,
  });

  factory PatientInfo.placeholder() => PatientInfo(
        id: 'PT-${DateTime.now().millisecondsSinceEpoch.toString().substring(8)}',
        name: '',
        age: 0,
        gender: '',
        phone: '',
      );
}

// ──────────────────────────────────────────────────────────────────────────────
// TRIAGE PROVIDER — Central State & Navigation Vault
// ──────────────────────────────────────────────────────────────────────────────

class TriageProvider extends ChangeNotifier {
  // ── Page Navigation ──────────────────────────────────────────────────────

  final PageController pageController = PageController();

  int _currentPage = 0;
  int get currentPage => _currentPage;

  static const int totalPages = 7;

  static const int pageBase = 0;
  static const int pageRegister = 1;
  static const int pageSteth = 2;
  static const int pageEcg = 3;
  static const int pageSpo2Temp = 4;
  static const int pageUrine = 5;
  static const int pageResult = 6;

  // ── Patient Info ─────────────────────────────────────────────────────────

  PatientInfo _patientInfo = PatientInfo.placeholder();
  PatientInfo get patientInfo => _patientInfo;

  void setPatientInfo(PatientInfo info) {
    _patientInfo = info;
    notifyListeners();
  }

  void setGender(String? gender) {
    if (gender == null || gender.isEmpty) return;
    _patientInfo = PatientInfo(
      id: _patientInfo.id,
      name: _patientInfo.name,
      age: _patientInfo.age,
      gender: gender,
      phone: _patientInfo.phone,
      village: _patientInfo.village,
    );
    notifyListeners();
  }

  // ── Step States ──────────────────────────────────────────────────────────

  ScanStatus _stethStatus = ScanStatus.initial;
  ScanStatus get stethStatus => _stethStatus;

  ScanStatus _ecgStatus = ScanStatus.initial;
  ScanStatus get ecgStatus => _ecgStatus;

  ScanStatus _spo2TempStatus = ScanStatus.initial;
  ScanStatus get spo2TempStatus => _spo2TempStatus;

  ScanStatus _urineStatus = ScanStatus.initial;
  ScanStatus get urineStatus => _urineStatus;

  // ── Step Results ─────────────────────────────────────────────────────────

  StethResult? _stethResult;
  StethResult? get stethResult => _stethResult;

  EcgResult? _ecgResult;
  EcgResult? get ecgResult => _ecgResult;

  Spo2TempResult? _spo2TempResult;
  Spo2TempResult? get spo2TempResult => _spo2TempResult;

  UrineResult? _urineResult;
  UrineResult? get urineResult => _urineResult;

  // ════════════════════════════════════════════════════════════════════════
  // HARDWARE DATA APPLIERS (Direct Hardware Telemetry Ingestion)
  // ════════════════════════════════════════════════════════════════════════

  // ── 1. Stethoscope (Dataset Bounds: HR 65 - 160) ────────────────────────
  void applyStethData({
    double heartRate = 72.0,
    String lungSound = 'Clear',
    ScanStatus status = ScanStatus.clean,
  }) {
    _stethResult = StethResult(
      heartRate: heartRate,
      lungSound: lungSound,
    );
    _stethStatus = status;
    notifyListeners();
  }

  void resetStethScan() {
    _stethStatus = ScanStatus.initial;
    _stethResult = null;
    notifyListeners();
  }

  // ── 2. ECG (Dataset Bounds: HR 65 - 160) ────────────────────────────────
  void applyEcgData({
    double heartRate = 72.0,
    String rhythm = 'Normal Sinus',
    double qtInterval = 400.0,
    ScanStatus status = ScanStatus.clean,
  }) {
    _ecgResult = EcgResult(
      heartRate: heartRate,
      rhythm: rhythm,
      qtInterval: qtInterval,
    );
    _ecgStatus = status;
    notifyListeners();
  }

  void resetEcgScan() {
    _ecgStatus = ScanStatus.initial;
    _ecgResult = null;
    notifyListeners();
  }

  // ── 3. SpO2 + Temp (Dataset Bounds: SpO2 70-100, HR 65-160, Temp 36.5-38.8) ──
  void applySpo2TempData({
    int spo2 = 98,
    int heartRate = 72,
    double temperature = 36.8,
    ScanStatus status = ScanStatus.clean,
  }) {
    _spo2TempResult = Spo2TempResult(
      spo2: spo2,
      heartRate: heartRate,
      temperature: temperature,
    );
    _spo2TempStatus = status;
    notifyListeners();
  }

  void resetSpo2TempScan() {
    _spo2TempStatus = ScanStatus.initial;
    _spo2TempResult = null;
    notifyListeners();
  }

  // ── 4. Urine Scan ───────────────────────────────────────────────────────
  void applyUrineData({
    String color = 'Yellow',
    double ph = 6.5,
    String protein = 'Negative',
    String glucose = 'Negative',
    List<double>? rawRgb,
    ScanStatus status = ScanStatus.clean,
  }) {
    _urineResult = UrineResult(
      color: color,
      ph: ph,
      protein: protein,
      glucose: glucose,
      rawRgb: rawRgb,
    );
    _urineStatus = status;
    notifyListeners();
  }

  void resetUrineScan() {
    _urineStatus = ScanStatus.initial;
    _urineResult = null;
    notifyListeners();
  }

  // ════════════════════════════════════════════════════════════════════════
  // AGGREGATE EVALUATION & NAVIGATION
  // ════════════════════════════════════════════════════════════════════════

  bool get hasAnyAbnormal =>
      _stethStatus == ScanStatus.abnormal ||
      _ecgStatus == ScanStatus.abnormal ||
      _spo2TempStatus == ScanStatus.abnormal ||
      _urineStatus == ScanStatus.abnormal;

  bool get allTestsComplete =>
      _stethStatus != ScanStatus.initial &&
      _ecgStatus != ScanStatus.initial &&
      _spo2TempStatus != ScanStatus.initial &&
      _urineStatus != ScanStatus.initial;

  // ════════════════════════════════════════════════════════════════════════
  // JSON PAYLOAD GENERATOR (For API Sync)
  // ════════════════════════════════════════════════════════════════════════

  List<double> _getUrineRgb(String? color) {
    switch (color?.toLowerCase()) {
      case 'red':
        return [255.0, 0.0, 0.0];
      case 'dark brown':
        return [101.0, 67.0, 33.0];
      case 'amber':
        return [255.0, 191.0, 0.0];
      case 'pale yellow':
        return [255.0, 255.0, 224.0];
      default:
        return [255.0, 255.0, 0.0];
    }
  }

  Map<String, dynamic> generateVitalsJsonPayload() {
    final String activeId = (_patientInfo.id.isEmpty || _patientInfo.id == 'PT-0000' || _patientInfo.id == 'PT-0001')
        ? 'PT-${DateTime.now().millisecondsSinceEpoch.toString().substring(8)}'
        : _patientInfo.id;
    return {
      "patient_id": activeId,
      "timestamp": DateTime.now().toIso8601String(),
      "stethoscope_status": _stethStatus.name,
      "ecg_hr": (_ecgResult?.heartRate ?? _stethResult?.heartRate ?? 72.0).toDouble(),
      "spo2": (_spo2TempResult?.spo2 ?? 98).toDouble(),
      "temperature": (_spo2TempResult?.temperature ?? 36.8).toDouble(),
      "urine_rgb": _urineResult?.rawRgb ?? _getUrineRgb(_urineResult?.color),
      "patient_speech_text":
          "Auscultation: ${_stethResult?.lungSound ?? 'Clear'}. ECG Rhythm: ${_ecgResult?.rhythm ?? 'Normal Sinus'}.",
    };
  }

  Map<String, dynamic> generateTriageJsonPayload() {
    final String activeId = (_patientInfo.id.isEmpty || _patientInfo.id == 'PT-0000' || _patientInfo.id == 'PT-0001')
        ? 'PT-${DateTime.now().millisecondsSinceEpoch.toString().substring(8)}'
        : _patientInfo.id;
    return {
      "patient_id": activeId,
      "timestamp": DateTime.now().toIso8601String(),
      "triage": hasAnyAbnormal ? "RED" : "GREEN",
      "confidence": hasAnyAbnormal ? 0.88 : 0.96,
    };
  }

  Map<String, dynamic> generateJsonPayload() {
    return {
      "vitals": generateVitalsJsonPayload(),
      "triage": generateTriageJsonPayload(),
    };
  }

  /// Enforces hard validation rules matching AI training dataset bounds:
  /// - SpO2: 70 to 100
  /// - Heart Rate: 65 to 160
  /// - Temperature: 36.5 to 38.8
  ///
  /// Returns validation error string if out of bounds, or null if valid.
  static String? validateDatasetBounds({
    num? spo2,
    num? heartRate,
    num? temperature,
  }) {
    if (spo2 != null && (spo2 < 70 || spo2 > 100)) {
      return "SpO2 ($spo2%) out of dataset bounds (70 - 100)";
    }
    if (heartRate != null && (heartRate < 65 || heartRate > 160)) {
      return "Heart Rate ($heartRate BPM) out of dataset bounds (65 - 160)";
    }
    if (temperature != null && (temperature < 36.5 || temperature > 38.8)) {
      return "Temperature ($temperature°C) out of dataset bounds (36.5 - 38.8)";
    }
    return null;
  }

  /// Sends triage data to cloud API. Ensures a fresh dynamic ID is generated right before sync.
  Future<bool> syncDataToCloud() async {
    if (_patientInfo.id.isEmpty || _patientInfo.id == 'PT-0000' || _patientInfo.id == 'PT-0001') {
      final String freshId = 'PT-${DateTime.now().millisecondsSinceEpoch.toString().substring(8)}';
      _patientInfo = PatientInfo(
        id: freshId,
        name: _patientInfo.name,
        age: _patientInfo.age,
        gender: _patientInfo.gender,
        phone: _patientInfo.phone,
        village: _patientInfo.village,
      );
    }

    // Validate hard dataset bounds
    final String? boundsError = validateDatasetBounds(
      spo2: _spo2TempResult?.spo2,
      heartRate: _stethResult?.heartRate ?? _ecgResult?.heartRate ?? _spo2TempResult?.heartRate,
      temperature: _spo2TempResult?.temperature,
    );

    if (boundsError != null) {
      debugPrint("⛔ [VALIDATION_ERR] Submission blocked: $boundsError");
      return false;
    }

    final payload = generateJsonPayload();
    return await ApiService.pushTriageData(payload);
  }

  /// Dedicated method to save current session data directly to Cloud Backend
  /// (https://raksha-api-71a6.onrender.com).
  Future<SaveToCloudResult> saveToCloud() async {
    if (_patientInfo.id.isEmpty || _patientInfo.id == 'PT-0000' || _patientInfo.id == 'PT-0001') {
      final String freshId = 'PT-${DateTime.now().millisecondsSinceEpoch.toString().substring(8)}';
      _patientInfo = PatientInfo(
        id: freshId,
        name: _patientInfo.name,
        age: _patientInfo.age,
        gender: _patientInfo.gender,
        phone: _patientInfo.phone,
        village: _patientInfo.village,
      );
    }

    final payload = generateJsonPayload();
    return await ApiService.saveToCloud(payload);
  }

  void goToNextStep() {
    if (_currentPage < totalPages - 1) {
      _currentPage++;
      pageController.animateToPage(
        _currentPage,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeInOut,
      );
      notifyListeners();
    }
  }

  void goToPreviousStep() {
    if (_currentPage > 0) {
      _currentPage--;
      pageController.animateToPage(
        _currentPage,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeInOut,
      );
      notifyListeners();
    }
  }

  void goToPage(int index) {
    if (index >= 0 && index < totalPages) {
      _currentPage = index;
      pageController.animateToPage(
        _currentPage,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeInOut,
      );
      notifyListeners();
    }
  }

  void resetAll() {
    _currentPage = 0;
    _patientInfo = PatientInfo.placeholder();

    _stethStatus = ScanStatus.initial;
    _ecgStatus = ScanStatus.initial;
    _spo2TempStatus = ScanStatus.initial;
    _urineStatus = ScanStatus.initial;

    _stethResult = null;
    _ecgResult = null;
    _spo2TempResult = null;
    _urineResult = null;

    if (pageController.hasClients) {
      pageController.jumpToPage(0);
    }
    notifyListeners();
  }

  @override
  void dispose() {
    pageController.dispose();
    super.dispose();
  }
}
