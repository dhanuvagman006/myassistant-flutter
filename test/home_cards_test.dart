import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/features/home/home_cards.dart';
import 'package:myassistant/features/home/home_extras.dart';
import 'package:myassistant/features/shopping/shopping_models.dart';
import 'package:myassistant/features/shopping/shopping_service.dart';
import 'package:myassistant/models/news_item.dart';
import 'package:myassistant/features/home/home_feed.dart';
import 'package:myassistant/features/home/home_memory.dart';
import 'package:myassistant/models/brief.dart';
import 'package:myassistant/services/brief_service.dart';
import 'package:myassistant/services/call_history.dart';
import 'package:myassistant/services/missed_calls_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Home's cards on screen (2026-09-29): the states, the buttons, and that a
/// card leaves only once the server said yes.

final now = DateTime(2026, 9, 29, 14, 35);

class FakeActions extends HomeActions {
  final asked = <String>[];
  final done = <Object>[];
  Completer<bool>? pending;

  @override
  Future<bool> completeReminder(AgendaItem a) {
    done.add(a);
    pending = Completer<bool>();
    return pending!.future;
  }

  @override
  Future<bool> completePromise(PromiseItem p) async {
    done.add(p);
    return true;
  }

  @override
  void ask(String request) => asked.add(request);

  @override
  void hide(HomeCard c) => HomeMemory.instance.hide(c.id, now: now);

  int plays = 0;
  final prepared = <AgendaItem>[];

  @override
  void playBrief(BuildContext context) => plays++;

  @override
  Future<void> prepareMeeting(BuildContext context, AgendaItem item) async => prepared.add(item);
}

Future<FakeActions> show(WidgetTester t, TodayBrief b,
    {bool failed = false, bool stale = false, double textScale = 1, bool loading = false, DateTime? at}) async {
  SharedPreferences.setMockInitialValues({});
  HomeMemory.instance.debugSet(firstSeen: now.subtract(const Duration(days: 30)));
  MissedCallsService.instance.pending.value = const [];
  final svc = BriefService.instance;
  if (loading) {
    svc.debugShow(const TodayBrief());
    svc.loaded = false;
  } else {
    svc.debugShow(b, failed: failed, stale: stale);
  }
  final actions = FakeActions();
  t.view.physicalSize = const Size(400, 860);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(size: const Size(400, 860), textScaler: TextScaler.linear(textScale)),
      child: Scaffold(
        body: HomeFeedView(
          leading: const Text('Good afternoon'),
          padding: const EdgeInsets.all(20),
          actions: actions,
          clock: () => at ?? now,
        ),
      ),
    ),
  ));
  await t.pump(const Duration(milliseconds: 600));
  return actions;
}

final dueSoon = AgendaItem(
    kind: 'reminder', id: 11, title: 'Call the bank',
    atMs: now.add(const Duration(minutes: 20)).millisecondsSinceEpoch);

void main() {
  tearDown(() => BriefService.instance.debugShow(const TodayBrief()));

  testWidgets('loading shows the shape of the day, not a spinner', (t) async {
    await show(t, const TodayBrief(), loading: true);
    expect(find.bySemanticsLabel('Loading your day'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('a first load that failed says so, with Try again', (t) async {
    await show(t, const TodayBrief(), failed: true);
    expect(find.text("Couldn't load your day"), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    expect(find.text("You're all clear"), findsNothing, reason: 'never "all clear" about a day that did not load');
  });

  testWidgets('nothing needs the user: all clear, with the day\'s line', (t) async {
    await show(t, const TodayBrief());
    expect(find.text("You're all clear"), findsOneWidget);
    expect(find.text('Nothing needs you today.'), findsOneWidget);
  });

  testWidgets('Done waits for the server; the card leaves only on its yes', (t) async {
    final a = await show(t, TodayBrief(agenda: [dueSoon]));
    expect(find.text('Call the bank'), findsOneWidget);
    expect(find.text('In 20 min'), findsOneWidget);
    await t.tap(find.text('Done'));
    await t.pump();
    expect(a.done, [dueSoon]);
    expect(find.byType(CircularProgressIndicator), findsOneWidget, reason: 'the button shows it is working');
    expect(find.text('Call the bank'), findsOneWidget, reason: 'still there until the server answers');
    a.pending!.complete(false);
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('Call the bank'), findsOneWidget, reason: 'a failure leaves the card where it was');
    expect(find.textContaining("Couldn't mark it done."), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('Not now puts the card away until tomorrow; the day still lists it', (t) async {
    final a = await show(t, TodayBrief(
      agenda: [dueSoon],
      promises: const [PromiseItem(id: 7, text: 'Fix the tap')],
    ));
    expect(find.text('Call the bank'), findsOneWidget);
    // The reminder's second button is Later; the promise (Also) has Done.
    expect(find.text('Later'), findsOneWidget);
    HomeMemory.instance.hide(
        'reminder:11@${dueSoon.atMs}', now: now);
    // The switch starts in the frame this pump draws; the next one runs it.
    await t.pump();
    await t.pump(const Duration(milliseconds: 600));
    expect(find.text('Later'), findsNothing, reason: 'no longer a card');
    expect(find.text('Call the bank'), findsOneWidget,
        reason: 'still on the day list: Not now hides the card, not the plan');
    expect(find.text('Fix the tap'), findsOneWidget);
    expect(a.asked, isEmpty);
  });

  // PLAY MY MORNING (2026-09-30): the brightest thing under the greeting.
  testWidgets('Play my morning before noon, Play my day after; a tap plays it', (t) async {
    var a = await show(t, const TodayBrief(), at: DateTime(2026, 9, 29, 8, 5));
    expect(find.text('Play my morning'), findsOneWidget);
    expect(find.text('Hear your day in about a minute'), findsOneWidget);
    await t.tap(find.text('Play my morning'));
    expect(a.plays, 1);
    a = await show(t, const TodayBrief());
    expect(find.text('Play my day'), findsOneWidget);
    expect(find.bySemanticsLabel('Play my day'), findsOneWidget);
  });

  // PREPARE (2026-09-30): the meeting card opens Meeting Prep for that event.
  testWidgets('a meeting within two hours has Prepare, for exactly that event', (t) async {
    final meeting = AgendaItem(kind: 'meeting', title: 'Acme follow-up', eventId: 'evRavi',
        atMs: now.add(const Duration(minutes: 45)).millisecondsSinceEpoch);
    final a = await show(t, TodayBrief(agenda: [meeting]));
    expect(find.text('Acme follow-up'), findsOneWidget);
    await t.tap(find.text('Prepare'));
    await t.pump();
    expect(a.prepared.single.eventId, 'evRavi');
    expect(a.asked, isEmpty, reason: 'a sheet, not a spoken question');
  });

  testWidgets('a quick action hands its request to the assistant', (t) async {
    final a = await show(t, const TodayBrief());
    await t.tap(find.text('What did I promise?'));
    expect(a.asked, ['What have I promised anyone recently?']);
  });

  testWidgets('offline with a saved day: shown, and says how old it is', (t) async {
    BriefService.instance.updatedAt = DateTime(2026, 9, 29, 10, 40);
    await show(t, TodayBrief(agenda: [dueSoon]), stale: true);
    expect(find.text('Call the bank'), findsOneWidget);
    expect(find.text('Offline · updated 10:40 am'), findsOneWidget);
  });

  testWidgets('a missed call is a card with Call back', (t) async {
    SharedPreferences.setMockInitialValues({});
    await show(t, const TodayBrief());
    MissedCallsService.instance.pending.value = [
      CallEntry(name: 'Amma', number: '+919800000001', type: 'missed',
          at: now.subtract(const Duration(minutes: 10))),
    ];
    await t.pump(const Duration(milliseconds: 600));
    expect(find.text('Amma'), findsOneWidget);
    expect(find.text('10 min ago'), findsOneWidget);
    expect(find.text('Call back'), findsOneWidget);
    MissedCallsService.instance.pending.value = const [];
  });

  testWidgets('twice the text size: everything still fits', (t) async {
    await show(t, TodayBrief(
      agenda: [
        dueSoon,
        AgendaItem(kind: 'reminder', id: 12, title: 'Pick up the medicines from the pharmacy near the office',
            atMs: now.add(const Duration(hours: 4)).millisecondsSinceEpoch),
      ],
      promises: const [PromiseItem(id: 7, text: 'To Ravi: Send the revised quote with the new numbers', owedTo: 'Ravi', dueLabel: 'due today')],
      messages: const [BriefMessage(from: 'Priya', text: 'Lunch tomorrow?')],
    ), textScale: 2);
    expect(t.takeException(), isNull);
    expect(find.text('Call the bank'), findsOneWidget);
  });

  // ALWAYS USEFUL (owner, 2026-09-30): in every state there is something
  // worth reading or doing under the greeting — never a blank screen.
  group('always useful, in the six states the owner named', () {
    const story1 = NewsItem(title: 'Monsoon reaches the coast early', url: 'https://example.org/a',
        source: 'example.org', age: '2 hours ago');
    const story2 = NewsItem(title: 'New metro line opens on Monday', url: 'https://example.org/b',
        source: 'example.org', age: '5 hours ago');
    setUp(() {
      HomeNews.instance.debugSet(const [story1, story2]);
      ShoppingService.instance.debugSeed(const []);
    });
    tearDown(() {
      HomeNews.instance.debugSet(const []);
      ShoppingService.instance.debugSeed(const []);
    });

    int cards(WidgetTester t) => find.byType(Container).evaluate().length;

    testWidgets('1 · several upcoming events: the day fills Home — no news, no tips', (t) async {
      await show(t, TodayBrief(agenda: [
        AgendaItem(kind: 'meeting', title: 'Design review', atMs: now.add(const Duration(minutes: 25)).millisecondsSinceEpoch),
        dueSoon,
        AgendaItem(kind: 'reminder', id: 12, title: 'Pick up medicines', atMs: now.add(const Duration(hours: 3)).millisecondsSinceEpoch),
      ], promises: const [PromiseItem(id: 7, text: 'Send the invoice', dueLabel: 'due today')]));
      expect(find.text('Design review'), findsOneWidget);
      expect(find.text('Pick up medicines'), findsOneWidget);
      expect(find.text('In the news'), findsNothing, reason: 'a full day leaves no room for news');
      expect(find.text('Try asking'), findsNothing);
    });

    testWidgets('2 · no events: under the all-clear, the news and a tip', (t) async {
      await show(t, const TodayBrief());
      expect(find.text("You're all clear"), findsOneWidget);
      expect(find.text('In the news'), findsOneWidget);
      expect(find.text(story1.title), findsOneWidget);
      expect(find.text('Try asking'), findsOneWidget);
      expect(cards(t), greaterThan(4));
    });

    testWidgets('3 · reminders and a shopping list: the list before the news', (t) async {
      ShoppingService.instance.debugSeed(const [
        ShoppingItem(id: 1, name: 'milk'), ShoppingItem(id: 2, name: 'eggs'),
        ShoppingItem(id: 3, name: 'bread', checked: true),
      ]);
      await show(t, TodayBrief(agenda: [dueSoon]));
      expect(find.text('Call the bank'), findsOneWidget);
      expect(find.text('2 things to buy'), findsOneWidget);
      expect(find.text('Shopping list · milk, eggs'), findsOneWidget);
      expect(find.text('In the news'), findsOneWidget, reason: 'one personal card leaves room for two more');
      expect(find.text('Try asking'), findsNothing);
    });

    testWidgets('4 · no personal activity: rain worth knowing about, then the news', (t) async {
      final a = await show(t, const TodayBrief(
          weatherNote: WeatherNote(kind: 'rain', text: 'Rain likely 5 pm to 7 pm', from: '17:00')));
      expect(find.text('Rain likely 5 pm to 7 pm'), findsOneWidget);
      expect(find.text('In the news'), findsOneWidget);
      await t.tap(find.text('Remind me'));
      await t.pump();
      expect(a.asked.single, contains('umbrella'));
      expect(a.asked.single, contains('5 pm'));
    });

    testWidgets('5 · a first-time account: how to start, then the news and a tip', (t) async {
      await show(t, const TodayBrief());
      HomeMemory.instance.debugSet(firstSeen: now);
      await t.pump();
      await t.pump(const Duration(milliseconds: 600));
      expect(find.text('Ask me anything'), findsOneWidget);
      expect(find.text('In the news'), findsOneWidget);
      expect(find.text('Try asking'), findsOneWidget);
    });

    testWidgets('6 · offline with nothing saved and no news: the error, then a tip', (t) async {
      HomeNews.instance.debugSet(const []);
      await show(t, const TodayBrief(), failed: true);
      expect(find.text("Couldn't load your day"), findsOneWidget);
      expect(find.text('Try asking'), findsOneWidget, reason: 'a tip needs no connection');
      expect(find.text('In the news'), findsNothing, reason: 'no fake headlines');
    });

    testWidgets('the news can be put away from Home, and brought back', (t) async {
      await show(t, const TodayBrief());
      await t.tap(find.byTooltip('Hide news on Home'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 600));
      expect(find.text('In the news'), findsNothing);
      expect(HomeMemory.instance.newsOn.value, isFalse);
      await HomeMemory.instance.setNewsOn(true);
      await t.pump();
      await t.pump(const Duration(milliseconds: 600));
      expect(find.text('In the news'), findsOneWidget);
    });
  });
}
