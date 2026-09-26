import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/widgets/caption_scroll.dart';

/// The whole reply, still streaming (owner, 2026-09-26: "if we have long
/// output it's getting hidden… we need streaming like response, but the
/// full response should be visible").
void main() {
  // Ahem: every glyph a 20 x 20 square, 15 to a 300-wide line.
  const style = TextStyle(fontSize: 20, height: 1.0);
  String words(int lines, {String word = 'abcd'}) =>
      List.filled(lines * 3, word).join(' ');

  int overflows = 0;
  const passage = ValueKey('passage');

  Widget host(String text, {bool reduced = false}) => MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduced),
          child: Scaffold(
            body: Center(
              child: SizedBox(
                width: 300,
                height: 100,
                child: CaptionScroll(
                  onOverflow: () => overflows++,
                  child: Text(text, key: passage, style: style),
                ),
              ),
            ),
          ),
        ),
      );

  ScrollPosition position(WidgetTester tester) =>
      tester.state<ScrollableState>(find.byType(Scrollable)).position;

  Rect view(WidgetTester tester) => tester.getRect(find.byType(CaptionScroll));

  setUp(() => overflows = 0);

  testWidgets('short words just sit there: no scroll, no fade, no pill',
      (tester) async {
    await tester.pumpWidget(host(words(2)));
    await tester.pumpAndSettle();
    expect(position(tester).maxScrollExtent, 0);
    expect(tester.layers.whereType<ShaderMaskLayer>(), isEmpty);
    expect(find.byKey(const ValueKey('caption-latest')), findsNothing);
    expect(overflows, 0);
  });

  testWidgets('as a long reply streams in, the newest line stays in view',
      (tester) async {
    await tester.pumpWidget(host(words(3)));
    await tester.pumpAndSettle();
    for (var n = 4; n <= 9; n++) {
      await tester.pumpWidget(host('${words(n - 1)} last$n'));
      await tester.pumpAndSettle();
      final p = position(tester);
      expect(p.pixels, moreOrLessEquals(p.maxScrollExtent),
          reason: 'following the newest line ($n lines)');
    }
    expect(overflows, 1, reason: 'told once, the first time it outgrew the space');
    // The oldest words are above the view, and that edge fades.
    expect(tester.layers.whereType<ShaderMaskLayer>(), hasLength(1));
  });

  testWidgets('the new line glides into view rather than jumping', (tester) async {
    await tester.pumpWidget(host(words(6)));
    await tester.pumpAndSettle();
    final before = position(tester).pixels;
    await tester.pumpWidget(host(words(7)));
    await tester.pump(); // laid out: now past the end
    await tester.pump(const Duration(milliseconds: 60));
    final mid = position(tester).pixels;
    expect(mid, greaterThan(before));
    expect(mid, lessThan(position(tester).maxScrollExtent));
    await tester.pumpAndSettle();
    expect(position(tester).pixels, moreOrLessEquals(position(tester).maxScrollExtent));
  });

  testWidgets('"Remove animations": the newest line is simply there', (tester) async {
    await tester.pumpWidget(host(words(6), reduced: true));
    await tester.pumpAndSettle();
    await tester.pumpWidget(host(words(7), reduced: true));
    await tester.pump();
    await tester.pump();
    expect(position(tester).pixels, moreOrLessEquals(position(tester).maxScrollExtent));
  });

  testWidgets('the whole reply can be read back, from its first word', (tester) async {
    await tester.pumpWidget(host('first ${words(12)}'));
    await tester.pumpAndSettle();
    expect(position(tester).pixels, greaterThan(0), reason: 'at the newest line');
    await tester.drag(find.byType(CaptionScroll), const Offset(0, 1000));
    await tester.pumpAndSettle();
    expect(position(tester).pixels, 0);
    final first = tester.getTopLeft(find.byKey(passage));
    expect(view(tester).contains(first), isTrue, reason: 'the first word is on screen');
  });

  testWidgets('reading back, new words do not move what is being read', (tester) async {
    await tester.pumpWidget(host(words(10)));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(CaptionScroll), const Offset(0, 1000));
    await tester.pumpAndSettle();
    final top = tester.getTopLeft(find.byKey(passage)).dy;

    await tester.pumpWidget(host(words(13)));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.byKey(passage)).dy, top,
        reason: 'the view stayed where they were reading');
    // Both edges have more beyond them now: one mask covers both.
    expect(tester.layers.whereType<ShaderMaskLayer>(), hasLength(1));

    // "Latest" takes them to the end, and following resumes.
    final pill = find.byKey(const ValueKey('caption-latest'));
    expect(pill, findsOneWidget);
    await tester.tap(pill);
    await tester.pumpAndSettle();
    expect(pill, findsNothing);
    final p = position(tester);
    expect(p.pixels, moreOrLessEquals(p.maxScrollExtent));
    await tester.pumpWidget(host(words(15)));
    await tester.pumpAndSettle();
    expect(position(tester).pixels, moreOrLessEquals(position(tester).maxScrollExtent),
        reason: 'following again');
  });

  testWidgets('scrolling back down to the end resumes following', (tester) async {
    await tester.pumpWidget(host(words(10)));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(CaptionScroll), const Offset(0, 1000));
    await tester.pumpAndSettle();
    await tester.pumpWidget(host(words(12)));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('caption-latest')), findsOneWidget);
    await tester.drag(find.byType(CaptionScroll), const Offset(0, -2000));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('caption-latest')), findsNothing);
    await tester.pumpWidget(host(words(14)));
    await tester.pumpAndSettle();
    expect(position(tester).pixels, moreOrLessEquals(position(tester).maxScrollExtent));
  });
}
