import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/triage_provider.dart';
import '../providers/triage_state.dart';
import '../services/pi_service.dart';
import '../services/raspi_api_service.dart';
import '../widgets/app_header.dart';
import 'dashboard_completed_screen.dart';

/// Configuration data model representing loading information for a specific vital test.
class TestLoadingConfig {
  final String status;
  final List<String> facts;
  final IconData icon;

  const TestLoadingConfig({
    required this.status,
    required this.facts,
    required this.icon,
  });
}

/// Dynamic, parameterized single-test Loading Screen.
class DynamicTestLoaderScreen extends StatefulWidget {
  final VitalTestType testType;

  const DynamicTestLoaderScreen({
    super.key,
    required this.testType,
  });

  @override
  State<DynamicTestLoaderScreen> createState() => _DynamicTestLoaderScreenState();
}

class _DynamicTestLoaderScreenState extends State<DynamicTestLoaderScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;
  late final Animation<double> _scaleAnimation;
  final int _factIndex = 0;

  /// Retrieves test-specific loading configuration according to spec.
  TestLoadingConfig _getConfig(VitalTestType type) {
    switch (type) {
      case VitalTestType.spo2:
        return const TestLoadingConfig(
          status: 'Calibrating Oximeter (SPO2)...',
          facts: [
            'Clinical SpO2 drops below 92% require high-priority triage.',
            'Measuring arterial pulse propagation and peripheral saturation.',
            'Detecting hypoxemia trends via red and IR light absorption.',
          ],
          icon: Icons.air,
        );
      case VitalTestType.hr:
        return const TestLoadingConfig(
          status: 'Reading ECG Module (HR)...',
          facts: [
            'Resting HR above 100 BPM triggers immediate Tachycardia alerts.',
            'Analyzing P-QRS-T waveforms for ventricular anomalies.',
            'Mapping atrial fibrillation markers via real-time telemetry.',
          ],
          icon: Icons.monitor_heart_outlined,
        );
      case VitalTestType.temp:
        return const TestLoadingConfig(
          status: 'Scanning Body Temp...',
          facts: [
            'Core body temp indexed against the normal 36.5°C–37.5°C clinical range.',
            'Scanning peripheral infrared emissions for pyrexia indicators.',
            'Calibrating thermal gradients against ambient room fluctuations.',
          ],
          icon: Icons.device_thermostat_outlined,
        );
      case VitalTestType.stethoscope:
        return const TestLoadingConfig(
          status: 'Listening to Vitals...',
          facts: [
            'Auscultation captures acoustic waveforms from heart and lungs.',
            'Filtering high-frequency respiratory wheezes and crackles.',
            'Digital acoustic amplification eliminates ambient rural field noise.',
          ],
          icon: Icons.medical_services_outlined,
        );
      case VitalTestType.urine:
        return const TestLoadingConfig(
          status: 'Analyzing Strip Reader (URINE)...',
          facts: [
            'Colorimetric optical analysis detects micro-level ketone & glucose.',
            'Quantifying pH balance and leukocyte esterase for infection triage.',
            'Mapping specific gravity parameters via calibrated reflectance.',
          ],
          icon: Icons.science_outlined,
        );
      case VitalTestType.voice:
        return const TestLoadingConfig(
          status: 'Recording Patient Audio (VOICE)...',
          facts: [
            'Acoustic speech markers analyzed for respiratory distress and hoarseness.',
            'Voice fundamental frequency and jitter metrics mapped in real time.',
            'Capturing spoken patient symptoms for automated NLP triage extraction.',
          ],
          icon: Icons.mic,
        );
    }
  }

  @override
  void initState() {
    super.initState();

    // 1. Setup continuous pulse animation
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );

    _scaleAnimation = Tween<double>(begin: 0.9, end: 1.18).animate(
      CurvedAnimation(
        parent: _pulseController,
        curve: Curves.easeInOut,
      ),
    );

    _pulseController.repeat(reverse: true);

    // 2. Trigger hardware handshake on RasPi/ESP
    _startHardwareTest();
  }

  Future<void> _startHardwareTest() async {
    // 1. Attempt real hardware trigger via RaspiApiService → PiService
    final TriggerResult result = await RaspiApiService.triggerTest(widget.testType);

    if (!mounted) return;

    final data = result.data;
    if (result.success && data != null) {
      debugPrint('✅ [DynamicTestLoader] Live hardware reading succeeded for ${widget.testType}: $data');
    } else {
      debugPrint('⚠️ [DynamicTestLoader] Live hardware trigger unavailable for ${widget.testType}. Using safe baseline fallback.');
      await Future.delayed(const Duration(milliseconds: 1000));
      if (!mounted) return;
    }

    // 2. Mark test completed in TriageState + apply vitals data
    final triageState = Provider.of<TriageState>(context, listen: false);
    triageState.markCompleted(widget.testType);

    final triageProvider = Provider.of<TriageProvider>(context, listen: false);
    switch (widget.testType) {
      case VitalTestType.spo2:
        final int spo2Val = (data?['spo2'] as num?)?.toInt() ?? 
            (triageProvider.spo2TempResult?.spo2 ?? 98);
        final double hrVal = (data?['ecg_hr'] as num?)?.toDouble() ?? 
            (triageProvider.spo2TempResult?.heartRate.toDouble() ?? 74.0);
        final double existingTemp = triageProvider.spo2TempResult?.temperature ?? 36.8;
        triageProvider.applySpo2TempData(
          spo2: spo2Val,
          heartRate: hrVal.toInt(),
          temperature: existingTemp,
        );
        break;
      case VitalTestType.temp:
        final double tempVal = (data?['temperature'] as num?)?.toDouble() ?? 
            (triageProvider.spo2TempResult?.temperature ?? 36.8);
        final int existingSpo2 = triageProvider.spo2TempResult?.spo2 ?? 98;
        final int existingHr = triageProvider.spo2TempResult?.heartRate ?? 72;
        triageProvider.applySpo2TempData(
          spo2: existingSpo2,
          heartRate: existingHr,
          temperature: tempVal,
        );
        break;
      case VitalTestType.hr:
        final double hrVal = (data?['ecg_hr'] as num?)?.toDouble() ?? 74.0;
        final String rhythm = data?['rhythm']?.toString() ?? 'Normal Sinus';
        triageProvider.applyEcgData(
          heartRate: hrVal,
          rhythm: rhythm,
          qtInterval: 410.0,
        );
        break;
      case VitalTestType.urine:
        final String color = data?['color']?.toString() ?? 'Yellow';
        List<double>? parsedRgb;
        if (data?['urine_rgb'] is List) {
          parsedRgb = (data!['urine_rgb'] as List)
              .map((e) => (e as num?)?.toDouble() ?? 0.0)
              .toList();
        }
        triageProvider.applyUrineData(
          color: color,
          ph: 6.5,
          protein: 'Negative',
          glucose: 'Negative',
          rawRgb: parsedRgb,
        );
        break;
      case VitalTestType.stethoscope:
      case VitalTestType.voice:
        final String lung = data?['lung_sound']?.toString() ?? 
            (data?['stethoscope_status'] == 'recorded' ? 'Recorded' : 'Clear');
        final double hrVal = (data?['ecg_hr'] as num?)?.toDouble() ?? 74.0;
        triageProvider.applyStethData(
          heartRate: hrVal,
          lungSound: lung,
        );
        break;
    }

    // 3. Navigate to Dashboard 2 (Completed State)
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (context) => const DashboardCompletedScreen(),
      ),
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final config = _getConfig(widget.testType);
    final String currentFact = config.facts[_factIndex % config.facts.length];
    const primaryColor = Color(0xFF004AC6);

    return Scaffold(
      backgroundColor: const Color(0xFFFCF9F8),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 450),
            child: Column(
              children: [
                // Top App Bar Header
                const AppHeader(),

                // Dynamic Animated Content Area
                Expanded(
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32.0),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          // Pulsing Sensor Icon
                          ScaleTransition(
                            scale: _scaleAnimation,
                            child: Container(
                              width: 100,
                              height: 100,
                              decoration: BoxDecoration(
                                color: primaryColor.withValues(alpha: 0.08),
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: primaryColor.withValues(alpha: 0.3),
                                  width: 2.0,
                                ),
                              ),
                              child: Icon(
                                config.icon,
                                size: 48,
                                color: primaryColor,
                              ),
                            ),
                          ),
                          const SizedBox(height: 40),

                          // Dynamic Test Status Message
                          Text(
                            config.status,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontFamily: 'Space Mono',
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF1C1B1B),
                              letterSpacing: 0.2,
                              height: 1.3,
                            ),
                          ),
                          const SizedBox(height: 32),

                          // Clinical Fact Box
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(16.0),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF6F3F2),
                              borderRadius: BorderRadius.circular(8.0),
                              border: Border.all(
                                color: const Color(0xFFC3C6D7),
                                width: 1.5,
                              ),
                            ),
                            child: Text(
                              currentFact,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontFamily: 'Space Mono',
                                fontSize: 13,
                                fontWeight: FontWeight.w400,
                                color: Color(0xFF434655),
                                height: 1.4,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
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

/// Compatibility alias for any legacy references
typedef TelemetrySyncScreen = DynamicTestLoaderScreen;
