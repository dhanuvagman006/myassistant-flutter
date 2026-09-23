// The "What's new" card shows once per release and stays gone once closed.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/widgets/whats_new_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Future<void> show(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: WhatsNewCard()))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('first time: shown, listing what changed', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await show(tester);
    expect(find.text("What's new"), findsOneWidget);
    expect(find.textContaining('Search everything'), findsOneWidget);
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
