// The "What's new" card shows once per release and stays gone once closed.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/models/remote_config.dart';
import 'package:myassistant/services/api_service.dart';
import 'package:myassistant/widgets/whats_new_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Future<void> show(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: WhatsNewCard()))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  // The card describes the release the SERVER published (its changelog),
  // not a list baked into the build (2026-10-01).
  setUp(() {
    ApiService.config = const RemoteConfig(latestVersionName: '0.2.99', changelog: [
      'One tap on the orb stops and brings you home',
      'English in, English out: the assistant answers in the language you just spoke',
      'Say show me a picture of anyone or anything and it appears right here',
    ]);
  });
  tearDown(() => ApiService.config = const RemoteConfig());

  test("the server's changelog is the list; no changelog, no card", () {
    expect(WhatsNewCard.release, '0.2.99');
    expect(WhatsNewCard.items.length, 3);
    expect(WhatsNewCard.items.first.$2, contains('One tap on the orb'));
    ApiService.config = const RemoteConfig();
    expect(WhatsNewCard.items, isEmpty);
  });

  testWidgets('first time: shown, listing what changed', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await show(tester);
    expect(find.text("What's new"), findsOneWidget);
    expect(find.textContaining('One tap on the orb'), findsOneWidget);
    expect(find.textContaining('English in, English out'), findsOneWidget);
  });

  testWidgets('seen for the last release: shown again for this one', (tester) async {
    SharedPreferences.setMockInitialValues({'whats_new_seen_0.2.98': true});
    await show(tester);
    expect(find.text("What's new"), findsOneWidget);
  });

  testWidgets('closed once, it does not come back for this release', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await show(tester);
    await tester.tap(find.byTooltip('Dismiss'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text("What's new"), findsNothing);
    await show(tester); // next launch
    expect(find.text("What's new"), findsNothing);
  });
}
