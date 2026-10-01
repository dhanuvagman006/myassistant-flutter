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
import 'package:myassistant/screens/assistant_settings_screen.dart';
import 'package:myassistant/screens/business_card_flow.dart';
import 'package:myassistant/screens/chat_group_screen.dart';
import 'package:myassistant/services/app_feedback.dart';
import 'package:myassistant/widgets/activity_pill.dart';
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
import 'package:myassistant/models/news_item.dart';
import 'package:myassistant/screens/news_screen.dart';
import 'package:myassistant/screens/news_story_screen.dart';
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
import 'package:myassistant/screens/avatar_identity_screen.dart';
import 'package:myassistant/screens/identity_record_screen.dart';
import 'package:myassistant/services/avatar_message_service.dart';
import 'package:myassistant/screens/focus_screen.dart';
import 'package:myassistant/services/momentum_service.dart';
import 'package:myassistant/shell/home_shell.dart';
import 'package:myassistant/features/assistant/state/assistant_engine.dart';
import 'package:myassistant/features/assistant/state/assistant_state.dart';
import 'package:myassistant/widgets/inline_voice.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:myassistant/screens/connected_apps_screen.dart';
import 'package:myassistant/screens/help_improve_row.dart';
import 'package:myassistant/services/connections_service.dart';
import 'package:myassistant/services/privacy_prefs_service.dart';
import 'package:myassistant/screens/shortcuts_screen.dart';
import 'package:myassistant/services/shortcuts_service.dart';
import 'package:myassistant/models/shortcut.dart';
import 'package:myassistant/features/shopping/shopping_list_screen.dart';
import 'package:myassistant/features/shopping/shopping_models.dart';
import 'package:myassistant/features/shopping/shopping_service.dart';
import 'package:myassistant/design/tab_deck.dart';

/// The server's answer for the Notion card in [status], with a long name.
JsonTransport _connections(String status) => (method, path, [body]) async =>
    path == '/connections'
        ? {
            'connections': [
              {
                'id': 'notion', 'name': 'Notion', 'available': true, 'status': status,
                'workspace': status == 'not_connected'
                    ? null
                    : "Dhanush's workspace for the family business and the school trust",
              },
            ],
          }
        : {'connected': true};

Widget _connectedApps(String status, {bool connecting = false}) {
  ConnectionsService.instance.resetForTest();
  ConnectionsService.transport = _connections(status);
  return ConnectedAppsScreen(startConnecting: connecting);
}

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

/// Stories with the longest headlines and summaries a card has to hold.
final _news = [
  for (var i = 1; i <= 6; i++)
    NewsItem(
      id: 'n$i',
      title: i.isOdd
          ? 'Monsoon arrives early in Kerala as the weather office says rainfall '
              'this year will run above normal across the whole of the south'
          : 'Budget: new tax slabs for salaried workers',
      url: 'https://example.com/$i',
      source: 'timesofindia.indiatimes.example',
      age: '2 hours ago',
      snippet: 'A long summary that goes on for a while, so that the card has to '
          'cut it at two lines on a phone of any size and with any text size.',
      extra: const ['A second snippet with a few more words about the story.'],
      image: 'https://img.example/$i.jpg',
    ),
];

/// The voice deck over Home, as show_news leaves it.
class _ShellNews extends StatefulWidget {
  const _ShellNews();
  @override
  State<_ShellNews> createState() => _ShellNewsState();
}

class _ShellNewsState extends State<_ShellNews> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
        (_) => AssistantEngine.instance.showNews(_news, topic: 'today'));
  }

  @override
  void dispose() {
    AssistantEngine.instance.newsItems = const [];
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
  'News (offline)': () => NewsScreen(loader: (_) async => null),
  'News (cards)': () => NewsScreen(loader: (_) async => _news),
  'News story': () => NewsStoryScreen(item: _news.first),
  'News deck (voice, in the shell)': () => const _ShellNews(),
  'Call notes': () => const CallNotesScreen(),
  'Quick task': () => const QuickTaskScreen(),
  'Reminders': () => RemindersScreen(loader: () async => const []),
  'Search': () => const SearchScreen(),
  'Stocks': () => StocksScreen(loader: () async => const {}),
  'Theme colour': () => const ThemeColourScreen(),
  // The Focus page both before a session and while one runs.
  'Focus (choose how long)': () => const FocusScreen(),
  // SHORTCUTS (build 120): long names and steps.
  'Shortcuts (filled in)': () {
    ShortcutsService.instance.debugSeed(_shortcutsSeed());
    return const ShortcutsScreen();
  },
  'Shortcuts (none yet)': () {
    ShortcutsService.instance.debugSeed(const []);
    return const ShortcutsScreen();
  },
  // SHOPPING LIST (build 124): none yet, and full — long names, details,
  // shops and links, two amounts on one line, bought lines.
  'Shopping list (none yet)': () {
    ShoppingService.transport = (method, path, {body}) async =>
        const ShoppingReply(200, {'items': [], 'updatedAt': null, 'categories': []});
    ShoppingService.instance.debugSeed(const []);
    return const ShoppingListScreen();
  },
  'Shopping list (filled in)': () {
    ShoppingService.instance.debugSeed(ShoppingItem.listFrom(_shoppingJson()['items']));
    return const ShoppingListScreen();
  },
  'Shopping list (one kind)': () {
    ShoppingService.instance.debugSeed(ShoppingItem.listFrom(_shoppingJson()['items']));
    return const ShoppingListScreen(category: 'clothing_footwear');
  },
  'Shopping list (offline, saved list)': () {
    ShoppingService.transport = (method, path, {body}) async => const ShoppingReply(0, null);
    ShoppingService.instance.debugSeed(ShoppingItem.listFrom(_shoppingJson()['items']), failed: true);
    return const ShoppingListScreen();
  },
  'Shopping list (offline, nothing saved)': () {
    ShoppingService.transport = (method, path, {body}) async => const ShoppingReply(0, null);
    ShoppingService.instance.debugSeed(null, failed: true);
    return const ShoppingListScreen();
  },
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
  'Avatar identity': () => const AvatarIdentityScreen(),
  // SEND MESSAGES AS YOU (2026-09-26): before consent, and with a video.
  'Avatar identity (before consent)': () =>
      AvatarIdentityScreen(loader: () async => const AvatarProfile()),
  'Avatar identity (recorded)': () => AvatarIdentityScreen(
      loader: () async => AvatarProfile(
            consented: true,
            consentedAt: DateTime(2026, 9, 26).millisecondsSinceEpoch,
            enabled: true,
            hasVideo: true,
            video: IdentityVideo(
                id: 'v1',
                durationMs: 31250,
                createdAt: DateTime(2026, 9, 26).millisecondsSinceEpoch),
          )),
  'Record your video': () => const IdentityRecordScreen(),
  // CONNECTED APPS (build 120): the Notion card in all four states.
  'Connected apps (not connected)': () => _connectedApps('not_connected'),
  'Connected apps (connecting)': () => _connectedApps('not_connected', connecting: true),
  'Connected apps (connected)': () => _connectedApps('connected'),
  'Connected apps (needs reconnect)': () => _connectedApps('needs_reconnect'),
  // HELP IMPROVE (build 120): the one-time card, and the dialog behind it.
  'Help improve card': () => Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: SingleChildScrollView(child: HelpImproveAskCard(days: 14, onAnswer: (_) {})),
        ),
      ),
  'Help improve notice': () => Builder(
        builder: (c) {
          WidgetsBinding.instance.addPostFrameCallback((_) => showHelpImproveNotice(c, 14));
          return const Scaffold(body: SizedBox());
        },
      ),
  'Voice screen (long reply)': () => const _VoiceScreen(),
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

List<Shortcut> _shortcutsSeed() => [
      Shortcut.fromJson({
        'id': 1, 'name': 'Office mode for the long drive to the factory', 'version': 1,
        'other_names': ['ഓഫീസ് മോഡ്'],
        'steps': [
          {'i': 0, 'tool': 'phone_control', 'label': 'Phone on silent', 'class': 'in_app'},
          {'i': 1, 'tool': 'send_whatsapp_message', 'label': 'Chat message to Priya Shetty: “Leaving now, will call from the car” (you tap Send)', 'class': 'hand_back'},
          {'i': 2, 'tool': 'start_navigation', 'label': 'Directions to 4th floor, Mangalore One, MG Road, Bengaluru', 'class': 'stays'},
        ],
      }),
    ];

/// A full shopping list, as GET /shopping sends it.
Map<String, dynamic> _shoppingJson() {
  Map<String, dynamic> line(int id, String name, String category,
          {String amount = '', String details = '', String? store, String? link, bool checked = false}) =>
      {
        'id': id, 'name': name, 'quantity': null, 'unit': null, 'amountText': amount,
        'details': details, 'link': link, 'store': store, 'note': '', 'category': category,
        'recipe': null, 'source': 'manual', 'checked': checked, 'createdAt': id, 'updatedAt': id,
      };
  return {
    'items': [
      line(1, 'Onion', 'vegetables_fruit', amount: '1.5 kg + 2 pcs'),
      line(2, 'Organic cold-pressed groundnut oil from the farm shop near Mysore', 'oils',
          amount: '2 L'),
      line(3, 'Kurti', 'clothing_footwear',
          details: 'M, blue floral print, cotton, full sleeves — for Amma’s birthday next Sunday',
          store: 'Myntra',
          link: 'https://www.myntra.com/kurtas/biba/blue-floral-printed-cotton-kurta/123456/buy'),
      line(4, 'USB-C fast charger 25W with a two-metre braided cable', 'electronics_accessories',
          details: 'Samsung', store: 'Croma'),
      line(5, 'Dolo 650', 'health_medicines', amount: '2 strips'),
      line(6, 'Milk', 'dairy_eggs', amount: '2 L', checked: true),
      line(7, 'Bread', 'bakery', checked: true),
    ],
    'updatedAt': 7,
    'categories': [for (final c in shoppingCategories) c.toJson()],
  };
}

/// A full Momentum summary for today, with titles long enough to wrap.
Map<String, dynamic> momentumJsonForTests() => _momentumJson();

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
    // Hub's Shopping list row shows its count; the list screen is full.
    ShoppingService.transport =
        (method, path, {body}) async => ShoppingReply(200, _shoppingJson());
  });
  tearDown(() {
    HomeShell.lastTab = 0;
    AppFeedback.resetForTest();
    ConnectionsService.transport = apiTransport;
    PrivacyPrefsService.transport = apiTransport;
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
              .descendant(of: find.byType(TabDeck), matching: find.byType(ListView))
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

    testWidgets('Home: the greeting scrolls with the feed', (tester) async {
      _applyPhone(tester, gesture);
      await tester.pumpWidget(MaterialApp(home: _shellAt(0)));
      await _settle(tester);
      // The quote moved into the all-clear card (2026-09-29); the greeting
      // is the top of the list either way.
      expect(
          find.descendant(
              of: find.byType(Scrollable), matching: find.textContaining('Good ', findRichText: true)),
          findsOneWidget,
          reason: 'a pinned header let the feed slide under the greeting');
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
