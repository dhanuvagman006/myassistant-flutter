// Second pass over the 2026-09-24 UI fixes ("it overlaps, the toast
// repeats and is not closed"): cases the first pass left open.
//  A. A long toast (6 s) asked for again after the 5 s repeat window was
//     shown a second time — it restarted, the "it repeats" effect.
//  B. A toast already up when the voice session opened sat on the
//     session's text box (it was placed for the page).
//  C. The news and schedule panels scrolled their rows behind the dock, so
//     rows showed through the ring around the mic (hub.png, in a panel).
//  D. Cards near the dock stepped up a fixed 64 dp for a toast; a two-line
//     toast is taller, and covered the bottom of the card.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/features/assistant/state/assistant_engine.dart';
import 'package:myassistant/features/assistant/state/assistant_state.dart';
import 'package:myassistant/features/assistant/widgets/action_cards.dart';
import 'package:myassistant/models/news_item.dart';
import 'package:myassistant/models/schedule_item.dart';
import 'package:myassistant/services/app_feedback.dart';
import 'package:myassistant/widgets/news_panel.dart';
import 'package:myassistant/widgets/schedule_panel.dart';
import 'package:myassistant/shell/home_shell.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppFeedback.resetForTest();
  });
  tearDown(AppFeedback.resetForTest);

  testWidgets('a long toast repeated at 5.5 s is not shown a second time', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(
      scaffoldMessengerKey: AppFeedback.messengerKey,
      navigatorObservers: [AppFeedback.observer],
      home: Scaffold(body: Builder(builder: (c) {
        ctx = c;
        return const SizedBox.expand();
      })),
    ));
    const long = 'Saved to your documents under Ravi — ask me about it any time you like, '
        'I will remember it.';
    AppFeedback.show(long, context: ctx);
    for (var i = 0; i < 55; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // Real clock: make the 5 s window lapse the way it would on a phone.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5100)));
    AppFeedback.show(long, context: ctx);
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();
    expect(find.text(long), findsNothing, reason: 'the repeat re-showed it for another 6 s');
  });

  testWidgets('a toast up when the voice session opens does not cover its text box',
      (tester) async {
    tester.view.devicePixelRatio = 2.0;
    tester.view.physicalSize = const Size(720, 1280);
    const pad = FakeViewPadding(top: 48, bottom: 96);
    tester.view.padding = pad;
    tester.view.viewPadding = pad;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      scaffoldMessengerKey: AppFeedback.messengerKey,
      navigatorObservers: [AppFeedback.observer],
      home: const HomeShell(),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    AppFeedback.show('Reminder saved for five o\'clock.',
        context: tester.element(find.byType(HomeShell)));
    await tester.pump(const Duration(milliseconds: 500));
    AssistantEngine.instance
      ..inlineVoice = true
      ..phase = AssistantPhase.listening
      ..notifyListeners();
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
    final bars = find.descendant(of: find.byType(SnackBar), matching: find.byType(Material));
    if (bars.evaluate().isNotEmpty) {
      final bar = tester.getRect(bars.first);
      expect(bar.overlaps(tester.getRect(find.byType(TextField))), isFalse,
          reason: 'toast sits on the session text box');
    }
    AssistantEngine.instance
      ..inlineVoice = false
      ..phase = AssistantPhase.idle
      ..notifyListeners();
    await tester.pumpWidget(const SizedBox());
    AssistantEngine.instance.cancelReconnect();
    await tester.pump(const Duration(seconds: 7));
  });

  for (final which in ['news', 'schedule']) {
    testWidgets('the $which panel list never scrolls behind the dock notch', (tester) async {
      tester.view.devicePixelRatio = 2.0;
      tester.view.physicalSize = const Size(720, 1280);
      const pad = FakeViewPadding(top: 48, bottom: 96);
      tester.view.padding = pad;
      tester.view.viewPadding = pad;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const MaterialApp(home: HomeShell()));
      await tester.pump(const Duration(milliseconds: 300));
      final e = AssistantEngine.instance;
      if (which == 'news') {
        e.newsItems = [
          for (var i = 0; i < 14; i++)
            NewsItem(title: 'Headline number $i about the monsoon', url: 'https://example.com/$i'),
        ];
      } else {
        e.scheduleItems = [
          for (var i = 0; i < 14; i++)
            ScheduleItem(kind: 'meeting', title: 'Meeting number $i', time: '10:$i am'),
        ];
      }
      e.notifyListeners();
      await tester.pump(const Duration(milliseconds: 300));
      final panel = which == 'news' ? find.byType(NewsPanel) : find.byType(SchedulePanel);
      final list = find.descendant(of: panel, matching: find.byType(Scrollable)).first;
      final bar = tester.getRect(find.byType(BottomAppBar));
      expect(tester.getRect(list).bottom, lessThanOrEqualTo(bar.top + 0.5),
          reason: 'rows pass behind the bar and show through the ring around the mic');
      e
        ..newsItems = const []
        ..scheduleItems = const []
        ..notifyListeners();
      await tester.pumpWidget(const SizedBox());
      AssistantEngine.instance.cancelReconnect();
      await tester.pump(const Duration(seconds: 7));
    });
  }

  for (final lines in [1, 2, 3]) {
    testWidgets('a $lines-line toast and a result card do not overlap', (tester) async {
      tester.view.devicePixelRatio = 2.625;
      tester.view.physicalSize = const Size(1080, 2340);
      const pad = FakeViewPadding(top: 63, bottom: 42);
      tester.view.padding = pad;
      tester.view.viewPadding = pad;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        scaffoldMessengerKey: AppFeedback.messengerKey,
        navigatorObservers: [AppFeedback.observer],
        home: const HomeShell(),
      ));
      await tester.pump(const Duration(milliseconds: 300));
      final e = AssistantEngine.instance
        ..presentedTitle = 'Your note'
        ..presentedText = 'Buy milk and bread on the way home.'
        ..notifyListeners();
      await tester.pump(const Duration(milliseconds: 300));
      final text = switch (lines) {
        1 => 'Saved.',
        2 => 'Saved to your documents under Ravi — ask me about it any time.',
        _ => "Couldn't upload that — check your connection and try again. The "
            'recording is kept on this phone; try Stop again when you are back '
            'online, or share it from My documents instead.',
      };
      AppFeedback.show(text, context: tester.element(find.byType(HomeShell)));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      final bar = tester.getRect(find
          .descendant(of: find.byType(SnackBar), matching: find.byType(Material))
          .first);
      final card = tester.getRect(find.byType(ScriptCard));
      expect(bar.overlaps(card), isFalse, reason: 'toast covers the card');
      e
        ..presentedTitle = null
        ..presentedText = null
        ..notifyListeners();
      await tester.pumpWidget(const SizedBox());
      AssistantEngine.instance.cancelReconnect();
      await tester.pump(const Duration(seconds: 7));
    });
  }
}
