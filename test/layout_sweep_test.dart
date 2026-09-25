// LAYOUT SWEEP — every screen, on the phones people actually hold.
//
// A layout that overflows is not just ugly: on a real phone the part past
// the edge stops taking taps (the send arrow that "did nothing",
// 2026-09-24). So every screen is rendered on the owner's phone, a small
// phone, with large text, and with the keyboard up, and any overflow fails
// the test with the screen and the setting that broke it.
//
// Screens are rendered offline: loaders fail fast, so this checks the
// loading, empty and error states — the ones users meet first.
//
// Extended 2026-09-24 (the owner's "it overlaps" report): two setups with
// real system bars (gesture and 3-button navigation), the tabs and the
// voice screen INSIDE the shell with the dock and the mic, and checks that
// go beyond overflow — nothing ends under the mic, the Home header scrolls
// instead of covering the feed, the voice screen's text box and top row are
// clear of the dock and the activity pill, and a long toast fits.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/core/daily_quotes.dart';
import 'package:myassistant/screens/assistant_settings_screen.dart';
import 'package:myassistant/screens/business_card_flow.dart';
import 'package:myassistant/screens/chat_group_screen.dart';
import 'package:myassistant/services/app_feedback.dart';
import 'package:myassistant/widgets/activity_pill.dart';
import 'package:myassistant/screens/automation_setup_screen.dart';
import 'package:myassistant/screens/calls_screen.dart';
import 'package:myassistant/screens/chat_new_screen.dart';
import 'package:myassistant/screens/chat_screen.dart';
import 'package:myassistant/screens/clients_screen.dart';
import 'package:myassistant/screens/documents_screen.dart';
import 'package:myassistant/screens/email_setup_screen.dart';
import 'package:myassistant/screens/features_screen.dart';
import 'package:myassistant/screens/finance_screen.dart';
import 'package:myassistant/screens/hub_screen.dart';
import 'package:myassistant/screens/lock_screen.dart';
import 'package:myassistant/screens/mcp_servers_screen.dart';
import 'package:myassistant/screens/meetings/meeting_detail_screen.dart';
import 'package:myassistant/screens/meetings/meetings_screen.dart';
import 'package:myassistant/screens/phone/call_notes_screen.dart';
import 'package:myassistant/screens/quick_task_screen.dart';
import 'package:myassistant/screens/reminders_screen.dart';
import 'package:myassistant/screens/search_screen.dart';
import 'package:myassistant/screens/stocks_screen.dart';
import 'package:myassistant/screens/theme_colour_screen.dart';
import 'package:myassistant/screens/auth/auth_screen.dart';
import 'package:myassistant/screens/auth/phone_verify_screen.dart';
import 'package:myassistant/screens/auth/welcome_screen.dart';
import 'package:myassistant/screens/auth/guide_screen.dart';
import 'package:myassistant/screens/auth/permissions_screen.dart';
import 'package:myassistant/screens/phone/call_detail_screen.dart';
import 'package:myassistant/screens/voice_picker_screen.dart';
import 'package:myassistant/screens/meetings/meeting_recorder_screen.dart';
import 'package:myassistant/screens/studio/studio_screen.dart';
import 'package:myassistant/screens/diagnostics_screen.dart';
import 'package:myassistant/screens/mic_probe_screen.dart';
import 'package:myassistant/screens/avatar_identity_screen.dart';
import 'package:myassistant/screens/focus_screen.dart';
import 'package:myassistant/screens/momentum_screen.dart';
import 'package:myassistant/models/momentum.dart';
import 'package:myassistant/services/momentum_service.dart';
import 'package:myassistant/shell/home_shell.dart';
import 'package:myassistant/features/assistant/state/assistant_engine.dart';
import 'package:myassistant/features/assistant/state/assistant_state.dart';
import 'package:myassistant/widgets/inline_voice.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The voice screen as it is during a conversation, with a long answer.
class _VoiceScreen extends StatefulWidget {
  const _VoiceScreen();
  @override
  State<_VoiceScreen> createState() => _VoiceScreenState();
}

class _VoiceScreenState extends State<_VoiceScreen> {
  @override
  void initState() {
    super.initState();
    AssistantEngine.instance
      ..inlineVoice = true
      ..phase = AssistantPhase.listening;
    AssistantEngine.instance.caption.value = const CaptionLine('you',
        'Book a table for four at a quiet place near the office for tomorrow at eight and '
        'tell me the menu highlights before you confirm anything with them');
  }

  @override
  void dispose() {
    AssistantEngine.instance
      ..inlineVoice = false
      ..phase = AssistantPhase.idle;
    AssistantEngine.instance.caption.value = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const Scaffold(body: InlineCaptionOverlay());
}

/// The voice screen as it is during a conversation — INSIDE the shell, so
/// the dock, the stop orb and the activity pill are on screen with it.
class _ShellVoice extends StatefulWidget {
  const _ShellVoice();
  @override
  State<_ShellVoice> createState() => _ShellVoiceState();
}

class _ShellVoiceState extends State<_ShellVoice> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      AssistantEngine.instance
        ..inlineVoice = true
        ..phase = AssistantPhase.listening
        ..notifyListeners();
      AssistantEngine.instance.activityLabel.value = 'Searching the web — one moment';
    });
  }

  @override
  void dispose() {
    AssistantEngine.instance
      ..inlineVoice = false
      ..phase = AssistantPhase.idle;
    AssistantEngine.instance.activityLabel.value = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const HomeShell();
}

Widget _shellAt(int tab) {
  HomeShell.lastTab = tab;
  return const HomeShell();
}

class Phone {
  final String name;
  final Size px;
  final double dpr;
  final double text;
  final double keyboardPx;

  /// System bars, in dp: the navigation bar under the app (gesture handle
  /// ~16, 3-button bar 48) and the status bar above it.
  final double navDp;
  final double statusDp;
  const Phone(this.name, this.px, this.dpr,
      {this.text = 1.0, this.keyboardPx = 0, this.navDp = 0, this.statusDp = 0});
}

const phones = [
  Phone("owner's phone", Size(1080, 2340), 2.625),
  Phone('small phone', Size(720, 1280), 2.0),
  Phone('large text', Size(1080, 2340), 2.625, text: 1.3),
  Phone('keyboard up', Size(1080, 2340), 2.625, keyboardPx: 1190),
  Phone('gesture nav', Size(1080, 2340), 2.625, navDp: 16, statusDp: 24),
  Phone('3-button nav', Size(720, 1280), 2.0, navDp: 48, statusDp: 24),
  Phone('small + keyboard', Size(720, 1280), 2.0, keyboardPx: 560),
  Phone('huge text', Size(1080, 2340), 2.625, text: 2.0),
];

void _applyPhone(WidgetTester tester, Phone p) {
  tester.view.devicePixelRatio = p.dpr;
  tester.view.physicalSize = p.px;
  if (p.keyboardPx > 0) tester.view.viewInsets = FakeViewPadding(bottom: p.keyboardPx);
  if (p.navDp > 0 || p.statusDp > 0) {
    final pad = FakeViewPadding(top: p.statusDp * p.dpr, bottom: p.navDp * p.dpr);
    tester.view.padding = pad;
    tester.view.viewPadding = pad;
  }
  addTearDown(tester.view.reset);
}

/// Collects overflow reports (with the widget's source line) while [body]
/// runs; everything else thrown (no network, no plugins) is ignored.
Future<List<String>> _overflowsDuring(Future<void> Function() body) async {
  final overflows = <String>[];
  final original = FlutterError.onError;
  FlutterError.onError = (d) {
    final msg = d.exceptionAsString();
    if (msg.contains('overflowed') || msg.contains('presented off screen')) {
      final at = RegExp(r'lib/[^\s:]+\.dart:\d+').firstMatch(d.toString())?.group(0) ?? '?';
      overflows.add('${msg.split('\n').first} at $at');
    }
  };
  try {
    await body();
  } finally {
    FlutterError.onError = original;
  }
  return overflows;
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 300));
  }
}

Future<void> _teardownApp(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  AssistantEngine.instance.cancelReconnect();
  await tester.pump(const Duration(seconds: 5));
}

final screens = <String, Widget Function()>{
  'Settings (You)': () => const AssistantSettingsScreen(),
  'Do it for me setup': () => const AutomationSetupScreen(pendingGoal: 'order veg biryani from a 4-star place'),
  'Calls': () => const CallsScreen(),
  'New chat': () => const ChatNewScreen(),
  'Chat': () => const ChatScreen(),
  'Clients': () => const ClientsScreen(),
  'Documents': () => const DocumentsScreen(),
  'Email setup': () => const EmailSetupScreen(),
  'Features': () => const FeaturesScreen(),
  'Finance': () => const FinanceScreen(),
  'Hub': () => const HubScreen(),
  'Lock': () => const LockScreen(),
  'Connected tools': () => const McpServersScreen(),
  'Meeting detail': () => const MeetingDetailScreen(id: 1),
  'Meetings': () => const MeetingsScreen(),
  'Call notes': () => const CallNotesScreen(),
  'Quick task': () => const QuickTaskScreen(),
  'Reminders': () => RemindersScreen(loader: () async => const []),
  'Search': () => const SearchScreen(),
  'Stocks': () => StocksScreen(loader: () async => const {}),
  'Theme colour': () => const ThemeColourScreen(),
  // MOMENTUM (2026-09-25): full, with long titles, and the Focus page both
  // before a session and while one runs.
  'Momentum (filled in)': () {
    MomentumService.instance.debugSeed(MomentumSummary.fromJson(_momentumJson()));
    return const MomentumScreen();
  },
  'Focus (choose how long)': () => const FocusScreen(),
  'Focus (running)': () => const FocusScreen(
      minutes: 25, label: 'Quarterly report for the board meeting', autoStart: true),
  'Sign in': () => const AuthScreen(),
  'Phone verify': () => const PhoneVerifyScreen(),
  'Welcome': () => WelcomeScreen(onDone: () {}),
  'Guide': () => GuideScreen(onDone: () {}),
  'Permissions': () => PermissionsScreen(onDone: () {}),
  'Home (with dock)': () => const HomeShell(),
  'Call detail': () => const CallDetailScreen(callId: 1, peerLabel: 'Ravi Kumar (Sales, Bengaluru office)'),
  'Voice picker': () => const VoicePickerScreen(voices: [
        ('kore', 'Kore', 'Warm, calm — good for long answers'),
        ('puck', 'Puck', 'Bright and quick'),
      ], selectedId: 'kore'),
  'Meeting recorder': () => const MeetingRecorderScreen(title: 'Quarterly review with the regional sales team'),
  'Studio': () => const StudioScreen(),
  'Diagnostics': () => const DiagnosticsScreen(),
  'Mic test': () => const MicProbeScreen(),
  'Avatar identity': () => const AvatarIdentityScreen(),
  'Voice screen (long reply)': () => const _VoiceScreen(),
  'Do it for me (switched on)': () => const AutomationSetupScreen(),
  'Hub (with dock)': () => _shellAt(1),
  'Chat (with dock)': () => _shellAt(2),
  'You (with dock)': () => _shellAt(3),
  'Voice screen (in the shell)': () => const _ShellVoice(),
  'Group chat': () => const ChatGroupScreen(groupId: 1, title: 'Weekend trip planning committee'),
  'Chat thread': () => const ChatThreadScreen(phone: '+919845012345', name: 'Ravi Kumar'),
  'Card result': () => const Scaffold(
        body: CardResultSheet(person: {
          'name': 'Priya Sharma',
          'title': 'Head of Sales',
          'company': 'Acme Pvt Ltd',
          'phones': ['+919845012345'],
          'emails': ['priya@acme.in'],
          'website': 'acme.in',
        }),
      ),
};

/// A full Momentum summary for today, with titles long enough to wrap.
Map<String, dynamic> _momentumJson() {
  final today = MomentumService.today;
  final d = DateTime.parse(today);
  String day(int back) => MomentumService.dayOf(d.subtract(Duration(days: back)));
  return {
    'ok': true,
    'day': today,
    'priorities': [
      {'id': 1, 'title': 'Finish the quarterly report for the board meeting', 'done': true, 'position': 0},
      {'id': 2, 'title': 'Call the bank about the home loan paperwork', 'done': false, 'position': 1},
      {'id': 3, 'title': 'Book tickets', 'done': false, 'position': 2},
    ],
    'habits': [
      for (final (i, t) in ['Drink water', 'Walk 30 minutes', 'Read 10 pages', 'Meditate'].indexed)
        {
          'id': 10 + i, 'title': t, 'emoji': '💧', 'remindAt': i == 0 ? '09:00' : null,
          'doneToday': i.isEven, 'streak': 12 - i, 'best': 30,
          'last7': [true, false, true, true, true, i.isOdd, i.isEven],
        },
    ],
    'focus': {'todayMin': 95, 'weekMin': 610, 'totalMin': 12450},
    'streak': {'current': 128, 'best': 128, 'activeToday': true, 'graceUsedThisWeek': true},
    'week': {
      'days': [
        for (var k = 6; k >= 0; k--)
          {'day': day(k), 'active': k != 3, 'wins': k * 2, 'focusMin': 20 * k, 'habits': 3, 'forgiven': k == 3},
      ],
      'wins': 42, 'focusMin': 610, 'habitsKept': 21, 'bestDay': day(6),
    },
    'milestones': [
      {'id': 'streak_100', 'label': '100-day streak', 'earned': true},
      {'id': 'focus_100h', 'label': '100 hours of focus', 'earned': true},
      {'id': 'wins_50', 'label': '50 wins', 'earned': false},
    ],
  };
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // Home runs with its Momentum card filled in (long titles, big
    // numbers), so the card is swept at every text size too.
    MomentumService.transport =
        (method, path, {body}) async => MomentumReply(200, _momentumJson());
  });
  tearDown(() {
    HomeShell.lastTab = 0;
    AppFeedback.resetForTest();
  });

  for (final s in screens.entries) {
    for (final p in phones) {
      testWidgets('${s.key} — ${p.name}', (tester) async {
        _applyPhone(tester, p);

        final overflows = <String>[];
        final original = FlutterError.onError;
        FlutterError.onError = (d) {
          final msg = d.exceptionAsString();
          if (msg.contains('overflowed')) {
            // Where: the widget's source line, so the report is actionable.
            final at = RegExp(r'lib/[^\s:]+\.dart:\d+').firstMatch(d.toString())?.group(0) ?? '?';
            overflows.add('${msg.split('\n').first} at $at');
          }
          // Everything else (no network, no plugin in tests) is not what
          // this sweep is about.
        };
        try {
          await tester.pumpWidget(MaterialApp(
            home: MediaQuery.withClampedTextScaling(
              minScaleFactor: p.text,
              maxScaleFactor: p.text,
              child: s.value(),
            ),
          ));
          for (var i = 0; i < 6; i++) {
            await tester.pump(const Duration(milliseconds: 300));
          }
          await tester.pumpWidget(const SizedBox());
          // The assistant keeps retrying its server offline (by design);
          // a test ends that on purpose.
          AssistantEngine.instance.cancelReconnect();
          await tester.pump(const Duration(seconds: 5));
        } finally {
          FlutterError.onError = original;
        }
        // Anything thrown outside layout is not this sweep's business.
        tester.takeException();
        expect(overflows, isEmpty, reason: '${s.key} on ${p.name}: ${overflows.join(' | ')}');
      });
    }
  }

  // ── Beyond overflow: what sits on top of what ───────────────────────────
  const threeButton = Phone('3-button nav', Size(720, 1280), 2.0, navDp: 48, statusDp: 24);
  const gesture = Phone('gesture nav', Size(1080, 2340), 2.625, navDp: 16, statusDp: 24);

  group('dock clearance', () {
    for (final p in const [threeButton, gesture]) {
      for (final tab in const [0, 1, 3]) {
        testWidgets('tab $tab ends above the mic — ${p.name}', (tester) async {
          _applyPhone(tester, p);
          await tester.pumpWidget(MaterialApp(home: _shellAt(tab)));
          await _settle(tester);
          final screen = tester.getRect(find.byType(HomeShell));
          final orb = tester.getRect(find.byType(AssistantOrbButton));
          // The fade under the dock is solid from the bar's top edge down,
          // so the ring around the mic never shows a slice of the list.
          final fade = tester.getRect(find.byKey(const ValueKey('dock-fade')));
          expect(fade.top, lessThanOrEqualTo(orb.top),
              reason: 'the fade covers the whole notch around the mic');
          expect(fade.bottom, screen.bottom);
          // The visible tab's list reserves room for the dock AND the mic.
          final lists = find
              .descendant(of: find.byType(IndexedStack), matching: find.byType(ListView))
              .hitTestable();
          if (tab == 3 && lists.evaluate().isEmpty) return; // still loading offline
          final list = tester.widget<ListView>(lists.first);
          final pad = (list.padding! as EdgeInsets).bottom;
          expect(screen.bottom - pad, lessThanOrEqualTo(orb.top - 8),
              reason: 'the last row clears the mic (padding $pad)');
          await _teardownApp(tester);
        });
      }
    }

    testWidgets('Home: the greeting and quote scroll with the feed', (tester) async {
      _applyPhone(tester, gesture);
      await tester.pumpWidget(MaterialApp(home: _shellAt(0)));
      await _settle(tester);
      expect(
          find.descendant(
              of: find.byType(Scrollable), matching: find.text(DailyQuotes.today())),
          findsOneWidget,
          reason: 'a pinned header let the feed slide under the quote');
      await _teardownApp(tester);
    });
  });

  // A Flex squeezed to zero height paints nothing and reports no overflow —
  // that is how Quick task went blank with the keyboard up and still
  // passed. Its box and title must actually be on screen.
  group('nothing collapses with the keyboard up', () {
    for (final p in phones.where((p) => p.keyboardPx > 0)) {
      testWidgets('Quick task — ${p.name}', (tester) async {
        _applyPhone(tester, p);
        await tester.pumpWidget(const MaterialApp(home: QuickTaskScreen()));
        await _settle(tester);
        expect(find.byType(TextField).hitTestable(), findsOneWidget);
        expect(find.text('Assign a task').hitTestable(), findsOneWidget);
        await _teardownApp(tester);
      });
    }
  });

  group('voice screen in the shell', () {
    for (final p in const [threeButton, gesture]) {
      testWidgets('text box, Sound button and activity pill are all clear — ${p.name}',
          (tester) async {
        _applyPhone(tester, p);
        await tester.pumpWidget(const MaterialApp(home: _ShellVoice()));
        await _settle(tester);
        final orb = tester.getRect(find.byType(AssistantOrbButton));
        final field = find.byType(TextField);
        expect(field, findsOneWidget);
        expect(tester.getRect(field).bottom, lessThanOrEqualTo(orb.top - 8),
            reason: 'the stop orb must not sit on the text box');
        final sound = tester.getRect(find.text('Sound on'));
        final pill = tester.getRect(find.byType(AssistantActivityPill));
        expect(sound.overlaps(pill), isFalse,
            reason: 'the activity pill used to cover the Sound button');
        expect(tester.widget<TextField>(field).keyboardType, TextInputType.text,
            reason: 'multi-line keyboards turn Send into a newline');
        await _teardownApp(tester);
      });
    }
  });

  group('toasts', () {
    const long = 'Contacts permission is off — the call to "Ravi Kumar" was NOT '
        'placed. Enable Contacts in Settings, then ask me again and I will try.';
    for (final p in phones) {
      testWidgets('a three-line toast fits — ${p.name}', (tester) async {
        _applyPhone(tester, p);
        final overflows = await _overflowsDuring(() async {
          await tester.pumpWidget(MaterialApp(home: _shellAt(0)));
          await tester.pump();
          AppFeedback.show(long, context: tester.element(find.byType(HomeShell)));
          await _settle(tester);
          expect(find.text(long), findsOneWidget);
          await _teardownApp(tester);
        });
        tester.takeException();
        expect(overflows, isEmpty, reason: overflows.join(' | '));
      });
    }

    for (final p in const [threeButton, gesture]) {
      testWidgets('a toast never covers the dock, the mic or the text box — ${p.name}',
          (tester) async {
        _applyPhone(tester, p);
        await tester.pumpWidget(const MaterialApp(home: _ShellVoice()));
        await _settle(tester);
        AppFeedback.sessionVisible = () => true; // as HomeShell sets it
        AppFeedback.show('Translator on — everyone near the phone is heard.',
            context: tester.element(find.byType(HomeShell)));
        await _settle(tester);
        final bar = tester.getRect(find
            .descendant(of: find.byType(SnackBar), matching: find.byType(Material))
            .first);
        expect(bar.overlaps(tester.getRect(find.byType(BottomAppBar))), isFalse);
        expect(bar.overlaps(tester.getRect(find.byType(AssistantOrbButton))), isFalse);
        expect(bar.overlaps(tester.getRect(find.byType(TextField))), isFalse,
            reason: 'during a session the toast is lifted over the text box');
        await _teardownApp(tester);
      });
    }
  });
}
