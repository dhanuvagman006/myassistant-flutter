// MOMENTUM ON HOME (2026-09-25) — the card near the top of the feed: the
// streak, Today's 3 with tick boxes and a ring, habit chips, Focus. Owner:
// "plan and add some features that make much better and keeps user
// motivated and productive".
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/models/momentum.dart';
import 'package:myassistant/services/momentum_service.dart';
import 'package:myassistant/widgets/momentum_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> summaryJson({
  List<Map<String, dynamic>> priorities = const [],
  List<Map<String, dynamic>> habits = const [],
  int streak = 0,
}) =>
    {
      'ok': true,
      'day': '2026-09-25',
      'priorities': priorities,
      'habits': habits,
      'focus': {'todayMin': 0, 'weekMin': 0, 'totalMin': 0},
      'streak': {'current': streak, 'best': streak, 'activeToday': false, 'graceUsedThisWeek': false},
      'week': {
        'days': [
          for (var i = 19; i <= 25; i++)
            {'day': '2026-09-$i', 'active': false, 'wins': 0, 'focusMin': 0, 'habits': 0, 'forgiven': false},
        ],
        'wins': 0,
        'focusMin': 0,
        'habitsKept': 0,
        'bestDay': null,
      },
      'milestones': const [],
    };

Map<String, dynamic> pri(int id, String title, {bool done = false, int position = 0}) =>
    {'id': id, 'title': title, 'done': done, 'position': position};

Map<String, dynamic> habit(int id, String title, {bool doneToday = false}) => {
      'id': id,
      'title': title,
      'emoji': '💧',
      'remindAt': null,
      'doneToday': doneToday,
      'streak': 0,
      'best': 0,
      'last7': [false, false, false, false, false, false, doneToday],
    };

void main() {
  final svc = MomentumService.instance;
  late List<(String, String, Map<String, dynamic>?)> calls;
  late Map<String, dynamic> Function() answer;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    MomentumService.onHabitsChanged = (_) {};
    await svc.reset();
    calls = [];
    answer = () => summaryJson();
    MomentumService.clock = () => DateTime(2026, 9, 25, 10, 30);
    MomentumService.transport = (method, path, {body}) async {
      calls.add((method, path, body));
      return MomentumReply(200, answer());
    };
  });

  Future<void> show(WidgetTester t, Map<String, dynamic> json) async {
    t.view.devicePixelRatio = 2.625;
    t.view.physicalSize = const Size(1080, 2340);
    addTearDown(t.view.reset);
    svc.debugSeed(MomentumSummary.fromJson(json));
    await t.pumpWidget(const MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: MomentumCard())),
    ));
    await t.pump();
  }

  testWidgets('nothing planned yet: it asks for three wins and says it can be spoken',
      (t) async {
    await show(t, summaryJson());
    expect(find.text('What are 3 wins for today?'), findsOneWidget);
    expect(find.textContaining('my top three today are'), findsOneWidget);
    expect(find.text('Start a streak today'), findsOneWidget,
        reason: 'a streak of zero is an invitation, not a score');
    expect(t.binding.transientCallbackCount, 0, reason: 'a card at rest asks for no frames');
  });

  testWidgets('a tick shows at once and is sent to the server', (t) async {
    final gate = Completer<void>();
    MomentumService.transport = (method, path, {body}) async {
      calls.add((method, path, body));
      await gate.future;
      return MomentumReply(200, answer());
    };
    await show(t, summaryJson(streak: 4, priorities: [
      pri(1, 'Finish the report'),
      pri(2, 'Call the bank', position: 1),
    ]));
    expect(find.text('4-day streak'), findsOneWidget);
    expect(find.text('Finish the report'), findsOneWidget);
    expect(find.text('Add a win'), findsOneWidget, reason: 'room for a third');

    await t.tap(find.text('Finish the report'));
    await t.pump();
    expect(svc.summary!.priorities.firstWhere((p) => p.id == 1).done, isTrue,
        reason: 'the tick must show before the server answers');
    expect(calls.single.$1, 'PATCH');
    expect(calls.single.$2, startsWith('/priorities/1'));
    expect(calls.single.$3, containsPair('done', true));

    answer = () => summaryJson(streak: 5, priorities: [
          pri(1, 'Finish the report', done: true),
          pri(2, 'Call the bank', position: 1),
        ]);
    gate.complete();
    await t.pump();
    await t.pump();
    expect(find.text('5-day streak'), findsOneWidget, reason: 'the server\'s answer is drawn');
  });

  testWidgets('a habit chip ticks today\'s habit', (t) async {
    await show(t, summaryJson(habits: [habit(7, 'Water')]));
    await t.tap(find.textContaining('Water'));
    await t.pump();
    expect(calls, isNotEmpty);
    expect(calls.last.$1, 'PUT');
    expect(calls.last.$2, startsWith('/habits/7/check'));
    expect(calls.last.$3, containsPair('done', true));
  });

  testWidgets('all three done: one short celebration, then stillness', (t) async {
    Map<String, dynamic> twoOfThree() => summaryJson(priorities: [
          pri(1, 'One', done: true),
          pri(2, 'Two', done: true, position: 1),
          pri(3, 'Three', position: 2),
        ]);
    await show(t, twoOfThree());
    // The first answer is a first look: nothing in it is celebrated, so
    // only an all-done that happens now plays.
    answer = twoOfThree;
    await t.runAsync(() => svc.refresh(force: true));
    await t.pump();

    answer = () => summaryJson(priorities: [
          pri(1, 'One', done: true),
          pri(2, 'Two', done: true, position: 1),
          pri(3, 'Three', done: true, position: 2),
        ]);
    await t.tap(find.text('Three'));
    await t.runAsync(() async {
      for (var i = 0; i < 10 && svc.celebration.value == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await t.pump();
    expect(svc.celebration.value?.line, contains('All three done'));
    expect(find.byKey(const ValueKey('momentum-line')), findsOneWidget);

    await t.pump(const Duration(seconds: 2));
    expect(t.binding.transientCallbackCount, 0, reason: 'the burst is one-shot');
    await t.pump(const Duration(seconds: 3));
    expect(find.byKey(const ValueKey('momentum-line')), findsNothing,
        reason: 'the line goes after a few seconds');

    // The same day again: no second celebration.
    final seq = svc.celebration.value!.seq;
    await t.runAsync(() => svc.refresh(force: true));
    await t.pump();
    expect(svc.celebration.value!.seq, seq);
  });
}
