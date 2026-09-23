// Leaving an account must leave nothing behind, and erasing one must take
// more than a stray tap.
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/screens/account_section.dart';
import 'package:myassistant/services/auth_service.dart';
import 'package:myassistant/services/brief_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({'brief_cache_v1': '{"agenda":[]}'});
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('signing out forgets the previous account\'s home brief', () async {
    final brief = BriefService.instance; // registers its sign-out hook
    brief.loaded = true;
    await AuthService.instance.signOut();
    expect(brief.loaded, isFalse, reason: 'the next account would see this agenda');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('brief_cache_v1'), isNull,
        reason: 'the saved copy would repaint it on the next launch');
  });

  test('a first launch with no network ends in a retryable state, not a spinner', () async {
    final brief = BriefService.instance;
    await brief.reset();
    // flutter_test answers every real HTTP request with 400: no network.
    await brief.refresh(force: true);
    expect(brief.loaded, isFalse);
    expect(brief.failed, isTrue, reason: 'Home would spin forever with no retry');
  });

  testWidgets('deleting the account needs the word typed, not just a tap', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: AccountSection())),
    ));
    expect(find.text('Export my data'), findsOneWidget);
    expect(find.text('Sign out'), findsOneWidget);

    await tester.tap(find.text('Delete account'));
    await tester.pumpAndSettle();
    expect(find.text('Delete your account?'), findsOneWidget);
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    final forever = find.widgetWithText(TextButton, 'Delete forever');
    expect(tester.widget<TextButton>(forever).onPressed, isNull,
        reason: 'deletion was one tap away');
    await tester.enterText(find.byType(TextField), 'delete');
    await tester.pump();
    expect(tester.widget<TextButton>(forever).onPressed, isNotNull);
    // Stop here: the next tap would call the real server.
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });
}
