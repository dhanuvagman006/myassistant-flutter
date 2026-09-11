import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../design/neon_tokens.dart';
import '../widgets/contact_picker_sheet.dart';
import '../widgets/inline_voice.dart';
import '../features/assistant/assistant_screen.dart';
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
///  All boot work that used to live in AssistantScreen happens here,
///  because this is now the first screen after sign-in.
/// ─────────────────────────────────────────────────────────────────────────
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  /// Survives the full-tree rebuild a theme flip causes, so toggling dark
  /// mode in the You tab doesn't dump the user back on Home.
  static int lastTab = 0;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
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
    WidgetsBinding.instance.removeObserver(this);
    AssistantEngine.instance.removeListener(_maybeEscalateInline);
    super.dispose();
  }

  void _maybeEscalateInline() {
    final engine = AssistantEngine.instance;
    if (!mounted || _conversationShowing) return;
    // A turn that needs a tappable card gets the full screen; everything
    // else stays inline. (No state-resetting here: an eager reset during
    // the connect window used to kill sessions as they were being born.)
    if (engine.inlineVoice && engine.pendingConfirmation != null) {
      _openConversation();
    }
  }

  int _tab = HomeShell.lastTab;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final engine = AssistantEngine.instance;
    engine.start();
    engine.ensureFreshSession(); // account switch → new session, new greeting
    // A tapped message notification opens the conversation through the
    // same route as the mic button, so the assistant pops up and speaks.
    engine.onOpenConversation = () {
      if (!mounted || _conversationShowing) return false;
      _openConversation();
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
    engine.addListener(_maybeEscalateInline);
    engine.onPickContact = (spokenName, matches, onChosen) {
      if (!mounted) {
        onChosen(null);
        return;
      }
      ContactPickerSheet.show(context,
              spokenName: spokenName, matches: matches)
          .then(onChosen);
    };
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
  bool _conversationShowing = false;

  /// True while the document gallery is on top — a second recall replaces
  /// the open gallery instead of stacking another.
  bool _galleryShowing = false;
  int _galleryGen = 0;

  void _openConversation() {
    HapticFeedback.mediumImpact();
    _conversationShowing = true;
    Navigator.of(context)
        .push(
          PageRouteBuilder(
            fullscreenDialog: true,
            transitionDuration: const Duration(milliseconds: 280),
            pageBuilder: (_, __, ___) => const AssistantScreen(),
            transitionsBuilder: (_, anim, __, child) => SlideTransition(
              position: Tween(begin: const Offset(0, 0.06), end: Offset.zero)
                  .animate(
                      CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
              child: FadeTransition(opacity: anim, child: child),
            ),
          ),
        )
        .whenComplete(() => _conversationShowing = false);
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
        ],
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      // TAP: talk right here — the orb wakes in place, captions float above
      // the dock, no second screen. Tap again to stop. HOLD: the live face
      // agent (avatar video) opens full screen.
      floatingActionButton: AssistantOrbButton(
        onTap: () async {
          HapticFeedback.mediumImpact();
          final engine = AssistantEngine.instance;
          if (_conversationShowing) {
            // Self-heal: if the flag says the conversation screen is up but
            // the navigator has nothing to pop, the flag is stale (seen
            // once after an in-place update) — reset it and serve the tap
            // instead of silently ignoring the user's main button.
            if (!Navigator.of(context, rootNavigator: true).canPop()) {
              AppLog.add('orb', 'stale conversation flag — self-healed');
              _conversationShowing = false;
            } else {
              return;
            }
          }
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
        onLongPress: () async {
          HapticFeedback.heavyImpact();
          final engine = AssistantEngine.instance;
          if (_conversationShowing) {
            if (!Navigator.of(context, rootNavigator: true).canPop()) {
              AppLog.add('orb', 'stale conversation flag — self-healed');
              _conversationShowing = false;
            } else {
              return;
            }
          }
          // Hand the audio over cleanly, then open the screen WITH face
          // mode set — beginConversation reserves the avatar as part of
          // its own startup, so exactly one session comes up, with the
          // face. (The old toggle-then-open raced two startups.)
          if (engine.inlineVoice || engine.liveActive) {
            await engine.endInlineConversation();
          }
          engine.faceMode = true;
          _openConversation();
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
