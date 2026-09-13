import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../design/neon_tokens.dart';
import '../design/theme_controller.dart';
import '../widgets/contact_picker_sheet.dart';
import '../widgets/inline_voice.dart';
import '../widgets/assistant_result_overlay.dart';
import '../features/assistant/state/assistant_engine.dart';
import '../features/assistant/state/assistant_state.dart';
import '../core/log.dart';
import '../services/auth_service.dart';
import '../features/assistant/widgets/action_cards.dart' show DocumentGalleryScreen;
import '../screens/assistant_settings_screen.dart';
import '../screens/home_dashboard.dart';
import '../screens/chat_screen.dart';
import '../screens/hub_screen.dart';
import '../services/app_update_service.dart';
import '../services/assistant_identity.dart';
import '../services/brief_service.dart';
import '../services/location_service.dart';
import '../services/share_intake_service.dart';
import '../services/usage_service.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  HOME SHELL — the app's new backbone (Daylight redesign, Sept 2026).
///
///  Three tabs (Home · Hub · You) with the mic docked centre-stage: the
///  dashboard is the resting state, and the voice conversation is a
///  full-screen moment you summon — not a wall you live behind.
///  All boot work that used to live in the old conversation screen
///  happens here,
///  because this is now the first screen after sign-in.
/// ─────────────────────────────────────────────────────────────────────────
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  /// Survives the full-tree rebuild a theme flip causes, so toggling dark
  /// mode in the You tab doesn't dump the user back on Home.
  static int lastTab = 0;

  /// A tab the ASSISTANT was asked to open ("open my settings"). The shell
  /// listens and switches; a notifier rather than a plain field because
  /// the request arrives from a voice turn, long after this State was
  /// built, and nothing else would tell it to rebuild.
  static final ValueNotifier<int?> requestedTab = ValueNotifier<int?>(null);

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  /// The cached profile is written once at sign-in and can go stale — a
  /// renamed account kept being greeted by its old name. One quiet
  /// round-trip at startup keeps the spoken name current.
  void _refreshProfileOnce() {
    AuthService.instance.refreshUser().catchError((_) {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Returning to the foreground re-checks for a published update (the
    // service throttles to every 30 min) — a phone that keeps the app in
    // memory for days used to miss releases entirely.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      AssistantEngine.instance.onAppPaused();
    }
    if (state == AppLifecycleState.resumed && mounted) {
      // Adaptive theme: an app left open (or backgrounded) across dusk
      // catches up the moment it is looked at again.
      ThemeController.refresh();
      // A voice session interrupted by another app is rebuilt here —
      // coming back from Instagram used to leave the orb unable to speak.
      AssistantEngine.instance.onAppResumed();
      Timer(const Duration(seconds: 2), () {
        if (mounted) AppUpdateService.instance.check(context);
      });
    }
  }

  @override
  void dispose() {
    HomeShell.requestedTab.removeListener(_onTabRequested);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }



  int _tab = HomeShell.lastTab;

  void _onTabRequested() {
    final want = HomeShell.requestedTab.value;
    if (want == null || !mounted) return;
    HomeShell.requestedTab.value = null; // consume, so it fires once
    if (want < 0 || want > 3 || want == _tab) return;
    HomeShell.lastTab = want;
    setState(() => _tab = want);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    HomeShell.requestedTab.addListener(_onTabRequested);
    final engine = AssistantEngine.instance;
    engine.start();
    engine.ensureFreshSession(); // account switch → new session, new greeting
    // A tapped message notification opens the conversation through the
    // same route as the mic button, so the assistant pops up and speaks.
    engine.onOpenConversation = () {
      if (!mounted) return false;
      _startConversation();
      return true;
    };
    // Recalled documents ("show me Chetan's evidence") pop up as a
    // full-screen swipe gallery over whatever screen is on top — the
    // conversation keeps running underneath, mic stays hot.
    engine.onShowDocuments = (docs) {
      if (!mounted || docs.isEmpty) return false;
      final nav = Navigator.of(context, rootNavigator: true);
      if (_galleryShowing) nav.pop();
      _galleryShowing = true;
      // The pop above completes in a MICROTASK — its whenComplete used to
      // clear the flag we just set, so a third recall stacked galleries.
      final gen = ++_galleryGen;
      nav
          .push(MaterialPageRoute(
            fullscreenDialog: true,
            builder: (_) => DocumentGalleryScreen(documents: docs),
          ))
          .whenComplete(() {
        if (gen == _galleryGen) _galleryShowing = false;
      });
      return true;
    };
    // Duplicate contact names ("call Manish" with three Manishes) resolve
    // by TAP, not by a spoken back-and-forth: the sheet pops instantly over
    // whatever screen is on top and one tap places the call.
    // An inline turn that needs a CARD (a confirmation to tap) can't show
    // it on Home — the conversation screen opens just for those.
    engine.onPickContact = (spokenName, matches, onChosen) {
      if (!mounted) {
        onChosen(null);
        return;
      }
      ContactPickerSheet.show(context,
              spokenName: spokenName, matches: matches)
          .then(onChosen);
    };
    _bootOnce();
  }

  /// Everything below runs ONCE per process, not once per HomeShell.
  ///
  /// A theme change rebuilds the app from the root, so this State is
  /// recreated while the app is sitting in the user's hand — and adaptive
  /// mode, the default, flips the theme on its own at 19:00 and 06:00.
  /// Without this guard each flip re-fired the whole launch sequence:
  /// a second /auth/me, a fresh profile fetch, a GPS fix, a usage upload,
  /// and a re-armed update check that could throw its dialog over
  /// whatever the user was doing — including a live conversation.
  ///
  /// The engine callbacks above are deliberately NOT in here: they close
  /// over this State's context and must be re-pointed at the new one.
  ///
  /// Keyed on the ACCOUNT, not a bare bool: signing out and back in as
  /// someone else also rebuilds this State, and that genuinely does need
  /// the launch sequence again — otherwise the new user would be greeted
  /// under the previous user's assistant name. Same rule the engine uses
  /// for its session (ensureFreshSession).
  static String? _bootedUid;
  void _bootOnce() {
    final uid = AuthService.instance.user?.id.toString();
    if (uid == null || _bootedUid == uid) return;
    _bootedUid = uid;
    _refreshProfileOnce();
    // The assistant's user-chosen name — every visible mention reads this.
    AssistantIdentity.load();
    BriefService.instance.start();
    // Deliberately NO message announcing here: launching the app must be
    // SILENT. Unread messages sit in the Home feed and are spoken when
    // the user starts a conversation or taps the message notification.
    // Silent no-ops until their permissions are granted.
    UsageService.instance.syncIfPermitted();
    LocationService.instance.refresh();
    // Photos/PDFs shared from other apps land in the document pipeline.
    ShareIntakeService.instance.start();
    // OEM battery managers throttle sideloaded apps into silence (pushes
    // delayed, background killed) — ask ONCE for the exemption, a few
    // seconds in so it never fights the launch.
    Timer(const Duration(seconds: 4), _requestBatteryExemptionOnce);
    // Self-update: offer a newer published build once per launch, after
    // the permission prompts have had their moment.
    Timer(const Duration(seconds: 9), () {
      if (mounted) AppUpdateService.instance.check(context);
    });
  }

  /// Battery-optimization exemption — the difference between pushes that
  /// arrive and a Samsung that puts the app to sleep after a few hours.
  /// Asking once-ever was the bug: one dismissed dialog and notifications
  /// silently died forever. Now: skip while granted, otherwise re-ask at
  /// most once a week until it is granted.
  Future<void> _requestBatteryExemptionOnce() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final status = await Permission.ignoreBatteryOptimizations.status;
      if (status.isGranted) return;
      final lastAsk = prefs.getInt('battery_exemption_last_ask') ?? 0;
      final week = const Duration(days: 7).inMilliseconds;
      if (DateTime.now().millisecondsSinceEpoch - lastAsk < week) return;
      await Permission.ignoreBatteryOptimizations.request();
      // Marked AFTER the request: writing it first meant a launch that
      // was backgrounded within 4 s never asked, and the flag said it had.
      await prefs.setInt('battery_exemption_last_ask',
          DateTime.now().millisecondsSinceEpoch);
    } catch (_) {}
  }

  /// True while the conversation route is on top — the notification-tap
  /// hook must not stack a second copy of the screen.

  /// True while the document gallery is on top — a second recall replaces
  /// the open gallery instead of stacking another.
  bool _galleryShowing = false;
  int _galleryGen = 0;

  /// A tapped message notification used to open the conversation screen
  /// so the assistant could speak. The conversation now happens in place,
  /// so it just starts one.
  Future<void> _startConversation() async {
    HapticFeedback.mediumImpact();
    final engine = AssistantEngine.instance;
    if (engine.liveActive || engine.inlineVoice) return;
    await engine.beginInlineConversation(name: AuthService.instance.user?.name);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Neon.bg,
      extendBody: true,
      body: Stack(
        children: [
          IndexedStack(
            index: _tab,
            children: const [
              HomeDashboard(),
              HubScreen(),
              ChatScreen(),
              AssistantSettingsScreen(),
            ],
          ),
          // Floating captions for the inline (no-screen) conversation.
          const InlineCaptionOverlay(),
          // The cards a turn produces — a confirmation to tap, a call in
          // progress, a written piece, search results. These lived only
          // inside the old conversation screen, which is why Home had to
          // throw that screen over itself the moment a turn needed a tap.
          const AssistantResultOverlay(),
        ],
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      // TAP: talk right here — the orb wakes in place, captions float above
      // the dock, no second screen. Tap again to stop.
      //
      // There is no second screen any more, so the stale-flag self-heal
      // that used to guard both handlers is gone with it — the orb now
      // answers every tap, which is what it should always have done.
      floatingActionButton: AssistantOrbButton(
        onTap: () async {
          HapticFeedback.mediumImpact();
          final engine = AssistantEngine.instance;
          // Decide by what is actually RUNNING, not by a flag that may lag:
          // a live session, a connect in flight, or a busy classic turn all
          // mean "tap = stop"; a resting engine means "tap = talk".
          final running = engine.liveActive ||
              (engine.phase != AssistantPhase.idle &&
                  engine.phase != AssistantPhase.completed);
          AppLog.add('orb', running ? 'tap → stop' : 'tap → start');
          if (running) {
            await engine.endInlineConversation();
          } else {
            await engine.beginInlineConversation(
                name: AuthService.instance.user?.name);
          }
        },
        // HOLD used to open the conversation screen with the avatar face.
        // That screen is gone, and face mode is off server-side anyway
        // (features.face_mode is false), so a hold would have opened an
        // empty room. It ends the conversation instead — the one thing a
        // deliberate long press on a live mic should reliably do.
        onLongPress: () async {
          HapticFeedback.heavyImpact();
          final engine = AssistantEngine.instance;
          if (engine.inlineVoice || engine.liveActive) {
            AppLog.add('orb', 'hold → stop');
            await engine.endInlineConversation();
          }
        },
      ),
      bottomNavigationBar: BottomAppBar(
        color: Neon.surface,
        elevation: 0,
        height: 66,
        shape: const CircularNotchedRectangle(),
        notchMargin: 8,
        padding: EdgeInsets.zero,
        child: Row(
          children: [
            // Two items each side of the notch keeps the row symmetric.
            _navItem(0, Icons.space_dashboard_outlined,
                Icons.space_dashboard_rounded, 'Home'),
            _navItem(
                1, Icons.grid_view_outlined, Icons.grid_view_rounded, 'Hub'),
            const SizedBox(width: 72), // notch space for the mic
            _navItem(2, Icons.chat_bubble_outline_rounded,
                Icons.chat_bubble_rounded, 'Chat'),
            _navItem(3, Icons.person_outline_rounded, Icons.person_rounded,
                'You'),
          ],
        ),
      ),
    );
  }

  Widget _navItem(int i, IconData icon, IconData active, String label) {
    final selected = _tab == i;
    return Expanded(
      child: InkWell(
        onTap: () {
          HapticFeedback.selectionClick();
          HomeShell.lastTab = i;
          setState(() => _tab = i);
        },
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(selected ? active : icon,
                size: 23, color: selected ? Neon.textHi : Neon.textDim),
            const SizedBox(height: 3),
            Text(label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected ? Neon.textHi : Neon.textDim,
                )),
          ],
        ),
      ),
    );
  }
}
