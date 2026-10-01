// NEWS CARDS (2026-09-25). Owner: "update how we read the news and how it
// is dispayed now need card style with images.stacked swipe to see or tap
// to explan".
//
// Pinned here:
//  * the story model reads the server's shape (and derives the same id);
//  * the deck: left for the next story, right for the previous one, a
//    spring back before the first, "all caught up" after the last, tap
//    for the whole story, ‹ › and "3 of 10", screen-reader actions,
//    "Remove animations", and no ticker once it is still;
//  * the follow-along: the card whose headline is being spoken comes
//    forward, only forward, and a swipe of the user's own wins;
//  * read_news_story's news_focus, and a deck closed a moment ago;
//  * Hub → News: cached feed first, then the server's, per topic;
//  * "open the news" by voice opens the News screen.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:myassistant/features/assistant/state/assistant_engine.dart';
import 'package:myassistant/features/assistant/state/assistant_state.dart';
import 'package:myassistant/models/news_item.dart';
import 'package:myassistant/screens/hub_screen.dart';
import 'package:myassistant/screens/news_screen.dart';
import 'package:myassistant/screens/news_story_screen.dart';
import 'package:myassistant/services/app_feedback.dart';
import 'package:myassistant/services/avatar_message_service.dart';
import 'package:myassistant/services/news_follow.dart';
import 'package:myassistant/widgets/news_deck.dart';
import 'package:myassistant/widgets/news_panel.dart';
import 'package:shared_preferences/shared_preferences.dart';

final now = DateTime.utc(2026, 9, 25, 10, 10);

NewsItem story(int n, {String? title, String image = '', int hoursAgo = 2}) =>
    NewsItem(
      id: 'id$n',
      title: title ?? 'Story number $n about the day',
      url: 'https://paper$n.example/story-$n',
      source: 'paper$n.example',
      publishedAt: now.subtract(Duration(hours: hoursAgo)),
      snippet: 'Summary of story $n.',
      extra: ['More about story $n.'],
      image: image,
    );

List<NewsItem> stories(int n) => [for (var i = 1; i <= n; i++) story(i)];

void ownersPhone(WidgetTester tester) {
  tester.view.devicePixelRatio = 2.625;
  tester.view.physicalSize = const Size(1080, 2340);
  addTearDown(tester.view.reset);
}

Future<NewsDeckController> pumpDeck(
  WidgetTester tester,
  List<NewsItem> items, {
  bool reduced = false,
  VoidCallback? onRefresh,
  VoidCallback? onUserMove,
  void Function(NewsItem, Offset)? onOpen,
  ValueChanged<NewsItem>? onListen,
}) async {
  ownersPhone(tester);
  final c = NewsDeckController();
  await tester.pumpWidget(MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(
        size: const Size(1080 / 2.625, 2340 / 2.625),
        devicePixelRatio: 2.625,
        disableAnimations: reduced,
      ),
      child: Scaffold(
        body: NewsDeck(
          items: items,
          controller: c,
          now: now,
          onRefresh: onRefresh,
          onUserMove: onUserMove,
          onOpen: onOpen,
          onListen: onListen,
        ),
      ),
    ),
  ));
  await tester.pump();
  return c;
}

/// The card at the front is the only one that takes a finger.
Finder front(String title) => find.text(title).hitTestable();

Rect rectOf(WidgetTester tester, String title) =>
    tester.getRect(find.text(title));

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

/// Long enough for anything that ends to have ended: the deck's own move
/// (200 ms) and the ‹ › buttons' enabled-state fade (the framework's).
Future<void> rest(WidgetTester tester) async {
  for (var i = 0; i < 15; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// The engine is shared by every test: put it back as it was.
void resetEngine() {
  final e = AssistantEngine.instance;
  e
    ..newsItems = const []
    ..newsTopic = ''
    ..inlineVoice = false
    ..phase = AssistantPhase.idle;
  e.caption.value = null;
  e.newsFocus.value = null;
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppFeedback.resetForTest();
  });
  tearDown(AppFeedback.resetForTest);

  group('the story model', () {
    test('reads the shared story shape', () {
      final n = NewsItem.fromJson({
        'id': 'a1b2c3d4e5f6',
        'title': 'Monsoon arrives early',
        'url': 'https://thehindu.example/monsoon',
        'source': 'thehindu.example',
        'age': '2 hours ago',
        'ageMins': 120,
        'publishedAt': '2026-09-25T08:10:00Z',
        'snippet': 'It rained.',
        'extra': ['More rain.', 7, null],
        'image': 'https://img.example/full.jpg',
        'thumbnail': 'https://img.example/small.jpg',
        'favicon': 'https://img.example/fav.ico',
      });
      expect(n.id, 'a1b2c3d4e5f6');
      expect(n.ageMins, 120);
      expect(n.publishedAt, DateTime.utc(2026, 9, 25, 8, 10));
      expect(n.extra, ['More rain.']);
      expect(n.imageUrl, 'https://img.example/full.jpg');
      expect(n.imageUrls,
          ['https://img.example/full.jpg', 'https://img.example/small.jpg']);
      expect(n.favicon, 'https://img.example/fav.ico');
      expect(n.ageLabel(now), '2 h ago');
    });

    test('an older server\'s story still works, with the server\'s own id', () {
      final n = NewsItem.fromJson({
        'title': 'Old shape',
        'url': 'https://example.com/a',
        'age': '5 hours ago',
        'thumbnail': 'https://img.example/small.jpg',
      });
      // sha1("https://example.com/a")[:12], as src/tools/news.js makes it.
      expect(n.id, 'c4ed1c218d14');
      expect(n.key, 'c4ed1c218d14');
      expect(n.imageUrl, 'https://img.example/small.jpg',
          reason: 'no full picture: the small copy');
      expect(n.publishedAt, isNull);
      expect(n.ageMins, isNull);
      expect(n.ageLabel(now), '5 hours ago', reason: 'the index\'s own words');
    });

    test('odd values are empty, never a crash', () {
      final n = NewsItem.fromJson({
        'title': 'x',
        'url': 7,
        'ageMins': 'soon',
        'publishedAt': 'yesterday',
        'extra': 'not a list',
      });
      expect(n.url, '');
      expect(n.ageMins, isNull);
      expect(n.publishedAt, isNull);
      expect(n.extra, isEmpty);
      expect(n.imageUrl, '');
      expect(n.initial, 'X');
    });

    test('kept on the phone and read back unchanged', () {
      final a = story(3, image: 'https://img.example/3.jpg');
      final b = NewsItem.fromJson(
          jsonDecode(jsonEncode(a.toJson())) as Map<String, dynamic>);
      expect(b.toJson(), a.toJson());
    });

    test('"2 h ago", and plain words for other ages', () {
      NewsItem at(Duration d) =>
          NewsItem(title: 't', url: 'u', publishedAt: now.subtract(d));
      expect(at(const Duration(seconds: 20)).ageLabel(now), 'just now');
      expect(at(const Duration(minutes: 5)).ageLabel(now), '5 min ago');
      expect(at(const Duration(hours: 2, minutes: 40)).ageLabel(now), '2 h ago');
      expect(at(const Duration(hours: 30)).ageLabel(now), 'yesterday');
      expect(at(const Duration(days: 3)).ageLabel(now), '3 days ago');
    });
  });

  group('the deck', () {
    testWidgets('left is the next story, right brings the previous one back',
        (tester) async {
      final c = await pumpDeck(tester, stories(5));
      expect(front('Story number 1 about the day'), findsOneWidget);
      expect(find.text('1 of 5'), findsOneWidget);

      await tester.drag(find.byType(NewsDeck), const Offset(-240, 0));
      await settle(tester);
      expect(front('Story number 2 about the day'), findsOneWidget);
      expect(find.text('2 of 5'), findsOneWidget);
      expect(c.index, 1);

      await tester.drag(find.byType(NewsDeck), const Offset(240, 0));
      await settle(tester);
      expect(front('Story number 1 about the day'), findsOneWidget);
      expect(find.text('1 of 5'), findsOneWidget);
    });

    testWidgets('a quick flick counts, a short nudge springs back', (tester) async {
      await pumpDeck(tester, stories(3));
      await tester.fling(find.byType(NewsDeck), const Offset(-60, 0), 1500);
      await settle(tester);
      expect(find.text('2 of 3'), findsOneWidget, reason: 'a fast throw is a swipe');

      final before = rectOf(tester, 'Story number 2 about the day');
      await tester.drag(find.byType(NewsDeck), const Offset(-50, 0));
      await settle(tester);
      expect(find.text('2 of 3'), findsOneWidget, reason: 'a nudge is not a swipe');
      expect(rectOf(tester, 'Story number 2 about the day'), before,
          reason: 'it springs back to where it was');
    });

    testWidgets('before the first story it springs back', (tester) async {
      await pumpDeck(tester, stories(3));
      final before = rectOf(tester, 'Story number 1 about the day');
      final g = await tester.startGesture(tester.getCenter(find.byType(NewsDeck)));
      await g.moveBy(const Offset(40, 0));
      await g.moveBy(const Offset(200, 0));
      await tester.pump();
      final pulled = rectOf(tester, 'Story number 1 about the day');
      expect(pulled.left, greaterThan(before.left), reason: 'it gives a little');
      expect(pulled.left - before.left, lessThan(120),
          reason: 'with resistance: there is nothing before the first story');
      await g.up();
      await settle(tester);
      expect(rectOf(tester, 'Story number 1 about the day'), before);
      expect(find.text('1 of 3'), findsOneWidget);
    });

    testWidgets('the card leans as it is dragged, then flies off', (tester) async {
      await pumpDeck(tester, stories(3));
      final g = await tester.startGesture(tester.getCenter(find.byType(NewsDeck)));
      await g.moveBy(const Offset(-40, 0)); // past the slop: the drag starts here
      await g.moveBy(const Offset(-60, 0));
      await tester.pump();
      final t = tester.widget<Transform>(find
          .ancestor(of: find.text('Story number 1 about the day'), matching: find.byType(Transform))
          .first);
      expect(t.transform.entry(0, 1), isNot(0), reason: 'no tilt while dragged');
      expect(t.transform.getTranslation().x, lessThan(0), reason: 'it follows the finger');
      await g.moveBy(const Offset(-120, 0)); // far enough to count
      await tester.pump();
      await g.up();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('1 of 3'), findsOneWidget, reason: 'still flying');
      await settle(tester);
      expect(find.text('2 of 3'), findsOneWidget);
    });

    testWidgets('after the last story: all caught up, with Refresh', (tester) async {
      var refreshed = 0;
      await pumpDeck(tester, stories(2), onRefresh: () => refreshed++);
      final next = find.byTooltip('Next story');
      await tester.tap(next);
      await settle(tester);
      expect(find.text('2 of 2'), findsOneWidget);
      await tester.tap(next);
      await settle(tester);
      expect(front("You're all caught up"), findsOneWidget);
      expect(
          tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.chevron_right_rounded)).onPressed,
          isNull,
          reason: 'nothing after the end');
      // A swipe left at the end only gives a little and comes back.
      await tester.drag(find.byType(NewsDeck), const Offset(-240, 0));
      await settle(tester);
      expect(front("You're all caught up"), findsOneWidget);
      await tester.tap(find.text('Refresh'));
      expect(refreshed, 1);
      // And right from the end brings the last story back.
      await tester.drag(find.byType(NewsDeck), const Offset(240, 0));
      await settle(tester);
      expect(front('Story number 2 about the day'), findsOneWidget);
    });

    testWidgets('‹ › buttons step, and are off at either end', (tester) async {
      var moves = 0;
      await pumpDeck(tester, stories(3), onUserMove: () => moves++);
      IconButton button(IconData i) =>
          tester.widget<IconButton>(find.widgetWithIcon(IconButton, i));
      expect(button(Icons.chevron_left_rounded).onPressed, isNull);
      await tester.tap(find.byTooltip('Next story'));
      await settle(tester);
      await tester.tap(find.byTooltip('Next story'));
      await settle(tester);
      expect(find.text('3 of 3'), findsOneWidget);
      await tester.tap(find.byTooltip('Previous story'));
      await settle(tester);
      expect(find.text('2 of 3'), findsOneWidget);
      expect(moves, 3, reason: 'every tap is the user moving the deck');
    });

    testWidgets('tap opens the whole story, which can be listened to', (tester) async {
      NewsItem? heard;
      await pumpDeck(tester, stories(3), onListen: (n) => heard = n);
      await tester.tap(front('Story number 1 about the day'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(NewsStoryScreen), findsOneWidget);
      expect(find.text('Summary of story 1.'), findsOneWidget);
      expect(find.text('More about story 1.'), findsOneWidget);
      expect(find.text('paper1.example · 2 h ago'), findsOneWidget);
      expect(find.text('Open article'), findsOneWidget);
      expect(find.text('Share'), findsOneWidget);
      await tester.tap(find.text('Listen'));
      expect(heard?.id, 'id1');
      await tester.tap(find.byTooltip('Back'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(NewsStoryScreen), findsNothing);
    });

    testWidgets('the story grows out of the card that was tapped', (tester) async {
      await pumpDeck(tester, stories(2));
      await tester.tap(front('Story number 1 about the day'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      final scale = tester.widget<ScaleTransition>(find
          .ancestor(of: find.byType(NewsStoryScreen), matching: find.byType(ScaleTransition))
          .first);
      expect(scale.scale.value, lessThan(1), reason: 'it expands, it does not slide in');
      await tester.pump(const Duration(milliseconds: 300));
      expect(scale.scale.value, 1);
    });

    testWidgets('the card reads: publisher, time, headline, summary', (tester) async {
      await pumpDeck(tester, [story(1, image: 'https://img.example/1.jpg')]);
      await settle(tester);
      expect(find.text('paper1.example · 2 h ago'), findsWidgets);
      expect(find.text('Summary of story 1. More about story 1.'), findsOneWidget,
          reason: 'the summary, then its extra snippet');
      // Offline in a test the picture fails: the gradient card with the
      // publisher's initial takes its place, never a crash or a hole.
      expect(find.byType(NewsPlaceholder), findsWidgets);
      expect(find.text('P'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('large text: fewer lines, never an overflow', (tester) async {
      ownersPhone(tester);
      final long = [
        story(1, title: 'A very long headline ' * 6),
        story(2),
      ];
      await tester.pumpWidget(MaterialApp(
        home: MediaQuery.withClampedTextScaling(
          minScaleFactor: 2.0,
          maxScaleFactor: 2.0,
          child: Scaffold(body: NewsDeck(items: long, now: now)),
        ),
      ));
      await settle(tester);
      expect(tester.takeException(), isNull);
    });

    testWidgets('screen readers get next and previous actions', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpDeck(tester, stories(3));
      SemanticsNode deck() => tester.getSemantics(find.bySemanticsLabel('News stories'));
      int id(String label) =>
          CustomSemanticsAction.getIdentifier(CustomSemanticsAction(label: label));
      final data = deck().getSemanticsData();
      expect(data.customSemanticsActionIds, contains(id('Next story')));
      expect(data.customSemanticsActionIds, isNot(contains(id('Previous story'))));
      expect(data.value, '1 of 3');
      deck().owner!.performAction(deck().id, SemanticsAction.customAction, id('Next story'));
      await settle(tester);
      expect(find.text('2 of 3'), findsOneWidget);
      expect(deck().getSemanticsData().customSemanticsActionIds, contains(id('Previous story')));
      handle.dispose();
    });

    testWidgets('"Remove animations": no lean, no flight — the next card fades in',
        (tester) async {
      await pumpDeck(tester, stories(3), reduced: true);
      final before = rectOf(tester, 'Story number 1 about the day');
      final g = await tester.startGesture(tester.getCenter(find.byType(NewsDeck)));
      await g.moveBy(const Offset(-40, 0));
      await g.moveBy(const Offset(-160, 0));
      await tester.pump();
      expect(rectOf(tester, 'Story number 1 about the day'), before,
          reason: 'the card does not follow the finger');
      await g.up();
      await tester.pump();
      expect(find.text('2 of 3'), findsOneWidget, reason: 'the swipe still counts, at once');
      await rest(tester);
      expect(SchedulerBinding.instance.transientCallbackCount, 0);
    });

    testWidgets('nothing ticks once the deck is still', (tester) async {
      await pumpDeck(tester, stories(4));
      await settle(tester);
      expect(SchedulerBinding.instance.transientCallbackCount, 0,
          reason: 'a resting deck ran a ticker');
      expect(tester.binding.hasScheduledFrame, isFalse,
          reason: 'a resting deck asked for another frame');
      await tester.drag(find.byType(NewsDeck), const Offset(-240, 0));
      await rest(tester);
      expect(find.text('2 of 4'), findsOneWidget);
      expect(SchedulerBinding.instance.transientCallbackCount, 0,
          reason: 'something kept moving after the swipe');
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('the controller brings a story forward, near or far', (tester) async {
      final c = await pumpDeck(tester, stories(6));
      c.show(1);
      await settle(tester);
      expect(front('Story number 2 about the day'), findsOneWidget);
      c.show(4);
      await settle(tester);
      expect(front('Story number 5 about the day'), findsOneWidget);
      expect(find.text('5 of 6'), findsOneWidget);
      c.show(40);
      await settle(tester);
      expect(front("You're all caught up"), findsOneWidget, reason: 'clamped to the end');
      expect(SchedulerBinding.instance.transientCallbackCount, 0);
    });
  });

  group('follow-along', () {
    final deck = [
      const NewsItem(title: 'India beat Australia by six wickets to win the cricket series in Mumbai', url: 'a'),
      const NewsItem(title: 'Budget 2026: what the new tax slabs mean for salaried workers', url: 'b'),
      const NewsItem(title: 'Monsoon arrives early in Kerala as rainfall runs above normal', url: 'c'),
    ];

    test('the headline being read is found, in the assistant\'s own shorter words', () {
      const said = "Here are today's headlines, Sir. First, India beat Australia by six "
          'wickets to take the series in Mumbai.';
      expect(NewsFollow.next(deck, said, current: -1), 0);
      expect(NewsFollow.next(deck, said, current: 0), isNull,
          reason: 'nothing after it has been read yet');
      const more = '$said Second, the new tax slabs in the budget and what salaried workers pay.';
      expect(NewsFollow.next(deck, more, current: 0), 1);
      const third = '$more And the monsoon has arrived early in Kerala, with rainfall above normal.';
      expect(NewsFollow.next(deck, third, current: 1), 2);
    });

    test('only forward: an earlier headline heard again never pulls the deck back', () {
      const said = 'India beat Australia by six wickets in the cricket series in Mumbai.';
      expect(NewsFollow.next(deck, said, current: 2), isNull);
      expect(NewsFollow.next(deck, said, current: 1), isNull);
    });

    test('one shared word is not a match', () {
      expect(NewsFollow.next(deck, 'The weather in Mumbai is fine today.', current: -1), isNull);
      expect(NewsFollow.next(deck, 'Kerala.', current: -1), isNull);
      expect(NewsFollow.next(deck, '', current: -1), isNull);
    });

    test('only the latest thirty words count', () {
      const old = 'monsoon arrives early kerala rainfall above normal ';
      final filler = List.filled(40, 'and then something else happened').join(' ');
      expect(NewsFollow.next(deck, '$old $filler', current: 1), isNull,
          reason: 'words from a minute ago are not what is being read now');
    });

    test('a light stem: "arrives" is "arrived", "wickets" is "wicket"', () {
      expect(NewsFollow.stem('arrives'), NewsFollow.stem('arrived'));
      expect(NewsFollow.stem('arrive'), NewsFollow.stem('arriving'));
      expect(NewsFollow.stem('wickets'), NewsFollow.stem('wicket'));
      expect(NewsFollow.stem('class'), 'class');
    });
  });

  group('the voice deck', () {
    tearDown(resetEngine);

    Future<void> pumpPanel(WidgetTester tester, List<NewsItem> items) async {
      ownersPhone(tester);
      tester.view.padding = const FakeViewPadding(bottom: 300);
      await tester.pumpWidget(const MaterialApp(
        home: Material(child: Stack(children: [NewsPanel()])),
      ));
      AssistantEngine.instance
        ..newsItems = items
        ..newsTopic = 'today'
        ..notifyListeners();
      await tester.pump();
      await settle(tester);
    }

    final read = [
      const NewsItem(id: 'c1', title: 'India beat Australia by six wickets to win the cricket series in Mumbai', url: 'https://a.example/1'),
      const NewsItem(id: 'b2', title: 'Budget 2026: what the new tax slabs mean for salaried workers', url: 'https://a.example/2'),
      const NewsItem(id: 'm3', title: 'Monsoon arrives early in Kerala as rainfall runs above normal', url: 'https://a.example/3'),
    ];

    void say(String text) =>
        AssistantEngine.instance.caption.value = CaptionLine('hari', text);

    testWidgets('it shows the deck under its header, with a close', (tester) async {
      await pumpPanel(tester, read);
      expect(find.byType(NewsDeck), findsOneWidget);
      expect(find.text("Today's headlines"), findsOneWidget);
      expect(find.text('1 of 3'), findsOneWidget);
      await tester.tap(find.byTooltip('Close'));
      await tester.pump();
      // It fades and sinks away in 120 ms (ExitPresence).
      await tester.pump(const Duration(milliseconds: 60));
      await tester.pump(const Duration(milliseconds: 200));
      expect(AssistantEngine.instance.newsItems, isEmpty);
      expect(find.byType(NewsDeck), findsNothing);
    });

    testWidgets('the card being read comes to the front', (tester) async {
      await pumpPanel(tester, read);
      say("Here are today's headlines. First, India beat Australia by six wickets "
          'to win the series in Mumbai.');
      await settle(tester);
      expect(find.text('1 of 3'), findsOneWidget);
      say("Here are today's headlines. First, India beat Australia by six wickets "
          'to win the series in Mumbai. Second, the new tax slabs in the budget for salaried workers.');
      await settle(tester);
      expect(find.text('2 of 3'), findsOneWidget);
      // The user's own words never move it.
      AssistantEngine.instance.caption.value =
          const CaptionLine('you', 'monsoon arrives early in kerala rainfall above normal');
      await settle(tester);
      expect(find.text('2 of 3'), findsOneWidget);
    });

    testWidgets('a swipe of their own pauses the follow-along', (tester) async {
      await pumpPanel(tester, read);
      await tester.tap(find.byTooltip('Next story'));
      await settle(tester);
      await tester.tap(find.byTooltip('Previous story'));
      await settle(tester);
      expect(find.text('1 of 3'), findsOneWidget);
      say('Second, the new tax slabs in the budget for salaried workers.');
      await settle(tester);
      expect(find.text('1 of 3'), findsOneWidget, reason: 'they are reading; the deck waits');
      // Ten seconds on, it follows again.
      await tester.pump(NewsPanel.followPause);
      say('Second, the new tax slabs in the budget for salaried workers, and the '
          'monsoon arrives early in Kerala with rainfall above normal.');
      await settle(tester);
      expect(find.text('1 of 3'), isNot(findsOneWidget));
    });

    testWidgets('news_focus brings that story forward and holds it there', (tester) async {
      await pumpPanel(tester, read);
      AssistantEngine.instance.debugEvent({'type': 'news_focus', 'id': 'm3'});
      await settle(tester);
      expect(find.text('3 of 3'), findsOneWidget);
      AssistantEngine.instance.debugEvent({'type': 'news_focus', 'id': 'c1'});
      await settle(tester);
      expect(find.text('1 of 3'), findsOneWidget, reason: 'backwards too, when asked');
      // While it is being summarised, the follow-along does not move it.
      say('Second, the new tax slabs in the budget for salaried workers.');
      await settle(tester);
      expect(find.text('1 of 3'), findsOneWidget);
      // An id that is not on the deck is ignored.
      AssistantEngine.instance.debugEvent({'type': 'news_focus', 'id': 'nope'});
      await settle(tester);
      expect(find.text('1 of 3'), findsOneWidget);
    });

    testWidgets('"read me the second one" after closing the deck opens it on that story',
        (tester) async {
      await pumpPanel(tester, read);
      final e = AssistantEngine.instance..inlineVoice = true;
      e.clearNews();
      await settle(tester);
      expect(find.byType(NewsDeck), findsNothing);
      e.debugEvent({'type': 'news_focus', 'id': 'b2'});
      await settle(tester);
      expect(find.byType(NewsDeck), findsOneWidget);
      expect(find.text('2 of 3'), findsOneWidget);
    });

    testWidgets('show_news from the server fills the deck with the new fields', (tester) async {
      await pumpPanel(tester, const []);
      AssistantEngine.instance.debugEvent({
        'type': 'show_news',
        'topic': 'sports',
        'items': [
          {
            'id': 'aa11bb22cc33',
            'title': 'Football league final moves to Kolkata',
            'url': 'https://x.example/f',
            'image': 'https://img.example/f.jpg',
            'publishedAt': '2026-09-25T09:00:00Z',
          },
          {'title': '', 'url': 'https://x.example/empty'},
        ],
      });
      await settle(tester);
      final items = AssistantEngine.instance.newsItems;
      expect(items.length, 1, reason: 'a story with no headline is dropped');
      expect(items.single.id, 'aa11bb22cc33');
      expect(items.single.image, 'https://img.example/f.jpg');
      expect(find.text('News · sports'), findsOneWidget);
      expect(find.text('1 of 1'), findsOneWidget);
    });
  });

  group('Hub → News', () {
    tearDown(resetEngine);

    Future<void> pumpScreen(WidgetTester tester, NewsFeedLoader loader) async {
      ownersPhone(tester);
      await tester.pumpWidget(MaterialApp(home: NewsScreen(loader: loader, now: now)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await settle(tester);
    }

    testWidgets('topic chips, and the deck from the server', (tester) async {
      final asked = <String>[];
      await pumpScreen(tester, (topic) async {
        asked.add(topic);
        return [story(1, title: 'Top story for "$topic"'), story(2)];
      });
      expect(NewsScreen.topics.map((t) => t.$1), [
        'Top', 'India', 'World', 'Business', 'Tech', 'Sports',
        'Entertainment', 'Science', 'Health',
      ]);
      for (final chip in ['Top', 'India', 'World']) {
        expect(find.text(chip), findsOneWidget, reason: chip);
      }
      expect(asked, ['']);
      expect(front('Top story for ""'), findsOneWidget);
      await tester.tap(find.text('India'));
      await settle(tester);
      expect(asked, ['', 'india']);
      expect(front('Top story for "india"'), findsOneWidget);
      expect(find.text('1 of 2'), findsOneWidget);
    });

    testWidgets('it opens from the saved copy, then shows the fresh one', (tester) async {
      SharedPreferences.setMockInitialValues({
        'news_feed_v1_top': jsonEncode({
          'savedAt': '2026-09-25T06:00:00Z',
          'items': [story(7, title: 'Saved this morning').toJson()],
        }),
      });
      final pending = Completer<List<NewsItem>?>();
      ownersPhone(tester);
      await tester.pumpWidget(MaterialApp(
        home: NewsScreen(now: now, loader: (_) => pending.future),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(front('Saved this morning'), findsOneWidget,
          reason: 'the saved copy is up before the server answers');
      pending.complete([story(1, title: 'Fresh from the server')]);
      await settle(tester);
      expect(front('Fresh from the server'), findsOneWidget);
      final p = await SharedPreferences.getInstance();
      expect(p.getString('news_feed_v1_top'), contains('Fresh from the server'),
          reason: 'the fresh feed replaces the saved copy');
    });

    testWidgets('offline with a saved copy: the saved stories, and it says so', (tester) async {
      SharedPreferences.setMockInitialValues({
        'news_feed_v1_sports': jsonEncode({
          'savedAt': '2026-09-25T06:00:00Z',
          'items': [story(8, title: 'Saved sports story').toJson()],
        }),
        'news_topic': 'sports',
      });
      await pumpScreen(tester, (_) async => null);
      expect(front('Saved sports story'), findsOneWidget);
      expect(find.textContaining("Couldn't refresh"), findsOneWidget);
    });

    testWidgets('offline with nothing saved: a plain message and Try again', (tester) async {
      var calls = 0;
      await pumpScreen(tester, (_) async {
        calls++;
        return calls == 1 ? null : [story(1)];
      });
      expect(find.text("Couldn't load the news"), findsOneWidget);
      await tester.tap(find.text('Try again'));
      await settle(tester);
      expect(front('Story number 1 about the day'), findsOneWidget);
    });

    testWidgets('Hub has a News row that opens it', (tester) async {
      ownersPhone(tester);
      tester.view.physicalSize = const Size(1080, 5000);
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: HubScreen())));
      await tester.pump();
      expect(find.text('STAY INFORMED'), findsOneWidget);
      await tester.tap(find.text('News'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(NewsScreen), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 16));
    });

    testWidgets('"open the news" by voice opens the News screen', (tester) async {
      ownersPhone(tester);
      await tester.pumpWidget(MaterialApp(
        navigatorKey: AvatarMessageService.navigatorKey,
        home: const Scaffold(body: SizedBox()),
      ));
      AssistantEngine.instance.debugEvent({'type': 'open_app_screen', 'screen': 'news'});
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(NewsScreen), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 16));
    });
  });
}
