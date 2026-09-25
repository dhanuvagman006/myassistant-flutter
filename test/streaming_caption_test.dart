import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/widgets/streaming_caption.dart';

/// Owner, 2026-09-25: "when user speaks or agent speaks update the caption
/// appearing style need streaming style instead of the current style".
void main() {
  group('sentences', () {
    List<String> split(String t) =>
        [for (final (s, e) in captionSentences(t)) t.substring(s, e)];

    test('one paragraph per sentence, without the spaces between', () {
      expect(split('Hello there. How are you?'), ['Hello there.', 'How are you?']);
      expect(split('  Wait… what? Really!  '), ['Wait…', 'what?', 'Really!']);
      expect(split('He said "yes." Then he left.'), ['He said "yes."', 'Then he left.']);
      expect(split('नमस्ते। आप कैसे हैं?'), ['नमस्ते।', 'आप कैसे हैं?']);
    });

    test('a title or an initial never splits a name', () {
      expect(split('Dr. Rao will call at 5 p.m. today. Okay?'),
          ['Dr. Rao will call at 5 p.m. today.', 'Okay?']);
      expect(split('A. R. Rahman is playing.'), ['A. R. Rahman is playing.']);
      // Words that really do end sentences still do.
      expect(split('No. I am. Yes.'), ['No.', 'I am.', 'Yes.']);
    });

    test('an unfinished sentence and a decimal stay whole', () {
      expect(split('It costs 3.5 lakh and'), ['It costs 3.5 lakh and']);
      expect(split(''), isEmpty);
      expect(split('   '), isEmpty);
    });
  });

  group('words', () {
    const white = Color(0xFFFFFFFF);
    const style = TextStyle(fontSize: 20, color: white);

    Widget host(String text, {bool reduced = false}) => MediaQuery(
          data: MediaQueryData(disableAnimations: reduced),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: SizedBox(
              width: 400,
              child: StreamingCaption(text: text, style: style),
            ),
          ),
        );

    /// The opacity of [sentence]'s character at [index], as drawn now.
    double alphaAt(WidgetTester tester, String sentence, int index) {
      final t = tester.widget<Text>(find.text(sentence));
      if (t.data != null) return t.style!.color!.a;
      var pos = 0;
      for (final span in (t.textSpan! as TextSpan).children!) {
        final s = span as TextSpan;
        if (index < pos + s.text!.length) return s.style!.color!.a;
        pos += s.text!.length;
      }
      throw StateError('$index is past the end of "$sentence"');
    }

    testWidgets('each word fades in where it will stay, then nothing moves',
        (tester) async {
      await tester.pumpWidget(host('Book a table'));
      expect(find.text('Book a table'), findsOneWidget,
          reason: 'every word is laid out from the start, so none moves when it appears');
      expect(alphaAt(tester, 'Book a table', 0), 0);
      await tester.pump(const Duration(milliseconds: 130));
      final first = alphaAt(tester, 'Book a table', 0);
      final last = alphaAt(tester, 'Book a table', 8);
      expect(first, inExclusiveRange(0, 1));
      expect(last, lessThan(first), reason: 'the words flow in one after another');
      await tester.pump(const Duration(milliseconds: 600));
      expect(alphaAt(tester, 'Book a table', 0), 1);
      expect(alphaAt(tester, 'Book a table', 8), 1);
      expect(tester.widget<Text>(find.text('Book a table')).textAlign, TextAlign.start,
          reason: 'a centred line shifts sideways as every word joins it');
      expect(tester.binding.hasScheduledFrame, isFalse,
          reason: 'a settled caption must ask for no frames');
    });

    testWidgets('new words join at the end; the words already there stay put',
        (tester) async {
      await tester.pumpWidget(host('Book a table'));
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpWidget(host('Book a table for two'));
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.text('Book a table for two'), findsOneWidget);
      expect(alphaAt(tester, 'Book a table for two', 0), 1);
      expect(alphaAt(tester, 'Book a table for two', 11), 1);
      expect(alphaAt(tester, 'Book a table for two', 13), lessThan(0.5),
          reason: 'the new word fades in');
      await tester.pump(const Duration(milliseconds: 500));
      expect(alphaAt(tester, 'Book a table for two', 17), 1);
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('a whole reply at once still flows in within a moment',
        (tester) async {
      // Sound off: the whole reply lands in one update.
      final many = 'Okay ${List.generate(40, (i) => 'word$i').join(' ')}';
      await tester.pumpWidget(host('Okay'));
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpWidget(host(many));
      await tester.pump(const Duration(milliseconds: 100));
      expect(alphaAt(tester, many, many.length - 1), 0,
          reason: 'the last word waits its turn');
      await tester.pump(StreamingCaption.burstCap + StreamingCaption.fade);
      expect(alphaAt(tester, many, many.length - 1), 1,
          reason: 'forty words may not take forty staggers');
    });

    testWidgets('a finished sentence softens as the next one streams in below it',
        (tester) async {
      const one = 'Please book a table.';
      await tester.pumpWidget(host(one));
      await tester.pump(const Duration(seconds: 1));
      expect(alphaAt(tester, one, 0), 1);
      await tester.pumpWidget(host('$one At the Italian place.'));
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.text(one), findsOneWidget, reason: 'each sentence is its own paragraph');
      expect(find.text('At the Italian place.'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 120));
      expect(alphaAt(tester, one, 0), inExclusiveRange(0.6, 1.0),
          reason: 'it eases down, it does not snap');
      await tester.pump(const Duration(milliseconds: 700));
      expect(alphaAt(tester, one, 0), closeTo(0.6, 1e-9));
      expect(alphaAt(tester, 'At the Italian place.', 0), 1);
      // At rest: plain text in the softer colour, no spans left over.
      expect(tester.widget<Text>(find.text(one)).data, one);
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('a caption shown again mid-reply is simply there', (tester) async {
      final long = List.generate(12, (i) => 'Sentence $i is here.').join(' ');
      expect(long.length, greaterThan(StreamingCaption.settleLongerThan));
      await tester.pumpWidget(host(long));
      expect(alphaAt(tester, 'Sentence 11 is here.', 0), 1);
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('Remove animations: words appear at once', (tester) async {
      await tester.pumpWidget(host('Book a table', reduced: true));
      expect(alphaAt(tester, 'Book a table', 0), 1);
      await tester.pumpWidget(host('Book a table. For two', reduced: true));
      expect(alphaAt(tester, 'For two', 0), 1);
      expect(alphaAt(tester, 'Book a table.', 0), closeTo(0.6, 1e-9));
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('text that changes keeps what it shares and fades in the rest',
        (tester) async {
      await tester.pumpWidget(host('Book a tab'));
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpWidget(host('Book a cab'));
      await tester.pump(const Duration(milliseconds: 16));
      expect(alphaAt(tester, 'Book a cab', 0), 1);
      expect(alphaAt(tester, 'Book a cab', 7), lessThan(1));
      await tester.pump(const Duration(milliseconds: 500));
      expect(alphaAt(tester, 'Book a cab', 7), 1);
    });
  });

  group('the glide', () {
    // Ahem: every glyph a 20 x 20 square, 15 to a 300-wide line.
    const style = TextStyle(fontSize: 20, height: 1.0);
    String lines(int n) => List.filled(n * 3, 'abcd').join(' ');

    Widget host(String text, {bool reduced = false}) => MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: reduced),
            child: Center(
              child: SizedBox(
                width: 300,
                height: 100,
                child: LayoutBuilder(
                  builder: (context, area) => ClipRect(
                    child: SingleChildScrollView(
                      reverse: true,
                      physics: const NeverScrollableScrollPhysics(),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(minHeight: area.maxHeight),
                        child: Align(
                          alignment: Alignment.topLeft,
                          child: CaptionGlide(
                            viewport: area.maxHeight,
                            child: Text(text, style: style),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );

    double top(WidgetTester tester) => tester.getTopLeft(find.byType(Text)).dy;

    testWidgets('a new line of a long passage eases it up instead of jolting it',
        (tester) async {
      await tester.pumpWidget(host(lines(6))); // 120 px in 100: over by 20
      final before = top(tester);
      await tester.pumpWidget(host(lines(7))); // over by 40: pushed up 20
      expect(top(tester), moreOrLessEquals(before),
          reason: 'on the frame it grows, the passage is still drawn where it was');
      await tester.pump(const Duration(milliseconds: 60));
      final mid = top(tester);
      expect(mid, lessThan(before));
      expect(mid, greaterThan(before - 20));
      await tester.pump(const Duration(milliseconds: 300));
      expect(top(tester), moreOrLessEquals(before - 20));
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('while it fits, a new line just appears below', (tester) async {
      await tester.pumpWidget(host(lines(2)));
      final before = top(tester);
      await tester.pumpWidget(host(lines(3)));
      expect(top(tester), before);
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('Remove animations: no glide', (tester) async {
      await tester.pumpWidget(host(lines(6), reduced: true));
      final before = top(tester);
      await tester.pumpWidget(host(lines(7), reduced: true));
      expect(top(tester), moreOrLessEquals(before - 20));
      expect(tester.binding.transientCallbackCount, 0, reason: 'nothing animates');
    });
  });
}
