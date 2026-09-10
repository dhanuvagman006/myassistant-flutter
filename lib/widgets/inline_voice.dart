
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../design/neon_tokens.dart';
import '../features/assistant/state/assistant_engine.dart';
import '../features/assistant/state/assistant_state.dart';
import '../features/assistant/widgets/siri_orb.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  INLINE VOICE — talk to the assistant from Home, no second screen.
///
///  The dock orb becomes the assistant itself: tap and the presence orb
///  wakes in place with a soft expanding halo; captions float above the
///  dock while either side is speaking and slip away when the exchange
///  ends. Hold the orb for the live face agent.
/// ─────────────────────────────────────────────────────────────────────────

/// The dock button: a calm mic circle when idle, the live presence orb
/// with a pulsing halo while a conversation is running.
class AssistantOrbButton extends StatefulWidget {
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  const AssistantOrbButton(
      {super.key, required this.onTap, required this.onLongPress});

  @override
  State<AssistantOrbButton> createState() => _AssistantOrbButtonState();
}

class _AssistantOrbButtonState extends State<AssistantOrbButton>
    with SingleTickerProviderStateMixin {
  final engine = AssistantEngine.instance;
  late final AnimationController _halo =
      AnimationController(vsync: this, duration: const Duration(seconds: 2));

  bool get _active =>
      engine.liveActive ||
      (engine.phase != AssistantPhase.idle &&
          engine.phase != AssistantPhase.completed);

  @override
  void initState() {
    super.initState();
    engine.addListener(_sync);
    _sync();
  }

  void _sync() {
    if (!mounted) return;
    if (_active && !_halo.isAnimating) _halo.repeat();
    if (!_active && _halo.isAnimating) {
      _halo.stop();
      _halo.reset();
    }
    setState(() {});
  }

  @override
  void dispose() {
    engine.removeListener(_sync);
    _halo.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final active = _active;
    return GestureDetector(
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: SizedBox(
        width: 76,
        height: 76,
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (active)
              AnimatedBuilder(
                animation: _halo,
                builder: (_, __) =>
                    CustomPaint(size: const Size(76, 76), painter: _HaloPainter(_halo.value)),
              ),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: active
                  ? ValueListenableBuilder<double>(
                      key: const ValueKey('live'),
                      valueListenable: engine.micLevelListenable,
                      builder: (_, level, __) => SiriOrb(
                        size: 64,
                        phase: engine.phase,
                        level: level,
                        connected: true,
                      ),
                    )
                  : Container(
                      key: const ValueKey('idle'),
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Neon.textHi,
                        boxShadow: [
                          BoxShadow(
                            color: Neon.textHi.withValues(alpha: 0.28),
                            blurRadius: 18,
                            offset: const Offset(0, 6),
                          ),
                        ],
                      ),
                      child:
                          Icon(Icons.mic_rounded, color: Neon.onInk, size: 30),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Two staggered rings breathing outward from the orb.
class _HaloPainter extends CustomPainter {
  final double t;
  _HaloPainter(this.t);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    for (final phase in const [0.0, 0.5]) {
      final p = (t + phase) % 1.0;
      final radius = 30 + p * 26;
      final alpha = (1 - p) * 0.35;
      canvas.drawCircle(
        c,
        radius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.2 - p * 1.4
          ..color = Neon.violet.withValues(alpha: alpha),
      );
    }
  }

  @override
  bool shouldRepaint(_HaloPainter old) => old.t != t;
}

/// Center-screen live captions, lyrics-style: while the inline
/// conversation runs the page behind dims, and what is being said appears
/// large in the middle of the screen — the assistant's words bright, the
/// user's own words softer. Everything fades away when the session ends.
class InlineCaptionOverlay extends StatefulWidget {
  const InlineCaptionOverlay({super.key});

  @override
  State<InlineCaptionOverlay> createState() => _InlineCaptionOverlayState();
}

class _InlineCaptionOverlayState extends State<InlineCaptionOverlay> {
  final engine = AssistantEngine.instance;
  String _text = '';
  bool _fromUser = false;

  /// SPEECH-PACED REVEAL. The transcript arrives at GENERATION speed —
  /// seconds ahead of the audio — so showing it raw makes the lyrics run
  /// ahead of the voice. Instead the assistant's text is released at
  /// speaking rate, only while the voice is actually playing, and snapped
  /// to complete when the turn ends. The user's own words are already
  /// real-time and bypass pacing.
  static const double _charsPerSecond = 15;
  double _budget = 0; // characters released so far
  DateTime _lastTick = DateTime.now();
  Timer? _pacer;

  void _ensurePacer() {
    _pacer ??= Timer.periodic(const Duration(milliseconds: 200), (_) {
      final now = DateTime.now();
      final dt = now.difference(_lastTick).inMilliseconds / 1000.0;
      _lastTick = now;
      if (!mounted) return;
      final speaking = engine.phase == AssistantPhase.speaking;
      if (!_fromUser && speaking && _budget < _text.length) {
        _budget = (_budget + dt * _charsPerSecond)
            .clamp(0, _text.length.toDouble());
        setState(() {});
      } else if (!_fromUser && !speaking && !engine.phase.busy) {
        // Turn is over — whatever remains lands at once, in sync with the
        // silence, never trailing into the next exchange.
        if (_budget < _text.length) {
          _budget = _text.length.toDouble();
          setState(() {});
        }
      }
    });
  }

  /// The paced view of the text: everything for the user's own words,
  /// the released prefix (whole words) for the assistant's.
  String _visibleText() {
    if (_fromUser || _budget >= _text.length) return _text;
    var cut = _budget.floor().clamp(0, _text.length);
    // Extend to the end of the current word so words never appear cut.
    while (cut < _text.length && _text[cut] != ' ') {
      cut++;
    }
    return _text.substring(0, cut);
  }

  bool get _active =>
      engine.inlineVoice &&
      (engine.liveActive ||
          (engine.phase != AssistantPhase.idle &&
              engine.phase != AssistantPhase.completed));

  @override
  void initState() {
    super.initState();
    engine.caption.addListener(_onCaption);
    engine.addListener(_onEngine);
  }

  @override
  void dispose() {
    engine.caption.removeListener(_onCaption);
    engine.removeListener(_onEngine);
    _pacer?.cancel();
    super.dispose();
  }

  void _onCaption() {
    if (!mounted) return;
    final c = engine.caption.value;
    if (c == null || c.text.trim().isEmpty) return;
    final t = c.text.trim();
    final fromUser = c.speaker == 'you';
    setState(() {
      // A NEW turn (speaker flip, or text that isn't an extension of the
      // old) restarts the release from zero; an extension keeps pace.
      if (fromUser != _fromUser || !t.startsWith(_visibleAnchor())) {
        _budget = 0;
        _lastTick = DateTime.now();
      }
      _text = t;
      _fromUser = fromUser;
    });
    _ensurePacer();
  }

  /// A short stable prefix of the current text, used to detect whether an
  /// update extends the same turn or starts a new one.
  String _visibleAnchor() {
    final n = _text.length < 24 ? _text.length : 24;
    return _text.substring(0, n);
  }

  void _onEngine() {
    if (!mounted) return;
    // Session over → the words leave with it.
    if (!_active && _text.isNotEmpty) _text = '';
    setState(() {});
  }

  /// The whole turn as LYRIC LINES. Sentences first, then any long
  /// sentence is wrapped into ~60-character lines at word boundaries —
  /// so every line is short enough to show WHOLE, nothing is ever
  /// clipped, and a monologue scrolls upward line by line exactly like a
  /// lyrics view. The last line is what is being spoken right now.
  static const _maxLine = 60;

  List<String> _lines() {
    final out = <String>[];
    for (final sentence in _visibleText().split(RegExp(r'(?<=[.!?।…])\s+'))) {
      final t = sentence.trim();
      if (t.isEmpty) continue;
      if (t.length <= _maxLine) {
        out.add(t);
        continue;
      }
      var line = '';
      for (final w in t.split(RegExp(r'\s+'))) {
        if (line.isEmpty) {
          line = w;
        } else if (line.length + 1 + w.length <= _maxLine) {
          line = '$line $w';
        } else {
          out.add(line);
          line = w;
        }
      }
      if (line.isNotEmpty) out.add(line);
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final show = _active;
    final lines = _lines();
    final current = lines.isNotEmpty ? lines.last : '';
    final start = lines.length - 4 < 0 ? 0 : lines.length - 4;
    final previous = lines.length > 1
        ? lines.sublist(start, lines.length - 1)
        : const <String>[];
    return IgnorePointer(
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOut,
        opacity: show ? 1 : 0,
        child: Container(
          // A deep fade — the page behind must never compete with the words.
          color: Colors.black.withValues(alpha: 0.8),
          alignment: Alignment.center,
          padding: const EdgeInsets.fromLTRB(28, 80, 28, 160),
          child: AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Earlier lines recede upward, dimmed — context, not focus.
                // Lines are pre-wrapped to lyric length, so every one
                // shows WHOLE — clipping history was how real content got
                // hidden behind an ellipsis.
                for (final l in previous)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Text(
                      l,
                      textAlign: TextAlign.center,
                      style: GoogleFonts.spaceGrotesk(
                        color: Colors.white.withValues(alpha: 0.38),
                        fontSize: 19,
                        height: 1.3,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.3,
                      ),
                    ),
                  ),
                // The line being spoken RIGHT NOW — the spotlight.
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  switchInCurve: Curves.easeOut,
                  child: Text(
                    current,
                    key: ValueKey('$_fromUser|$current'),
                    textAlign: TextAlign.center,
                    style: GoogleFonts.spaceGrotesk(
                      color: _fromUser
                          ? Colors.white.withValues(alpha: 0.62)
                          : Colors.white,
                      fontSize: _fromUser ? 22 : 30,
                      height: 1.3,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
