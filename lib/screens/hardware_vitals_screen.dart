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

  @override
  void initState() {
    super.initState();
    BleService().rawDataStream.listen((data) {
      if (mounted) {
        setState(() {
          _rawBleData = data;
        });

        // The exact break in the pipeline: Parse telemetry and update UI state!
        try {
          final parts = data.split('|').map((e) => e.trim()).toList();
          if (parts.length >= 2) {
            final sensorCode = parts[0];
            final jsonPayload = parts[1];
            
            final triageProvider = context.read<TriageProvider>();
            final triageState = context.read<TriageState>();
            
            // 1. Update the actual values in the data provider
            triageProvider.updateFromBleJson(sensorCode, jsonPayload);
            
            // 2. Extract specific values for the UI State Completion checkmarks
            final Map<String, dynamic> parsed = jsonDecode(jsonPayload);
            switch (sensorCode) {
              case 'SPO2':
              case 'MAX30102':
                if (parsed.containsKey('spo2_percent')) {
                  triageState.markCompleted(VitalTestType.spo2, reading: "${parsed['spo2_percent']}%");
                }
                if (parsed.containsKey('heart_rate_bpm')) {
                  triageState.markCompleted(VitalTestType.hr, reading: "${parsed['heart_rate_bpm']} BPM");
                }
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
                if (parsed.containsKey('heart_rate_bpm')) {
                  triageState.markCompleted(VitalTestType.hr, reading: "${parsed['heart_rate_bpm']} BPM");
                }
                break;
              case 'STETH':
                if (parsed.containsKey('rms')) {
                  triageState.markCompleted(VitalTestType.stethoscope, reading: "RMS: ${parsed['rms']}");
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
      
      // Inject final transcript to XGBoost extraction
      triageProvider.setPatientTranscript(_liveTranscript);
      triageState.markCompleted(VitalTestType.voice, reading: "RECORDED");
    } else {
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
              _liveTranscript = transcript;
            });
            // Update provider live
            triageProvider.setPatientTranscript(transcript);
          }
        });
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
    final payload = triageProvider.generateJsonPayload();
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

    if (mewsResult["override"] == true && mewsResult["status"] == "RED") {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => MewsCriticalAlertScreen(reason: mewsResult["reason"]),
        ),
      );
      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => TriageResultScreen(vitals: result),
      ),
    );
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
                                          onTap: () => _navigateToTest(context, VitalTestType.spo2),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                        Expanded(
                                          child: _buildCard(
                                            isCompleted: triageState.isCompleted(VitalTestType.hr),
                                            icon: Icons.monitor_heart_outlined,
                                            title: 'ECG',
                                            sensor: 'SENSOR: MAX30102',
                                            onTap: () => _navigateToTest(context, VitalTestType.hr),
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
                                          onTap: () => _navigateToTest(context, VitalTestType.temp),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: _buildCard(
                                          isCompleted: triageState.isCompleted(VitalTestType.urine),
                                          icon: Icons.science,
                                          title: 'URINE',
                                          sensor: 'SENSOR: STRIP-READER',
                                          onTap: () => _navigateToTest(context, VitalTestType.urine),
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
                                    onTap: () => _navigateToTest(context, VitalTestType.stethoscope),
                                  ),
                                ),
                              ],
                            ),
                          ),

                          // Raw bytes display (PRD requirement)
                          if (_rawBleData.isNotEmpty)
                            Expanded(
                              flex: 1,
                              child: Container(
                                margin: const EdgeInsets.only(top: 12),
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: Colors.black87,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                width: double.infinity,
                                child: SingleChildScrollView(
                                  child: Text(
                                    'RAW BLE BYTES:\n$_rawBleData',
                                    style: const TextStyle(
                                      fontFamily: 'Space Mono',
                                      color: Colors.greenAccent,
                                      fontSize: 10,
                                    ),
                                  ),
                                ),
                              ),
                            ),

                          // MIC ACTION BUTTON (88px x 88px)
                          const SizedBox(height: 10),
                          Center(
                            child: InkWell(
                              onTap: () => _navigateToTest(context, VitalTestType.voice),
                              child: Container(
                                width: 80.0,
                                height: 80.0,
                                decoration: BoxDecoration(
                                  color: _isListening
                                      ? Colors.red.withValues(alpha: 0.1)
                                      : triageState.isCompleted(VitalTestType.voice)
                                          ? _completedBg
                                          : Colors.white,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: _isListening
                                        ? Colors.red
                                        : triageState.isCompleted(VitalTestType.voice)
                                            ? _completedGreen
                                            : _borderGray,
                                    width: triageState.isCompleted(VitalTestType.voice) || _isListening ? 2.0 : 1.0,
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
                                  triageState.isCompleted(VitalTestType.voice) && !_isListening
                                      ? Icons.check_circle
                                      : Icons.mic,
                                  color: _isListening
                                      ? Colors.red
                                      : triageState.isCompleted(VitalTestType.voice)
                                          ? _completedGreen
                                          : _primaryContainer,
                                  size: 38,
                                ),
                              ),
                            ),
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

  /// Helper to build Vital Card matching HTML spec with tap interaction
  Widget _buildCard({
    required bool isCompleted,
    required IconData icon,
    required String title,
    required String sensor,
    required VoidCallback onTap,
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
                    child: Text(
                      title,
                      style: const TextStyle(
                        fontFamily: 'Space Mono',
                        fontSize: 28,
                        fontWeight: FontWeight.w700,
                        color: _onSurface,
                      ),
                    ),
                  ),
                ),
                Text(
                  isCompleted ? 'Tap to retake Test' : sensor,
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
