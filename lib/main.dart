import 'package:package_info_plus/package_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kDebugMode;

import 'core/bundled_fonts.dart';
import 'design/accent_controller.dart';
import 'design/motion.dart';
import 'design/theme_controller.dart';
import 'design/neon_tokens.dart';
import 'screens/auth/auth_screen.dart';
import 'screens/auth/assistant_setup_screen.dart';
import 'screens/auth/phone_verify_screen.dart';
import 'screens/lock_screen.dart';
import 'screens/splash_screen.dart';
import 'services/api_service.dart';
import 'services/app_feedback.dart';
import 'services/app_lock.dart';
import 'services/auth_service.dart';
import 'features/poster/poster_controller.dart';
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
  useBundledFonts();
  // Background call-recording scans (WorkManager) — cheap registration;
  // the periodic task itself only exists while AI call analysis is on.
  await BackgroundScan.init();
  // Every Manrope weight, asked for together and early (2026-09-24): the
  // clarity pass added Medium, Bold and ExtraBold, which a phone updating
  // from build 107 has never downloaded. They load while the rest of
  // startup runs, and runApp waits at most 400 ms for them (NeonType).
  final fonts = NeonType.preload();
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
  await fonts; // usually long done; never throws
  AppLock.instance.init(); // F1 — resolves before AuthGate finishes restoring
  // Before runApp, so back reaches it before the app's Navigator.
  WidgetsBinding.instance.addObserver(LockBackGuard(() => AuthGate.locked));
  // Signing out also clears this phone's copy of the identity video and
  // any downloaded video notes (2026-09-26).
  AvatarMessageService.wireSignOut();
  // …and the photo cards: the card, its photo and his signature on this
  // phone (review, 2026-09-26: they met the next account on a shared phone).
  PosterController.wireSignOut();
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
        // Toasts wait while a sheet or dialog covers the screen, and do not
        // follow the user off the page they belonged to.
        navigatorObservers: [AppFeedback.observer],
        theme: AppTheme.light(),
        darkTheme: AppTheme.light(),
        themeMode: ThemeMode.light, // AppTheme reads Neon.isDark itself
        // F1 — the app lock, drawn over the Navigator so it covers every
        // screen, not only the first one (audit, 2026-09-27).
        builder: (context, child) => LockLayer(
            locked: () => AuthGate.locked,
            changes: AuthGate.lockChanges,
            child: child!),
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

  /// Up while the session restores and the splash plays. A theme change
  /// rebuilds the entire tree from the root (see the KeyedSubtree in
  /// [MyAssistantApp]), so the State is recreated even though the app
  /// never left the foreground. Restoring the session is a
  /// once-per-process job: re-running it flashed the splash screen over a
  /// live app and re-ran the launch sequence behind it. Adaptive theme
  /// does that flip on its own at dusk and dawn. So this lives here, not
  /// in the State.
  static final ValueNotifier<bool> splash =
      ValueNotifier<bool>(!AuthService.instance.restored);
  static bool _restoreStarted = false;

  /// Whether the app lock (F1) is up now. [LockLayer] draws it over every
  /// screen; it applies where [_AuthGateState._gate] would reach the app
  /// itself — never over the splash, sign-in or number verification.
  static bool get locked {
    if (splash.value) return false;
    final auth = AuthService.instance;
    if (!auth.isSignedIn || _needsPhone(auth)) return false;
    return AppLock.instance.shouldLock;
  }

  /// What [locked] depends on.
  static final Listenable lockChanges =
      Listenable.merge([splash, AuthService.instance, AppLock.instance]);

  /// Registration is not finished until a number is VERIFIED: it is the
  /// address other people's agents deliver to, so an account without one
  /// can never be reached.
  ///
  /// id == -1 is the offline/server-hiccup placeholder AuthService falls
  /// back to, and it carries no phone state. Gating on it would strand an
  /// already-verified user behind a screen that cannot complete without a
  /// network — so an unknown user is let through, and the gate applies
  /// only when the server actually told us the number is missing.
  static bool _needsPhone(AuthService auth) {
    final u = auth.user;
    return !_skipPhoneGate && u != null && u.id > 0 && !u.phoneVerified;
  }

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> with WidgetsBindingObserver {
  bool get _restoring => AuthGate.splash.value;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this); // F1 — relock on background
    AppLock.instance.addListener(_onAuthChanged);
    AuthService.instance.addListener(_onAuthChanged);
    AuthGate.splash.addListener(_onAuthChanged);
    if (_restoring && !AuthGate._restoreStarted) {
      AuthGate._restoreStarted = true;
      // THE SPLASH MUST BE SEEN. A cached session restores in ~50 ms,
      // which gave the animated opening exactly one frame — "the splash
      // screen is not visible". Hold it just long enough for the
      // entrance to play; a slow restore already takes longer anyway.
      final shownAt = DateTime.now();
      AuthService.instance.init().whenComplete(() {
        const minShow = Duration(milliseconds: 1700);
        final left = minShow - DateTime.now().difference(shownAt);
        Future.delayed(left.isNegative ? Duration.zero : left,
            () => AuthGate.splash.value = false);
      });
    }
  }

  @override
  void dispose() {
    AuthGate.splash.removeListener(_onAuthChanged);
    AuthService.instance.removeListener(_onAuthChanged);
    AppLock.instance.removeListener(_onAuthChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Ask again after the app has been away for a while (F1) — not for a
    // quick trip to the camera or a UPI app (AppLock.grace).
    if (state == AppLifecycleState.paused) AppLock.instance.notePaused();
    if (state == AppLifecycleState.resumed) AppLock.instance.noteResumed();
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

  /// FROM THE SPLASH INTO THE APP, NOT A CUT (2026-09-24). After the
  /// animated splash the app used to cut to Home in one frame, the dock
  /// and mic at full size — on every cold launch — and sign-in, unlock
  /// and setup-to-app were the same kind of cut. Each step now fades into
  /// the next. What shows, and when it starts, is unchanged: the next
  /// screen is built at once, only its first 280 ms are a fade.
  ///
  /// EXCEPT THE LOCK. Relocking switches INSTANTLY: a lock that faded in
  /// would leave private content showing under a half-drawn lock.
  @override
  Widget build(BuildContext context) {
    final gate = _gate();
    return AnimatedSwitcher(
      duration: gate is _Locked
          ? Duration.zero
          : const Duration(milliseconds: 280),
      reverseDuration: const Duration(milliseconds: 160),
      switchInCurve: Motion.easeFadeIn,
      switchOutCurve: Motion.easeFadeOut,
      layoutBuilder: (current, previous) => Stack(
        fit: StackFit.expand,
        children: [...previous, if (current != null) current],
      ),
      child: KeyedSubtree(key: ValueKey(gate.runtimeType), child: gate),
    );
  }

  Widget _gate() {
    if (_restoring) return const SplashScreen();
    final auth = AuthService.instance;
    if (!auth.isSignedIn) return const AuthScreen();
    if (AuthGate._needsPhone(auth)) return const PhoneVerifyScreen();

    // F1 — optional fingerprint/PIN wall in front of everything. The lock
    // itself is drawn over every screen by LockLayer; here the app stops
    // until unlock, its live voice session included.
    if (AppLock.instance.shouldLock) return const _Locked();
    // Last onboarding step: a first-time account names its assistant.
    return const AssistantSetupGate();
  }
}

/// Home while the app lock is up: nothing runs and nothing shows under
/// the lock ([LockLayer]).
class _Locked extends StatelessWidget {
  const _Locked();

  @override
  Widget build(BuildContext context) => ColoredBox(color: Neon.bg);
}
