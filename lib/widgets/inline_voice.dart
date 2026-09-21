
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../design/neon_tokens.dart';
import '../features/assistant/state/assistant_engine.dart';
import '../features/assistant/state/assistant_state.dart';
import 'voice_orb.dart';

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
    with TickerProviderStateMixin {
  final engine = AssistantEngine.instance;
  late final AnimationController _halo =
      AnimationController(vsync: this, duration: const Duration(seconds: 2));

  /// Slow breathing on the RESTING orb — the assistant's presence, not a
  /// decoration. ±2% over 4 s; TickerMode pauses it when offstage.
  late final AnimationController _breath = AnimationController(
      vsync: this, duration: const Duration(seconds: 4), lowerBound: 0.98,
      upperBound: 1.02)
    ..repeat(reverse: true);

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
    _breath.dispose();
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
                  // The big centre orb carries the session now; a second
                  // waveform down here was redundant noise. During a
                  // session this button has ONE job and now looks like
                  // it: stop.
                  ? Container(
                      key: const ValueKey('live'),
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Neon.surfaceHigh,
                        border: Border.all(
                            color: Neon.violet.withValues(alpha: 0.7),
                            width: 2),
                      ),
                      child: Icon(Icons.stop_rounded,
                          color: Neon.textHi, size: 30),
                    )
                  : ScaleTransition(
                      key: const ValueKey('idle'),
                      scale: _breath,
                      child: Container(
                        width: 64,
                        height: 64,
                        // THE MIC IS THE APP. A plain white puck was the
                        // single biggest piece of "this looks unfinished"
                        // on every screen — it now wears the brand
                        // gradient and throws its own light.
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: Neon.gBrand,
                          boxShadow: [
                            BoxShadow(
                              color: Neon.violet.withValues(alpha: 0.55),
                              blurRadius: 26,
                              spreadRadius: 1,
                              offset: const Offset(0, 8),
                            ),
                            BoxShadow(
                              color: Neon.pink.withValues(alpha: 0.30),
                              blurRadius: 18,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: const Icon(Icons.mic_rounded,
                            color: Colors.white, size: 30),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Two staggered rings breathing outward from the orb. Radii scale with
/// the painted size, so the same painter serves the 76 px dock orb and
/// the large centre-screen orb.
class _HaloPainter extends CustomPainter {
  final double t;
  _HaloPainter(this.t);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final s = size.shortestSide / 2;
    for (final phase in const [0.0, 0.5]) {
      final p = (t + phase) % 1.0;
      final radius = s * (0.79 + p * 0.68);
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

class _InlineCaptionOverlayState extends State<InlineCaptionOverlay>
    with SingleTickerProviderStateMixin {
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
      (engine.starting || // overlay up from the very first frame of a tap
          engine.liveActive ||
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
          // A NEAR-SOLID fade. At 0.82 the page ghosted through and its
          // text collided with the orb and rings — on pure black it read
          // as broken layering. The session is a place, not a tint.
          color: Colors.black.withValues(alpha: 0.94),
          padding: const EdgeInsets.fromLTRB(28, 60, 28, 120),
          child: Column(
            children: [
              const Spacer(flex: 5),
              // THE PRESENCE — the orb from the reference design: a
              // glossy mint sphere in a tunnel of rings that runs off
              // both edges of the screen, teal on the left and magenta
              // on the right. See widgets/voice_orb.dart.
              //
              // FULL WIDTH ON PURPOSE. The rings reach both edges in the
              // reference; boxing them into the old 330 px square is what
              // would make this read as a small copy of it. The padding
              // the overlay puts on its text does not apply here, so the
              // backdrop is pulled out to the screen edges.
              SizedBox(
                height: 330,
                child: ValueListenableBuilder<double>(
                  valueListenable: engine.micLevelListenable,
                  builder: (_, level, __) {
                    final mood = switch (engine.phase) {
                      AssistantPhase.listening => OrbMood.listening,
                      AssistantPhase.thinking ||
                      AssistantPhase.searching =>
                        OrbMood.thinking,
                      AssistantPhase.speaking => OrbMood.speaking,
                      _ => engine.liveActive ? OrbMood.listening : OrbMood.idle,
                    };
                    return Stack(
                      alignment: Alignment.center,
                      clipBehavior: Clip.none,
                      children: [
                        if (show)
                          Positioned(
                            left: -28,
                            right: -28,
                            top: 0,
                            bottom: 0,
                            child: VoiceOrbBackdrop(
                              orbSize: 168,
                              mood: mood,
                              level: level,
                            ),
                          ),
                        VoiceOrb(size: 168, mood: mood, level: level),
                      ],
                    );
                  },
                ),
              ),
              const SizedBox(height: 24),
              // THE WORDS — under the orb, lyrics-style. Before any words
              // exist, the state itself is the caption: the user must
              // never stare at an empty black area wondering if it heard.
              if (lines.isEmpty)
                Expanded(
                  flex: 7,
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 250),
                      child: Text(
                        switch (engine.phase) {
                          AssistantPhase.listening => 'Listening…',
                          AssistantPhase.thinking ||
                          AssistantPhase.searching =>
                            'Thinking…',
                          AssistantPhase.speaking => '',
                          _ => engine.liveActive
                              ? 'Listening…'
                              : 'Connecting…',
                        },
                        key: ValueKey('${engine.phase}|${engine.liveActive}'),
                        style: GoogleFonts.spaceGrotesk(
                          color: Colors.white.withValues(alpha: 0.45),
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.3,
                        ),
                      ),
                    ),
                  ),
                )
              else
              Expanded(
                flex: 7,
                child: Align(
                  alignment: Alignment.topCenter,
                  child: AnimatedSize(
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOut,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final l in previous)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: Text(
                              l,
                              textAlign: TextAlign.center,
                              style: GoogleFonts.spaceGrotesk(
                                color: Colors.white.withValues(alpha: 0.38),
                                fontSize: 15.5,
                                height: 1.3,
                                fontWeight: FontWeight.w600,
                                letterSpacing: -0.2,
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
                              fontSize: _fromUser ? 19 : 24,
                              height: 1.3,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.4,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// THE ANSWER OUTLIVES THE VOICE. When an inline session ends, its last
/// spoken reply lingers as a small card above the dock — spoken words
/// evaporate, and "what did it just say?" was a real complaint. Dismiss
/// with the ✕ or let it fade on its own.
class AnswerAfterglow extends StatefulWidget {
  const AnswerAfterglow({super.key});

  @override
  State<AnswerAfterglow> createState() => _AnswerAfterglowState();
}

class _AnswerAfterglowState extends State<AnswerAfterglow> {
  final engine = AssistantEngine.instance;
  bool _wasActive = false;
  String? _text;
  Timer? _hide;

  @override
  void initState() {
    super.initState();
    engine.addListener(_sync);
  }

  @override
  void dispose() {
    engine.removeListener(_sync);
    _hide?.cancel();
    super.dispose();
  }

  void _sync() {
    if (!mounted) return;
    final active = engine.inlineVoice &&
        (engine.starting ||
            engine.liveActive ||
            (engine.phase != AssistantPhase.idle &&
                engine.phase != AssistantPhase.completed));
    if (active && _text != null) {
      // A new session replaces the old afterglow immediately.
      _hide?.cancel();
      setState(() => _text = null);
    }
    if (_wasActive && !active) {
      String? last;
      for (final t in engine.transcript.reversed) {
        if (t.role == TranscriptRole.assistant && t.text.trim().isNotEmpty) {
          last = t.text.trim();
          break;
        }
      }
      // Only a real answer earns an afterglow — never the greeting alone.
      if (last != null && last.length > 12 && !last.endsWith('?')) {
        setState(() => _text = last);
        _hide?.cancel();
        _hide = Timer(const Duration(seconds: 14), () {
          if (mounted) setState(() => _text = null);
        });
      }
    }
    _wasActive = active;
  }

  @override
  Widget build(BuildContext context) {
    final t = _text;
    return IgnorePointer(
      ignoring: t == null,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 300),
        opacity: t == null ? 0 : 1,
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: EdgeInsets.only(
                left: 16,
                right: 16,
                bottom: 116 + MediaQuery.of(context).viewPadding.bottom),
            child: t == null
                ? const SizedBox.shrink()
                : Container(
                    padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
                    decoration: BoxDecoration(
                      color: Neon.surfaceHigh,
                      borderRadius: BorderRadius.circular(Neon.rMd),
                      border: Border.all(color: Neon.line),
                      boxShadow: Neon.cardShadow,
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Icon(Icons.auto_awesome,
                              size: 15, color: Neon.violet),
                        ),
                        const SizedBox(width: 9),
                        Flexible(
                          child: Text(
                            t,
                            maxLines: 4,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: Neon.textHi,
                                fontSize: 13,
                                height: 1.4),
                          ),
                        ),
                        InkWell(
                          onTap: () => setState(() => _text = null),
                          child: Padding(
                            padding: const EdgeInsets.all(4),
                            child: Icon(Icons.close_rounded,
                                size: 16, color: Neon.textDim),
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

