import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/services.dart';

import 'design/neon_tokens.dart';
import 'shell/home_shell.dart';
import 'screens/auth/auth_screen.dart';
import 'screens/auth/phone_verify_screen.dart';
import 'screens/lock_screen.dart';
import 'screens/splash_screen.dart';
import 'services/api_service.dart';
import 'services/app_lock.dart';
import 'services/auth_service.dart';
import 'services/style_prefs.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:firebase_core/firebase_core.dart';
import 'services/push_service.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp();
    await PushService.instance.init();
  } catch (e) {
    debugPrint('Firebase init failed (missing google-services.json?): $e');
  }
  AudioPlayer.global.setAudioContext(AudioContext(
    android: const AudioContextAndroid(
      isSpeakerphoneOn: true,
      stayAwake: true,
      contentType: AndroidContentType.speech,
      usageType: AndroidUsageType.media,
      audioFocus: AndroidAudioFocus.none,
    ),
    iOS: AudioContextIOS(
      category: AVAudioSessionCategory.playAndRecord,
      options: const {
        AVAudioSessionOptions.defaultToSpeaker,
        AVAudioSessionOptions.allowBluetooth,
      },
    ),
  ));
  // Daylight design: light bars, dark icons.
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
    systemNavigationBarColor: Neon.bg,
    systemNavigationBarIconBrightness: Brightness.dark,
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
/// directly in a live voice conversation with their assistant
/// (AssistantScreen). Voice mode, history, clients, settings and MCP are
/// secondary screens behind ⋯ More.
class MyAssistantApp extends StatelessWidget {
  const MyAssistantApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MyAssistant',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.light(),
      themeMode: ThemeMode.light, // light-first, always
      home: const AuthGate(),
    );
  }
}

/// Splash while restoring the session, then AuthScreen (signed out) or the
/// live assistant (signed in). Listens to AuthService so sign-in and sign-out
/// swap automatically. The first-run interview is handled by the agent
/// page itself as a glass sheet — no extra route.
/// DEV ONLY — skip the mandatory phone-verification step.
///
///     flutter run --dart-define=SKIP_PHONE_GATE=true
///
/// Exists so work can continue while Firebase Phone Auth is unavailable
/// (it needs the Blaze plan to send real SMS). Two things keep it from
/// ever reaching users: it is a COMPILE-TIME constant, so without the flag
/// the branch is not even built; and it is ANDed with kDebugMode, so
/// passing the flag to a release build still does nothing.
///
/// While this is on, the account has no verified number — so agent-to-agent
/// messaging will not find it, and nobody can send to it. Everything else
/// works normally.
const bool _skipPhoneGate =
    kDebugMode && bool.fromEnvironment('SKIP_PHONE_GATE');

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

    // Registration is not finished until a number is VERIFIED: it is the
    // address other people's agents deliver to, so an account without one
    // can never be reached.
    //
    // id == -1 is the offline/server-hiccup placeholder AuthService falls
    // back to, and it carries no phone state. Gating on it would strand an
    // already-verified user behind a screen that cannot complete without a
    // network — so an unknown user is let through, and the gate applies
    // only when the server actually told us the number is missing.
    final u = auth.user;
    if (!_skipPhoneGate && u != null && u.id > 0 && !u.phoneVerified) {
      return const PhoneVerifyScreen();
    }

    // F1 — optional fingerprint/PIN wall in front of everything.
    if (AppLock.instance.shouldLock) return const LockScreen();
    return const HomeShell();
  }
}
