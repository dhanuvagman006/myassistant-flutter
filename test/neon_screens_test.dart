// The neon pass on Reminders, Calendar, Calls, Call notes, Meetings and
// Focus (2026-09-30): glow follows meaning — the reminder that is due, the
// picked day, a missed call — and a list card has a page to grow into.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:myassistant/design/neon_tokens.dart';
import 'package:myassistant/design/neon_widgets.dart';
import 'package:myassistant/features/calendar/calendar_models.dart';
import 'package:myassistant/features/calendar/calendar_widgets.dart';
import 'package:myassistant/models/call_outcome.dart';
import 'package:myassistant/models/reminder.dart';
import 'package:myassistant/screens/calls_screen.dart';
import 'package:myassistant/screens/focus_screen.dart';
import 'package:myassistant/screens/phone/call_detail_screen.dart';
import 'package:myassistant/screens/reminders_screen.dart';
import 'package:myassistant/widgets/month_calendar.dart';
import 'package:myassistant/widgets/neon_cards.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Neon.setDark(true);
  });
  tearDown(() => Neon.setDark(false));

  void phone(WidgetTester t) {
    t.view.devicePixelRatio = 2.625;
    t.view.physicalSize = const Size(1080, 2340);
    addTearDown(t.view.reset);
  }

  test('due now: late, or due within a quarter of an hour — never a done one',
      () {
    final now = DateTime(2026, 9, 30, 14);
    Reminder r(DateTime? at, {bool done = false}) =>
        Reminder(id: 1, text: 'r', dueAt: at, done: done);
    expect(isDueNow(r(now.subtract(const Duration(hours: 3))), now), isTrue);
    expect(isDueNow(r(now.add(const Duration(minutes: 10))), now), isTrue);
    expect(isDueNow(r(now.add(const Duration(hours: 2))), now), isFalse);
    expect(isDueNow(r(null), now), isFalse, reason: 'anytime is never due');
    expect(isDueNow(r(now.subtract(const Duration(hours: 1)), done: true), now),
        isFalse);
  });

  test('a call wears what happened: missed is danger', () {
    CallOutcome call(String status) => CallOutcome(
        id: 1,
        contact: 'Ravi',
        detail: '',
        status: status,
        reason: '',
        transcript: '',
        createdAt: 0,
        updatedAt: 0);
    expect(callTone(call('no_answer')), NeonTone.danger);
    expect(callTone(call('completed')), NeonTone.success);
    expect(callTone(call('dialing')), NeonTone.tip);
    expect(callTone(call('failed')), NeonTone.warning);
  });

  test("the calendar's dots take Home's tones", () {
    expect(calendarTone('meeting'), NeonTone.info);
    expect(calendarTone('reminder'), NeonTone.action);
    expect(calendarTone('promise'), NeonTone.action);
    expect(calendarTone('payment'), NeonTone.warning);
    expect(calendarTone('income'), NeonTone.success);
  });

  test('a class has its own tone, icon and label; older rows still parse', () {
    expect(calendarTone('class'), NeonTone.brand);
    expect(calendarTone('class'),
        isNot(anyOf(calendarTone('meeting'), calendarTone('reminder'))));
    expect(calendarKindIcon('class'), Icons.school_rounded);
    expect(calendarKindLabel('class'), 'Class');
    expect(calendarKindLabel('anniversary'), 'Anniversary');
    // Unknown kinds render as a reminder, as before.
    expect(calendarTone('whatever'), NeonTone.action);
    expect(calendarKindIcon('whatever'), Icons.alarm_rounded);
    expect(calendarKindLabel('whatever'), 'Reminder');

    final start = DateTime(2026, 10, 5, 9).millisecondsSinceEpoch;
    final end = DateTime(2026, 10, 5, 9, 50).millisecondsSinceEpoch;
    final c = CalendarEntry.fromBrief(2026, 10, 5,
        {'kind': 'class', 'title': 'DBMS · Room 204', 'at': start, 'end': end});
    expect(c.kind, 'class');
    expect(c.endAt, DateTime(2026, 10, 5, 9, 50));
    expect(c.end, isNull, reason: 'not a multi-day span');
    expect(c.covers(DateTime(2026, 10, 6)), isFalse);
    expect(calTimeRange(c.at!, c.endAt), '9:00 – 9:50 am');
    expect(
        calTimeRange(
            DateTime(2026, 10, 5, 11, 30), DateTime(2026, 10, 5, 12, 20)),
        '11:30 am – 12:20 pm');

    final old = CalendarEntry.fromBrief(
        2026, 10, 5, {'kind': 'meeting', 'title': 'Standup', 'at': start});
    expect(old.endAt, isNull);
    expect(calTimeRange(old.at!, old.endAt), '9:00 am');
  });

  testWidgets('a class row shows its time range', (t) async {
    phone(t);
    final e = CalendarEntry(
        date: DateTime(2026, 10, 5),
        kind: 'class',
        title: 'DBMS · Room 204',
        at: DateTime(2026, 10, 5, 9),
        endAt: DateTime(2026, 10, 5, 9, 50));
    await t.pumpWidget(MaterialApp(
        home: Scaffold(body: CalEntryRow(e, today: DateTime(2026, 10, 5)))));
    expect(find.textContaining('9:00 – 9:50 am'), findsOneWidget);
    expect(find.textContaining('Class'), findsWidgets);
  });

  testWidgets("the calendar screen's legend has no academic kind (couples, not classes)", (t) async {
    phone(t);
    await t.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: MonthCalendar(
                    extrasFor: (_, __) => const {}, onDaySelected: (_) {})))));
    for (var i = 0; i < 4; i++) {
      await t.pump(const Duration(milliseconds: 300));
    }
    expect(find.text('Class'), findsNothing);
    expect(find.text('Meeting'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 1));
  });

  test('the focus ring repaints when its light changes, not otherwise', () {
    FocusRingPainter p(List<Color>? g) => FocusRingPainter(
        remaining: 0.5, color: Neon.violet, track: Neon.line, gradient: g);
    expect(p(Neon.rim).shouldRepaint(p(Neon.rim)), isFalse);
    expect(p(Neon.rim).shouldRepaint(p([Neon.cyan, Neon.violet])), isTrue);
  });

  testWidgets(
      'a reminder that is due glows in the action tone; the rest sit quiet',
      (t) async {
    phone(t);
    final now = DateTime.now();
    await t.pumpWidget(MaterialApp(
      home: RemindersScreen(
          loader: () async => [
                Reminder(
                    id: 1,
                    text: 'Call the bank',
                    dueAt: now.subtract(const Duration(hours: 1)),
                    done: false),
                Reminder(
                    id: 2,
                    text: 'Renew the passport',
                    dueAt: now.add(const Duration(days: 6)),
                    done: false),
              ]),
    ));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(find.byType(NeonScaffold), findsOneWidget);
    final lit = t.widget<GlowCard>(find.ancestor(
        of: find.text('Call the bank'), matching: find.byType(GlowCard)));
    expect(lit.tone, NeonTone.action);
    expect(
        find.ancestor(
            of: find.text('Renew the passport'),
            matching: find.byType(GlowCard)),
        findsNothing,
        reason: 'a screen where everything glows has no focus');
    expect(
        find.ancestor(
            of: find.text('Renew the passport'),
            matching: find.byType(RimCard)),
        findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 1));
  });

  testWidgets('no reminders: the empty page offers the next step', (t) async {
    phone(t);
    await t.pumpWidget(MaterialApp(
        home: RemindersScreen(loader: () async => const <Reminder>[])));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    final empty = t.widget<NeonEmptyState>(find.byType(NeonEmptyState));
    expect(empty.actionLabel, 'New reminder');
    expect(empty.onAction, isNotNull);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 1));
  });

  testWidgets(
      'the picked day is lit in the brand gradient, today ringed in cyan',
      (t) async {
    phone(t);
    await t.pumpWidget(const MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: MonthCalendar()))));
    for (var i = 0; i < 4; i++) {
      await t.pump(const Duration(milliseconds: 300));
    }
    // Today is the picked day on open.
    final today = '${DateTime.now().day}';
    final cell = t.widget<Container>(find
        .ancestor(of: find.text(today), matching: find.byType(Container))
        .first);
    final deco = cell.decoration! as BoxDecoration;
    expect(deco.gradient, isNotNull, reason: 'the picked day is lit');
    expect(deco.boxShadow, isNotEmpty, reason: 'with its halo');
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 1));
  });

  testWidgets(
      'a call page shows its header on the first frame, for the row to fly into',
      (t) async {
    phone(t);
    await t.pumpWidget(MaterialApp(
      home: CallDetailScreen(
        callId: 7,
        peerLabel: 'Ravi',
        preview: {
          'id': 7,
          'peer_name': 'Ravi',
          'started_at': DateTime(2026, 9, 30, 10, 5).millisecondsSinceEpoch,
          'status': 'done',
        },
      ),
    ));
    final hero =
        find.byWidgetPredicate((w) => w is Hero && w.tag == callHeroTag(7));
    expect(hero, findsOneWidget);
    expect(find.text('30 Sep · 10:05 am'), findsOneWidget);
    // Offline here: the page says so under the header, which stays.
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 300));
    }
    expect(find.byType(NeonErrorState), findsOneWidget);
    expect(hero, findsOneWidget);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 1));
  });
}
