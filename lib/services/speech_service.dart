import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:vosk_flutter/vosk_flutter.dart' as vosk;

// ─────────────────────────────────────────────────────────────────────────────
// AppSpeechService
//
// Wraps the vosk_flutter plugin for 100% offline speech-to-text recognition.
// Strict memory management: models and recognizers are created on demand when
// listening starts and explicitly disposed when listening stops or UI is popped.
// ─────────────────────────────────────────────────────────────────────────────

class AppSpeechService {
  static final AppSpeechService _instance = AppSpeechService._internal();
  factory AppSpeechService() => _instance;
  AppSpeechService._internal();

  final _voskPlugin = vosk.VoskFlutterPlugin.instance();
  
  vosk.Model? _model;
  vosk.Recognizer? _recognizer;
  vosk.SpeechService? _voskSpeechService;

  bool _isInitialized = false;
  bool _isListening = false;
  bool get isListening => _isListening;

  static const String _modelZipPath = 'assets/models/vosk-model-small-en-us-0.15.zip';

  /// Ensures microphone permission is granted before attempting audio recording.
  Future<bool> requestMicrophonePermission() async {
    try {
      final status = await Permission.microphone.request();
      if (!status.isGranted) {
        debugPrint('⚠️ [AppSpeechService] Microphone permission not granted: $status');
        return false;
      }
      return true;
    } catch (e) {
      debugPrint('⚠️ [AppSpeechService] Permission request error: $e');
      return false;
    }
  }

  /// Initializes the Vosk model and recognizer from the bundled zip asset.
  Future<void> initialize() async {
    if (_isInitialized) return;
    
    try {
      final modelPath = await vosk.ModelLoader().loadFromAssets(_modelZipPath);
      _model = await _voskPlugin.createModel(modelPath);
      _recognizer = await _voskPlugin.createRecognizer(model: _model!, sampleRate: 16000);
      _voskSpeechService = await _voskPlugin.initSpeechService(_recognizer!);
      
      _isInitialized = true;
      debugPrint('✅ [AppSpeechService] Vosk offline STT initialized successfully.');
    } catch (e, stack) {
      debugPrint('❌ [AppSpeechService] Failed to initialize Vosk: $e\n$stack');
    }
  }

  /// Starts listening to the microphone and streams partial/final results.
  /// Returns a Stream of String transcripts.
  Stream<String>? startListening() {
    if (!_isInitialized || _voskSpeechService == null) {
      debugPrint('⚠️ [AppSpeechService] Cannot start listening: Not initialized.');
      return null;
    }

    try {
      _voskSpeechService!.start();
      _isListening = true;
      
      return _voskSpeechService!.onResult().map<String>((event) {
        try {
          final Map<String, dynamic> data = jsonDecode(event.toString());
          return (data['text'] ?? '').toString();
        } catch (_) {
          return '';
        }
      }).where((text) => text.isNotEmpty);
    } catch (e) {
      debugPrint('❌ [AppSpeechService] Error starting speech service: $e');
      return null;
    }
  }

  /// Stops listening to the microphone.
  Future<void> stopListening() async {
    if (!_isListening || _voskSpeechService == null) return;
    try {
      await _voskSpeechService!.stop();
      _isListening = false;
    } catch (e) {
      debugPrint('❌ [AppSpeechService] Error stopping speech service: $e');
    }
  }

  /// Strictly disposes of the recognizer, model, and service to free C++ heap memory.
  /// This MUST be called when the UI is popped or app is backgrounded to prevent leaks.
  Future<void> dispose() async {
    await stopListening();
    
    try {
      _voskSpeechService?.dispose(); // Might be void, so no await
      _recognizer?.dispose(); // Might be void, so no await
      _model?.dispose(); // Might be void, so no await
      
      _voskSpeechService = null;
      _recognizer = null;
      _model = null;
      _isInitialized = false;
      
      debugPrint('🗑️ [AppSpeechService] Vosk resources explicitly freed.');
    } catch (e) {
      debugPrint('❌ [AppSpeechService] Error disposing Vosk: $e');
    }
  }
}
