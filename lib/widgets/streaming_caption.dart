import 'dart:math' as math;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../design/motion.dart';

/// STREAMING CAPTIONS (owner, 2026-09-25: "when user speaks or agent
/// speaks update the caption appearing style need streaming style instead
/// of the current style").
///
/// The voice screen showed each turn LYRICS-STYLE: one big centred line
/// per sentence, swapped for the next when the sentence ended, the old one
/// shrinking into a dim stack above. It read as blocks of text trading
/// places. Now the words STREAM, the way live captions do:
///
///  * Each word fades in where it will stay, as it is heard. A fragment
///    that brings several words at once flows in one word after another
///    ([stagger], the whole burst within [burstCap]) instead of landing as
///    a block.
///  * Left-aligned, in reading order: a centred line moves sideways by half
///    a word every time a word joins it.
///  * One paragraph per sentence, stacked. The sentence being spoken is at
///    full strength; the ones before it soften ([earlierOpacity]), so the
///    eye stays on what is being said now and the rest still reads.
///  * A finished sentence is never laid out again: while words fade in,
///    only the sentence they belong to is shaped and drawn.
///  * The ticker runs only while something is fading; a settled caption
///    asks for no frames. "Remove animations": the words are simply there.
///
/// The screen around it follows the newest line and lets the whole
/// passage be scrolled back through (CaptionScroll).
class StreamingCaption extends StatefulWidget {
  const StreamingCaption({
    super.key,
    required this.text,
    required this.style,
    this.earlierOpacity = 0.6,
    this.sentenceGap = 6,
  });

  /// Everything shown so far this turn. It grows as words arrive; a text
  /// that is not an extension of the last one keeps the part they share.
  final String text;

  /// The words' style. Its colour is the sentence being spoken.
  final TextStyle style;

  /// Earlier sentences' share of that colour's opacity.
  final double earlierOpacity;

  /// Space between two sentences.
  final double sentenceGap;

  /// How long one word takes to fade in.
  static const Duration fade = Duration(milliseconds: 260);

  /// The step between words that arrive together...
  static const Duration stagger = Duration(milliseconds: 55);

  /// ...and the most one burst may take to start its last word, so a whole
  /// reply arriving at once (sound off) still flows in within a moment.
  static const Duration burstCap = Duration(milliseconds: 400);

  /// How long a finished sentence takes to soften.
  static const Duration dim = Duration(milliseconds: 300);

  /// A caption already this long when it is first built was on screen a
  /// moment ago (the screen was rebuilt mid-reply): it is there at once.
  static const int settleLongerThan = 160;

  @override
  State<StreamingCaption> createState() => _StreamingCaptionState();
}

/// Where each sentence of [text] starts and ends (end exclusive, without
/// the spaces between sentences). A sentence ends at . ! ? । or … followed
/// by a space — but not after a title or an initial ("Dr. Rao",
/// "A. R. Rahman", "5 p.m. today"), where a new line would split a name.
@visibleForTesting
List<(int, int)> captionSentences(String text) {
  final out = <(int, int)>[];
  var start = 0;
  while (start < text.length && _isSpace(text.codeUnitAt(start))) {
    start++;
  }
  for (final m in _sentenceEnd.allMatches(text)) {
    if (m.start < start) continue;
    final end = m.start + m.group(1)!.length;
    if (_abbreviated(text, m.start, m.group(1)!)) continue;
    if (end > start) out.add((start, end));
    start = m.end;
  }
  var end = text.length;
  while (end > start && _isSpace(text.codeUnitAt(end - 1))) {
    end--;
  }
  if (end > start) out.add((start, end));
  return out;
}

/// Sentence-ending punctuation (and any closing quote or bracket), then
/// the space before the next sentence.
final _sentenceEnd = RegExp('([.!?।…]+["”’)\\]]*)\\s+');

/// Titles that take a full stop and are followed by a name. Only ones
/// that never end a sentence on their own ("No." and "am." do).
const _titles = {
  'mr', 'mrs', 'ms', 'dr', 'prof', 'sr', 'jr', 'st', 'vs', 'approx', //
  'rs', 'govt', 'dept', 'ltd', 'inc', 'mt', 'ft', 'smt', 'shri',
};

bool _abbreviated(String text, int at, String punct) {
  if (punct != '.') return false;
  var i = at;
  while (i > 0 && _isLetter(text.codeUnitAt(i - 1))) {
    i--;
  }
  final word = text.substring(i, at);
  if (word.isEmpty) return false;
  // One letter: an initial, or the "m" of "p.m.".
  if (word.length == 1) return true;
  return _titles.contains(word.toLowerCase());
}

bool _isSpace(int c) => c == 0x20 || c == 0x0A || c == 0x09 || c == 0x0D;

bool _isLetter(int c) =>
    (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A);

/// The pieces new words are split into: each word with the space in front
/// of it, and a trailing run of space on its own.
final _chunks = RegExp(r'\s*\S+|\s+');

class _StreamingCaptionState extends State<StreamingCaption>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_onTick);

  /// This caption's own clock. It runs with the ticker and holds still
  /// while nothing moves (nothing needs the time then).
  Duration _now = Duration.zero;
  Duration _base = Duration.zero;

  String _text = '';

  /// Every character before this is fully in.
  int _settled = 0;

  /// Words still fading in, in order: [start, end) and when they begin.
  /// Contiguous: together with [_settled] they cover the whole text.
  final List<(int, int, Duration)> _words = [];

  /// Where the sentence being spoken starts; before it, earlier sentences.
  int _current = 0;

  /// Earlier sentences still softening: [start, end) and when they began.
  final List<(int, int, Duration)> _dims = [];

  bool _still = false;
  bool _begun = false;

  /// Sentences that are neither fading nor softening, as built last time:
  /// start → (end, opacity, widget). Handing Flutter the same widget skips
  /// the whole rebuild of a sentence that has not changed.
  final Map<int, (int, double, Widget)> _built = {};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _still = Motion.reduced(context);
    if (!_begun) {
      _begun = true;
      _text = widget.text;
      if (_still || _text.length > StreamingCaption.settleLongerThan) {
        _settleAll();
      } else {
        _admit(0);
      }
      _current = _currentStart();
      _ensureTicking();
    } else if (_still) {
      _settleAll();
    }
  }

  @override
  void didUpdateWidget(StreamingCaption old) {
    super.didUpdateWidget(old);
    if (old.style != widget.style ||
        old.earlierOpacity != widget.earlierOpacity ||
        old.sentenceGap != widget.sentenceGap) {
      _built.clear();
    }
    final t = widget.text;
    if (t == _text) return;
    // What the two texts share stays exactly as it is on screen; only the
    // rest is new. Normally that is all of the old text (words are only
    // ever added), and only the added words fade in.
    var keep = 0;
    final n = math.min(t.length, _text.length);
    while (keep < n && t.codeUnitAt(keep) == _text.codeUnitAt(keep)) {
      keep++;
    }
    if (keep < _text.length) {
      _built.clear();
      _settled = math.min(_settled, keep);
      _words
        ..removeWhere((w) => w.$1 >= keep)
        ..replaceRange(0, _words.length, [
          for (final w in _words) (w.$1, math.min(w.$2, keep), w.$3),
        ]);
      _dims
        ..removeWhere((d) => d.$1 >= keep)
        ..replaceRange(0, _dims.length, [
          for (final d in _dims) (d.$1, math.min(d.$2, keep), d.$3),
        ]);
      if (_current > keep) _current = 0;
    }
    _text = t;
    if (_still) {
      _settleAll();
    } else {
      _admit(math.max(keep, _words.isEmpty ? _settled : _words.last.$2));
    }
    _moveCurrent();
    _ensureTicking();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _settleAll() {
    _settled = _text.length;
    _words.clear();
    _dims.clear();
  }

  /// Queues the words from [from] to the end to fade in one after another.
  void _admit(int from) {
    if (from >= _text.length) return;
    final pieces = _chunks.allMatches(_text, from).toList();
    if (pieces.isEmpty) return;
    final step = pieces.length <= 1
        ? Duration.zero
        : Duration(
            microseconds: math.min(StreamingCaption.stagger.inMicroseconds,
                StreamingCaption.burstCap.inMicroseconds ~/ (pieces.length - 1)));
    // After the words still waiting their turn, but never queued so far
    // behind that the caption lags what was said.
    var at = _now;
    if (_words.isNotEmpty) {
      final next = _words.last.$3 + step;
      if (next > at) at = next;
    }
    final latest = _now + StreamingCaption.burstCap;
    if (at > latest) at = latest;
    for (final (i, p) in pieces.indexed) {
      _words.add((p.start, p.end, at + step * i));
    }
  }

  int _currentStart() {
    final s = captionSentences(_text);
    return s.isEmpty ? 0 : s.last.$1;
  }

  /// A new sentence has started: the one before it softens, from the
  /// moment the new sentence's first word appears.
  void _moveCurrent() {
    final start = _currentStart();
    if (start > _current) {
      var begin = _now;
      for (final w in _words) {
        if (w.$2 > start) {
          if (w.$3 > begin) begin = w.$3;
          break;
        }
      }
      if (!_still) _dims.add((_current, start, begin));
      _current = start;
    } else if (start < _current) {
      _current = start;
    }
  }

  void _ensureTicking() {
    if ((_words.isNotEmpty || _dims.isNotEmpty) && !_ticker.isActive) {
      _base = _now;
      _ticker.start();
    }
  }

  void _onTick(Duration elapsed) {
    _now = _base + elapsed;
    // Words that are fully in join the settled run, in order.
    while (_words.isNotEmpty &&
        _now - _words.first.$3 >= StreamingCaption.fade) {
      _settled = math.max(_settled, _words.first.$2);
      _words.removeAt(0);
    }
    _dims.removeWhere((d) => _now - d.$3 >= StreamingCaption.dim);
    if (_words.isEmpty && _dims.isEmpty) {
      _ticker.stop();
      _base = _now;
    }
    setState(() {});
  }

  double _progress(Duration begin, Duration length) =>
      ((_now - begin).inMicroseconds / length.inMicroseconds).clamp(0.0, 1.0);

  /// How much of the colour's opacity the character at [i] has now.
  double _opacityAt(int i) {
    var a = 1.0;
    if (i < _current) {
      a = widget.earlierOpacity;
      for (final d in _dims) {
        if (i >= d.$1 && i < d.$2) {
          final k = Motion.easeMove.transform(_progress(d.$3, StreamingCaption.dim));
          a = 1.0 + (widget.earlierOpacity - 1.0) * k;
          break;
        }
      }
    }
    if (i >= _settled) {
      for (final w in _words) {
        if (i >= w.$1 && i < w.$2) {
          a *= Motion.easeFadeIn.transform(_progress(w.$3, StreamingCaption.fade));
          break;
        }
      }
    }
    return a;
  }

  /// True when nothing in [s, e) is fading or softening.
  bool _atRest(int s, int e) {
    if (e > _settled) return false;
    for (final d in _dims) {
      if (d.$1 < e && d.$2 > s) return false;
    }
    return true;
  }

  Widget _sentence(int s, int e, Color color) {
    if (_atRest(s, e)) {
      final opacity = s < _current ? widget.earlierOpacity : 1.0;
      final hit = _built[s];
      if (hit != null && hit.$1 == e && hit.$2 == opacity) return hit.$3;
      final w = Text(
        _text.substring(s, e),
        key: ValueKey(s),
        textAlign: TextAlign.start,
        style: widget.style.copyWith(color: color.withValues(alpha: color.a * opacity)),
      );
      _built[s] = (e, opacity, w);
      return w;
    }
    _built.remove(s);
    // Runs of equal opacity: the edges of the settled text, of each word
    // still fading and of each sentence still softening.
    final cuts = <int>{s, e};
    void cut(int x) {
      if (x > s && x < e) cuts.add(x);
    }

    cut(_settled);
    cut(_current);
    for (final w in _words) {
      cut(w.$1);
      cut(w.$2);
    }
    for (final d in _dims) {
      cut(d.$1);
      cut(d.$2);
    }
    final edges = cuts.toList()..sort();
    final runs = <TextSpan>[];
    var from = edges.first;
    var opacity = _opacityAt(from);
    for (var k = 1; k < edges.length; k++) {
      final at = edges[k];
      final next = at < e ? _opacityAt(at) : double.nan;
      if (next == opacity) continue;
      runs.add(TextSpan(
        text: _text.substring(from, at),
        style: TextStyle(color: color.withValues(alpha: color.a * opacity)),
      ));
      from = at;
      opacity = next;
    }
    return Text.rich(
      TextSpan(children: runs),
      key: ValueKey(s),
      textAlign: TextAlign.start,
      style: widget.style,
    );
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.style.color ?? const Color(0xFFFFFFFF);
    final sentences = captionSentences(_text);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, (s, e)) in sentences.indexed)
          Padding(
            key: ValueKey(s),
            padding: EdgeInsets.only(top: i == 0 ? 0 : widget.sentenceGap),
            child: _sentence(s, e, color),
          ),
      ],
    );
  }
}
