// THE TELEPROMPTER (2026-09-26) — "that text should go like a lyric".
//
// The identity script scrolls over the camera at reading pace: which line
// is lit at a moment, how long the whole script takes, the breaths after
// stops and commas, how the view glides between lines (and jumps instead
// with "Remove animations" on), that every line fits a small phone on one
// row, and the recording limits the recorder enforces around it.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:myassistant/design/neon_tokens.dart';
import 'package:myassistant/screens/identity_record_screen.dart';
import 'package:myassistant/widgets/teleprompter.dart';

Duration sec(double s) => Duration(microseconds: (s * 1e6).round());

/// Plain arithmetic: no breaths, no minimum.
TeleprompterTimeline plain(List<String> lines, {double wordsPerSecond = 1}) =>
    TeleprompterTimeline(lines,
        wordsPerSecond: wordsPerSecond,
        sentencePause: Duration.zero,
        commaPause: Duration.zero,
        minHold: Duration.zero);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The real Manrope from assets/google_fonts: the width checks below
  // measure the font the phone draws, not the test font.
  setUpAll(() async {
    GoogleFonts.config.allowRuntimeFetching = false;
    for (final w in NeonType.weights) {
      GoogleFonts.manrope(fontWeight: w);
    }
    await GoogleFonts.pendingFonts();
  });

  final script = TeleprompterTimeline(identityScript.split('\n'));

  group('the identity script', () {
    test('opens with the consent sentence, said on camera', () {
      expect(
          identityScript.replaceAll('\n', ' '),
          startsWith("I'm recording this so my assistant can make video "
              'messages in my voice, only when I ask.'));
      expect(identityScriptVersion, 1);
    });

    test('about 75 words, with numbers and a question', () {
      expect(TeleprompterTimeline.wordsIn(identityScript),
          inInclusiveRange(65, 80));
      expect(identityScript, contains('?'));
      expect(identityScript, contains('five fifteen'));
    });

    test('reads in about 30 seconds, breaths included', () {
      expect(TeleprompterTimeline.defaultWordsPerSecond, 2.4);
      expect(script.total.inMilliseconds, inInclusiveRange(30000, 36000));
      // With the breaths, an unhurried 2.1 words a second or so.
      final pace = TeleprompterTimeline.wordsIn(identityScript) /
          (script.total.inMilliseconds / 1000);
      expect(pace, inInclusiveRange(2.0, 2.3));
      // Inside what the recorder will save, with room to finish — at the
      // slower pace too.
      expect(script.total, greaterThan(IdentityRecordRules.minLength));
      final slow = TeleprompterTimeline(identityScript.split('\n'),
          wordsPerSecond: TeleprompterTimeline.defaultWordsPerSecond *
              ReadingPace.slower.factor);
      expect(slow.total, greaterThan(script.total));
      expect(IdentityRecordRules.maxLength - slow.total,
          greaterThan(const Duration(seconds: 12)));
    });

    testWidgets('every line fits a 360-dp phone on one row', (t) async {
      // 360 dp less the recorder's 20 px either side. Six of the sixteen
      // lines used to wrap here, leaving one word on a second row.
      const width = 320.0;
      for (final scale in [1.0, 1.15, 1.3]) {
        final scaler = TextScaler.linear(scale);
        final size = Teleprompter.fittedFontSize(script.lines, width,
            textScaler: scaler);
        expect(scaler.scale(size),
            greaterThanOrEqualTo(Teleprompter.minFontSize - 0.01),
            reason: 'still large at $scale');
        for (final l in script.lines) {
          final p = TextPainter(
            text: TextSpan(
                text: l,
                style: Teleprompter.lineStyle.copyWith(fontSize: size)),
            textDirection: TextDirection.ltr,
            textScaler: scaler,
          )..layout(maxWidth: width);
          expect(p.computeLineMetrics().length, 1, reason: '"$l" at $scale');
          p.dispose();
        }
      }
      // Where there is room, the full size.
      expect(Teleprompter.fittedFontSize(script.lines, 1000), NeonType.title2);
    });
  });

  group('the clock', () {
    final t = plain(['one two', 'three four five', 'six']);

    test('which line is being read at a moment', () {
      expect(t.total, const Duration(seconds: 6));
      expect(t.lineAt(Duration.zero), 0);
      expect(t.lineAt(sec(1.99)), 0);
      expect(t.lineAt(sec(2)), 1);
      expect(t.lineAt(sec(4.99)), 1);
      expect(t.lineAt(sec(5)), 2);
      expect(t.lineAt(sec(90)), 2, reason: 'the last line stays lit');
      expect(t.isDone(sec(5.9)), isFalse);
      expect(t.isDone(sec(6)), isTrue);
      expect(t.progress(sec(3)), closeTo(0.5, 1e-9));
      expect(t.progress(sec(60)), 1);
    });

    test('a breath after a stop or a comma; no line is rushed', () {
      final b = TeleprompterTimeline(
          ['one two three four, five six.', 'Hi!', 'seven eight nine ten'],
          wordsPerSecond: 2);
      // 6 words = 3 s, plus a comma and a full stop.
      expect(b.startOf(1), sec(3 + 0.15 + 0.35));
      // "Hi!" is half a second of words: held for the minimum.
      expect(b.startOf(2) - b.startOf(1), TeleprompterTimeline.defaultMinHold);
      expect(b.total - b.startOf(2), sec(2));
    });

    test('the identity script: each line starts where the one before ends',
        () {
      for (var i = 0; i < script.lines.length; i++) {
        final start = script.startOf(i);
        expect(script.lineAt(start), i);
        if (i > 0) {
          expect(script.lineAt(start - const Duration(milliseconds: 1)), i - 1);
          expect(start - script.startOf(i - 1),
              greaterThanOrEqualTo(TeleprompterTimeline.defaultMinHold));
        }
      }
    });

    test('the pace can be tuned', () {
      final normal = plain(script.lines, wordsPerSecond: 2.4);
      final quick = plain(script.lines, wordsPerSecond: 4.8);
      expect(quick.total.inMilliseconds,
          closeTo(normal.total.inMilliseconds / 2, 2));
      // The recorder's choices: slower is slower, faster is faster.
      TeleprompterTimeline at(ReadingPace p) => TeleprompterTimeline(
          script.lines,
          wordsPerSecond: TeleprompterTimeline.defaultWordsPerSecond * p.factor);
      expect(at(ReadingPace.slower).total, greaterThan(script.total));
      expect(at(ReadingPace.faster).total, lessThan(script.total));
      expect(at(ReadingPace.normal).total, script.total);
    });

    test('words, not tokens; blank rows are no lines', () {
      expect(TeleprompterTimeline.wordsIn("I'm here — it's 5 o'clock"), 5);
      expect(TeleprompterTimeline(['a b', '  ', '', 'c']).lines, ['a b', 'c']);
    });
  });

  group('the lyric look', () {
    final t = plain(['one two', 'three four', 'five six']);
    final lead = t.glideLead;

    test('glides into a new line just before its time, then holds on it', () {
      final from = sec(2) - lead;
      expect(t.scrollAt(from - const Duration(milliseconds: 1)), 0);
      final mid = t.scrollAt(from + t.glide ~/ 2);
      expect(mid, greaterThan(0));
      expect(mid, lessThan(1));
      expect(t.scrollAt(from + t.glide), 1);
      expect(t.scrollAt(sec(3.5)), 1);
    });

    test('a line is lit when it is due, not half a second after', () {
      for (var i = 1; i < script.lines.length; i++) {
        expect(script.emphasisOf(i, script.startOf(i)), greaterThan(0.7),
            reason: script.lines[i]);
      }
    });

    test('the line being read is bright and full size; the rest are not',
        () {
      final at = script.startOf(6) + script.glide;
      expect(script.opacityOf(6, at), 1);
      expect(script.scaleOf(6, at), 1);
      // Next: faint but readable. Just read: still half lit, for a reader
      // a line behind. Two back: faint. Far off: gone.
      final next = script.opacityOf(7, at);
      final last = script.opacityOf(5, at);
      expect(next, inExclusiveRange(0.3, 1));
      expect(last, greaterThanOrEqualTo(0.5));
      expect(last, lessThan(next));
      expect(script.opacityOf(4, at), inExclusiveRange(0.1, last));
      expect(script.scaleOf(7, at), lessThan(1));
      expect(script.opacityOf(0, at), 0);
      expect(script.opacityOf(14, at), 0);
    });

    test('the outgoing and incoming lines cross over during the glide', () {
      final at = sec(2) - lead + t.glide ~/ 2;
      final a = t.emphasisOf(0, at), b = t.emphasisOf(1, at);
      expect(a + b, closeTo(1, 1e-9));
      expect(a, inExclusiveRange(0, 1));
    });

    test('"Remove animations": the view jumps line to line, never glides',
        () {
      for (var ms = 0; ms <= script.total.inMilliseconds; ms += 40) {
        final at = Duration(milliseconds: ms);
        final line = script.lineAt(at);
        expect(script.scrollAt(at, reduced: true), line.toDouble());
        expect(script.emphasisOf(line, at, reduced: true), 1);
        expect(script.scaleOf(line, at, reduced: true), 1);
      }
      // The same moment with animations on is between two lines.
      final at = script.startOf(3) + const Duration(milliseconds: 100);
      expect(script.scrollAt(at) % 1, isNot(0));
    });
  });

  group('the widget', () {
    Future<ValueNotifier<Duration>> pumpPrompter(WidgetTester tester,
        {bool reduced = false, int? rows}) async {
      final elapsed = ValueNotifier(Duration.zero);
      addTearDown(elapsed.dispose);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
              child: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 360,
                  height: rows == null ? 300 : null,
                  child: Teleprompter(
                      timeline: script, elapsed: elapsed, visibleLines: rows),
                ),
              ),
            ),
          ),
        ),
      ));
      return elapsed;
    }

    testWidgets('the line being read sits at the anchor, the next below it',
        (tester) async {
      final elapsed = await pumpPrompter(tester);
      expect(tester.getCenter(find.text(script.lines[0])).dy,
          closeTo(300 * 0.3, 1));
      elapsed.value = script.startOf(6) + script.glide;
      await tester.pump();
      final now = tester.getCenter(find.text(script.lines[6])).dy;
      expect(now, closeTo(300 * 0.3, 1));
      expect(tester.getCenter(find.text(script.lines[7])).dy, greaterThan(now));
      expect(tester.getCenter(find.text(script.lines[5])).dy, lessThan(now));
    });

    testWidgets('as a band, exactly so many lines tall', (tester) async {
      await pumpPrompter(tester, rows: 4);
      final band = tester.getSize(find.byType(Teleprompter)).height;
      final line = tester.getSize(find.text(script.lines[0])).height + 10;
      expect(band, closeTo(4 * line, 4));
    });

    testWidgets('moves with the clock alone: no ticker, no rebuild',
        (tester) async {
      final elapsed = await pumpPrompter(tester);
      final flow = tester.renderObject(find.byType(Flow));
      elapsed.value = script.startOf(4) + script.glide ~/ 2;
      expect(flow.debugNeedsPaint, isTrue, reason: 'a repaint, nothing more');
      expect(flow.debugNeedsLayout, isFalse);
      await tester.pump();
      expect(tester.hasRunningAnimations, isFalse);
      expect(tester.binding.hasScheduledFrame, isFalse,
          reason: 'an idle prompter asks for no frames');
    });

    testWidgets('"Remove animations": mid-glide, the new line is already in place',
        (tester) async {
      final elapsed = await pumpPrompter(tester, reduced: true);
      elapsed.value = script.startOf(6) + const Duration(milliseconds: 100);
      await tester.pump();
      expect(tester.getCenter(find.text(script.lines[6])).dy,
          closeTo(300 * 0.3, 1));
    });
  });

  group('the recording limits', () {
    test('cannot be saved under 20 s; stops by itself at a minute', () {
      expect(IdentityRecordRules.minLength, const Duration(seconds: 20));
      expect(IdentityRecordRules.maxLength, const Duration(seconds: 60));
      expect(IdentityRecordRules.canSave(const Duration(milliseconds: 19999)),
          isFalse);
      expect(IdentityRecordRules.canSave(const Duration(seconds: 20)), isTrue);
      expect(IdentityRecordRules.canSave(const Duration(seconds: 31)), isTrue);
      expect(IdentityRecordRules.mustStop(const Duration(milliseconds: 59999)),
          isFalse);
      expect(IdentityRecordRules.mustStop(const Duration(seconds: 60)), isTrue);
    });

    test('a minute stays a size a phone can send', () {
      final bits = (IdentityRecordRules.videoBitrate +
              IdentityRecordRules.audioBitrate) *
          IdentityRecordRules.maxLength.inSeconds;
      expect(bits / 8 / 1e6, lessThan(21), reason: 'MB at most');
    });

    test('a take that is too short says why', () {
      expect(IdentityRecordRules.tooShort, contains('20 seconds'));
      expect(IdentityRecordRules.tooShort, contains('30'));
    });
  });
}
