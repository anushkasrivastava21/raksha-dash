import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/triage_provider.dart';
import '../providers/triage_state.dart';
import '../widgets/app_header.dart';
import 'register.dart';

/// Alias for BaseScreen to match linear routing terminology
typedef BaseScreen = RakshaTriageHomeScreen;

/// Converts the HTML/Tailwind layout completely into a single stateless Flutter Widget.
class RakshaTriageHomeScreen extends StatelessWidget {
  /// Callback when the "Start New Patient Check" primary button is tapped
  final VoidCallback? onStartCheck;

  /// Application version string displayed in footer
  final String appVersion;

  /// Footer tagline text
  final String tagline;

  /// Optional custom hero vector icon URL
  final String? heroImageUrl;

  const RakshaTriageHomeScreen({
    super.key,
    this.onStartCheck,
    this.appVersion = 'v1.0-alpha',
    this.tagline = 'Healthcare for rural India',
    this.heroImageUrl,
  });

  // Core Brand Colors
  static const Color primaryBlue = Color(0xFF2563EB); // Cobalt Blue #2563EB
  static const Color darkCharcoal = Color(0xFF121212); // Deep Charcoal #121212
  static const Color subtextColor = Color(0xFF6B7280); // Gray 500
  static const Color borderGray = Color(0xFFE5E7EB); // Border Gray #E5E7EB
  static const Color footerBorder = Color(0xFFF3F4F6); // Soft Footer Border

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Column(
          children: [
            // Top App Bar
            _buildTopAppBar(),

            // Main Centered Content
            Expanded(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24.0,
                    vertical: 16.0,
                  ),
                  child: Container(
                    constraints: const BoxConstraints(maxWidth: 480),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Central Vector Hero Illustration
                        _buildHeroIllustration(),
                        const SizedBox(height: 40),

                        // Hero Action Button
                        _buildHeroActionButton(context),
                      ],
                    ),
                  ),
                ),
              ),
            ),

            // Fixed Bottom Footer
            _buildFooter(),
          ],
        ),
      ),
    );
  }

  /// Builds the top fixed App Bar containing the Raksha Shield icon and title
  Widget _buildTopAppBar() {
    return const AppHeader();
  }

  /// Builds the center healthcare medical cross + ECG line hero graphic
  Widget _buildHeroIllustration() {
    const String defaultUrl =
        'https://lh3.googleusercontent.com/aida/AP1WRLusOUcBYCOhAlFxqAlkbFhsvFsKWGuMXjK28uMsEPZRxNSuNu68o-DtCtDMMUq2pSCSxEJp7Tx1z__1tLT7Lmhj1v2wfSM6qGlpOY_rvxEqiXc0qJKX6k1uwd6jpYIHRdSihFgOL8XvPSIedzw3LKhavdbWgltyp8Rfh_4hTRUQTTsTnsW_PYtIRpjcCoFtMfEZGO4mugPCkB-BdKCX1AvUSbT4H5L2f8jyCpdhTn8Soekrh1_GlLI_2dI';

    final String targetUrl = heroImageUrl ?? defaultUrl;

    return Container(
      height: 240,
      width: 240,
      alignment: Alignment.center,
      child: Image.network(
        targetUrl,
        fit: BoxFit.contain,
        errorBuilder: (context, error, stackTrace) =>
            _buildFallbackVectorHero(),
        loadingBuilder: (context, child, loadingProgress) {
          if (loadingProgress == null) return child;
          return _buildFallbackVectorHero();
        },
      ),
    );
  }

  /// Offline CustomPainter vector fallback for the Medical Cross + ECG Wave
  Widget _buildFallbackVectorHero() {
    return SizedBox(
      height: 200,
      width: 200,
      child: CustomPaint(
        painter: _MedicalPulseCrossPainter(color: primaryBlue),
      ),
    );
  }

  /// Builds the oversized Primary Hero Button
  Widget _buildHeroActionButton(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 76.0),
      child: ElevatedButton(
        onPressed: () {
          if (onStartCheck != null) {
            onStartCheck!();
          } else {
            // Strictly reset all global state before initiating a new patient flow
            Provider.of<TriageState>(context, listen: false).reset();
            Provider.of<TriageProvider>(context, listen: false).resetAll();

            final String dynamicId = 'PT-${DateTime.now().millisecondsSinceEpoch.toString().substring(8)}';
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => RakshaPatientRegistrationScreen(
                  patientId: dynamicId,
                ),
              ),
            );
          }
        },
        style: ElevatedButton.styleFrom(
          backgroundColor: primaryBlue,
          foregroundColor: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12.0),
            side: const BorderSide(color: primaryBlue, width: 2.0),
          ),
          padding: const EdgeInsets.symmetric(vertical: 20.0, horizontal: 24.0),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: const [
            Icon(Icons.add_rounded, size: 28, color: Colors.white),
            SizedBox(width: 12),
            Flexible(
              child: Text(
                'Start New Patient Check',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                  letterSpacing: 0.1,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Builds the pinned bottom footer section
  Widget _buildFooter() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 16.0),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: footerBorder, width: 1.0)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            tagline,
            style: const TextStyle(
              color: darkCharcoal,
              fontFamily: 'Inter',
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            appVersion,
            style: const TextStyle(
              color: subtextColor,
              fontFamily: 'Inter',
              fontSize: 12,
              fontWeight: FontWeight.w400,
            ),
          ),
        ],
      ),
    );
  }
}
/// CustomPainter that renders a vector line outline of a Medical Cross with ECG Pulse Wave
class _MedicalPulseCrossPainter extends CustomPainter {
  final Color color;

  _MedicalPulseCrossPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final double w = size.width;
    final double h = size.height;

    // Medical Cross Outline Path
    final Path crossPath = Path();
    const double r = 12.0; // corner radius

    final double left = w * 0.3;
    final double right = w * 0.7;
    final double top = h * 0.15;
    final double bottom = h * 0.85;
    final double midTop = h * 0.38;
    final double midBottom = h * 0.62;
    final double midLeft = w * 0.15;
    final double midRight = w * 0.85;

    crossPath.moveTo(left + r, top);
    crossPath.lineTo(right - r, top);
    crossPath.quadraticBezierTo(right, top, right, top + r);
    crossPath.lineTo(right, midTop);
    crossPath.lineTo(midRight - r, midTop);
    crossPath.quadraticBezierTo(midRight, midTop, midRight, midTop + r);
    crossPath.lineTo(midRight, midBottom - r);
    crossPath.quadraticBezierTo(midRight, midBottom, midRight - r, midBottom);
    crossPath.lineTo(right, midBottom);
    crossPath.lineTo(right, bottom - r);
    crossPath.quadraticBezierTo(right, bottom, right - r, bottom);
    crossPath.lineTo(left + r, bottom);
    crossPath.quadraticBezierTo(left, bottom, left, bottom - r);
    crossPath.lineTo(left, midBottom);
    crossPath.lineTo(midLeft + r, midBottom);
    crossPath.quadraticBezierTo(midLeft, midBottom, midLeft, midBottom - r);
    crossPath.lineTo(midLeft, midTop + r);
    crossPath.quadraticBezierTo(midLeft, midTop, midLeft + r, midTop);
    crossPath.lineTo(left, midTop);
    crossPath.lineTo(left, top + r);
    crossPath.quadraticBezierTo(left, top, left + r, top);
    crossPath.close();

    canvas.drawPath(crossPath, paint);

    // Heartbeat / ECG Wave Line passing through the center
    final Path ecgPath = Path();
    final double cy = h * 0.5;

    ecgPath.moveTo(w * 0.05, cy);
    ecgPath.lineTo(w * 0.35, cy);
    ecgPath.lineTo(w * 0.42, cy - h * 0.1);
    ecgPath.lineTo(w * 0.48, cy + h * 0.18);
    ecgPath.lineTo(w * 0.55, cy - h * 0.22);
    ecgPath.lineTo(w * 0.62, cy + h * 0.08);
    ecgPath.lineTo(w * 0.68, cy);
    ecgPath.lineTo(w * 0.95, cy);

    canvas.drawPath(ecgPath, paint..strokeWidth = 3.0);
  }

  @override
  bool shouldRepaint(covariant _MedicalPulseCrossPainter oldDelegate) =>
      oldDelegate.color != color;
}
