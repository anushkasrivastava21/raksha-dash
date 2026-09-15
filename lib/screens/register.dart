import 'package:flutter/material.dart';
import '../widgets/app_header.dart';
import 'hardware_vitals_screen.dart';

/// Converts the HTML/Tailwind layout completely into a single stateful Flutter Widget.
class RakshaPatientRegistrationScreen extends StatefulWidget {
  /// System generated patient ID string
  final String patientId;

  /// Callback when the "Proceed to Vitals" button is pressed
  final VoidCallback? onProceedPressed;

  /// Optional controllers and state handlers for form integration
  final TextEditingController? nameController;
  final TextEditingController? ageController;
  final TextEditingController? aadhaarController;
  final TextEditingController? ayushmanController;
  final String? selectedGender;
  final ValueChanged<String?>? onGenderChanged;

  const RakshaPatientRegistrationScreen({
    super.key,
    this.patientId = 'PT-27609',
    this.onProceedPressed,
    this.nameController,
    this.ageController,
    this.aadhaarController,
    this.ayushmanController,
    this.selectedGender,
    this.onGenderChanged,
  });

  @override
  State<RakshaPatientRegistrationScreen> createState() =>
      _RakshaPatientRegistrationScreenState();
}

class _RakshaPatientRegistrationScreenState
    extends State<RakshaPatientRegistrationScreen> {
  String? _selectedGender;

  @override
  void initState() {
    super.initState();
    _selectedGender = widget.selectedGender;
  }

  // Core Brand Colors
  static const Color primaryBlue = Color(0xFF2563EB); // Cobalt Blue #2563EB
  static const Color darkCharcoal = Color(0xFF121212); // Deep Charcoal #121212
  static const Color outlineGray = Color(0xFF737686); // Icon & Subtext Outline #737686
  static const Color borderGray = Color(0xFFE5E2E1); // Border #E5E2E1
  static const Color bgSurface = Colors.white; // Background #FFFFFF
  static const Color inputBg = Color(0xFFFFFFFF); // Field Surface

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: bgSurface,
      body: SafeArea(
        child: Column(
          children: [
            const AppHeader(),
            // Main Content Area
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24.0,
                  vertical: 16.0,
                ),
                child: Center(
                  child: Container(
                    constraints: const BoxConstraints(maxWidth: 520),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Header Section
                        _buildHeader(),
                        const SizedBox(height: 24),

                        // Form Fields Section
                        _buildFormSection(),
                      ],
                    ),
                  ),
                ),
              ),
            ),

            // Primary Action Button Pinned at Bottom
            _buildBottomActionArea(context),
          ],
        ),
      ),
    );
  }

  /// Builds Header with Shield brand icon, Title and Patient ID Subtitle
  Widget _buildHeader() {
    return Column(
      children: [
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CustomPaint(
              size: const Size(20, 22),
              painter: _RakshaShieldBrandPainter(color: primaryBlue),
            ),
            const SizedBox(width: 8),
            const Text(
              'Raksha',
              style: TextStyle(
                color: primaryBlue,
                fontFamily: 'Inter',
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        const Text(
          'New Patient Registration',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: darkCharcoal,
            fontFamily: 'Inter',
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'System Generated Patient ID: ${widget.patientId}',
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: outlineGray,
            fontFamily: 'Inter',
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  /// Builds the complete input form fields stack
  Widget _buildFormSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Patient Name Field
        _buildFieldLabel('Patient Name'),
        const SizedBox(height: 6),
        _buildTextField(
          controller: widget.nameController,
          hintText: 'Enter full name',
          prefixIcon: Icons.person_outline_rounded,
        ),
        const SizedBox(height: 20),

        // Age & Gender Row
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Age Field
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildFieldLabel('Age'),
                  const SizedBox(height: 6),
                  _buildTextField(
                    controller: widget.ageController,
                    hintText: 'Years',
                    prefixIcon: Icons.calendar_today_outlined,
                    keyboardType: TextInputType.number,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 16),

            // Gender Field
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildFieldLabel('Gender'),
                  const SizedBox(height: 6),
                  _buildGenderDropdown(),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),

        // Divider
        const Divider(color: borderGray, height: 1, thickness: 1),
        const SizedBox(height: 24),

        // Aadhaar ID Field (Optional)
        _buildTextField(
          controller: widget.aadhaarController,
          hintText: 'Aadhaar ID (Optional)',
          prefixIcon: Icons.badge_outlined,
          isItalicHint: true,
        ),
        const SizedBox(height: 20),

        // Ayushman ID Field (Optional)
        _buildTextField(
          controller: widget.ayushmanController,
          hintText: 'Ayushman ID (Optional)',
          prefixIcon: Icons.health_and_safety_outlined,
          isItalicHint: true,
        ),
      ],
    );
  }

  /// Builds field label text
  Widget _buildFieldLabel(String labelText) {
    return Text(
      labelText,
      style: const TextStyle(
        color: darkCharcoal,
        fontFamily: 'Inter',
        fontSize: 14,
        fontWeight: FontWeight.w600,
      ),
    );
  }

  /// Builds standardized text input field matching 56px height & outline style
  Widget _buildTextField({
    required String hintText,
    required IconData prefixIcon,
    TextEditingController? controller,
    TextInputType keyboardType = TextInputType.text,
    bool isItalicHint = false,
  }) {
    return Container(
      height: 56.0,
      decoration: BoxDecoration(
        color: inputBg,
        borderRadius: BorderRadius.circular(8.0),
        border: Border.all(color: borderGray, width: 1.0),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14.0),
      child: Row(
        children: [
          Icon(prefixIcon, color: outlineGray, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: controller,
              keyboardType: keyboardType,
              style: const TextStyle(
                fontFamily: 'Inter',
                fontSize: 16,
                color: darkCharcoal,
              ),
              decoration: InputDecoration(
                hintText: hintText,
                hintStyle: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 16,
                  color: outlineGray,
                  fontStyle: isItalicHint ? FontStyle.italic : FontStyle.normal,
                ),
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Builds functional DropdownButtonFormField for Gender selection
  Widget _buildGenderDropdown() {
    return Container(
      height: 56.0,
      decoration: BoxDecoration(
        color: inputBg,
        borderRadius: BorderRadius.circular(8.0),
        border: Border.all(color: borderGray, width: 1.0),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14.0),
      child: Row(
        children: [
          const Icon(Icons.wc_outlined, color: outlineGray, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: DropdownButtonFormField<String>(
              alignment: Alignment.centerLeft,
              initialValue: (_selectedGender != null && _selectedGender!.isNotEmpty)
                  ? _selectedGender
                  : null,
              onChanged: (value) {
                setState(() {
                  _selectedGender = value;
                });
                if (widget.onGenderChanged != null) {
                  widget.onGenderChanged!(value);
                }
              },
              icon: const Icon(
                Icons.expand_more_rounded,
                color: outlineGray,
                size: 22,
              ),
              decoration: const InputDecoration(
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.zero,
              ),
              hint: const Text(
                'Select gender',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 16,
                  color: outlineGray,
                ),
              ),
              style: const TextStyle(
                fontFamily: 'Inter',
                fontSize: 16,
                color: darkCharcoal,
              ),
              dropdownColor: Colors.white,
              items: const [
                DropdownMenuItem(
                  value: 'Male',
                  alignment: Alignment.centerLeft,
                  child: Text('Male'),
                ),
                DropdownMenuItem(
                  value: 'Female',
                  alignment: Alignment.centerLeft,
                  child: Text('Female'),
                ),
                DropdownMenuItem(
                  value: 'Other',
                  alignment: Alignment.centerLeft,
                  child: Text('Other'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Builds bottom action button container
  Widget _buildBottomActionArea(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 20.0),
      child: Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 520),
          height: 56.0,
          child: ElevatedButton(
            onPressed: () {
              if (widget.onProceedPressed != null) {
                widget.onProceedPressed!();
              } else {
                Navigator.pushReplacement(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const RakshaHardwareVitalsScreen(),
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
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: const [
                Text(
                  'Proceed to Vitals',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                SizedBox(width: 8),
                Icon(Icons.arrow_forward_rounded, size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// CustomPainter for the Raksha Shield Header Logo
class _RakshaShieldBrandPainter extends CustomPainter {
  final Color color;

  _RakshaShieldBrandPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final Paint strokePaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final double w = size.width;
    final double h = size.height;

    // Shield outline
    final Path shieldPath = Path();
    shieldPath.moveTo(w * 0.5, 0);
    shieldPath.lineTo(w, h * 0.22);
    shieldPath.lineTo(w, h * 0.52);
    shieldPath.cubicTo(w, h * 0.82, w * 0.5, h, w * 0.5, h);
    shieldPath.cubicTo(w * 0.5, h, 0, h * 0.82, 0, h * 0.52);
    shieldPath.lineTo(0, h * 0.22);
    shieldPath.close();

    canvas.drawPath(shieldPath, strokePaint);

    // Inner plus cross
    final double cx = w * 0.5;
    final double cy = h * 0.48;
    final double crossRadius = w * 0.22;

    canvas.drawLine(
      Offset(cx - crossRadius, cy),
      Offset(cx + crossRadius, cy),
      strokePaint..strokeWidth = 1.8,
    );
    canvas.drawLine(
      Offset(cx, cy - crossRadius),
      Offset(cx, cy + crossRadius),
      strokePaint..strokeWidth = 1.8,
    );
  }

  @override
  bool shouldRepaint(covariant _RakshaShieldBrandPainter oldDelegate) =>
      oldDelegate.color != color;
}
