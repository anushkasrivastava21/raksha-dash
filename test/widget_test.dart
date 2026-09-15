import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:raksha_app/main.dart';
import 'package:raksha_app/screens/hardware_vitals_screen.dart';

void main() {
  testWidgets('RakshaApp smoke test renders dashboard when authenticated',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 1.0;
    
    await tester.pumpWidget(const RakshaApp(isAuthenticated: true));
    await tester.pump();

    // Verify RakshaHardwareVitalsScreen renders
    expect(find.byType(RakshaHardwareVitalsScreen), findsWidgets);
  });
}
