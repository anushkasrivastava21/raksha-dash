import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:tflite_flutter/tflite_flutter.dart';

// ─────────────────────────────────────────────────────────────────────────────
// InferenceService
//
// Wraps Anirudh's compiled TFLite models (ECG CNN + Urine CNN) with a
// lazy-singleton pattern.  Interpreters are allocated once on first call and
// reused across the app lifetime.
//
// Model contract (from experiment_MED/model_analysis.md):
//   ECG CNN  : input  float32 (1, 1, 256) — 256 normalised ECG samples
//              output float32 (1, 2)      — logits [Normal, Arrhythmia]
//              argmax → 0 = Normal, 1 = Arrhythmia
//
//   Urine CNN: input  float32 (1, 3)      — normalised [R, G, B] (0–255)
//              output float32 (1, 2)      — logits [Normal, Abnormal]
//              argmax → 0 = Normal, 1 = Abnormal
//
// Error handling: every inference call is wrapped in try-catch.  On failure
// the function logs the error and safely returns a non-critical default
// (false / 1.0 = Normal) so the live demo never crashes.
// ─────────────────────────────────────────────────────────────────────────────

class InferenceService {
  // ── Singleton ──────────────────────────────────────────────────────────────
  static final InferenceService _instance = InferenceService._internal();
  factory InferenceService() => _instance;
  InferenceService._internal();

  // ── Interpreter State ─────────────────────────────────────────────────────
  Interpreter? _ecgInterpreter;
  Interpreter? _urineInterpreter;
  bool _isInitialized = false;

  // ── Asset Paths ───────────────────────────────────────────────────────────
  static const String _ecgModelPath = 'assets/models/ecg_cnn.tflite';
  static const String _urineModelPath = 'assets/models/urine_cnn.tflite';

  // ── ECG Signal Constants (from ecg_processor.py / model_analysis.md) ─────
  /// Expected number of normalised ECG samples per inference window.
  static const int ecgWindowSize = 256;

  // ─────────────────────────────────────────────────────────────────────────
  // Initialisation
  // ─────────────────────────────────────────────────────────────────────────

  /// Lazily loads both interpreters from Flutter asset bundle.
  /// Safe to call multiple times — subsequent calls are no-ops.
  Future<void> initialize() async {
    if (_isInitialized) return;
    await Future.wait([
      _loadEcgInterpreter(),
      _loadUrineInterpreter(),
    ]);
    _isInitialized = true;
    debugPrint('✅ [InferenceService] Both TFLite interpreters initialised.');
  }

  Future<void> _loadEcgInterpreter() async {
    try {
      final rawBytes = await rootBundle.load(_ecgModelPath);
      final bytes = rawBytes.buffer.asUint8List();
      _ecgInterpreter = Interpreter.fromBuffer(bytes);
      debugPrint('🧠 [InferenceService] ECG CNN loaded (${bytes.length} bytes).');
    } catch (e, stack) {
      debugPrint('❌ [InferenceService] Failed to load ECG model: $e\n$stack');
      _ecgInterpreter = null;
    }
  }

  Future<void> _loadUrineInterpreter() async {
    try {
      final rawBytes = await rootBundle.load(_urineModelPath);
      final bytes = rawBytes.buffer.asUint8List();
      _urineInterpreter = Interpreter.fromBuffer(bytes);
      debugPrint('🧠 [InferenceService] Urine CNN loaded (${bytes.length} bytes).');
    } catch (e, stack) {
      debugPrint('❌ [InferenceService] Failed to load Urine model: $e\n$stack');
      _urineInterpreter = null;
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // ECG Inference
  // ─────────────────────────────────────────────────────────────────────────

  /// Accepts a list of raw ECG ADC sample floats from the BLE payload.
  ///
  /// Pre-processing (mirrors ecg_processor.py):
  ///   1. Trim or zero-pad to [ecgWindowSize] samples.
  ///   2. Zero-mean normalisation.
  ///   3. Peak normalisation (divide by max absolute value).
  ///
  /// Returns `true` if the model predicts Arrhythmia (class index 1),
  /// `false` if Normal. Defaults to `false` on any inference error.
  Future<bool> runEcgInference(List<double> rawSamples) async {
    if (_ecgInterpreter == null) {
      debugPrint('⚠️ [InferenceService] ECG interpreter unavailable — defaulting to Normal.');
      return false;
    }

    try {
      // ── 1. Prepare input tensor: shape (1, 1, 256) ──────────────────────
      final samples = _prepareEcgWindow(rawSamples);

      // TFLite expects a nested List matching the tensor shape.
      // Shape: [batch=1, channels=1, length=256]
      final input = [
        [samples]
      ];
      // Output: [batch=1, classes=2]
      final output = [List.filled(2, 0.0)];

      _ecgInterpreter!.run(input, output);

      final logits = output[0]; // [Normal, Arrhythmia]
      final isArrhythmia = logits[1] > logits[0];

      debugPrint(
        '🫀 [ECG Inference] logits=${logits.map((v) => v.toStringAsFixed(3)).toList()} '
        '→ ${isArrhythmia ? "ARRHYTHMIA" : "Normal Sinus Rhythm"}',
      );
      return isArrhythmia;
    } catch (e, stack) {
      debugPrint('❌ [InferenceService] ECG inference error: $e\n$stack');
      return false; // Safe default: non-critical, do not crash demo
    }
  }

  /// Normalises and pads/trims the raw sample list to [ecgWindowSize].
  List<double> _prepareEcgWindow(List<double> raw) {
    // Trim or zero-pad to ecgWindowSize
    final padded = List<double>.filled(ecgWindowSize, 0.0);
    final len = raw.length < ecgWindowSize ? raw.length : ecgWindowSize;
    for (int i = 0; i < len; i++) {
      padded[i] = raw[i];
    }

    // Zero-mean
    final mean = padded.reduce((a, b) => a + b) / padded.length;
    for (int i = 0; i < padded.length; i++) {
      padded[i] -= mean;
    }

    // Peak normalisation
    double maxAbs = padded.map((v) => v.abs()).reduce((a, b) => a > b ? a : b);
    if (maxAbs > 0) {
      for (int i = 0; i < padded.length; i++) {
        padded[i] /= maxAbs;
      }
    }
    return padded;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Urine Inference
  // ─────────────────────────────────────────────────────────────────────────

  /// Accepts raw R, G, B floats from the BLE urine colorimetric sensor.
  ///
  /// Pre-processing (mirrors urine_processor.py):
  ///   Clamp each channel to 0–255 (ADC values already normalised by BLE firmware).
  ///
  /// Returns a severity float:
  ///   `1.0` = Normal (model predicts class 0)
  ///   `2.0` = Abnormal (model predicts class 1)
  ///
  /// Falls back to `1.0` (Normal) on any inference error.
  Future<double> runUrineInference(List<double> rgb) async {
    if (_urineInterpreter == null) {
      debugPrint('⚠️ [InferenceService] Urine interpreter unavailable — defaulting to Normal.');
      return 1.0;
    }

    if (rgb.length < 3) {
      debugPrint('⚠️ [InferenceService] Urine RGB list too short (${rgb.length}) — defaulting Normal.');
      return 1.0;
    }

    try {
      // Input shape: (1, 3) — normalised [R, G, B]
      final r = rgb[0].clamp(0.0, 255.0);
      final g = rgb[1].clamp(0.0, 255.0);
      final b = rgb[2].clamp(0.0, 255.0);

      final input = [
        [r, g, b]
      ];
      final output = [List.filled(2, 0.0)];

      _urineInterpreter!.run(input, output);

      final logits = output[0]; // [Normal, Abnormal]
      final isAbnormal = logits[1] > logits[0];

      final severity = isAbnormal ? 2.0 : 1.0;
      debugPrint(
        '🧪 [Urine Inference] RGB=[$r,$g,$b] logits=${logits.map((v) => v.toStringAsFixed(3)).toList()} '
        '→ severity=$severity',
      );
      return severity;
    } catch (e, stack) {
      debugPrint('❌ [InferenceService] Urine inference error: $e\n$stack');
      return 1.0; // Safe default: Normal
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Lifecycle
  // ─────────────────────────────────────────────────────────────────────────

  /// Releases interpreter resources. Call from app dispose if needed.
  void dispose() {
    _ecgInterpreter?.close();
    _urineInterpreter?.close();
    _ecgInterpreter = null;
    _urineInterpreter = null;
    _isInitialized = false;
    debugPrint('🗑️ [InferenceService] Interpreters released.');
  }
}
