// FOCUS (2026-09-25, Momentum) — the countdown's arithmetic, the session
// that survives the app being killed, and the page that redraws once a
// second only while it is on screen and running.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:myassistant/screens/focus_screen.dart';
import 'package:myassistant/services/focus_service.dart';
import 'package:myassistant/services/momentum_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeAlerts implements FocusAlerts {
  final log = <String>[];
  DateTime? endsAt;
  bool? rest;

  @override
  Future<void> show({required DateTime endsAt, required String label, required bool rest}) async {
    log.add('show');
    this.endsAt = endsAt;
    this.rest = rest;
  }

  @override
  Future<void> cancel() async => log.add('cancel');

  @override
  Future<void> finished() async => log.add('finished');
}

Map<String, dynamic> emptySummary() => {
      'ok': true,
      'day': '2026-09-25',
      'priorities': [],
      'habits': [],
      'focus': {'todayMin': 0, 'weekMin': 0, 'totalMin': 0},
      'streak': {'current': 0, 'best': 0, 'activeToday': false, 'graceUsedThisWeek': false},
      'week': {'days': [], 'wins': 0, 'focusMin': 0, 'habitsKept': 0, 'bestDay': null},
      'milestones': [],
    };

void main() {
  GoogleFonts.config.allowRuntimeFetching = false;
  final svc = FocusService.instance;
  late DateTime now;
  late FakeAlerts alerts;
  late List<(String, String, Map<String, dynamic>?)> calls;
  var offline = false;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    now = DateTime(2026, 9, 25, 10, 0);
    FocusService.clock = () => now;
    MomentumService.clock = () => now;
    alerts = FakeAlerts();
    FocusService.alerts = alerts;
    calls = [];
    offline = false;
    MomentumService.onHabitsChanged = null;
    await MomentumService.instance.reset();
    MomentumService.transport = (m, p, {body}) async {
      calls.add((m, p, body));
      if (offline) return const MomentumReply(0, null);
      return MomentumReply(200, {...emptySummary(), if (m == 'POST') 'focusId': 41});
    };
    await svc.reset();
    alerts.log.clear();
  });

  group('the clock', () {
    test('time left counts pauses out and "+5 min" in', () {
      var c = FocusClock(startedAt: now, plannedMin: 25);
      expect(c.remaining(now.add(const Duration(minutes: 10))), const Duration(minutes: 15));
      c = c.pause(now.add(const Duration(minutes: 10)));
      expect(c.remaining(now.add(const Duration(minutes: 20))), const Duration(minutes: 15),
          reason: 'paused: time stands still');
      c = c.resume(now.add(const Duration(minutes: 20)));
      expect(c.remaining(now.add(const Duration(minutes: 30))), const Duration(minutes: 5));
      c = c.plus(5);
      expect(c.total, const Duration(minutes: 30));
      expect(c.remaining(now.add(const Duration(minutes: 30))), const Duration(minutes: 10));
      expect(c.minutesDone(now.add(const Duration(minutes: 30, seconds: 59))), 20);
      expect(c.isDone(now.add(const Duration(minutes: 39))), isFalse);
      expect(c.isDone(now.add(const Duration(minutes: 40))), isTrue);
      expect(c.remaining(now.add(const Duration(hours: 3))), Duration.zero, reason: 'never negative');
      expect(c.progress(now.add(const Duration(minutes: 25))), closeTo(0.5, 1e-9));
    });

    test('it survives being written down and read back', () {
      final c = FocusClock(startedAt: now, plannedMin: 45, extraMin: 5)
          .pause(now.add(const Duration(minutes: 3)))
          .resume(now.add(const Duration(minutes: 4)));
      final back = FocusClock.fromJson(jsonDecode(jsonEncode(c.toJson())) as Map<String, dynamic>);
      final at = now.add(const Duration(minutes: 20));
      expect(back.remaining(at), c.remaining(at));
      expect(back.total, c.total);
      expect(back.paused, isFalse);
    });

    test('the digits read like a timer', () {
      expect(focusTimeText(const Duration(minutes: 24, seconds: 59)), '24:59');
      expect(focusTimeText(const Duration(minutes: 5)), '5:00');
      expect(focusTimeText(const Duration(hours: 1, minutes: 4, seconds: 9)), '1:04:09');
      expect(focusTimeText(const Duration(seconds: -3)), '0:00');
    });
  });

  group('the session', () {
    test('start: saved, in the shade, and known to the server', () async {
      await svc.start(25, label: 'The report');
      expect(svc.running, isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('focus_session_v1'), isNotNull);
      expect(alerts.log, ['show']);
      expect(alerts.endsAt, now.add(const Duration(minutes: 25)));
      expect(calls.single.$1, 'POST');
      expect(calls.single.$3, {'plannedMin': 25, 'label': 'The report'});
      expect(svc.session!.serverId, 41);
    });

    test('a second start keeps the first', () async {
      await svc.start(25);
      await svc.start(45);
      expect(svc.session!.clock.plannedMin, 25);
    });

    test('pause takes it out of the shade; resume puts it back, later', () async {
      await svc.start(25);
      now = now.add(const Duration(minutes: 5));
      await svc.pause();
      expect(alerts.log.last, 'cancel');
      now = now.add(const Duration(minutes: 10));
      await svc.resume();
      expect(alerts.log.last, 'show');
      expect(alerts.endsAt, now.add(const Duration(minutes: 20)), reason: 'the pause did not count');
    });

    test('ended early: the minutes done are logged, and the alert is cancelled', () async {
      await svc.start(25);
      now = now.add(const Duration(minutes: 12, seconds: 40));
      await svc.end();
      expect(svc.session!.done, isTrue);
      expect(svc.session!.completed, isFalse);
      expect(calls.last.$1, 'PATCH');
      expect(calls.last.$2, '/focus/41?day=2026-09-25');
      expect(calls.last.$3, {'actualMin': 12, 'completed': false});
      expect(alerts.log.last, 'cancel');
      expect(svc.session!.logged, isTrue);
    });

    test('after a restart it carries on from the right second', () async {
      final started = now.subtract(const Duration(minutes: 10));
      SharedPreferences.setMockInitialValues({
        'focus_session_v1': jsonEncode(FocusSession(
          kind: FocusKind.focus,
          clock: FocusClock(startedAt: started, plannedMin: 25),
          label: 'Deck',
          serverId: 41,
        ).toJson()),
      });
      await svc.restore(force: true);
      expect(svc.running, isTrue);
      expect(svc.session!.clock.remaining(now), const Duration(minutes: 15));
      expect(svc.session!.label, 'Deck');
    });

    test('one that ran out while the app was away is finished and logged in full', () async {
      SharedPreferences.setMockInitialValues({
        'focus_session_v1': jsonEncode(FocusSession(
          kind: FocusKind.focus,
          clock: FocusClock(startedAt: now.subtract(const Duration(minutes: 40)), plannedMin: 25),
          serverId: 41,
        ).toJson()),
      });
      await svc.restore(force: true);
      expect(svc.session!.done, isTrue);
      expect(svc.session!.completed, isTrue);
      expect(svc.session!.minutes, 25);
      expect(calls.last.$3, {'actualMin': 25, 'completed': true});
      expect(alerts.log, ['finished'], reason: 'the alert that rang stays');
    });

    test('offline at the end: logged at the next launch instead', () async {
      await svc.start(25);
      offline = true;
      now = now.add(const Duration(minutes: 25));
      await svc.tick();
      expect(svc.session!.done, isTrue);
      expect(svc.session!.logged, isFalse);
      offline = false;
      await svc.restore(force: true);
      expect(svc.session!.logged, isTrue);
      expect(calls.where((c) => c.$1 == 'PATCH').last.$3, {'actualMin': 25, 'completed': true});
    });

    test('a break is its own short thing, never logged as focus', () async {
      await svc.startBreak();
      expect(svc.session!.kind, FocusKind.rest);
      expect(svc.session!.clock.plannedMin, 5);
      expect(alerts.rest, isTrue);
      now = now.add(const Duration(minutes: 5));
      await svc.tick();
      expect(svc.session!.done, isTrue);
      expect(calls, isEmpty);
    });
  });

  group('the page', () {
    // Offstage too: a page covered by another one is offstage, not gone.
    dynamic stateOf(WidgetTester t) =>
        t.state(find.byType(FocusScreen, skipOffstage: false));

    Future<void> open(WidgetTester t, Widget screen) async {
      t.view.devicePixelRatio = 2.625;
      t.view.physicalSize = const Size(1080, 2340);
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(home: screen));
      await t.pump();
      await t.pump(const Duration(milliseconds: 50));
    }

    Future<void> close(WidgetTester t) async {
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 1));
    }

    Future<void> second(WidgetTester t) async {
      now = now.add(const Duration(seconds: 1));
      await t.pump(const Duration(seconds: 1));
    }

    testWidgets('counts down once a second, and rests while paused', (t) async {
      await open(t, const FocusScreen(minutes: 25, label: 'The report', autoStart: true));
      expect(find.text('25:00'), findsOneWidget);
      expect(find.text('The report'), findsOneWidget);
      expect(stateOf(t).ticking, isTrue);
      await second(t);
      expect(find.text('24:59'), findsOneWidget);

      await t.tap(find.text('Pause'));
      await t.pump();
      expect(stateOf(t).ticking, isFalse, reason: 'paused: nothing counts');
      // Long enough for the button's own press ripple to finish.
      for (var i = 0; i < 6; i++) {
        await t.pump(const Duration(milliseconds: 300));
      }
      expect(SchedulerBinding.instance.transientCallbackCount, 0);
      expect(t.binding.hasScheduledFrame, isFalse, reason: 'a paused timer asks for no frames');
      now = now.add(const Duration(seconds: 30));
      await t.pump(const Duration(seconds: 5));
      expect(find.text('24:59'), findsOneWidget);
      expect(find.text('Paused'), findsOneWidget);

      await t.tap(find.text('Resume'));
      await t.pump();
      expect(stateOf(t).ticking, isTrue);
      await t.tap(find.text('+5 min'));
      await t.pump();
      expect(find.text('29:59'), findsOneWidget);
      await close(t);
    });

    testWidgets('the ring and its buttons sit in the middle of the screen', (t) async {
      await open(t, const FocusScreen(minutes: 25, autoStart: true));
      final mid = t.getSize(find.byType(FocusScreen)).width / 2;
      final ring = find.byWidgetPredicate(
          (w) => w is CustomPaint && w.painter is FocusRingPainter);
      expect(t.getCenter(ring).dx, closeTo(mid, 1));
      expect(t.getCenter(find.text('Pause')).dx, greaterThan(mid - 1),
          reason: 'Pause sits right of +5 min, both centred as a pair');
      await close(t);
    });

    testWidgets('covered by another page, it stops asking for frames', (t) async {
      await open(t, const FocusScreen(minutes: 15, autoStart: true));
      expect(stateOf(t).ticking, isTrue);
      final nav = t.state<NavigatorState>(find.byType(Navigator));
      nav.push(MaterialPageRoute(builder: (_) => const Scaffold(body: Text('on top'))));
      await t.pump();
      await t.pump(const Duration(milliseconds: 600));
      expect(stateOf(t).ticking, isFalse);
      nav.pop();
      await t.pump();
      await t.pump(const Duration(milliseconds: 600));
      expect(stateOf(t).ticking, isTrue);
      await close(t);
    });

    testWidgets('End asks, then logs what was done', (t) async {
      await open(t, const FocusScreen(minutes: 25, autoStart: true));
      now = now.add(const Duration(minutes: 3, seconds: 5));
      await t.tap(find.text('End'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      expect(find.text('3 minutes will be logged.'), findsOneWidget);
      await t.tap(find.widgetWithText(TextButton, 'End'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      expect(find.text('Focus ended'), findsOneWidget);
      expect(find.text('3 minutes of focus logged.'), findsOneWidget);
      expect(calls.last.$3, {'actualMin': 3, 'completed': false});
      expect(stateOf(t).ticking, isFalse);
      await close(t);
    });

    testWidgets('time up: "take 5?", and the break starts from there', (t) async {
      await open(t, const FocusScreen(minutes: 25, autoStart: true));
      now = now.add(const Duration(minutes: 25));
      await t.pump(const Duration(seconds: 1));
      await t.pump(const Duration(milliseconds: 400));
      expect(find.text('Focus done — take 5?'), findsOneWidget);
      expect(find.text('25 minutes of focus logged.'), findsOneWidget);
      await t.tap(find.text('Start a 5-minute break'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 50));
      expect(find.text('5:00'), findsOneWidget);
      expect(find.text('Break'), findsWidgets);
      await close(t);
    });

    testWidgets('opened after a restart, it shows the session where it is', (t) async {
      SharedPreferences.setMockInitialValues({
        'focus_session_v1': jsonEncode(FocusSession(
          kind: FocusKind.focus,
          clock: FocusClock(startedAt: now.subtract(const Duration(minutes: 10)), plannedMin: 25),
          serverId: 41,
        ).toJson()),
      });
      await open(t, const FocusScreen());
      expect(find.text('15:00'), findsOneWidget);
      await close(t);
    });

    testWidgets('with nothing running it asks how long first', (t) async {
      await open(t, const FocusScreen());
      expect(find.text('How long?'), findsOneWidget);
      expect(stateOf(t).ticking, isFalse);
      await t.tap(find.text('45 min'));
      await t.pump();
      await t.tap(find.text('Start'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 50));
      expect(find.text('45:00'), findsOneWidget);
      await close(t);
    });
  });
}
