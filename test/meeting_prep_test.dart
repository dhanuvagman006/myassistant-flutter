import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/features/meeting_prep/meeting_prep.dart';
import 'package:myassistant/features/meeting_prep/meeting_prep_sheet.dart';

/// Meeting Prep (2026-09-30): the prep's shape from the server, and the
/// sheet — the meeting, who is in it, numbered talking points, the lit
/// "Remind me 10 min before", loading, none, failure, big text.

final startMs = DateTime(2026, 9, 30, 15).millisecondsSinceEpoch;

Map<String, dynamic> prepJson({bool known = true, int? remindAt, String link = ''}) => {
      'meeting': {
        'id': 'evRavi',
        'source': 'google',
        'title': 'Acme follow-up',
        'startMs': startMs,
        'endMs': startMs + 3600000,
        'timeText': '3 pm',
        'whenText': 'in 45 min',
        'location': 'Acme office',
        'link': link,
        'attendees': ['Ravi Kumar', 'Sunil Shah'],
      },
      'summary': known
          ? 'Acme follow-up with Ravi Kumar and Sunil Shah. Last time you agreed the pricing.'
          : "Acme follow-up, in 45 min. I don't have any earlier notes about this meeting or the people in it.",
      'people': known
          ? [
              {'name': 'Ravi Kumar', 'role': 'client, Acme', 'lastContact': '23 Sep', 'notes': 'Wants the quote before Friday'},
              {'name': 'Sunil Shah', 'role': '', 'lastContact': '', 'notes': ''},
            ]
          : [],
      'context': known ? ['Price held for the first order'] : [],
      'talkingPoints': ['Confirm the samples reached Ravi', 'Ask for the delivery address', 'Share the revised quote'],
      'asks': known ? ['You promised Ravi: Send the revised quote'] : [],
      'risks': known ? ['Overdue: Send the revised quote'] : [],
      'known': known,
      'source': 'ai',
      'remindAt': remindAt,
    };

class FakeApi extends MeetingPrepApi {
  FakeApi({this.result, this.remindOk = true});
  Completer<MeetingPrep?>? pending;
  MeetingPrep? result;
  bool remindOk;
  final fetched = <String?>[];
  final reminded = <MeetingPrep>[];

  @override
  Future<MeetingPrep?> fetch({String? meetingId}) {
    fetched.add(meetingId);
    if (pending != null) return pending!.future;
    return Future.value(result);
  }

  @override
  Future<bool> remindBefore(MeetingPrep p) async {
    reminded.add(p);
    return remindOk;
  }
}

Future<void> open(WidgetTester t, {MeetingPrep? prep, String? meetingId, required FakeApi api, double textScale = 1}) async {
  t.view.physicalSize = const Size(400, 860);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(size: const Size(400, 860), textScaler: TextScaler.linear(textScale)),
      child: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => showMeetingPrep(context, prep: prep, meetingId: meetingId, api: api),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  ));
  await t.tap(find.text('open'));
  await t.pump();
  await t.pump(const Duration(milliseconds: 600));
}

void main() {
  test('the prep parses; empty names and blank lines are dropped', () {
    final j = prepJson(remindAt: startMs - 600000);
    (j['people'] as List).add({'name': '  ', 'role': 'x'});
    (j['talkingPoints'] as List).add('   ');
    final p = MeetingPrep.fromJson(j);
    expect(p.meeting!.id, 'evRavi');
    expect(p.meeting!.attendees, ['Ravi Kumar', 'Sunil Shah']);
    expect(p.people.map((x) => x.name), ['Ravi Kumar', 'Sunil Shah']);
    expect(p.talkingPoints, hasLength(3));
    expect(p.remindAtMs, startMs - 600000);
    expect(p.known, isTrue);
    expect(MeetingPrep.fromJson({'meeting': null}).meeting, isNull);
  });

  testWidgets('the meeting, its people, numbered points, and the lit reminder', (t) async {
    final api = FakeApi();
    await open(t, prep: MeetingPrep.fromJson(prepJson(remindAt: startMs - 600000)), api: api);
    expect(find.text('Acme follow-up'), findsOneWidget);
    expect(find.text('In 45 min · 3 pm · Acme office'), findsOneWidget);
    expect(find.textContaining('Last time you agreed the pricing'), findsOneWidget);
    expect(find.text("Who's there"), findsOneWidget);
    expect(find.bySemanticsLabel('Ravi Kumar, client, Acme'), findsOneWidget);
    expect(find.bySemanticsLabel('Sunil Shah'), findsOneWidget);
    expect(find.textContaining('last in touch 23 Sep'), findsOneWidget);
    expect(find.bySemanticsLabel('Point 1: Confirm the samples reached Ravi'), findsOneWidget);
    expect(find.text('Watch out'), findsOneWidget);
    expect(api.fetched, isEmpty, reason: 'the voice directive carries the prep whole');

    await t.ensureVisible(find.text('Remind me 10 min before'));
    await t.tap(find.text('Remind me 10 min before'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    expect(api.reminded.single.meeting!.id, 'evRavi');
    expect(find.text('Reminder set'), findsOneWidget);
    await t.pump(const Duration(seconds: 5));
  });

  testWidgets('a reminder that could not be set says so and keeps the button', (t) async {
    final api = FakeApi(remindOk: false);
    await open(t, prep: MeetingPrep.fromJson(prepJson(remindAt: startMs - 600000)), api: api);
    await t.tap(find.text('Remind me 10 min before'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('Remind me 10 min before'), findsOneWidget);
    expect(find.textContaining("Couldn't set the reminder."), findsOneWidget);
    await t.pump(const Duration(seconds: 6));
  });

  testWidgets('too close to remind: no reminder button; a call link: Join the call', (t) async {
    await open(t,
        prep: MeetingPrep.fromJson(prepJson(link: 'https://meet.google.com/abc-defg-hij')), api: FakeApi());
    expect(find.text('Remind me 10 min before'), findsNothing);
    expect(find.text('Join the call'), findsOneWidget);
  });

  testWidgets('nothing known: said plainly, still with talking points', (t) async {
    await open(t, prep: MeetingPrep.fromJson(prepJson(known: false)), api: FakeApi());
    expect(find.textContaining("I don't have any earlier notes"), findsOneWidget);
    expect(find.text("Who's there"), findsNothing);
    expect(find.bySemanticsLabel(RegExp('^Point 3:')), findsOneWidget);
  });

  testWidgets("Home's Prepare fetches that event, loading while it does", (t) async {
    final api = FakeApi()..pending = Completer<MeetingPrep?>();
    await open(t, meetingId: 'evRavi', api: api);
    expect(api.fetched, ['evRavi']);
    expect(find.bySemanticsLabel('Preparing your meeting'), findsOneWidget);
    api.pending!.complete(MeetingPrep.fromJson(prepJson()));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(find.text('Acme follow-up'), findsOneWidget);
  });

  testWidgets('no meeting: a calm empty state; a failure: Try again', (t) async {
    final api = FakeApi(result: const MeetingPrep());
    await open(t, api: api);
    expect(find.text('No meetings in the next 24 hours'), findsOneWidget);
    Navigator.of(t.element(find.text('No meetings in the next 24 hours'))).pop();
    await t.pump(const Duration(milliseconds: 600));

    final failing = FakeApi(result: null);
    await open(t, api: failing);
    expect(find.text("Couldn't prepare this meeting"), findsOneWidget);
    failing.result = MeetingPrep.fromJson(prepJson());
    await t.tap(find.text('Try again'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(find.text('Acme follow-up'), findsOneWidget);
    expect(failing.fetched, hasLength(2));
  });

  testWidgets('twice the text size: everything still fits', (t) async {
    await open(t,
        prep: MeetingPrep.fromJson(prepJson(remindAt: startMs - 600000, link: 'https://meet.google.com/x')),
        api: FakeApi(),
        textScale: 2);
    expect(t.takeException(), isNull);
    expect(find.text('Acme follow-up'), findsOneWidget);
  });
}
