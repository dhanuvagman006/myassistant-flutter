// MOMENTUM SERVICE (2026-09-25) — the state behind the Home card and the
// Momentum screen: a tap shows at once and is taken back if the server
// says no; requests go out one at a time, in order; the last good copy
// paints Home instantly (for the same day only); celebrations play once;
// habit reminders follow the habits.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/models/momentum.dart';
import 'package:myassistant/services/habit_alarms.dart';
import 'package:myassistant/services/momentum_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The summary a server would send for [day].
Map<String, dynamic> summaryJson({
  String day = '2026-09-25',
  List<Map<String, dynamic>> priorities = const [],
  List<Map<String, dynamic>> habits = const [],
  int streak = 0,
  bool activeToday = false,
  List<String> earned = const [],
}) =>
    {
      'ok': true,
      'day': day,
      'priorities': priorities,
      'habits': habits,
      'focus': {'todayMin': 0, 'weekMin': 0, 'totalMin': 0},
      'streak': {'current': streak, 'best': streak, 'activeToday': activeToday, 'graceUsedThisWeek': false},
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
      'milestones': [
        for (final id in ['streak_3', 'streak_7'])
          {'id': id, 'label': id == 'streak_3' ? '3-day streak' : '7-day streak', 'earned': earned.contains(id)},
      ],
    };

Map<String, dynamic> pri(int id, String title, {bool done = false, int position = 0}) =>
    {'id': id, 'title': title, 'done': done, 'position': position};

/// A fake server: records every request, answers from [reply], and can be
/// held so a test sees the screen BEFORE the answer arrives.
class FakeServer {
  final calls = <(String, String, Map<String, dynamic>?)>[];
  MomentumReply Function(String method, String path, Map<String, dynamic>? body) reply =
      (m, p, b) => MomentumReply(200, summaryJson());
  Completer<void>? gate;

  Future<MomentumReply> call(String method, String path, {Map<String, dynamic>? body}) async {
    calls.add((method, path, body));
    final g = gate;
    if (g != null) await g.future;
    return reply(method, path, body);
  }
}

/// Lets queued requests reach the fake server.
Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  final svc = MomentumService.instance;
  late FakeServer server;
  late List<List<MomentumHabit>> armed;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    armed = [];
    MomentumService.onHabitsChanged = armed.add;
    await svc.reset();
    armed.clear();
    server = FakeServer();
    MomentumService.transport = server.call;
    MomentumService.clock = () => DateTime(2026, 9, 25, 10, 30);
  });

  test('the day is the phone\'s own date, on every request', () async {
    await svc.refresh(force: true);
    expect(server.calls.single.$1, 'GET');
    expect(server.calls.single.$2, '?day=2026-09-25');
    expect(MomentumService.tomorrow, '2026-09-26');
    expect(MomentumService.dayOf(DateTime(2027, 1, 5)), '2027-01-05');
  });

  test('a tick shows at once, before the server has answered', () async {
    svc.debugSeed(MomentumSummary.fromJson(summaryJson(priorities: [pri(1, 'Report'), pri(2, 'Bank', position: 1)])));
    server.gate = Completer<void>();
    server.reply = (m, p, b) =>
        MomentumReply(200, summaryJson(priorities: [pri(1, 'Report', done: true), pri(2, 'Bank', position: 1)],
            streak: 1, activeToday: true));
    final done = svc.togglePriority(1);
    expect(svc.summary!.priorities.first.done, isTrue, reason: 'optimistic');
    expect(svc.summary!.activeToday, isTrue, reason: 'today counts at once');
    await settle();
    expect(server.calls.single.$1, 'PATCH');
    expect(server.calls.single.$2, '/priorities/1?day=2026-09-25');
    expect(server.calls.single.$3, {'done': true});
    server.gate!.complete();
    expect(await done, isTrue);
    expect(svc.summary!.priorities.first.done, isTrue);
    expect(svc.summary!.streak, 1);
    expect(svc.lastError, isNull);
  });

  test('a refused change is taken back, and says why', () async {
    svc.debugSeed(MomentumSummary.fromJson(summaryJson(priorities: [pri(1, 'Report')])));
    server.reply = (m, p, b) => const MomentumReply(409, {'ok': false, 'error': 'that day already has 3 priorities'});
    final ok = await svc.movePriorityToTomorrow(1);
    expect(ok, isFalse);
    expect(svc.summary!.priorities.map((p) => p.title), ['Report'], reason: 'rolled back');
    expect(svc.lastError, 'That day already has three.');

    server.reply = (m, p, b) => const MomentumReply(0, null);
    expect(await svc.togglePriority(1), isFalse);
    expect(svc.summary!.priorities.first.done, isFalse);
    expect(svc.lastError, "Couldn't save — check your connection.");
  });

  test('requests go out one at a time, in the order they were made', () async {
    svc.debugSeed(MomentumSummary.fromJson(summaryJson(priorities: [pri(1, 'Report')])));
    server.gate = Completer<void>();
    var serverDone = false;
    server.reply = (m, p, b) {
      if (m == 'PATCH') serverDone = b!['done'] as bool;
      return MomentumReply(200, summaryJson(priorities: [pri(1, 'Report', done: serverDone)]));
    };
    final a = svc.togglePriority(1); // tick
    await Future<void>.delayed(Duration.zero);
    final b = svc.togglePriority(1); // untick, quickly
    await Future<void>.delayed(Duration.zero);
    expect(server.calls.length, 1, reason: 'the second waits for the first');
    expect(svc.summary!.priorities.first.done, isFalse, reason: 'both edits shown');
    server.gate!.complete();
    await a;
    await b;
    expect(server.calls.map((c) => c.$3), [
      {'done': true},
      {'done': false},
    ]);
    expect(svc.summary!.priorities.first.done, isFalse);
  });

  test('adding keeps the list: the new one shows now, and saved ones go by id', () async {
    svc.debugSeed(MomentumSummary.fromJson(summaryJson(priorities: [pri(7, 'Report', done: true)])));
    server.reply = (m, p, b) => MomentumReply(200,
        summaryJson(priorities: [pri(7, 'Report', done: true), pri(8, 'Call the bank', position: 1)]));
    final f = svc.addPriority('  Call   the bank ');
    expect(svc.summary!.priorities.last.title, 'Call the bank');
    expect(svc.summary!.priorities.last.id, isNegative, reason: 'not saved yet');
    expect(await f, isTrue);
    final c = server.calls.single;
    expect(c.$1, 'PUT');
    expect(c.$3, {
      'day': '2026-09-25',
      'items': [
        {'id': 7, 'title': 'Report'},
        {'title': 'Call the bank'},
      ],
    });
    expect(svc.summary!.priorities.last.id, 8);
  });

  test('three is the most, said before anything is sent', () async {
    svc.debugSeed(MomentumSummary.fromJson(summaryJson(
        priorities: [pri(1, 'a'), pri(2, 'b', position: 1), pri(3, 'c', position: 2)])));
    expect(await svc.addPriority('d'), isFalse);
    expect(server.calls, isEmpty);
    expect(svc.lastError, 'Today already has three.');
  });

  test('habits: a tick shows at once and moves today\'s dot and streak', () async {
    svc.debugSeed(MomentumSummary.fromJson(summaryJson(habits: [
      {'id': 3, 'title': 'Water', 'emoji': '💧', 'doneToday': false, 'streak': 2, 'best': 4,
        'last7': [false, false, false, false, true, true, false]},
    ])));
    server.gate = Completer<void>();
    final f = svc.toggleHabit(3);
    final h = svc.summary!.habits.single;
    expect(h.doneToday, isTrue);
    expect(h.last7.last, isTrue);
    expect(h.streak, 3);
    await settle();
    expect(server.calls.single.$2, '/habits/3/check?day=2026-09-25');
    expect(server.calls.single.$3, {'day': '2026-09-25', 'done': true});
    server.gate!.complete();
    await f;
  });

  test('the last good copy paints at once — for today only', () async {
    server.reply = (m, p, b) => MomentumReply(200, summaryJson(priorities: [pri(1, 'Report')], streak: 4));
    await svc.refresh(force: true);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final prefs = await SharedPreferences.getInstance();
    final saved = jsonDecode(prefs.getString('momentum_cache_v1')!) as Map<String, dynamic>;
    expect(saved['day'], '2026-09-25');

    // A new launch, offline, the same day: the card is there at once.
    final copy = prefs.getString('momentum_cache_v1')!;
    await svc.reset();
    SharedPreferences.setMockInitialValues({'momentum_cache_v1': copy});
    server.reply = (m, p, b) => const MomentumReply(0, null);
    svc.start();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(svc.summary?.streak, 4);
    expect(svc.summary?.priorities.single.title, 'Report');

    // The next morning, still offline: yesterday's three are not today's.
    await svc.reset();
    SharedPreferences.setMockInitialValues({'momentum_cache_v1': copy});
    MomentumService.clock = () => DateTime(2026, 9, 26, 8);
    svc.start();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(svc.summary, isNull);
    expect(svc.failed, isTrue);
    await svc.reset();
  });

  test('all three done celebrates once; milestones only once reached here', () async {
    final seen = <String>[];
    void listen() {
      final c = svc.celebration.value;
      if (c != null) seen.add(c.line);
    }

    svc.celebration.addListener(listen);
    addTearDown(() => svc.celebration.removeListener(listen));

    // First look: a 3-day streak already earned is recorded, not celebrated.
    server.reply = (m, p, b) => MomentumReply(200, summaryJson(
        priorities: [pri(1, 'a', done: true), pri(2, 'b', position: 1), pri(3, 'c', position: 2)],
        earned: ['streak_3']));
    await svc.refresh(force: true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(seen, isEmpty);

    // The other two ticked: all three.
    server.reply = (m, p, b) => MomentumReply(200, summaryJson(
        priorities: [pri(1, 'a', done: true), pri(2, 'b', done: true, position: 1), pri(3, 'c', done: true, position: 2)],
        earned: ['streak_3']));
    await svc.togglePriority(2);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(seen, ['All three done — a winning day.']);
    await svc.refresh(force: true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(seen.length, 1, reason: 'once per day, not once per refresh');

    // A new milestone.
    server.reply = (m, p, b) => MomentumReply(200, summaryJson(earned: ['streak_3', 'streak_7']));
    await svc.refresh(force: true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(seen.last, '7-day streak — well done.');
    expect(seen.length, 2);
  });

  test('habit reminders follow the habits, and stop at sign-out', () async {
    server.reply = (m, p, b) => MomentumReply(200, summaryJson(habits: [
          {'id': 3, 'title': 'Water', 'emoji': '💧', 'remindAt': '09:00', 'doneToday': false,
            'streak': 0, 'best': 0, 'last7': List.filled(7, false)},
        ]));
    await svc.refresh(force: true);
    expect(armed.length, 1);
    await svc.refresh(force: true);
    expect(armed.length, 1, reason: 'unchanged: not re-armed');
    await svc.reset();
    expect(armed.last, isEmpty, reason: 'signed out: nothing rings');
  });

  group('habit reminder plan', () {
    MomentumHabit h(int id, String? at, {bool done = false}) =>
        MomentumHabit(id: id, title: 'Water', emoji: '💧', remindAt: at, doneToday: done);

    test('one a day for a week, from the next time it comes round', () {
      final now = DateTime(2026, 9, 25, 10, 30);
      final plan = HabitAlarms.plan([h(3, '09:00'), h(4, '21:30'), h(5, null)], now);
      final nine = plan.where((a) => a.id ~/ 8 == (HabitAlarms.base + 3 * 8) ~/ 8).toList();
      expect(nine.length, 6, reason: 'today\'s 9:00 has passed');
      expect(nine.first.at, DateTime(2026, 9, 26, 9));
      final evening = plan.where((a) => a.at.hour == 21).toList();
      expect(evening.length, 7);
      expect(evening.first.at, DateTime(2026, 9, 25, 21, 30));
      expect(plan.every((a) => HabitAlarms.isHabitAlarm(a.id)), isTrue);
      expect(plan.first.title, '💧 Water');
    });

    test('a habit already ticked today is not reminded about today', () {
      final now = DateTime(2026, 9, 25, 10, 30);
      final plan = HabitAlarms.plan([h(4, '21:30', done: true)], now);
      expect(plan.first.at, DateTime(2026, 9, 26, 21, 30));
      expect(plan.length, 6);
      expect(HabitAlarms.idFor(4, 0), isNot(HabitAlarms.idFor(4, 1)));
      expect(HabitAlarms.idFor(4, 6), lessThan(HabitAlarms.idFor(5, 0)), reason: 'no overlap');
    });
  });
}
