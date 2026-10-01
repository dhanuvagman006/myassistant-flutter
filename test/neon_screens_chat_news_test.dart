// CHAT, NEWS AND DOCUMENTS IN THE NEON LOOK (2026-09-30). Pins what the
// screen pass promised:
//   * the sent bubble is the brand gradient and its words read on both
//     ends of it (4.5:1), with a soft halo; a received one is a raised
//     surface with a rim;
//   * the composer's rim lights while it has the keyboard; its send
//     button sends, and waits (turning) while sending;
//   * the front news card's picture flies into its story on one tag, the
//     cards behind it do not, and nothing flies with Remove animations on;
//   * a document tile dips under the finger.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:myassistant/design/motion.dart';
import 'package:myassistant/design/neon_tokens.dart';
import 'package:myassistant/design/neon_widgets.dart';
import 'package:myassistant/models/news_item.dart';
import 'package:myassistant/models/user_document.dart';
import 'package:myassistant/screens/news_story_screen.dart';
import 'package:myassistant/widgets/chat_bubble.dart';
import 'package:myassistant/widgets/document_tile.dart';
import 'package:myassistant/widgets/news_deck.dart';

double _contrast(Color a, Color b) {
  final x = a.computeLuminance(), y = b.computeLuminance();
  return (x > y ? x + 0.05 : y + 0.05) / (x > y ? y + 0.05 : x + 0.05);
}

NewsItem _story(int n) => NewsItem(
      title: 'Story $n',
      url: 'https://example.com/$n',
      source: 'paper.example',
      snippet: 'Summary $n.',
    );

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);
  late bool wasDark;
  setUp(() {
    wasDark = Neon.isDark;
    Neon.setDark(true);
  });
  tearDown(() => Neon.setDark(wasDark));

  group('chat', () {
    test('words on the sent gradient read at 4.5:1 on both ends', () {
      for (final accent in [null, const Color(0xFF3D8BFF), const Color(0xFFC77DFF)]) {
        Neon.setAccent(accent);
        final stops = chatSentStops();
        for (final c in stops) {
          expect(_contrast(c, ChatBubble.ink(true)), greaterThanOrEqualTo(4.5),
              reason: 'accent $accent, stop $c');
        }
      }
      Neon.setAccent(null);
    });

    testWidgets('sent: gradient and halo; received: raised surface and rim',
        (t) async {
      await t.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: Column(children: [
            ChatBubble(mine: true, child: Text('mine')),
            ChatBubble(mine: false, child: Text('theirs')),
          ]),
        ),
      ));
      BoxDecoration deco(String text) => t
          .widget<Container>(find
              .ancestor(of: find.text(text), matching: find.byType(Container))
              .first)
          .decoration! as BoxDecoration;
      final mine = deco('mine'), theirs = deco('theirs');
      expect(mine.gradient, isNotNull);
      expect(mine.boxShadow, isNotEmpty, reason: 'the sent bubble glows');
      expect(theirs.gradient, isNull);
      expect(theirs.border, isNotNull, reason: 'a received bubble has a rim');
      expect(theirs.boxShadow, isNull, reason: 'only yours glows');
    });

    testWidgets('a long press on a bubble opens its menu', (t) async {
      var held = 0;
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ChatBubble(
              mine: false, onLongPress: () => held++, child: const Text('hi')),
        ),
      ));
      await t.longPress(find.text('hi'));
      expect(held, 1);
    });

    testWidgets('the composer lights while typing, and its button sends',
        (t) async {
      final c = TextEditingController();
      addTearDown(c.dispose);
      var sent = 0;
      Widget app({bool sending = false}) => MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: ChatComposer(
                    controller: c, onSend: () => sent++, sending: sending),
              ),
            ),
          );
      await t.pumpWidget(app());
      double glow() {
        final box = t.widget<AnimatedContainer>(find
            .ancestor(
                of: find.byType(TextField),
                matching: find.byType(AnimatedContainer))
            .first);
        final shadows = (box.decoration! as BoxDecoration).boxShadow ?? [];
        return shadows.fold(0.0, (m, s) => m + s.color.a);
      }

      expect(glow(), 0, reason: 'at rest the rim is quiet');
      await t.tap(find.byType(TextField));
      await t.pumpAndSettle();
      expect(glow(), greaterThan(0), reason: 'focused, the rim lights');

      await t.enterText(find.byType(TextField), 'hello');
      await t.tap(find.bySemanticsLabel('Send'));
      await t.pump(const Duration(milliseconds: 200));
      expect(sent, 1);

      await t.pumpWidget(app(sending: true));
      await t.pump(const Duration(milliseconds: 200));
      expect(find.byType(NeonLoader), findsOneWidget);
      await t.tap(find.byType(NeonLoader), warnIfMissed: false);
      await t.pump(const Duration(milliseconds: 200));
      expect(sent, 1, reason: 'no second send while one is on its way');
      await t.pumpWidget(const SizedBox());
    });
  });

  group('news', () {
    Iterable<Hero> liveHeroes(WidgetTester t) => t
        .widgetList<HeroMode>(find.byType(HeroMode))
        .where((m) => m.enabled)
        .expand((m) => t.widgetList<Hero>(
            find.descendant(of: find.byWidget(m), matching: find.byType(Hero))));

    Future<void> deck(WidgetTester t, {bool reduced = false}) async {
      t.view.physicalSize = const Size(1080, 2340);
      t.view.devicePixelRatio = 2.625;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        builder: reduced
            ? (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(disableAnimations: true),
                  child: child!,
                )
            : null,
        home: Scaffold(
          body: NewsDeck(items: [_story(1), _story(2), _story(3)]),
        ),
      ));
      await t.pump(const Duration(milliseconds: 50));
    }

    testWidgets('only the front card\'s picture carries the story\'s tag',
        (t) async {
      await deck(t);
      final live = liveHeroes(t).toList();
      expect(live, hasLength(1));
      expect(live.single.tag, newsHeroTag(_story(1)));
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('the story marks its picture with the same tag', (t) async {
      final item = _story(1);
      await t.pumpWidget(MaterialApp(
        home: NewsStoryScreen(item: item, heroTag: newsHeroTag(item)),
      ));
      await t.pump();
      expect(
          t.widgetList<Hero>(find.byType(Hero)).where((h) => h.tag == newsHeroTag(item)),
          hasLength(1));
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('tapping the card flies its picture into the story', (t) async {
      await deck(t);
      await t.tap(find.text('Story 1').hitTestable());
      await t.pump();
      await t.pump(const Duration(milliseconds: 60));
      expect(find.byType(NewsStoryScreen), findsOneWidget);
      // Mid-flight: the picture rides in the navigator's overlay.
      expect(
          find.descendant(
              of: find.byType(Overlay), matching: find.byType(ClipRRect)),
          findsWidgets);
      await t.pump(const Duration(milliseconds: 400));
      expect(find.text('Summary 1.'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('with Remove animations on, nothing flies', (t) async {
      await deck(t, reduced: true);
      expect(liveHeroes(t), isEmpty);
      await t.pumpWidget(const SizedBox());
    });
  });

  testWidgets('a document tile dips under the finger', (t) async {
    const d = UserDocument(
      id: 7,
      filename: 'a.pdf',
      mime: 'application/pdf',
      title: 'Receipt',
      category: 'receipt',
      docDate: '',
      summary: '',
      note: '',
      createdAt: 0,
    );
    var opened = 0;
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 140,
            height: 200,
            child: DocumentGridTile(
                document: d, onOpen: () => opened++, onLongPress: () {}),
          ),
        ),
      ),
    ));
    final g = await t.startGesture(t.getCenter(find.text('Receipt')));
    await t.pump(const Duration(milliseconds: 120));
    final scale = t
        .widget<AnimatedScale>(find
            .ancestor(of: find.text('Receipt'), matching: find.byType(AnimatedScale))
            .first)
        .scale;
    expect(scale, lessThan(1));
    await g.up();
    await t.pump(const Duration(milliseconds: 200));
    expect(opened, 1);
    expect(find.byType(Tappable), findsOneWidget);
  });
}
