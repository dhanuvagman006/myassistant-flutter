// Home's layers close like screens: Android Back closes the news panel
// before it leaves the app, and web results have their own ✕ and sit clear
// of the dock (they used to have no close at all and stay over every tab).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/features/assistant/state/assistant_engine.dart';
import 'package:myassistant/features/assistant/state/assistant_state.dart';
import 'package:myassistant/models/news_item.dart';
import 'package:myassistant/shell/home_shell.dart';
import 'package:myassistant/widgets/inline_voice.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> pumpShell(WidgetTester tester) async {
    tester.view.devicePixelRatio = 2.0;
    tester.view.physicalSize = const Size(720, 1280);
    const pad = FakeViewPadding(top: 48, bottom: 96); // 3-button navigation
    tester.view.padding = pad;
    tester.view.viewPadding = pad;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: HomeShell()));
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> teardown(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    AssistantEngine.instance.cancelReconnect();
    await tester.pump(const Duration(seconds: 5));
  }

  testWidgets('Back closes the news panel instead of leaving the app', (tester) async {
    await pumpShell(tester);
    final engine = AssistantEngine.instance
      ..newsItems = const [NewsItem(title: 'Monsoon arrives early', url: 'https://example.com')]
      ..notifyListeners();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Monsoon arrives early'), findsOneWidget);
    final popped = await tester.binding.handlePopRoute();
    await tester.pump(const Duration(milliseconds: 300));
    expect(popped, isTrue, reason: 'Back was handled by the app');
    expect(engine.newsItems, isEmpty);
    expect(find.text('Monsoon arrives early'), findsNothing);
    await teardown(tester);
  });

  testWidgets('web results have a close button and clear the mic', (tester) async {
    await pumpShell(tester);
    final engine = AssistantEngine.instance
      ..searchResults = const [
        SearchResult(
            title: 'Train times', url: 'https://example.com', snippet: 'Every 20 min', source: 'example.com'),
      ]
      ..notifyListeners();
    await tester.pump(const Duration(milliseconds: 300));
    final card = tester.getRect(find.text('Train times'));
    final orb = tester.getRect(find.byType(AssistantOrbButton));
    expect(card.bottom, lessThanOrEqualTo(orb.top), reason: 'above the mic, not under it');
    expect(card.top, greaterThan(0), reason: 'and not off the top of the screen');
    await tester.tap(find.byTooltip('Close sources'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(engine.searchResults, isEmpty);
    expect(find.text('Train times'), findsNothing);
    await teardown(tester);
  });
}
