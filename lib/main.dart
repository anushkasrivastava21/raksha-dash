import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart'; // <-- Naya import

import 'providers/triage_provider.dart';
import 'services/api_service.dart';
import 'providers/triage_state.dart';
import 'screens/asha_login_screen.dart';
import 'screens/base.dart';
import 'screens/dashboard_completed_screen.dart';
import 'screens/hardware_vitals_screen.dart';
import 'screens/register.dart';
import 'screens/triage_result_screen.dart';

// <-- BLE Permission logic yahan daal di
Future<void> requestBlePermissions() async {
  Map<Permission, PermissionStatus> statuses = await [
    Permission.bluetoothScan,
    Permission.bluetoothConnect,
    Permission.location,
  ].request();

  if (statuses.values.every((status) => status.isGranted)) {
    debugPrint("W: BLE Permissions granted.");
  } else {
    debugPrint("FATAL: BLE Permissions denied.");
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // <-- App load hone se pehle permission maangega
  await requestBlePermissions();

  // Attempt to flush offline cache in the background
  // Using ignore to prevent linter errors on newer SDKs if we don't await,
  // but since it's quick to return if empty, we can just await it.
  // Actually, to not block UI thread on timeout, we will not await it,
  // and use ignore: discarded_futures just in case.
  // ignore: discarded_futures, unawaited_futures
  ApiService.flushOfflineQueue();

  final prefs = await SharedPreferences.getInstance();
  final bool isAuthenticated = prefs.getBool('is_authenticated') ?? false;

  runApp(RakshaApp(isAuthenticated: isAuthenticated));
}

/// Root Application Widget with dynamic authentication gate & route registry
class RakshaApp extends StatelessWidget {
  final bool isAuthenticated;

  const RakshaApp({
    super.key,
    this.isAuthenticated = false,
  });

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => TriageProvider()),
        ChangeNotifierProvider(create: (_) => TriageState()),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Raksha Triage App',
        theme: ThemeData(
          fontFamily: 'Space Mono',
          useMaterial3: false,
          scaffoldBackgroundColor: Colors.white,
        ),
        initialRoute: isAuthenticated ? '/dashboard' : '/login',
        routes: {
          '/login': (context) => const AshaLoginScreen(),
          '/dashboard': (context) => const RakshaHardwareVitalsScreen(),
          '/dashboard_completed': (context) => const DashboardCompletedScreen(),
          '/triage_result': (context) => const TriageResultScreen(),
          '/hardware_vitals': (context) => const RakshaHardwareVitalsScreen(),
          '/register': (context) => const RakshaPatientRegistrationScreen(),
          '/home': (context) => const BaseScreen(),
        },
      ),
    );
  }
}