import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/vitals_model.dart';
import '../providers/triage_state.dart';
import '../services/raspi_api_service.dart';
import '../widgets/app_header.dart';
import 'telemetry_sync_screen.dart';
import 'triage_result_screen.dart';

/// Native Flutter implementation of Dashboard 2 (Completed State - RAW VITALS).
/// Mobile-constrained layout matching original HTML/CSS design specification.
class DashboardCompletedScreen extends StatefulWidget {
  const DashboardCompletedScreen({super.key});

  @override
  State<DashboardCompletedScreen> createState() => _DashboardCompletedScreenState();
}

class _DashboardCompletedScreenState extends State<DashboardCompletedScreen> {
  bool _isExecutingTriage = false;

  static const Color _surfaceContainerLow = Color(0xFFF6F3F2);
  static const Color _surfaceContainerLowest = Color(0xFFFFFFFF);
  static const Color _primaryCobalt = Color(0xFF004AC6);
  static const Color _primaryContainer = Color(0xFF2563EB);
  static const Color _onSurface = Color(0xFF1C1B1B);
  static const Color _outline = Color(0xFF737686);
  static const Color _outlineVariant = Color(0xFFC3C6D7);
  static const Color _borderGray = Color(0xFFE5E7EB);

  // Completed state green colors matching HTML spec (#DFF5E1 & #34A853)
  static const Color _completedBg = Color(0xFFDFF5E1);
  static const Color _completedGreen = Color(0xFF34A853);

  void _navigateToTest(BuildContext context, VitalTestType type) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => DynamicTestLoaderScreen(testType: type),
      ),
    );
  }

  Future<void> _handleExecuteTriage() async {
    setState(() {
      _isExecutingTriage = true;
    });

    try {
      final VitalsModel? result = await RaspiApiService.getTriageResult();
      if (!mounted) return;

      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => TriageResultScreen(vitals: result),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isExecutingTriage = false;
        });
      }
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

                          // GRID LAYOUT (Completed + Pending State Vitals Cards)
                          Expanded(
                            child: Column(
                              children: [
                                // Row 1: SPO2 & HR
                                Expanded(
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: _buildVitalCard(
                                          isCompleted: triageState.isCompleted(VitalTestType.spo2),
                                          icon: triageState.isCompleted(VitalTestType.spo2)
                                              ? Icons.check_circle
                                              : Icons.air,
                                          title: 'SPO2',
                                          subtitle: 'Tap to retake Test',
                                          onTap: () => _navigateToTest(context, VitalTestType.spo2),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: _buildVitalCard(
                                          isCompleted: triageState.isCompleted(VitalTestType.hr),
                                          icon: triageState.isCompleted(VitalTestType.hr)
                                              ? Icons.check_circle
                                              : Icons.monitor_heart,
                                          title: 'HR',
                                          subtitle: 'Tap to retake Test',
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
                                        child: _buildVitalCard(
                                          isCompleted: triageState.isCompleted(VitalTestType.temp),
                                          icon: triageState.isCompleted(VitalTestType.temp)
                                              ? Icons.check_circle
                                              : Icons.thermostat,
                                          title: 'TEMP',
                                          subtitle: 'Tap to retake Test',
                                          onTap: () => _navigateToTest(context, VitalTestType.temp),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: _buildVitalCard(
                                          isCompleted: triageState.isCompleted(VitalTestType.urine),
                                          icon: triageState.isCompleted(VitalTestType.urine)
                                              ? Icons.check_circle
                                              : Icons.science,
                                          title: 'URINE',
                                          subtitle: 'Tap to retake Test',
                                          onTap: () => _navigateToTest(context, VitalTestType.urine),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 8),

                                // Row 3: STETHOSCOPE (Full Width)
                                Expanded(
                                  child: _buildVitalCard(
                                    isCompleted: triageState.isCompleted(VitalTestType.stethoscope),
                                    icon: triageState.isCompleted(VitalTestType.stethoscope)
                                        ? Icons.check_circle
                                        : Icons.medical_services_outlined,
                                    title: 'STETHOSCOPE',
                                    subtitle: 'Tap to retake Test',
                                    onTap: () => _navigateToTest(context, VitalTestType.stethoscope),
                                  ),
                                ),
                              ],
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
                        onPressed: (isReady && !_isExecutingTriage) ? _handleExecuteTriage : null,
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
                        icon: _isExecutingTriage
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  color: Colors.white,
                                  strokeWidth: 2.0,
                                ),
                              )
                            : const Icon(Icons.memory, size: 24),
                        label: Text(
                          _isExecutingTriage ? 'CALCULATING TRIAGE...' : 'EXECUTE AI TRIAGE',
                          style: const TextStyle(
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

  /// Helper to build Completed or Pending Vital Card matching HTML spec
  Widget _buildVitalCard({
    required bool isCompleted,
    required IconData icon,
    required String title,
    required String subtitle,
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
                    icon,
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
                  subtitle,
                  style: TextStyle(
                    fontFamily: 'Space Mono',
                    fontSize: 10,
                    color: isCompleted ? _completedGreen : _outline,
                    letterSpacing: 1.2,
                    fontWeight: isCompleted ? FontWeight.w700 : FontWeight.w400,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
