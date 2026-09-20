import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../design/neon_tokens.dart';
import '../design/theme_controller.dart';
import '../widgets/contact_picker_sheet.dart';
import '../widgets/ambient_background.dart';
import '../widgets/inline_voice.dart';
import '../widgets/activity_pill.dart';
import '../widgets/news_panel.dart';
import '../widgets/schedule_panel.dart';
import '../widgets/assistant_result_overlay.dart';
import '../features/assistant/state/assistant_engine.dart';
import '../features/assistant/state/assistant_state.dart';
import '../services/call_notes_service.dart';
import '../services/streak_service.dart';
import '../services/call_recording_watcher.dart';
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
      // Coming back from a phone call is exactly when a fresh system
      // call recording exists — pick it up for analysis now.
      CallRecordingWatcher.instance.scan();
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
    // AI CALL ANALYSIS over the phone's own recorder: hydrate the consent
    // toggle so the watcher knows whether to pick up new recordings.
    CallNotesService.instance.start();
    // Count today towards the streak before the first frame settles, so
    // the header shows the right number on this launch, not the next one.
    StreakService.instance.touch().then((_) {
      if (mounted) setState(() {});
    });
    // ON BY DEFAULT — but only after the user has been TOLD. One sheet,
    // once per install, shortly after sign-in lands on Home; nothing is
    // read until they answer (the server holds consentAt at 0 till then).
    Timer(const Duration(seconds: 3), () {
      if (mounted) _maybeShowCallNotesIntro();
    });
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
  ///
  /// The conversation starts ONLY on a user gesture — an orb tap or a
  /// tapped notification. The app opening or returning to the foreground
  /// never starts one: the assistant must not speak unprompted.
  /// The call-notes sign-in notice. Consent by information: the feature
  /// ships ON, the user is told plainly what it does the first time they
  /// land on Home, and one tap either keeps it or kills it. Nothing is
  /// read before they answer.
  Future<void> _maybeShowCallNotesIntro() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool('call_notes_intro_v1') == true) return;
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        isDismissible: false,
        enableDrag: false,
        backgroundColor: Neon.surface,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
        builder: (ctx) => Padding(
          padding: const EdgeInsets.fromLTRB(22, 20, 22, 26),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(Icons.graphic_eq_rounded, color: Neon.violet, size: 20),
                const SizedBox(width: 9),
                Text('Your calls, understood',
                    style: TextStyle(
                        color: Neon.textHi,
                        fontSize: 17,
                        fontWeight: FontWeight.w700)),
              ]),
              const SizedBox(height: 10),
              Text(
                'Your assistant can read the call recordings your phone\'s '
                'own dialer saves, and turn them into your agenda — '
                'meetings, reminders and promises are filed automatically, '
                'and you can ask what was said on any recorded call.\n\n'
                '• Only calls recorded from now on are read.\n'
                '• Audio is deleted right after transcription; only text '
                'is kept, and your files are never touched.\n'
                '• You can switch this off any time in Hub → Call notes.\n'
                '• Where you live may require telling the other person a '
                'call is recorded — that part is on you.',
                style:
                    TextStyle(color: Neon.textLo, fontSize: 13, height: 1.45),
              ),
              const SizedBox(height: 16),
              Row(children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () async {
                      Navigator.pop(ctx);
                      await CallNotesService.instance.setAnalysis(false);
                    },
                    child: const Text('Turn off'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    onPressed: () async {
                      Navigator.pop(ctx);
                      await CallRecordingWatcher.instance.ensurePermission();
                      await CallNotesService.instance.setAnalysis(true);
                      CallRecordingWatcher.instance.scan();
                    },
                    child: const Text('Keep it on'),
                  ),
                ),
              ]),
            ],
          ),
        ),
      );
      await prefs.setBool('call_notes_intro_v1', true);
    } catch (_) {}
  }

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
      // The ambient ground sits behind every tab, so switching tabs does
      // not switch rooms.
      body: AmbientBackground(
        child: Stack(
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
          // CONTENT MUST NOT END MID-LETTER. Every tab is a scrolling
          // list under a floating mic and a notched dock, so whatever is
          // passing behind them showed as ghost text sliced by the orb.
          // A short fade to the page ground makes the list dissolve into
          // the dock instead — the standard fix, and the reason lists
          // also carry bottom padding so the LAST card clears it.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 92,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Neon.bg.withValues(alpha: 0.0),
                      Neon.bg.withValues(alpha: 0.85),
                      Neon.bg,
                    ],
                    stops: const [0.0, 0.55, 1.0],
                  ),
                ),
              ),
            ),
          ),
          // Floating captions for the inline (no-screen) conversation.
          const InlineCaptionOverlay(),
          // The last spoken answer lingers as a readable card once the
          // voice stops — spoken words evaporate; this one doesn't.
          const AnswerAfterglow(),
          // The cards a turn produces — a confirmation to tap, a call in
          // progress, a written piece, search results. These lived only
          // inside the old conversation screen, which is why Home had to
          // throw that screen over itself the moment a turn needed a tap.
          const AssistantResultOverlay(),
          // Today's headlines, over everything but the activity pill.
          const NewsPanel(),
          // The day's commitments, same layer as the headlines.
          const SchedulePanel(),
          // WHAT IT IS DOING, WHILE IT DOES IT. Sits above the captions and
          // the cards, clear of the dock. Without this a web search — now
          // the default for anything that could have changed, not a last
          // resort — was four silent seconds that read as a frozen app.
          Positioned(
            left: 0,
            right: 0,
            // AT THE TOP, because the bottom of this screen is crowded and
            // every bottom position collided with something. The Scaffold
            // paints bottomNavigationBar and the FAB AFTER the body, so a
            // pill in the body is covered by the 76dp centre-docked orb;
            // moving it clear of the orb then put it across the result and
            // confirmation cards, which sit at padding.bottom + 84. The
            // top is empty, is never overdrawn by the dock or the cards,
            // and is where a status banner belongs anyway.
            top: 10 + MediaQuery.of(context).viewPadding.top,
            child: const Align(
              alignment: Alignment.center,
              child: AssistantActivityPill(),
            ),
          ),
        ],
      ),
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
            // Active tab in the primary accent — the standard convention;
            // white-on-gray needed a second look to find where you were.
            // The little grow on selection is the only dock motion.
            AnimatedScale(
              scale: selected ? 1.12 : 1.0,
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutBack,
              // The selected tab sits in its own soft violet pill, so
              // "where am I" reads at a glance instead of needing a
              // colour comparison between two small icons.
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
                decoration: BoxDecoration(
                  color: selected
                      ? Neon.violet.withValues(alpha: 0.16)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(Neon.rPill),
                ),
                child: Icon(selected ? active : icon,
                    size: 22, color: selected ? Neon.violet : Neon.textDim),
              ),
            ),
            const SizedBox(height: 3),
            Text(label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected ? Neon.violet : Neon.textDim,
                )),
          ],
        ),
      ),
    );
  }
}
