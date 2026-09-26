import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../design/motion.dart';
import '../design/neon_tokens.dart';

/// WHERE THE READER IS, AT ANY MOMENT OF A RECORDING (2026-09-26).
///
/// The owner: "that text should go like a lyric". A script is a list of
/// short lines; each line gets as long as its words take to say at
/// [wordsPerSecond], so the words light up at reading pace and the whole
/// identity script lasts about 30 seconds. Pure arithmetic on a clock —
/// no widgets, no timers — so the pace can be tested and tuned on its own.
///
/// People do not read at a metronome's pace (review, 2026-09-26): a line
/// also gets a breath after a full stop or a comma, and never less than
/// [minHold] — "Hello there!" flashed by in under a second.
///
/// A new line's glide starts [glideLead] BEFORE its time, so it is lit
/// when it is due rather than half a second after; the view glides over
/// [glide] (the lyric feel). With "Remove animations" on, it jumps.
class TeleprompterTimeline {
  TeleprompterTimeline(
    Iterable<String> lines, {
    this.wordsPerSecond = defaultWordsPerSecond,
    this.glide = defaultGlide,
    this.sentencePause = defaultSentencePause,
    this.commaPause = defaultCommaPause,
    this.minHold = defaultMinHold,
    this.glideLead = defaultGlideLead,
  }) : lines = List.unmodifiable(
            lines.map((l) => l.trim()).where((l) => l.isNotEmpty)) {
    assert(wordsPerSecond > 0);
    var at = 0;
    final starts = <int>[];
    for (final l in this.lines) {
      starts.add(at);
      final said = wordsIn(l) / wordsPerSecond * 1e6 +
          _count(l, _sentenceEnd) * sentencePause.inMicroseconds +
          _count(l, _comma) * commaPause.inMicroseconds;
      at += math.max(said, minHold.inMicroseconds.toDouble()).round();
    }
    _startsUs = starts;
    total = Duration(microseconds: at);
  }

  /// An unhurried reading pace: slow enough to say every word clearly on
  /// camera (the voice is cloned from it), quick enough not to drag. With
  /// the breaths after stops and commas the identity script averages
  /// about 2.1 words a second.
  static const double defaultWordsPerSecond = 2.4;

  /// How long the view takes to move up to a new line.
  static const Duration defaultGlide = Duration(milliseconds: 420);

  /// A breath after . ! ? and a shorter one after , ; : —
  static const Duration defaultSentencePause = Duration(milliseconds: 350);
  static const Duration defaultCommaPause = Duration(milliseconds: 150);

  /// No line goes by quicker than this.
  static const Duration defaultMinHold = Duration(milliseconds: 1400);

  /// How far ahead of its time a line starts to glide in.
  static const Duration defaultGlideLead = Duration(milliseconds: 250);

  final List<String> lines;
  final double wordsPerSecond;
  final Duration glide;
  final Duration sentencePause;
  final Duration commaPause;
  final Duration minHold;
  final Duration glideLead;

  static final RegExp _sentenceEnd = RegExp(r'[.!?]+');
  static final RegExp _comma = RegExp(r'[,;:—–]');
  static int _count(String line, RegExp p) => p.allMatches(line).length;

  /// When the last word should have been said.
  late final Duration total;

  late final List<int> _startsUs;

  /// Words, not tokens: "I'm" is one, and a dash on its own is none.
  static int wordsIn(String line) =>
      RegExp(r"[\p{L}\p{N}]+(?:['’][\p{L}]+)*", unicode: true)
          .allMatches(line)
          .length;

  /// When line [i] starts.
  Duration startOf(int i) => Duration(microseconds: _startsUs[i]);

  /// The line being read at [t]: the first before the start, the last
  /// once the script is over.
  int lineAt(Duration t) {
    final us = t.inMicroseconds;
    var i = 0;
    while (i + 1 < _startsUs.length && _startsUs[i + 1] <= us) {
      i++;
    }
    return i;
  }

  /// The whole script has been read.
  bool isDone(Duration t) => t >= total;

  /// 0..1 through the script, for the progress bar.
  double progress(Duration t) => total == Duration.zero
      ? 1
      : (t.inMicroseconds / total.inMicroseconds).clamp(0.0, 1.0);

  /// How far the view has moved, in lines. A whole number while a line is
  /// read; between two numbers only during the glide into a new line,
  /// which starts [glideLead] before that line's time.
  double scrollAt(Duration t, {bool reduced = false}) {
    if (lines.isEmpty) return 0;
    if (reduced || glide <= Duration.zero) return lineAt(t).toDouble();
    final ahead = t + glideLead;
    final i = lineAt(ahead);
    if (i == 0) return 0;
    final into = (ahead.inMicroseconds - _startsUs[i]) / glide.inMicroseconds;
    if (into >= 1) return i.toDouble();
    return (i - 1) + Motion.easeMove.transform(into.clamp(0.0, 1.0));
  }

  /// How lit line [i] is: 1 while it is read, 0 otherwise. The outgoing
  /// and the incoming line cross over during the glide.
  double emphasisOf(int i, Duration t, {bool reduced = false}) =>
      (1 - (i - scrollAt(t, reduced: reduced)).abs()).clamp(0.0, 1.0);

  /// The ink of line [i]: full for the line being read; what comes next is
  /// faint but readable (the eye reads ahead); the line just read stays
  /// half lit, so a reader a line behind still reads it; two back is
  /// faint, and further off the lines fade out entirely.
  double opacityOf(int i, Duration t, {bool reduced = false}) {
    final d = i - scrollAt(t, reduced: reduced);
    final rest = d >= 0
        ? (0.75 - 0.15 * d).clamp(0.0, upcomingInk)
        : (0.75 + 0.25 * d).clamp(0.0, pastInk);
    final e = emphasisOf(i, t, reduced: reduced);
    return rest + (1 - rest) * e;
  }

  /// The line being read is drawn full size; the rest a little smaller.
  double scaleOf(int i, Duration t, {bool reduced = false}) =>
      restScale + (1 - restScale) * emphasisOf(i, t, reduced: reduced);

  static const double upcomingInk = 0.55;
  static const double pastInk = 0.5;
  static const double restScale = 0.86;
}

/// The script over the camera: the line being read sits at [anchor] (a
/// fraction of the height), bright and full size; the lines move up past
/// it like lyrics.
///
/// Driven by [elapsed] alone and PAINTED, never rebuilt: the lines are laid
/// out once, and each frame only moves and fades them (a Flow). No ticker
/// of its own — the recorder's clock runs only while it records, so an idle
/// screen asks for no frames.
///
/// With [visibleLines] it is exactly that many lines tall (the recorder's
/// band under the camera); without, it fills what it is given.
class Teleprompter extends StatelessWidget {
  const Teleprompter({
    super.key,
    required this.timeline,
    required this.elapsed,
    this.anchor = 0.3,
    this.visibleLines,
  });

  final TeleprompterTimeline timeline;
  final ValueListenable<Duration> elapsed;
  final double anchor;
  final int? visibleLines;

  /// Large on purpose — read at arm's length, over a moving picture. The
  /// phone's text size still counts, up to [maxTextScale].
  static final TextStyle lineStyle =
      NeonType.manrope(NeonType.title2, FontWeight.w700).copyWith(
        color: Colors.white,
        height: 1.25,
        letterSpacing: -0.2,
        // Legible over a bright window as well as a dark room; the scrim
        // behind does most of the work, this keeps the edges crisp.
        shadows: [
          Shadow(color: Colors.black.withValues(alpha: 0.6), blurRadius: 12),
          Shadow(
              color: Colors.black.withValues(alpha: 0.4),
              offset: const Offset(0, 1),
              blurRadius: 3),
        ],
      );

  static const double maxTextScale = 1.3;

  /// Never smaller than this when a long line is fitted to a narrow phone.
  static const double minFontSize = NeonType.title3;

  static const double _padV = 5;

  /// One size for every line, so the longest fits [width] on one row: on
  /// a 360-dp phone six of the sixteen script lines wrapped at full size,
  /// leaving a lone word on a second row (review, 2026-09-26). Never drawn
  /// smaller than [minFontSize] — past that a line may wrap rather than
  /// turn unreadable. The size returned is before [textScaler].
  static double fittedFontSize(Iterable<String> lines, double width,
      {TextScaler textScaler = TextScaler.noScaling,
      TextDirection direction = TextDirection.ltr}) {
    final base = lineStyle.fontSize ?? NeonType.title2;
    if (!width.isFinite || width <= 0) return base;
    var widest = 0.0;
    for (final l in lines) {
      final p = TextPainter(
        text: TextSpan(text: l, style: lineStyle),
        textDirection: direction,
        textScaler: textScaler,
        maxLines: 1,
      )..layout();
      widest = math.max(widest, p.width);
      p.dispose();
    }
    if (widest <= width) return base;
    // The floor is on the size DRAWN: at a larger text setting the size
    // before scaling may go lower and still draw at least minFontSize.
    final grow = textScaler.scale(base) / base;
    final floor = minFontSize / (grow > 0 ? grow : 1);
    // A hair under the exact fit: glyph widths do not scale quite linearly.
    return math.max(floor, base * width / widest * 0.98);
  }

  @override
  Widget build(BuildContext context) {
    final reduced = Motion.reduced(context);
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: maxTextScale,
      child: LayoutBuilder(builder: (context, box) {
        final scaler = MediaQuery.textScalerOf(context);
        final size = fittedFontSize(timeline.lines, box.maxWidth,
            textScaler: scaler, direction: Directionality.of(context));
        final style = lineStyle.copyWith(fontSize: size);
        final flow = ClipRect(
          child: Flow(
            delegate: _LyricFlow(
              timeline: timeline,
              elapsed: elapsed,
              reduced: reduced,
              anchor: anchor,
            ),
            children: [
              for (final line in timeline.lines)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: _padV),
                  child:
                      Text(line, textAlign: TextAlign.center, style: style),
                ),
            ],
          ),
        );
        final rows = visibleLines;
        if (rows == null) return flow;
        final line = scaler.scale(size) * (style.height ?? 1.25) + 2 * _padV;
        return SizedBox(height: line * rows, child: flow);
      }),
    );
  }
}

class _LyricFlow extends FlowDelegate {
  _LyricFlow({
    required this.timeline,
    required this.elapsed,
    required this.reduced,
    required this.anchor,
  }) : super(repaint: elapsed);

  final TeleprompterTimeline timeline;
  final ValueListenable<Duration> elapsed;
  final bool reduced;
  final double anchor;

  // Lines take their own height (a long line may wrap) and the full width.
  @override
  BoxConstraints getConstraintsForChild(int i, BoxConstraints constraints) =>
      BoxConstraints(maxWidth: constraints.maxWidth);

  @override
  Size getSize(BoxConstraints constraints) => constraints.biggest;

  @override
  void paintChildren(FlowPaintingContext context) {
    final n = context.childCount;
    if (n == 0) return;
    final size = context.size;
    final centers = List<double>.filled(n, 0);
    var y = 0.0;
    for (var i = 0; i < n; i++) {
      final h = context.getChildSize(i)!.height;
      centers[i] = y + h / 2;
      y += h;
    }
    final t = elapsed.value;
    final s = timeline.scrollAt(t, reduced: reduced).clamp(0.0, n - 1.0);
    final lo = s.floor();
    final hi = (lo + 1).clamp(0, n - 1);
    final focus = centers[lo] + (centers[hi] - centers[lo]) * (s - lo);
    final dy = size.height * anchor - focus;
    for (var i = 0; i < n; i++) {
      final o = timeline.opacityOf(i, t, reduced: reduced);
      if (o < 0.01) continue;
      final c = context.getChildSize(i)!;
      final top = centers[i] - c.height / 2 + dy;
      if (top > size.height || top + c.height < 0) continue;
      final k = timeline.scaleOf(i, t, reduced: reduced);
      final m = Matrix4.identity()
        ..translateByDouble(
            (size.width - c.width) / 2 + c.width / 2, top + c.height / 2, 0, 1)
        ..scaleByDouble(k, k, 1, 1)
        ..translateByDouble(-c.width / 2, -c.height / 2, 0, 1);
      context.paintChild(i, transform: m, opacity: o);
    }
  }

  @override
  bool shouldRepaint(_LyricFlow old) =>
      old.timeline != timeline ||
      old.elapsed != elapsed ||
      old.reduced != reduced ||
      old.anchor != anchor;

  @override
  bool shouldRelayout(_LyricFlow old) => old.timeline != timeline;
}
