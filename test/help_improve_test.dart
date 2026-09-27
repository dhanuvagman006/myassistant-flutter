// "HELP IMPROVE THE ASSISTANT" (build 120) — off until the user says yes.
//
// Pins: the service reads the server's answer and the one-time ask; the
// switch shows the notice BEFORE anything is sent and sends nothing when
// the user backs out; turning off asks first; the one-time card offers
// both answers in the same style; the You screen carries the row.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/screens/app_lock_section.dart';
import 'package:myassistant/screens/help_improve_row.dart';
import 'package:myassistant/services/privacy_prefs_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late List<(String, String, Object?)> calls;
  late Map<String, dynamic> server;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    calls = [];
    server = {
      'helpImprove': null, 'effective': false, 'ask': true,
      'noticeVersion': 'help-improve-v1', 'keeps': {'recordingDays': 14, 'privateTurnDays': 7},
    };
    PrivacyPrefsService.instance.resetForTest();
    PrivacyPrefsService.transport = (method, path, [body]) async {
      calls.add((method, path, body));
      if (method == 'PUT') {
        final on = (body as Map)['helpImprove'] as bool;
        server = {...server, 'helpImprove': on, 'ask': false};
        return {'helpImprove': on, 'effective': on};
      }
      return server;
    };
  });
  tearDown(() => PrivacyPrefsService.transport = apiTransport);

  test('not asked yet: off, and the card is due', () async {
    final s = PrivacyPrefsService.instance;
    await s.load();
    expect(s.helpImprove, isNull);
    expect(s.isOn, isFalse);
    expect(s.ask, isTrue);
    expect(s.recordingDays, 14);
  });

  test('an answer is sent with the notice version and its source', () async {
    final s = PrivacyPrefsService.instance;
    await s.load();
    expect(await s.set(true, source: 'ask_card'), isTrue);
    final put = calls.last;
    expect(put.$1, 'PUT');
    expect(put.$2, '/privacy/prefs');
    expect(put.$3, {'helpImprove': true, 'source': 'ask_card', 'noticeVersion': 'help-improve-v1'});
    expect(s.isOn, isTrue);
    expect(s.ask, isFalse);
  });

  test('a failed save changes nothing', () async {
    PrivacyPrefsService.transport = (m, p, [b]) async => m == 'GET' ? server : null;
    final s = PrivacyPrefsService.instance;
    await s.load();
    expect(await s.set(true, source: 'settings'), isFalse);
    expect(s.helpImprove, isNull);
    expect(s.ask, isTrue);
  });

  Future<void> pumpRow(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: AppLockSection())),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('the You screen carries the switch, off to begin with', (tester) async {
    await pumpRow(tester);
    expect(find.text('Help improve the assistant'), findsOneWidget);
    expect(find.text('Let our team check your chats to fix mistakes.'), findsOneWidget);
    final sw = tester.widget<Switch>(find.descendant(
        of: find.byType(HelpImproveRow), matching: find.byType(Switch)));
    expect(sw.value, isFalse);
  });

  testWidgets('turning on shows the notice first; "Not now" sends nothing', (tester) async {
    await pumpRow(tester);
    final before = calls.length;
    await tester.tap(find.descendant(of: find.byType(HelpImproveRow), matching: find.byType(Switch)));
    await tester.pumpAndSettle();
    expect(find.text('Help improve the assistant?'), findsOneWidget);
    expect(find.textContaining('kept up to 14 days'), findsOneWidget);
    expect(calls.skip(before).where((c) => c.$1 == 'PUT'), isEmpty, reason: 'sent before the notice');
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(calls.where((c) => c.$1 == 'PUT'), isEmpty);
    expect(PrivacyPrefsService.instance.isOn, isFalse);
  });

  testWidgets('"Turn on" saves it; turning off asks, then saves false', (tester) async {
    await pumpRow(tester);
    final sw = find.descendant(of: find.byType(HelpImproveRow), matching: find.byType(Switch));
    await tester.tap(sw);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Turn on'));
    await tester.pumpAndSettle();
    expect(calls.where((c) => c.$1 == 'PUT').single.$3, containsPair('helpImprove', true));
    expect(PrivacyPrefsService.instance.isOn, isTrue);

    await tester.tap(sw);
    await tester.pumpAndSettle();
    expect(find.text('Turn off?'), findsOneWidget);
    await tester.tap(find.text('Keep on'));
    await tester.pumpAndSettle();
    expect(calls.where((c) => c.$1 == 'PUT').length, 1, reason: 'Keep on still sent a change');

    await tester.tap(sw);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Turn off'));
    await tester.pumpAndSettle();
    final puts = calls.where((c) => c.$1 == 'PUT').toList();
    expect(puts.length, 2);
    expect(puts.last.$3, containsPair('helpImprove', false));
    expect(puts.last.$3, containsPair('source', 'settings'));
    expect(PrivacyPrefsService.instance.isOn, isFalse);
    // Let the toast finish before the test ends.
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('the one-time card: both answers, the same style', (tester) async {
    bool? answer;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: HelpImproveAskCard(days: 14, onAnswer: (v) => answer = v)),
    ));
    final no = find.widgetWithText(OutlinedButton, 'No thanks');
    final yes = find.widgetWithText(OutlinedButton, 'Yes, help improve');
    expect(no, findsOneWidget);
    expect(yes, findsOneWidget, reason: 'the two answers must look alike');
    await tester.tap(no);
    expect(answer, isFalse);
    await tester.tap(yes);
    expect(answer, isTrue);
  });
}
