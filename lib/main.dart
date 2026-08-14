import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'design/neon_tokens.dart';
import 'features/assistant/live/live_screen.dart';
import 'screens/auth/auth_screen.dart';
import 'screens/lock_screen.dart';
import 'screens/splash_screen.dart';
import 'services/api_service.dart';
import 'services/app_lock.dart';
import 'services/auth_service.dart';
import 'services/style_prefs.dart';
import 'theme/app_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Liquid Glass is dark-first: paint the system bars to match.
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: Neon.bg,
    systemNavigationBarIconBrightness: Brightness.light,
  ));
  // Style + language prefs load in parallel with the first frame; every
  // later read is a plain field access (no disk on hot paths).
  StylePrefs.instance.load();
  // Runtime server override (Diagnostics screen) — must resolve before
  // the first request, or the engine would connect to the wrong host.
  ApiService.loadServerOverride();
  AppLock.instance.init(); // F1 — resolves before AuthGate finishes restoring
  runApp(const MyAssistantApp());
}

/// The live call IS the app: after the security gates the user lands
/// directly in a live video conversation with their assistant
/// (LiveScreen). Voice mode, history, clients, settings and MCP are
/// secondary screens behind ⋯ More.
class MyAssistantApp extends StatelessWidget {
  const MyAssistantApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MyAssistant',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.dark, // dark-first, always
      home: const AuthGate(),
    );
  }
}

/// Splash while restoring the session, then AuthScreen (signed out) or the
/// live assistant (signed in). Listens to AuthService so sign-in and sign-out
/// swap automatically. The first-run interview is handled by the agent
/// page itself as a glass sheet — no extra route.
class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> with WidgetsBindingObserver {
  bool _restoring = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this); // F1 — relock on background
    AppLock.instance.addListener(_onAuthChanged);
    AuthService.instance.addListener(_onAuthChanged);
    AuthService.instance.init().whenComplete(() {
      if (mounted) setState(() => _restoring = false);
    });
  }

  @override
  void dispose() {
    AuthService.instance.removeListener(_onAuthChanged);
    AppLock.instance.removeListener(_onAuthChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Ask again whenever the app leaves the foreground (F1).
    if (state == AppLifecycleState.paused) AppLock.instance.relock();
  }

  void _onAuthChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (_restoring) return const SplashScreen();
    final auth = AuthService.instance;
    if (!auth.isSignedIn) return const AuthScreen();
    // F1 — optional fingerprint/PIN wall in front of everything.
    if (AppLock.instance.shouldLock) return const LockScreen();
    return const LiveScreen();
  }
}
