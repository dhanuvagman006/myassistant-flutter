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
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/screens/assistant_settings_screen.dart';
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
import 'package:myassistant/screens/avatar_identity_screen.dart';
import 'package:myassistant/shell/home_shell.dart';
import 'package:myassistant/features/assistant/state/assistant_engine.dart';
import 'package:shared_preferences/shared_preferences.dart';

class Phone {
  final String name;
  final Size px;
  final double dpr;
  final double text;
  final double keyboardPx;
  const Phone(this.name, this.px, this.dpr, {this.text = 1.0, this.keyboardPx = 0});
}

const phones = [
  Phone("owner's phone", Size(1080, 2340), 2.625),
  Phone('small phone', Size(720, 1280), 2.0),
  Phone('large text', Size(1080, 2340), 2.625, text: 1.3),
  Phone('keyboard up', Size(1080, 2340), 2.625, keyboardPx: 1190),
];

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
};

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final s in screens.entries) {
    for (final p in phones) {
      testWidgets('${s.key} — ${p.name}', (tester) async {
        tester.view.devicePixelRatio = p.dpr;
        tester.view.physicalSize = p.px;
        if (p.keyboardPx > 0) tester.view.viewInsets = FakeViewPadding(bottom: p.keyboardPx);
        addTearDown(tester.view.reset);

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
}
