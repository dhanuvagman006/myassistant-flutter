import 'dart:async';

import '../screens/chat_screen.dart' show ChatThreadScreen;
import '../screens/chat_group_screen.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../design/dock_metrics.dart';
import '../design/motion.dart';
import '../design/tab_deck.dart';
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
import '../services/call_recording_watcher.dart';
import '../services/focus_service.dart';
import '../services/news_feed.dart';
import '../services/notification_service.dart';
import '../services/avatar_message_service.dart';
import '../services/push_service.dart';
import 'focus_nav.dart';
import '../screens/bills_email_screen.dart' show BillsEmailNav;
import '../core/log.dart';
import '../services/auth_service.dart';
import '../features/assistant/widgets/action_cards.dart' show DocumentGalleryScreen;
import '../screens/assistant_settings_screen.dart';
import '../screens/home_dashboard.dart';
import '../screens/meetings/meetings_screen.dart';
import '../services/telemetry.dart';
import '../screens/hub_screen.dart';
import '../features/shopping/shopping_list_screen.dart' show ShoppingNav;
import '../screens/quick_task_screen.dart';
import '../services/app_feedback.dart';
import '../services/app_update_service.dart';
import '../services/assistant_identity.dart';
import '../services/brief_service.dart';
import '../services/location_service.dart';
import '../services/share_intake_service.dart';
import '../services/usage_service.dart';
import '../services/api_service.dart';
import '../services/device_control_service.dart';
import '../services/greeting_voice.dart';
import '../features/reminders/reminder_popup.dart';

/// Where a tapped notification goes, by its payload: a video note left in
/// the tray opens the notes again, a Bills by email one opens that screen
/// (build 120), a focus one opens Focus; anything else just opens the app.
/// [billsEmail] is for tests.
Future<void> openNotificationPayload(String what,
    {Future<void> Function()? billsEmail}) {
  if (what == AvatarMessageService.videoNotePayload) {
    return PushService.instance.openVideoNotes();
  }
  if (what == 'bills_email') return (billsEmail ?? BillsEmailNav.open)();
  // The shopping trip's notification and its Next / Done (build 124).
  if (what == ReminderNotifications.shoppingPayload ||
      what.startsWith('${ReminderNotifications.shoppingPayload}:')) {
    return ShoppingNav.fromNotification(what);
  }
  if (what == 'focus') return FocusNav.open();
  // A direct message (2026-10-04): that person's chat.
  if (what.startsWith('dm:')) {
    final parts = what.split(':');
    final phone = parts.length > 1 ? parts[1] : '';
    final nav = AvatarMessageService.navigatorKey.currentState;
    if (phone.isEmpty || nav == null || ChatThreadScreen.openPhone == phone) {
      return Future<void>.value();
    }
    final name = parts.length > 2 ? parts.sublist(2).join(':') : 'Chat';
    return nav.push(MaterialPageRoute<void>(
        builder: (_) => ChatThreadScreen(phone: phone, name: name)));
  }
  // A group message (2026-10-04): that group's chat.
  if (what.startsWith('group:')) {
    final parts = what.split(':');
    final id = int.tryParse(parts.length > 1 ? parts[1] : '');
    final nav = AvatarMessageService.navigatorKey.currentState;
    if (id == null || nav == null || ChatGroupScreen.openGroupId == id) {
      return Future<void>.value();
    }
    final title = parts.length > 2 ? parts.sublist(2).join(':') : 'Group';
    return nav.push(MaterialPageRoute<void>(
        builder: (_) => ChatGroupScreen(groupId: id, title: title)));
  }
  // A reminder's own notification (2026-09-30): its pop-up.
  if (what.startsWith(ReminderNotifications.reminderPayload)) {
    return ReminderPopup.openFromPayload(what);
  }
  // Momentum is gone (2026-09-29): an old 'momentum' tap opens the app.
  return Future<void>.value();
}

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

class _HomeShellState extends State<HomeShell>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  /// The cached profile is written once at sign-in and can go stale — a
  /// renamed account kept being greeted by its old name. One quiet
  /// round-trip at startup keeps the spoken name current.
  void _refreshProfileOnce() {
    AuthService.instance.refreshUser().catchError((_) {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshBattery();
      // The fast voice connects now, so the orb's tap listens at once.
      AssistantEngine.instance.prewarmVoice();
    }
    // Returning to the foreground re-checks for a published update (the
    // service throttles to every 30 min) — a phone that keeps the app in
    // memory for days used to miss releases entirely.
    // PAUSED ONLY, NOT INACTIVE. `inactive` fires for anything that
    // merely covers the window — the notification shade, a permission
    // sheet, the app switcher preview, even a swipe gesture. Silencing
    // the session for those tore the microphone down dozens of times a
    // day; `paused` is the state that actually means "gone".
    if (state == AppLifecycleState.paused) {
      AssistantEngine.instance.onAppPaused();
    }
    if (state == AppLifecycleState.resumed && mounted) {
      // Adaptive theme: an app left open (or backgrounded) across dusk
      // catches up the moment it is looked at again.
      ThemeController.refresh();
      // A voice session interrupted by another app is rebuilt here —
      // coming back from Instagram used to leave the orb unable to speak.
      AssistantEngine.instance.onAppResumed();
      // A widget tap while the app was already running arrives here.
      _checkQuickTaskLaunch();
      // Coming back from a phone call is exactly when a fresh system
      // call recording exists — pick it up for analysis now.
      CallRecordingWatcher.instance.scan();
      // News: the saved copy is refreshed quietly if it has gone stale.
      unawaited(NewsFeed.warm());
      unawaited(FocusService.instance.tick());
      Timer(const Duration(seconds: 2), () {
        // Never over a conversation: the sheet used to open on top of one.
        if (mounted && !_conversationRunning) {
          AppUpdateService.instance.check(context);
        }
      });
    }
  }

  /// Is the keyboard up? Kept here and changed only when it FLIPS.
  ///
  /// KEYBOARD FRAMES MUST BE CHEAP (2026-09-24: one 83 ms frame as the
  /// keyboard came up on his phone). This screen used to read the keyboard
  /// height straight from MediaQuery, which made the WHOLE shell — every
  /// tab, the dock, the overlays — rebuild on every frame of the keyboard
  /// sliding in or out, for a yes/no that changes once. It is now read
  /// from the window when the metrics change, and the shell rebuilds only
  /// when the answer changes.
  bool _keyboardUp = false;

  bool _windowKeyboardUp() {
    final view = View.maybeOf(context);
    return view != null && view.viewInsets.bottom > 0;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _keyboardUp = _windowKeyboardUp();
  }

  @override
  void didChangeMetrics() {
    if (!mounted) return;
    final up = _windowKeyboardUp();
    if (up != _keyboardUp) setState(() => _keyboardUp = up);
  }

  /// The quiet news fetch after launch (see _bootOnce); cancelled with the
  /// shell so it never outlives it.
  Timer? _newsWarm;

  @override
  void dispose() {
    _newsWarm?.cancel();
    HomeShell.requestedTab.removeListener(_onTabRequested);
    AssistantEngine.instance.removeListener(_onEngineForPicker);
    AssistantEngine.instance.removeListener(_onEngineForToast);
    _cancelToastLift();
    _tabChanges.dispose();
    // Only if it is still ours: a rebuilt shell (theme flip) has set its own.
    if (AppFeedback.sessionVisible == _sessionVisible) {
      AppFeedback.sessionVisible = null;
    }
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }



  int _tab = HomeShell.lastTab;


  /// LEAVING THE TAB ENDS THE CONVERSATION.
  ///
  /// The live session used to outlive navigation entirely — it was only
  /// ever ended by tapping the orb a second time. So walking from a
  /// conversation to Hub and back left the microphone hot behind the
  /// dashboard and the orb stuck on its stop icon, which is what he saw
  /// on Home (2026-09-20, screenshot). Nothing may keep listening once
  /// the user has moved on; the orb goes back to the mic, and a tap
  /// starts a fresh session.
  void _endConversationOnNavigate() {
    final e = AssistantEngine.instance;
    if (e.liveActive || e.inlineVoice) {
      unawaited(e.endInlineConversation());
    }
  }

  void _onTabRequested() {
    final want = HomeShell.requestedTab.value;
    if (want == null || !mounted) return;
    HomeShell.requestedTab.value = null; // consume, so it fires once
    if (want < 0 || want > 3 || want == _tab) return;
    _endConversationOnNavigate();
    _switchTab(want);
  }

  /// Moving to another tab takes the old tab's toast and the lingering
  /// answer card with it — they were about the screen being left. [from]
  /// is where the dock tap landed: the tab opens in a circle from there
  /// (tab_deck.dart); without it, it slides in from its side.
  void _switchTab(int i, {Offset? from}) {
    AppFeedback.dismiss();
    HomeShell.lastTab = i;
    Telemetry.instance.event('tab', {'name': const ['home', 'hub', 'chats', 'you'][i.clamp(0, 3)]});
    _tabChanges.value++;
    setState(() {
      _tab = i;
      _tabFrom = from;
    });
    // Back on Home the orb is a tap away: the fast voice connects now
    // (it closes itself when nobody talks to it).
    if (i == 0) AssistantEngine.instance.prewarmVoice();
  }

  /// Where the last dock tap landed (the circle's centre).
  Offset? _tabFrom;
  Offset? _tapDown;

  /// Ticks on every tab switch (the answer card listens).
  final ValueNotifier<int> _tabChanges = ValueNotifier<int>(0);

  bool _sessionVisible() => voiceSessionOnScreen(AssistantEngine.instance);

  /// A toast already up when the voice session opens was placed for the
  /// page — right where the session's text box now sits. It moves up.
  bool _sessionWasVisible = false;

  void _onEngineForToast() {
    final now = _sessionVisible();
    if (now && !_sessionWasVisible) _liftToastOnceCovered();
    _sessionWasVisible = now;
  }

  /// ONE MOTION AT A TIME (2026-09-24). The toast used to blink out and
  /// replay its entrance higher up at the very moment the session was
  /// fading in — a second movement at the busiest moment. It now moves
  /// once the session has finished fading in and the screen is still.
  VoidCallback? _pendingLift;

  void _liftToastOnceCovered() {
    _cancelToastLift();
    // An Undo toast still closes at once, exactly as before (its change
    // goes through); only a plain toast waits to move.
    if (InlineCaptionOverlay.covering.value || AppFeedback.showingUndo) {
      AppFeedback.sessionOpened();
      return;
    }
    void lift() {
      if (!InlineCaptionOverlay.covering.value) return;
      _cancelToastLift();
      if (mounted && _sessionVisible()) AppFeedback.sessionOpened();
    }

    _pendingLift = lift;
    InlineCaptionOverlay.covering.addListener(lift);
  }

  void _cancelToastLift() {
    final l = _pendingLift;
    if (l != null) InlineCaptionOverlay.covering.removeListener(l);
    _pendingLift = null;
  }

  /// SYSTEM BACK CLOSES WHAT IS OPEN, TOPMOST FIRST.
  ///
  /// The news and schedule panels, the voice session and the answer cards
  /// are layers of this screen, not routes — so Back used to skip them
  /// and leave the app, and they were still open on return.
  bool _overlayOpen(AssistantEngine e) =>
      e.newsItems.isNotEmpty ||
      e.scheduleItems.isNotEmpty ||
      voiceSessionOnScreen(e) ||
      e.searchResults.isNotEmpty ||
      e.searchSuggestions.isNotEmpty ||
      e.presentedText != null ||
      e.generatedImage != null;

  void _closeTopmost() {
    final e = AssistantEngine.instance;
    if (e.newsItems.isNotEmpty) {
      e.clearNews();
    } else if (e.scheduleItems.isNotEmpty) {
      e.clearSchedule();
    } else if (voiceSessionOnScreen(e)) {
      unawaited(e.endInlineConversation());
    } else if (e.presentedText != null) {
      e.dismissPresentedText();
    } else if (e.generatedImage != null) {
      e.dismissGeneratedImage();
    } else if (e.searchResults.isNotEmpty || e.searchSuggestions.isNotEmpty) {
      e.dismissSearchResults();
    }
  }

  /// THE DUPLICATE-NAME PICKER FOLLOWS THE CONVERSATION.
  ///
  /// The engine also asks "which one?" out loud. Answered by voice, the
  /// sheet used to stay open — and swiping the stale sheet away later
  /// counted as "cancel" and tore down the live turn. It now closes itself
  /// the moment the choice is made (or the turn is reset), and a new
  /// picker replaces an old one instead of stacking on it.
  int _pickerGen = 0;
  Route<dynamic>? _pickerRoute;

  void _closePickerQuietly() {
    final r = _pickerRoute;
    _pickerRoute = null;
    _pickerGen++; // its result is ours, not the user's: ignored
    if (r != null && r.isActive) r.navigator?.removeRoute(r);
  }

  void _onEngineForPicker() {
    if (_pickerRoute != null &&
        AssistantEngine.instance.ambiguousContacts.isEmpty) {
      _closePickerQuietly();
    }
  }

  /// The greeting the orb will speak, cached in the assistant's voice.
  Future<void> _warmGreeting() async {
    try {
      final u = AuthService.instance.user;
      await GreetingVoice.instance.prewarm(
        AssistantEngine.orbGreeting(name: u?.name, gender: u?.gender),
      );
    } catch (_) {/* a greeting that cannot be fetched simply stays quiet */}
  }

  /// Cached on ApiService so neither the header getter nor the socket
  /// connect has to await a platform channel on the hot path.
  Future<void> _refreshBattery() async {
    try {
      final pct = await DeviceControlService.instance.battery();
      if (pct != null && pct >= 0 && pct <= 100) ApiService.batteryPct = pct;
    } catch (_) {
      /* a phone that will not report its charge simply does not. */
    }
  }

  /// DID THE HOME-SCREEN WIDGET OPEN US?
  ///
  /// Asked rather than pushed, and asked in BOTH places, because the
  /// intent and the Dart side race: on a cold start the intent exists
  /// long before this widget is listening, and on a warm start the tap
  /// arrives while the app is already up. The native side keeps a flag
  /// and hands it over exactly once (MainActivity.takeQuickTask), so
  /// neither path can miss it and returning to the app later cannot
  /// reopen the capture.
  Future<void> _checkQuickTaskLaunch() async {
    try {
      final wanted = await const MethodChannel('hari/intent')
          .invokeMethod<bool>('takeQuickTask');
      if (wanted != true || !mounted) return;
      // Never on top of a live conversation — the widget is for handing
      // work over, and the session already has the microphone.
      final engine = AssistantEngine.instance;
      if (engine.liveActive || engine.inlineVoice) {
        await engine.endInlineConversation();
      }
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const QuickTaskScreen()),
      );
    } catch (e) {
      AppLog.add('quicktask', 'launch check failed: $e');
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    HomeShell.requestedTab.addListener(_onTabRequested);
    // Toasts step clear of the voice screen's text box, and anything the
    // assistant also says out loud is not repeated as a toast.
    AppFeedback.sessionVisible = _sessionVisible;
    AssistantEngine.instance.addListener(_onEngineForPicker);
    _sessionWasVisible = _sessionVisible();
    AssistantEngine.instance.addListener(_onEngineForToast);
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkQuickTaskLaunch());
    final engine = AssistantEngine.instance;
    engine.start();
    engine.ensureFreshSession(); // account switch → new session, new greeting
    // AI CALL ANALYSIS over the phone's own recorder: hydrate the consent
    // toggle so the watcher knows whether to pick up new recordings.
    CallNotesService.instance.start();
    // The charge is read once at launch and on every resume, then carried
    // on requests and on the live socket — cheap, and it makes "I'm going
    // out" able to say "charge your phone first" without a round trip.
    _refreshBattery();
    // One /tts call in the app's lifetime; every later tap plays from
    // disk. Deliberately after the first frame — it must never delay
    // launch.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _warmGreeting();
      AssistantEngine.instance.prewarmVoice();
    });
    // (The app-open streak that was counted here is gone: the streak is
    // Momentum's now, on the server — days something got done.)
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
      // The keyboard goes down first (tester run, 2026-10-01): it came back
      // over the voice screen when the picture closed, hiding the dock orb
      // — so the one tap that stops the session had nothing to land on.
      FocusManager.instance.primaryFocus?.unfocus();
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
      _closePickerQuietly();
      final gen = ++_pickerGen;
      ContactPickerSheet.show(context,
              spokenName: spokenName,
              matches: matches,
              onRoute: (r) {
                if (gen == _pickerGen) _pickerRoute = r;
              })
          .then((chosen) {
        if (gen != _pickerGen) return; // closed by us, not the user
        _pickerRoute = null;
        onChosen(chosen);
      });
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
    // Hub → News opens from a saved copy: fetch it once the launch has
    // settled, never in the way of the first frames.
    _newsWarm = Timer(const Duration(seconds: 8), () => unawaited(NewsFeed.warm()));
    unawaited(FocusService.instance.restore());
    // A tapped notification: see openNotificationPayload.
    ReminderNotifications.onOpen = (what) => unawaited(openNotificationPayload(what));
    // A reminder due while the app is open pops up by itself.
    ReminderPopup.startWatching();
    // Deliberately NO message announcing here: launching the app must be
    // SILENT. Unread messages sit in the Home feed and are spoken when
    // the user starts a conversation or taps the message notification.
    // Silent no-ops until their permissions are granted.
    UsageService.instance.syncIfPermitted();
    LocationService.instance.refresh();
    // Photos/PDFs shared from other apps land in the document pipeline.
    ShareIntakeService.instance.start();
    unawaited(_launchPrompts());
  }

  bool get _conversationRunning {
    final e = AssistantEngine.instance;
    return e.liveActive || e.inlineVoice;
  }

  /// ONE PROMPT PER LAUNCH, NEVER OVER A CONVERSATION.
  ///
  /// Launch used to stack them on timers: the call-notes sheet at 3 s, the
  /// battery-exemption dialog at 4 s, the update sheet at 9 s — three
  /// interruptions in the first ten seconds, the last one liable to land
  /// on top of a conversation the user had just started. Now, in order of
  /// importance, the first one that is due is shown and the rest wait for
  /// a later launch:
  ///   1. the call-notes notice (once per install; consent needs it)
  ///   2. "Help improve the assistant?" (once, until they answer)
  ///   3. a newer build (the update sheet)
  ///   4. the battery exemption (weekly until granted)
  Future<void> _launchPrompts() async {
    await Future<void>.delayed(const Duration(seconds: 4));
    // Let a conversation the user started finish first (up to a minute).
    for (var i = 0; i < 30 && mounted && _conversationRunning; i++) {
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    if (!mounted || _conversationRunning) return;
    if (await _maybeShowCallNotesIntro()) return;
    // The one-time "Help improve" question is not shown (owner, 2026-09-27:
    // every tester has agreed); the switch stays in You → Privacy.
    if (!mounted || _conversationRunning) return;
    if (await AppUpdateService.instance.check(context)) return;
    if (!mounted || _conversationRunning) return;
    await _requestBatteryExemptionOnce();
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
  /// Returns true when the sheet was shown.
  Future<bool> _maybeShowCallNotesIntro() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool('call_notes_intro_v1') == true) return false;
      if (!mounted) return false;
      // Marked only when a button is pressed. The system Back button used
      // to close this sheet and still mark it answered, so the user was
      // never asked and the feature ran on a choice they never made.
      Future<void> answer(BuildContext ctx, bool keep) async {
        Navigator.pop(ctx);
        await prefs.setBool('call_notes_intro_v1', true);
        if (keep) {
          await CallRecordingWatcher.instance.ensurePermission();
          await CallNotesService.instance.setAnalysis(true);
          CallRecordingWatcher.instance.scan();
        } else {
          await CallNotesService.instance.setAnalysis(false);
        }
      }

      await showAppSheet<void>(
        context: context,
        isDismissible: false,
        enableDrag: false,
        backgroundColor: Neon.surface,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
        builder: (ctx) => PopScope(
          canPop: false,
          child: Padding(
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
                      onPressed: () => answer(ctx, false),
                      child: const Text('Turn off'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => answer(ctx, true),
                      child: const Text('Keep it on'),
                    ),
                  ),
                ]),
              ],
            ),
          ),
        ),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _startConversation() async {
    HapticFeedback.mediumImpact();
    final engine = AssistantEngine.instance;
    if (engine.liveActive || engine.inlineVoice) return;
    await engine.beginInlineConversation(name: AuthService.instance.user?.name);
  }

  @override
  Widget build(BuildContext context) {
    // The keyboard hides the dock (the Scaffold stops extending the body
    // behind it), so there is nothing to fade into while it is up.
    final keyboardUp = _keyboardUp;
    final engine = AssistantEngine.instance;
    return ListenableBuilder(
      listenable: engine,
      builder: (context, child) => PopScope(
        canPop: !_overlayOpen(engine),
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _closeTopmost();
        },
        child: child!,
      ),
      child: Scaffold(
      backgroundColor: Neon.bg,
      extendBody: true,
      // The ambient ground sits behind every tab, so switching tabs does
      // not switch rooms. Not drawn while the voice session covers it.
      body: ValueListenableBuilder<bool>(
        valueListenable: InlineCaptionOverlay.covering,
        builder: (context, covered, page) =>
            AmbientBackground(covered: covered, child: page!),
        child: Stack(
        children: [
          _UnderSession(
            engine: engine,
            // Tabs are siblings in space: a dock tap brings the new one
            // through (a fade, a lift, pivoting on the button), a sideways
            // swipe moves between them with the finger (tab_deck.dart).
            // Every tab stays built; only the one on screen paints or ticks
            // (a spinner on a hidden Chat once kept the phone redrawing 60
            // times a second).
            child: TabDeck(
              index: _tab,
              origin: _tabFrom,
              onSwipe: (i) {
                _endConversationOnNavigate();
                _switchTab(i);
              },
              children: const [
                HomeDashboard(),
                HubScreen(),
                MeetingsScreen(),
                AssistantSettingsScreen(),
              ],
            ),
          ),
          // CONTENT MUST NOT END MID-LETTER. Every tab is a scrolling
          // list under a floating mic and a notched dock, so whatever is
          // passing behind them showed as ghost text sliced by the orb.
          //
          // SOLID FROM THE BAR DOWN (2026-09-24, hub.png / you.png). The
          // fade used to be a fixed 92 dp that ignored how tall the dock
          // really is (66 dp + the system navigation inset), so at the
          // notch around the mic it was only ~20% opaque and list text
          // showed through the ring. It is now sized from the body's own
          // padding (bar + inset): fully opaque from the bar's top edge
          // down — the notch ring is always plain ground — with a short
          // fade above it where the mic rises over the list.
          if (!keyboardUp)
            Builder(builder: (context) {
              final dockTop = MediaQuery.paddingOf(context).bottom;
              const rise = 52.0; // the mic rises 38 dp over the bar + glow
              final h = dockTop + rise;
              return Positioned(
                key: const ValueKey('dock-fade'),
                left: 0,
                right: 0,
                bottom: 0,
                height: h,
                child: IgnorePointer(
                  // It comes back with the dock when the keyboard closes:
                  // faded in, not switched on in one frame.
                  child: EnterOnce(
                    duration: Motion.micro,
                    child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Neon.bg.withValues(alpha: 0.0),
                          Neon.bg.withValues(alpha: 0.85),
                          Neon.bg,
                          Neon.bg,
                        ],
                        stops: [0.0, 0.6 * rise / h, rise / h, 1.0],
                      ),
                    ),
                    ),
                  ),
                ),
              );
            }),
          // Floating captions for the inline (no-screen) conversation.
          const InlineCaptionOverlay(),
          // The last spoken answer lingers as a readable card once the
          // voice stops — spoken words evaporate; this one doesn't.
          AnswerAfterglow(dismissOn: _tabChanges),
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
            // viewPadding only: it does not move with the keyboard, so a
            // keyboard frame does not rebuild the shell for it.
            top: 10 + MediaQuery.viewPaddingOf(context).top,
            // During a voice session the top-right corner holds the Sound
            // button: the pill drops below that row instead of covering it.
            child: ListenableBuilder(
              listenable: engine,
              builder: (_, child) => AnimatedPadding(
                // In step with the session's own 240 ms fade (it was a
                // linear 200 ms: the pill dropped on a different clock).
                duration: const Duration(milliseconds: 240),
                curve: Motion.easeMove,
                padding: EdgeInsets.only(
                    top: voiceSessionOnScreen(engine) ? 56 : 0),
                child: child,
              ),
              // Its own layer: its dots move for as long as a tool runs.
              child: const RepaintBoundary(
                child: Align(
                  alignment: Alignment.center,
                  child: AssistantActivityPill(),
                ),
              ),
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
      // Hidden while the keyboard is up: docked, it floated over the text
      // box (seen 2026-09-24). Send is on the box; Stop is one tap away
      // once the keyboard closes.
      //
      // NO SPIN WHEN TYPING ENDS (2026-09-24). Hiding it used to swap the
      // button for nothing, so the Scaffold ran its stock FAB change: it
      // shrank the mic out, and brought it back with a hard-coded 45° turn
      // on an ease-in scale — every time typing ended the mic visibly spun
      // and snapped into its notch. The slot now always holds the same
      // widget and the mic is simply not built while the keyboard is up
      // (so no halo ticks behind the keyboard either); it plays its own
      // quiet entrance when it returns (AssistantOrbButton).
      floatingActionButton: Visibility(
        visible: !keyboardUp,
        child: AssistantOrbButton(
        onTap: () async {
          HapticFeedback.mediumImpact();
          final engine = AssistantEngine.instance;
          // ONE TAP STOPS, ALWAYS (client, 1 Oct: two taps to get out, and
          // "Listening" on screen when it was not). A connect in flight, a
          // conversation still marked open, a live session or a busy turn
          // all mean "tap = stop"; only a resting engine means "tap = talk".
          final running = engine.starting ||
              engine.inlineVoice ||
              engine.liveActive ||
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
      ),
      bottomNavigationBar: _DockRim(child: BottomAppBar(
        color: Neon.isDark
            ? Color.alphaBlend(Neon.violet.withValues(alpha: 0.07), Neon.surface)
            : Neon.surface,
        elevation: 0,
        height: Dock.barHeight,
        shape: const CircularNotchedRectangle(),
        // A snug cradle: the visible mic is 64 dp inside its 76 dp box, so
        // a wide margin left a thick ring of whatever was behind the bar.
        notchMargin: 4,
        padding: EdgeInsets.zero,
        child: Row(
          children: [
            // Two items each side of the notch keeps the row symmetric.
            _navItem(0, Icons.space_dashboard_outlined,
                Icons.space_dashboard_rounded, 'Home'),
            _navItem(
                1, Icons.grid_view_outlined, Icons.grid_view_rounded, 'Hub'),
            const SizedBox(width: 72), // notch space for the mic
            // One family for the resting icons (2026-09-24): Home and Hub
            // used the square-cornered outlines while Chat and You used
            // the rounded ones. The selected tab keeps its filled one.
            // Nearby took the Chat tab (2026-10-01, the owner): people around
            // who share what they do. Chat moved to the Hub (Messages).
            // Chats took Nearby's tab (owner, 2026-10-04); Nearby is in the Hub.
            _navItem(2, Icons.chat_bubble_outline_rounded,
                Icons.chat_bubble_rounded, 'Chats'),
            _navItem(3, Icons.person_outline, Icons.person_rounded, 'You'),
          ],
        ),
      )),
    ),
    );
  }

  Widget _navItem(int i, IconData icon, IconData active, String label) {
    final selected = _tab == i;
    return Expanded(
      // The button dips under the finger at once (2026-09-30): nothing
      // scrolls in the dock, so there is no scroll to wait out (PressScale).
      child: PressScale(
        scale: 0.94,
        child: InkWell(
        onTapDown: (d) => _tapDown = d.globalPosition,
        onTap: () {
          HapticFeedback.selectionClick();
          if (i == _tab) return;
          _endConversationOnNavigate();
          _switchTab(i, from: _tapDown);
        },
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Active tab in the primary accent — the standard convention;
            // white-on-gray needed a second look to find where you were.
            //
            // ONE MOVE, NOT FOUR (2026-09-24). Selecting a tab used to
            // grow the icon to 1.12 on an overshooting curve (the one
            // bounce in the shell), fade the pill in linearly, swap the
            // icon and its colour in one frame and thicken the label from
            // w500 to w700, which made it re-centre. Now the icon grows a
            // little (1.06) on the standard curve with its pill, the two
            // icons cross-fade, and the label keeps one weight and only
            // changes colour. Taps and haptics are unchanged.
            AnimatedScale(
              scale: selected ? 1.06 : 1.0,
              duration: Motion.short,
              curve: Motion.easeMove,
              filterQuality: FilterQuality.medium,
              // The selected tab sits in its own soft violet pill, so
              // "where am I" reads at a glance instead of needing a
              // colour comparison between two small icons.
              child: AnimatedContainer(
                duration: Motion.short,
                curve: Motion.easeMove,
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
                // At night the pill is lit (2026-09-30, the client's
                // reference): cyan glass with its own glow.
                decoration: BoxDecoration(
                  color: selected
                      ? (Neon.isDark
                          ? Neon.cyan.withValues(alpha: 0.16)
                          : Neon.violet.withValues(alpha: 0.16))
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(Neon.rPill),
                  border: selected && Neon.isDark
                      ? Border.all(color: Neon.cyan.withValues(alpha: 0.55))
                      : null,
                  boxShadow: selected && Neon.isDark
                      ? Neon.halo(Neon.cyan, strength: 0.45)
                      : null,
                ),
                child: AnimatedSwitcher(
                  duration: Motion.micro,
                  switchInCurve: Motion.easeFadeIn,
                  switchOutCurve: Motion.easeFadeOut,
                  child: Icon(selected ? active : icon,
                      key: ValueKey(selected),
                      size: 22,
                      color: selected
                          ? (Neon.isDark ? Neon.cyan : Neon.violet)
                          : Neon.textDim),
                ),
              ),
            ),
            const SizedBox(height: 3),
            // The dock is a fixed 66 dp: its labels grow with the system
            // text size only up to 1.3x (at 2x they ran out of the bar),
            // the way the system's own navigation labels do. 12 sp, the
            // app's floor (was 11), and the selected tab is bold for real:
            // "Home" and "Chat" measured the same 3 px stems on build 106.
            MediaQuery.withClampedTextScaling(
              maxScaleFactor: 1.3,
              child: TweenAnimationBuilder<Color?>(
                tween: ColorTween(
                    end: selected
                        ? (Neon.isDark ? Neon.cyan : Neon.violet)
                        : Neon.textDim),
                duration: Motion.micro,
                curve: Motion.easeMove,
                builder: (_, color, __) => Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    // One weight in both states (motion: a label that
                    // thickens when picked re-centres in one frame); the
                    // pick shows by colour and the icon's small growth.
                    style: NeonType.manrope(NeonType.caption, FontWeight.w600)
                        .copyWith(color: color)),
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }
}

/// THE TABS, WHILE THE VOICE SESSION COVERS THEM.
///
/// The session is an opaque layer over the whole page, yet everything
/// under it kept working as if it could be seen (2026-09-24, measuring the
/// voice screen and the keyboard on his phone):
///
///  * PAINT. The four tabs — Home's feed and calendar among them — were
///    drawn again on every frame the orb moved. Once the session has faded
///    all the way in ([InlineCaptionOverlay.covering]) they are not
///    painted at all; they are back on the frame it starts to leave.
///  * LAYOUT. The keyboard shrinks the page a little on every frame it
///    slides, and all four tabs were laid out again each time, for a
///    keyboard that only the session's text box uses. While the session
///    is on screen they keep the size they had.
///
/// Nothing is rebuilt or thrown away: state, scroll positions and the
/// half-typed Chat message are exactly where they were.
class _UnderSession extends StatelessWidget {
  const _UnderSession({required this.engine, required this.child});
  final AssistantEngine engine;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([engine, InlineCaptionOverlay.covering]),
      builder: (context, tabs) => _HoldLayout(
        hold: voiceSessionOnScreen(engine),
        child: Visibility.maintain(
          visible: !InlineCaptionOverlay.covering.value,
          // Visibility.maintain keeps animations running on purpose;
          // under a session that covers them nobody can see them move.
          child: TickerMode(
            enabled: !InlineCaptionOverlay.covering.value,
            child: tabs!,
          ),
        ),
      ),
      // Their own layer: the overlays above repaint often (captions, the
      // activity pill, cards), and the tabs have no reason to repaint
      // with them.
      child: RepaintBoundary(child: child),
    );
  }
}

/// Lays its child out with the constraints it had before [hold] turned
/// on, for as long as it stays on — so a parent that changes size every
/// frame (the keyboard) does not lay the child out every frame. The child
/// is still painted from the top-left and may reach past the bottom edge;
/// that part is under the keyboard and the session, where nobody sees it.
class _HoldLayout extends SingleChildRenderObjectWidget {
  const _HoldLayout({required this.hold, required super.child});
  final bool hold;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderHoldLayout(hold);

  @override
  void updateRenderObject(BuildContext context, _RenderHoldLayout ro) =>
      ro.hold = hold;
}

class _RenderHoldLayout extends RenderProxyBox {
  _RenderHoldLayout(this._hold);

  bool _hold;
  BoxConstraints? _held;

  set hold(bool v) {
    if (v == _hold) return;
    _hold = v;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    final kid = child;
    // Held only at the same width: a rotation mid-session re-lays out.
    final keep = _hold && _held != null && _held!.maxWidth == constraints.maxWidth;
    if (!keep) _held = constraints;
    if (kid == null) {
      size = constraints.smallest;
      return;
    }
    kid.layout(_held!, parentUsesSize: true);
    size = constraints.constrain(kid.size);
  }
}

/// THE DOCK'S LIT EDGE (2026-09-30, the client's reference): the brand's
/// light traced along the bar's top and around the mic's cradle, with a
/// soft glow — the same notched outline the bar is cut to.
class _DockRim extends StatelessWidget {
  const _DockRim({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!Neon.isDark) return child;
    return CustomPaint(
      foregroundPainter: _DockRimPainter(
        geometry: Scaffold.geometryOf(context),
        colors: [Neon.cyan, Neon.violet, Neon.pink],
      ),
      child: child,
    );
  }
}

class _DockRimPainter extends CustomPainter {
  _DockRimPainter({required this.geometry, required this.colors})
      : super(repaint: geometry);

  final ValueListenable<ScaffoldGeometry> geometry;
  final List<Color> colors;

  @override
  void paint(Canvas canvas, Size size) {
    final g = geometry.value;
    final top = g.bottomNavigationBarTop;
    final fab = g.floatingActionButtonArea;
    // As BottomAppBar cuts itself: the mic's box, moved into the bar's
    // coordinates, widened by the notch margin (4).
    final guest = top == null || fab == null ? null : fab.translate(0, -top).inflate(4);
    final outline = const CircularNotchedRectangle()
        .getOuterPath(Offset.zero & size, guest);
    final shader = LinearGradient(colors: colors).createShader(Offset.zero & size);
    canvas.save();
    // Only the top edge and the cradle: the sides and bottom are off the
    // screen's edge or under the system bar.
    canvas.clipRect(Rect.fromLTWH(0, -40, size.width, 46));
    canvas.drawPath(
        outline,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 7
          ..shader = shader
          ..color = Colors.white.withValues(alpha: 0.22)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5));
    canvas.drawPath(
        outline,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..shader = shader);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_DockRimPainter old) => old.colors != colors;
}
