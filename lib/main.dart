import 'package:package_info_plus/package_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kDebugMode;

import 'design/accent_controller.dart';
import 'design/theme_controller.dart';
import 'screens/auth/auth_screen.dart';
import 'screens/auth/assistant_setup_screen.dart';
import 'screens/auth/phone_verify_screen.dart';
import 'screens/lock_screen.dart';
import 'screens/splash_screen.dart';
import 'services/api_service.dart';
import 'services/app_feedback.dart';
import 'services/app_lock.dart';
import 'services/auth_service.dart';
import 'services/avatar_message_service.dart';
import 'services/brief_service.dart';
import 'services/style_prefs.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:firebase_core/firebase_core.dart';
import 'services/background_scan.dart';
import 'services/push_service.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Background call-recording scans (WorkManager) — cheap registration;
  // the periodic task itself only exists while AI call analysis is on.
  await BackgroundScan.init();
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
  // Load the saved theme BEFORE the first frame (also sets the system
  // bars to match — light bars/dark icons or the other way around).
  await ThemeController.load();
  await AccentController.load();
  // Style + language prefs load in parallel with the first frame; every
  // later read is a plain field access (no disk on hot paths).
  StylePrefs.instance.load();
  // Runtime server override (Diagnostics screen) — must resolve before
  // the first request, or the engine would connect to the wrong host.
  ApiService.loadServerOverride();
  // AWAITED, AND IT HAS TO BE. This used to be fire-and-forget alongside
  // runApp, which is a race: the session POST, the capability report and
  // the live socket all go out within the first second, and on a phone
  // where the platform channel answers a moment later they carry no
  // X-App-Build header at all. The server then records build 0 — and
  // every build gate reads that as "too old", which is how the client was
  // told his up-to-date app needed updating before it could open anything.
  //
  // He lost this race on all 288 of his turns while another tester on the
  // same APK never did, because it is decided by device timing and nothing
  // else. One platform channel call costs a few milliseconds; a build the
  // server never learns costs the feature.
  try {
    final info = await PackageInfo.fromPlatform();
    ApiService.appBuild = int.tryParse(info.buildNumber);
  } catch (_) {
    // Unknown build is survivable; a wrong one is not.
  }
  AppLock.instance.init(); // F1 — resolves before AuthGate finishes restoring
  runApp(const MyAssistantApp());
}

/// The live call IS the app: after the security gates the user lands
/// directly in a live voice conversation with their assistant
/// (HomeShell). Voice mode, history, clients, settings and MCP are
/// secondary screens behind ⋯ More.
class MyAssistantApp extends StatelessWidget {
  const MyAssistantApp({super.key});

  @override
  Widget build(BuildContext context) {
    // The whole tree re-creates when the theme flips: tokens are resolved
    // in build methods, and the KeyedSubtree defeats const-widget caching.
    // Two things repaint the whole app: the light/dark flip and the
    // user's accent colour. Both resolve inside build methods, so the
    // tree is rebuilt for either.
    return ValueListenableBuilder<Color>(
      valueListenable: AccentController.seed,
      builder: (_, __, ___) => ValueListenableBuilder<bool>(
      valueListenable: ThemeController.dark,
      builder: (_, dark, __) => MaterialApp(
        title: 'MyAssistant',
        debugShowCheckedModeBanner: false,
        scaffoldMessengerKey: AppFeedback.messengerKey,
        // Lets the avatar-message popup appear from a push tap no matter
        // which screen is on top.
        navigatorKey: AvatarMessageService.navigatorKey,
        theme: AppTheme.light(),
        darkTheme: AppTheme.light(),
        themeMode: ThemeMode.light, // AppTheme reads Neon.isDark itself
        home: KeyedSubtree(
            key: ValueKey('$dark|${AccentController.seed.value.toARGB32()}'),
            child: const AuthGate()),
      ),
      ),
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
  /// A theme change rebuilds the entire tree from the root (see the
  /// KeyedSubtree in [MyAssistantApp]), so this State is recreated even
  /// though the app never left the foreground. Restoring the session is a
  /// once-per-process job: re-running it flashed the splash screen over a
  /// live app and re-ran the launch sequence behind it. Adaptive theme
  /// does that flip on its own at dusk and dawn.
  late bool _restoring = !AuthService.instance.restored;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this); // F1 — relock on background
    AppLock.instance.addListener(_onAuthChanged);
    AuthService.instance.addListener(_onAuthChanged);
    if (_restoring) {
      // THE SPLASH MUST BE SEEN. A cached session restores in ~50 ms,
      // which gave the animated opening exactly one frame — "the splash
      // screen is not visible". Hold it just long enough for the
      // entrance to play; a slow restore already takes longer anyway.
      final shownAt = DateTime.now();
      AuthService.instance.init().whenComplete(() {
        const minShow = Duration(milliseconds: 1700);
        final left = minShow - DateTime.now().difference(shownAt);
        Future.delayed(left.isNegative ? Duration.zero : left, () {
          if (mounted) setState(() => _restoring = false);
        });
      });
    }
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
    // Coming BACK to the foreground refetches the home brief. Without this
    // the dashboard showed whatever the 5-minute timer last saw, which read
    // as "changes only appear after closing and reopening the app".
    if (state == AppLifecycleState.resumed) {
      BriefService.instance.refresh(force: true);
      // Re-assert the FCM token too. Idempotent and instant when already
      // registered; rescues devices whose launch-time registration failed
      // (offline start) and would otherwise miss every push until the next
      // cold start.
      if (AuthService.instance.isSignedIn) {
        PushService.instance.syncToken(force: true);
      }
    }
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
    // Last onboarding step: a first-time account names its assistant.
    return const AssistantSetupGate();
  }
}
