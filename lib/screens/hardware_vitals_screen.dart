import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/vitals_model.dart';
import '../providers/triage_state.dart';
import '../providers/triage_provider.dart';
import '../patient_provider.dart';
import '../services/ble_service.dart';
import '../services/speech_service.dart';
import '../services/api_service.dart';
import '../services/keyword_extractor.dart';
import '../widgets/app_header.dart';
import 'telemetry_sync_screen.dart';
import 'triage_result_screen.dart';

/// Native Flutter implementation of Dashboard 1 (Empty State - RAW VITALS).
/// Mobile-constrained layout matching original HTML/CSS design specification.
class RakshaHardwareVitalsScreen extends StatefulWidget {
  final VoidCallback? onExecuteTriage;

  const RakshaHardwareVitalsScreen({
    super.key,
    this.onExecuteTriage,
  });

  @override
  State<RakshaHardwareVitalsScreen> createState() => _RakshaHardwareVitalsScreenState();
}

class _RakshaHardwareVitalsScreenState extends State<RakshaHardwareVitalsScreen> {
  // Color constants matching Dashboard 1 HTML/CSS specification
  static const Color _surfaceContainerLow = Color(0xFFF6F3F2);
  static const Color _surfaceContainerLowest = Color(0xFFFFFFFF);
  static const Color _primaryCobalt = Color(0xFF004AC6);
  static const Color _primaryContainer = Color(0xFF2563EB);
  static const Color _onSurface = Color(0xFF1C1B1B);
  static const Color _outline = Color(0xFF737686);
  static const Color _outlineVariant = Color(0xFFC3C6D7);
  static const Color _borderGray = Color(0xFFE5E7EB);
  static const Color _completedBg = Color(0xFFDFF5E1);
  static const Color _completedGreen = Color(0xFF34A853);

  String _rawBleData = "";
  bool _isConnecting = false;

  // Speech integration state
  StreamSubscription<String>? _speechSubscription;
  bool _isListening = false;
  String _liveTranscript = "";
  StreamSubscription<String>? _bleSubscription;

  // ── Force Pass helpers ──────────────────────────────────────────────────
  // Injects a clinically valid random payload for the selected sensor only.
  // All other sensor values and triage logic are completely unaffected.
  void _forcePassSensor(VitalTestType type) {
    final triageProvider = context.read<TriageProvider>();
    final triageState = context.read<TriageState>();
    final rng = DateTime.now().millisecondsSinceEpoch;

    switch (type) {
      case VitalTestType.spo2:
        // SpO2: 94–99%, HR: 68–95 BPM
        final spo2 = 94 + (rng % 6);
        final hr = 68 + (rng % 28);
        triageProvider.updateFromBleJson('SPO2', '{"spo2_percent":$spo2,"heart_rate_bpm":$hr,"ir_raw":120000}');
        triageState.markCompleted(VitalTestType.spo2, reading: '$spo2%');
        break;
      case VitalTestType.hr:
        // ECG: HR 68–95 BPM, Normal Sinus
        final hr = 68 + (rng % 28);
        triageProvider.updateFromBleJson('ECG', '{"heart_rate_bpm":$hr,"hr":$hr,"rhythm":"Normal Sinus","qt":400}');
        triageState.markCompleted(VitalTestType.hr, reading: '$hr BPM');
        break;
      case VitalTestType.temp:
        // Temp: 36.6–37.2°C
        final temp = (366 + (rng % 7)) / 10.0;
        triageProvider.updateFromBleJson('TEMP', '{"body_temp_c":$temp}');
        triageState.markCompleted(VitalTestType.temp, reading: '$temp°C');
        break;
      case VitalTestType.urine:
        // Urine: healthy pale yellow
        triageProvider.updateFromBleJson('URINE', '{"red":3100,"green":3000,"blue":2700}');
        triageState.markCompleted(VitalTestType.urine, reading: 'RGB(3100,3000,2700)');
        break;
      case VitalTestType.stethoscope:
        // Steth: moderate RMS
        triageProvider.updateFromBleJson('STETH', '{"rms":1800,"min":0,"max":3500,"samples":50}');
        triageState.markCompleted(VitalTestType.stethoscope, reading: 'RMS: 1800');
        break;
      case VitalTestType.voice:
        // Voice: inject a benign transcript
        triageProvider.setPatientTranscript('Patient reports no symptoms.');
        triageState.markCompleted(VitalTestType.voice, reading: 'FORCE PASS');
        break;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('⚡ Force Pass: ${type.name.toUpperCase()} injected'),
        backgroundColor: const Color(0xFF004AC6),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _bleSubscription = BleService().rawDataStream.listen((data) {
      if (mounted) {
        setState(() {
          _rawBleData = data;
        });

        // The exact break in the pipeline: Parse telemetry and update UI state!
        try {
          final int firstPipe = data.indexOf('|');
          if (firstPipe > 0) {
            final sensorCode = data.substring(0, firstPipe).trim();
            final jsonPayload = data.substring(firstPipe + 1).trim();
            
            final triageProvider = context.read<TriageProvider>();
            final triageState = context.read<TriageState>();
            
            // 1. Update the actual values in the data provider
            triageProvider.updateFromBleJson(sensorCode, jsonPayload);
            
            // 2. Extract specific values for the UI State Completion checkmarks
            final Map<String, dynamic> parsed = jsonDecode(jsonPayload);
            switch (sensorCode) {
              case 'SPO2':
              case 'MAX30102':
                // Removed passive auto-complete logic here.
                // It is now precisely handled by telemetry_sync_screen.dart to ensure SpO2 and ECG stay separate.
                break;
              case 'TEMP':
              case 'MLX90614':
                if (parsed.containsKey('body_temp_c')) {
                  triageState.markCompleted(VitalTestType.temp, reading: "${parsed['body_temp_c']}°C");
                }
                break;
              case 'URINE':
                if (parsed.containsKey('red') && parsed.containsKey('green') && parsed.containsKey('blue')) {
                  triageState.markCompleted(VitalTestType.urine, reading: "RGB(${parsed['red']}, ${parsed['green']}, ${parsed['blue']})");
                }
                break;
              case 'ECG':
              case 'HR':
                // Auto-complete handled in telemetry_sync_screen.dart
                break;
              case 'STETH':
                if (parsed.containsKey('rms')) {
                  triageState.markCompleted(VitalTestType.stethoscope, reading: "RMS: ${parsed['rms']}");
                }
                break;
              case 'ERR':
                if (parsed.containsKey('sensor') && parsed['sensor'] == 'TEMP') {
                  // TODO (Hardware Update): Bypassing broken MLX90614 sensor
                  triageState.markCompleted(VitalTestType.temp, reading: "37.0°C (BYPASS)");
                }
                break;
            }
          }
        } catch (e) {
          debugPrint("UI telemetry parsing error: $e");
        }
      }
    });
    // Preload speech model
    AppSpeechService().initialize();
  }

  @override
  void dispose() {
    _bleSubscription?.cancel();
    _speechSubscription?.cancel();
    AppSpeechService().dispose(); // Strict memory release on pop
    super.dispose();
  }

  Future<void> _toggleMicrophone() async {
    final speechService = AppSpeechService();
    final triageState = context.read<TriageState>();
    final triageProvider = context.read<TriageProvider>();

    if (_isListening) {
      await speechService.stopListening();
      _speechSubscription?.cancel();
      
      setState(() {
        _isListening = false;
      });

      final String cleanTranscript = _liveTranscript.trim();

      // UN-MOCK / STRICT VALIDATION:
      // If no speech was captured, DO NOT mark the card as completed!
      if (cleanTranscript.isEmpty) {
        debugPrint('⚠️ [VoicePipeline] Empty audio transcript. Resetting voice state to empty.');
        triageState.markEmpty(VitalTestType.voice);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('No speech detected. Please speak into the mic.'),
              duration: Duration(seconds: 2),
            ),
          );
        }
        return;
      }

      // 1. Ingest real transcript into central state
      triageProvider.setPatientTranscript(cleanTranscript);

      // 2. On-Device inference using Anirudh's negation-aware clinical model
      final List<String> detectedSymptoms = KeywordExtractor.extractSymptoms(cleanTranscript);
      debugPrint('🎙️ [VoicePipeline] Real transcript: "$cleanTranscript"');
      debugPrint('🧠 [VoicePipeline] Anirudh local extractor detected: $detectedSymptoms');

      // 3. Connect to Anirudh's backend ML Engine (/predict) if online/reachable
      ApiService.predictWithMlEngine(
        patientId: triageProvider.patientInfo.id,
        patientSpeechText: cleanTranscript,
        spo2: triageProvider.spo2TempResult?.spo2.toDouble(),
        temperature: triageProvider.spo2TempResult?.temperature,
        ecgHr: (triageProvider.ecgResult?.heartRate ?? triageProvider.stethResult?.heartRate),
        urineRgb: triageProvider.urineResult?.rawRgb,
      ).then((mlResult) {
        if (mlResult != null) {
          final serverSymptoms = mlResult['symptoms'] is List
              ? List<String>.from(mlResult['symptoms'])
              : <String>[];
          final serverTriage = mlResult['triage']?.toString();

          // ✅ NOW WIRED: feed server symptoms + triage signal back into the provider
          triageProvider.setServerSymptoms(serverSymptoms, triageColor: serverTriage);

          debugPrint('☁️ [VoicePipeline] ML Engine responded — symptoms: $serverSymptoms, triage: $serverTriage');

          // Update the voice card reading to reflect server-augmented symptom count
          if (mounted && serverSymptoms.isNotEmpty) {
            final allSymptoms = {...detectedSymptoms, ...serverSymptoms};
            context.read<TriageState>().markCompleted(
              VitalTestType.voice,
              reading: cleanTranscript.length > 18 ? "${cleanTranscript.substring(0, 18)}..." : cleanTranscript,
            );
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('☁️ ML Engine: ${allSymptoms.join(", ")}'),
                backgroundColor: const Color(0xFF004AC6),
                duration: const Duration(seconds: 4),
              ),
            );
          }
        } else {
          debugPrint('⚠️ [VoicePipeline] ML Engine unreachable — using on-device results only.');
        }
      });

      // 4. Mark completed ONLY when real speech data has been extracted
      final String readingLabel = cleanTranscript.isNotEmpty
          ? (cleanTranscript.length > 18 ? "${cleanTranscript.substring(0, 18)}..." : cleanTranscript)
          : "VOICE RECORDED";
      triageState.markCompleted(VitalTestType.voice, reading: readingLabel);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              detectedSymptoms.isNotEmpty
                  ? 'Symptoms Detected: ${detectedSymptoms.join(", ")}'
                  : 'Recorded: "$cleanTranscript"',
            ),
            backgroundColor: const Color(0xFF1E8E3E),
            duration: const Duration(seconds: 3),
          ),
        );
      }

    } else {
      // Ensure microphone permission is granted before starting
      final bool hasPermission = await speechService.requestMicrophonePermission();
      if (!hasPermission) {
        debugPrint('❌ [VoicePipeline] Microphone permission denied.');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Microphone permission required for voice triage.'),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }

      await speechService.initialize(); // Initialize here, AFTER permissions are granted!

      setState(() {
        _isListening = true;
        _liveTranscript = "";
      });
      
      triageState.markLoading(VitalTestType.voice);
      
      final stream = speechService.startListening();
      if (stream != null) {
        _speechSubscription = stream.listen((transcript) {
          if (mounted) {
            setState(() {
              if (_liveTranscript.isNotEmpty) {
                _liveTranscript += " $transcript";
              } else {
                _liveTranscript = transcript;
              }
            });
            triageProvider.setPatientTranscript(_liveTranscript);
          }
        });
      } else {
        setState(() {
          _isListening = false;
        });
        triageState.markEmpty(VitalTestType.voice);
      }
    }
  }

  void _navigateToTest(BuildContext context, VitalTestType type) {
    if (type == VitalTestType.voice) {
      _toggleMicrophone();
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => DynamicTestLoaderScreen(testType: type),
      ),
    );
  }

  Future<void> _handleExecuteTriage(BuildContext context) async {
    if (widget.onExecuteTriage != null) {
      widget.onExecuteTriage!();
      return;
    }

    final triageProvider = Provider.of<TriageProvider>(context, listen: false);
    
    // NEW ARCHITECTURE: Send Voice Keywords to ESP32
    final keywords = KeywordExtractor.extractSymptoms(triageProvider.patientTranscript);
    if (keywords.isNotEmpty) {
      final csv = keywords.join(',');
      await BleService().sendCommand("VOICE_KW:$csv\n");
      await Future.delayed(const Duration(milliseconds: 500));
    }
    
    // Request Triage from ESP32 -> Pi -> ESP32 -> Phone
    await BleService().sendCommand("SEND_TRIAGE\n");
    
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(child: CircularProgressIndicator()),
    );
    
    // Poll for the result to come back over BLE
    for (int i = 0; i < 30; i++) {
      await Future.delayed(const Duration(milliseconds: 500));
      if (triageProvider.piTriageResult != null) {
        break;
      }
    }
    
    if (!context.mounted) return;
    Navigator.of(context).pop(); // Dismiss loading

    if (triageProvider.piTriageResult == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Triage timed out. ESP32/Pi did not respond.')),
      );
      return;
    }

    final payload = triageProvider.generateJsonPayload();
    
    // Overwrite local evaluation with Pi's evaluation
    payload['triage']['triage'] = triageProvider.serverTriageSignal ?? payload['triage']['triage'];
    payload['triage']['symptoms'] = triageProvider.serverSymptoms;
    payload['triage']['confidence'] = triageProvider.piTriageResult?['confidence_score'] ?? payload['triage']['confidence'];

    final VitalsModel result = VitalsModel.fromJson(payload);
    
    // MEWS SAFETY OVERRIDE
    final mewsEngine = PatientProvider();
    mewsEngine.updateVitals(
      hr: result.ecgHr,
      s: result.spo2,
      temp: result.temperature,
    );
    final mewsResult = mewsEngine.evaluateMews();

    if (!context.mounted) return;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => TriageResultScreen(vitals: result),
      ),
    );

    if (mewsResult["override"] == true && mewsResult["status"] == "RED") {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => MewsCriticalAlertScreen(reason: mewsResult["reason"]),
        ),
      );
    }
  }

  Future<void> _toggleBleConnection() async {
    final ble = BleService();
    if (ble.isConnected) {
      await ble.disconnect();
    } else {
      setState(() { _isConnecting = true; });
      await ble.connectToEsp32();
      setState(() { _isConnecting = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final triageState = context.watch<TriageState>();
    final triageProvider = context.watch<TriageProvider>();
    final bool isReady = triageState.isReadyForAI;

    return Scaffold(
      backgroundColor: const Color(0xFFF0EDEC), // Neutral desktop backdrop
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 430),
            child: Container(
              color: _surfaceContainerLowest,
              child: Column(
                children: [
                  // TOP APP BAR HEADER
                  const AppHeader(),

                  // BLE Connection Banner (PRD requirement: BLE connection established)
                  StreamBuilder<bool>(
                    stream: BleService().connectionStateStream,
                    initialData: BleService().isConnected,
                    builder: (context, snapshot) {
                      final isConnected = snapshot.data ?? false;
                      return Container(
                        color: isConnected ? _completedBg : const Color(0xFFFDE8E8),
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        child: Row(
                          children: [
                            Icon(
                              isConnected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
                              color: isConnected ? _completedGreen : Colors.red,
                              size: 20,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                isConnected ? "BLE Connected to ESP32" : "BLE Disconnected",
                                style: TextStyle(
                                  fontFamily: 'Space Mono',
                                  color: isConnected ? _completedGreen : Colors.red,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                            if (_isConnecting)
                              const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            else
                              TextButton(
                                onPressed: _toggleBleConnection,
                                child: Text(
                                  isConnected ? "DISCONNECT" : "CONNECT",
                                  style: const TextStyle(fontFamily: 'Space Mono', fontSize: 12),
                                ),
                              ),
                          ],
                        ),
                      );
                    }
                  ),

                  // MAIN CONTENT AREA
                  Expanded(
                    child: Container(
                      color: _surfaceContainerLow,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24.0,
                        vertical: 16.0,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // SECTION HEADER
                          const Text(
                            'RAW VITALS',
                            style: TextStyle(
                              fontFamily: 'Space Mono',
                              fontSize: 22,
                              fontWeight: FontWeight.w700,
                              color: _onSurface,
                              letterSpacing: -0.5,
                            ),
                          ),
                          const SizedBox(height: 12),

                          // GRID LAYOUT (Vitals Cards)
                          Expanded(
                            flex: 3,
                            child: Column(
                              children: [
                                // Row 1: SPO2 & HR
                                Expanded(
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: _buildCard(
                                          isCompleted: triageState.isCompleted(VitalTestType.spo2),
                                          icon: Icons.air,
                                          title: 'SPO2',
                                          sensor: 'SENSOR: MAX30102',
                                          reading: triageState.isCompleted(VitalTestType.spo2) ? triageState.getReading(VitalTestType.spo2) : null,
                                          onTap: () => _navigateToTest(context, VitalTestType.spo2),
                                          onForcePass: () => _forcePassSensor(VitalTestType.spo2),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                        Expanded(
                                          child: _buildCard(
                                            isCompleted: triageState.isCompleted(VitalTestType.hr),
                                            icon: Icons.monitor_heart_outlined,
                                            title: 'ECG',
                                            sensor: 'SENSOR: AD8232',
                                            reading: triageState.isCompleted(VitalTestType.hr) ? triageState.getReading(VitalTestType.hr) : null,
                                            onTap: () => _navigateToTest(context, VitalTestType.hr),
                                            onForcePass: () => _forcePassSensor(VitalTestType.hr),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 8),

                                // Row 2: TEMP & URINE
                                Expanded(
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: _buildCard(
                                          isCompleted: triageState.isCompleted(VitalTestType.temp),
                                          icon: Icons.thermostat,
                                          title: 'TEMP',
                                          sensor: 'SENSOR: MLX90614',
                                          reading: triageState.isCompleted(VitalTestType.temp) ? triageState.getReading(VitalTestType.temp) : null,
                                          onTap: () => _navigateToTest(context, VitalTestType.temp),
                                          onForcePass: () => _forcePassSensor(VitalTestType.temp),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: _buildCard(
                                          isCompleted: triageState.isCompleted(VitalTestType.urine),
                                          icon: Icons.science,
                                          title: 'URINE',
                                          sensor: 'SENSOR: STRIP-READER',
                                          reading: triageState.isCompleted(VitalTestType.urine) ? triageState.getReading(VitalTestType.urine) : null,
                                          onTap: () => _navigateToTest(context, VitalTestType.urine),
                                          onForcePass: () => _forcePassSensor(VitalTestType.urine),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 8),

                                // Row 3: STETHOSCOPE (Full Width)
                                Expanded(
                                  child: _buildCard(
                                    isCompleted: triageState.isCompleted(VitalTestType.stethoscope),
                                    icon: Icons.medical_services_outlined,
                                    title: 'STETHOSCOPE',
                                    sensor: 'SENSOR: PIEZO-MIC',
                                    reading: triageState.isCompleted(VitalTestType.stethoscope) ? triageState.getReading(VitalTestType.stethoscope) : null,
                                    onTap: () => _navigateToTest(context, VitalTestType.stethoscope),
                                    onForcePass: () => _forcePassSensor(VitalTestType.stethoscope),
                                  ),
                                ),
                              ],
                            ),
                          ),


                          // MIC / VOICE SECTION
                          const SizedBox(height: 10),
                          Column(
                            children: [
                              if (_isListening) ...
                                [
                                  // Live transcript preview
                                  if (_liveTranscript.isNotEmpty)
                                    Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
                                      child: Text(
                                        _liveTranscript,
                                        textAlign: TextAlign.center,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontFamily: 'Space Mono',
                                          fontSize: 11,
                                          color: Color(0xFF434655),
                                        ),
                                      ),
                                    ),
                                  // STOP & SUBMIT button — clearly visible when recording
                                  SizedBox(
                                    width: double.infinity,
                                    child: ElevatedButton.icon(
                                      onPressed: _toggleMicrophone,
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: Colors.red,
                                        foregroundColor: Colors.white,
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                                        padding: const EdgeInsets.symmetric(vertical: 12),
                                      ),
                                      icon: const Icon(Icons.stop_circle_outlined),
                                      label: const Text(
                                        'STOP & SUBMIT',
                                        style: TextStyle(fontFamily: 'Space Mono', fontWeight: FontWeight.w700),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                ]
                              else ...
                                [
                                  // Mic circle button
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      GestureDetector(
                                        onTap: () => _navigateToTest(context, VitalTestType.voice),
                                        onLongPress: () => _forcePassSensor(VitalTestType.voice),
                                        child: Container(
                                          width: 80.0,
                                          height: 80.0,
                                          decoration: BoxDecoration(
                                            color: triageState.isCompleted(VitalTestType.voice)
                                                ? _completedBg
                                                : Colors.white,
                                            shape: BoxShape.circle,
                                            border: Border.all(
                                              color: triageState.isCompleted(VitalTestType.voice)
                                                  ? _completedGreen
                                                  : _borderGray,
                                              width: triageState.isCompleted(VitalTestType.voice) ? 2.0 : 1.0,
                                            ),
                                            boxShadow: const [
                                              BoxShadow(
                                                color: Color(0x0D000000),
                                                blurRadius: 4,
                                                offset: Offset(0, 2),
                                              ),
                                            ],
                                          ),
                                          child: Icon(
                                            triageState.isCompleted(VitalTestType.voice)
                                                ? Icons.check_circle
                                                : Icons.mic,
                                            color: triageState.isCompleted(VitalTestType.voice)
                                                ? _completedGreen
                                                : _primaryContainer,
                                            size: 38,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  const Text(
                                    'Hold to Force Pass',
                                    style: TextStyle(
                                      fontFamily: 'Space Mono',
                                      fontSize: 10,
                                      color: Color(0xFF737686),
                                    ),
                                  ),
                                  if (triageProvider.patientTranscript.isNotEmpty)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 8.0, left: 8.0, right: 8.0),
                                      child: Text(
                                        triageProvider.patientTranscript,
                                        textAlign: TextAlign.center,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontFamily: 'Space Mono',
                                          fontSize: 11,
                                          color: _completedGreen,
                                        ),
                                      ),
                                    ),
                                ],
                            ],
                          ),
                          const SizedBox(height: 6),
                        ],
                      ),
                    ),
                  ),

                  // BOTTOM ACTION AREA (Solid Vivid Button)
                  Container(
                    width: double.infinity,
                    decoration: const BoxDecoration(
                      color: _surfaceContainerLowest,
                      border: Border(
                        top: BorderSide(color: _outlineVariant, width: 2.0),
                      ),
                    ),
                    padding: const EdgeInsets.all(20.0),
                    child: SizedBox(
                      height: 60.0,
                      child: ElevatedButton.icon(
                        onPressed: isReady ? () => _handleExecuteTriage(context) : null,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _primaryCobalt,
                          foregroundColor: Colors.white,
                          disabledBackgroundColor: _primaryCobalt.withValues(alpha: 0.5),
                          disabledForegroundColor: Colors.white70,
                          elevation: 0,
                          side: const BorderSide(color: Color(0xFF121212), width: 2.0),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(4.0),
                          ),
                        ),
                        icon: const Icon(Icons.memory, size: 24),
                        label: const Text(
                          'EXECUTE AI TRIAGE',
                          style: TextStyle(
                            fontFamily: 'Space Mono',
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.5,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Helper to build Vital Card matching HTML spec with tap + long-press interaction.
  /// Long-pressing a card triggers Force Pass — injects a valid random reading
  /// for that sensor only, leaving all other sensor values and triage logic intact.
  Widget _buildCard({
    required bool isCompleted,
    required IconData icon,
    required String title,
    required String sensor,
    required String? reading,
    required VoidCallback onTap,
    required VoidCallback onForcePass,
  }) {
    return Material(
      color: isCompleted ? _completedBg : _surfaceContainerLowest,
      shape: RoundedRectangleBorder(
        side: BorderSide(
          color: isCompleted ? _completedGreen : _outlineVariant,
          width: isCompleted ? 2.0 : 1.0,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: isCompleted ? null : onForcePass,
        child: SizedBox.expand(
          child: Padding(
            padding: const EdgeInsets.all(12.0),
            child: Column(
              children: [
                Align(
                  alignment: Alignment.topRight,
                  child: Icon(
                    isCompleted ? Icons.check_circle : icon,
                    color: isCompleted ? _completedGreen : _outline,
                    size: 24,
                  ),
                ),
                Expanded(
                  child: Center(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        isCompleted ? (reading ?? 'DONE') : title,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontFamily: 'Space Mono',
                          fontSize: isCompleted ? 18 : 28,
                          fontWeight: FontWeight.w700,
                          color: isCompleted ? _completedGreen : _onSurface,
                        ),
                      ),
                    ),
                  ),
                ),
                Text(
                  isCompleted ? 'Tap to retake' : 'Hold to Force Pass',
                  style: TextStyle(
                    fontFamily: 'Space Mono',
                    fontSize: 10,
                    color: isCompleted ? _completedGreen : _outline,
                    letterSpacing: 1.2,
                    fontWeight: isCompleted ? FontWeight.w700 : FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}


class MewsCriticalAlertScreen extends StatelessWidget {
  final String reason;

  const MewsCriticalAlertScreen({super.key, required this.reason});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.red[900],
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 80),
                const SizedBox(height: 24),
                const Text(
                  'CRITICAL MEWS ALERT',
                  style: TextStyle(
                    fontFamily: 'Space Mono',
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  reason,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontFamily: 'Space Mono',
                    fontSize: 18,
                    color: Colors.white70,
                  ),
                ),
                const SizedBox(height: 40),
                ElevatedButton(
                  onPressed: () => Navigator.pop(context),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: Colors.red[900],
                    padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                  ),
                  child: const Text('ACKNOWLEDGE & RETURN', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
