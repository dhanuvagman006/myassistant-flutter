
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:permission_handler/permission_handler.dart';

import '../design/dock_metrics.dart';
import '../design/neon_tokens.dart';
import '../features/assistant/state/assistant_engine.dart';
import '../features/assistant/state/assistant_state.dart';
import '../services/app_feedback.dart';
import '../services/auth_service.dart';
import 'voice_orb.dart';

/// Is the full-screen voice session on screen right now? One definition
/// for the overlay, the shell's Back handling and the toast policy.
bool voiceSessionOnScreen(AssistantEngine e) =>
    e.inlineVoice &&
    (e.starting ||
        e.liveActive ||
        (e.phase != AssistantPhase.idle &&
            e.phase != AssistantPhase.completed));

/// Phases where the reply's words exist before its voice does: the paced
/// caption waits for the audio instead of running ahead of it.
bool _waitingForVoice(AssistantPhase p) => switch (p) {
      AssistantPhase.transcribing ||
      AssistantPhase.thinking ||
      AssistantPhase.searching ||
      AssistantPhase.findingContact ||
      AssistantPhase.preparingMessage ||
      AssistantPhase.generatingVoice =>
        true,
      _ => false,
    };

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
    // The app's main control had no label for screen readers.
    return Semantics(
      button: true,
      label: active ? 'Stop talking to the assistant' : 'Talk to the assistant',
      child: GestureDetector(
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      // Its own layer: the resting orb breathes forever, and without a
      // boundary every frame of that repainted the dock and the Home
      // screen behind it — on a screen otherwise sitting idle.
      child: RepaintBoundary(
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

  /// How far the top of the session's text box is from the bottom of the
  /// screen area it sits in (dp). It grows with the text (up to four
  /// lines), so answer cards and toasts that must stay clear of it read
  /// the real value instead of guessing a fixed height.
  static final ValueNotifier<double> typeBarReach = ValueNotifier<double>(0);

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
      } else if (!_fromUser && !speaking && !_waitingForVoice(engine.phase)) {
        // Turn is over — whatever remains lands at once, in sync with the
        // silence, never trailing into the next exchange. "Over" includes
        // a live session going back to LISTENING: that counts as busy, so
        // the old test never fired there and the end of a reply the voice
        // outran (often the closing question) never appeared.
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
    // Muted: there is no voice to keep pace with — the words ARE the answer.
    if (_fromUser || _budget >= _text.length || engine.speakerMuted) {
      return _text;
    }
    // Nothing released yet: keep the "Thinking…" status up instead of one
    // lonely first word sitting there until the audio starts.
    if (_budget < 1) return '';
    var cut = _budget.floor().clamp(0, _text.length);
    // Extend to the end of the current word so words never appear cut.
    while (cut < _text.length && _text[cut] != ' ') {
      cut++;
    }
    return _text.substring(0, cut);
  }

  // Up from the very first frame of a tap (engine.starting).
  bool get _active => voiceSessionOnScreen(engine);

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

  /// What the session is doing, in words — every phase, not just four.
  String _status(bool micPaused) {
    final p = engine.phase;
    if (micPaused && !_waitingForVoice(p) && p != AssistantPhase.speaking) {
      return 'Mic paused while you type';
    }
    return switch (p) {
      AssistantPhase.speaking => '',
      AssistantPhase.listening => 'Listening…',
      AssistantPhase.idle || AssistantPhase.completed =>
        engine.liveActive ? 'Listening…' : 'Connecting…',
      _ => p.label,
    };
  }

  OrbMood _mood(bool micPaused) {
    final p = engine.phase;
    if (p == AssistantPhase.speaking) return OrbMood.speaking;
    if (_waitingForVoice(p) ||
        p == AssistantPhase.dialing ||
        p == AssistantPhase.ringing) {
      return OrbMood.thinking;
    }
    // Paused for typing: the orb rests instead of pulsing with room noise.
    if (micPaused) return OrbMood.idle;
    if (p == AssistantPhase.listening) return OrbMood.listening;
    return engine.liveActive ? OrbMood.listening : OrbMood.idle;
  }

  @override
  Widget build(BuildContext context) {
    final show = _active;
    final micPaused = engine.micPausedForTyping;
    final lines = _lines();
    final current = lines.isNotEmpty ? lines.last : '';
    final start = lines.length - 4 < 0 ? 0 : lines.length - 4;
    final previous = lines.length > 1
        ? lines.sublist(start, lines.length - 1)
        : const <String>[];
    // AN INVISIBLE OVERLAY MUST NEVER EAT A TAP.
    //
    // This was IgnorePointer(always) because nothing in it was
    // touchable. It now carries a mute button and a text field, so it
    // has to accept taps — and an AnimatedOpacity at 0 still hit-tests,
    // which would have made every card on Home unclickable the moment a
    // session ended. It ignores pointers exactly while it is invisible.
    return IgnorePointer(
      ignoring: !show,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOut,
        opacity: show ? 1 : 0,
        // ROOM FOR THE KEYBOARD. Above an open keyboard a phone has ~300
        // points left, and the 330-point orb plus the dock's 120 did not
        // fit: the column overflowed — painted, but outside its own
        // bounds, where taps do not land — so the send arrow looked fine
        // and did nothing (2026-09-24). While typing, the orb shrinks and
        // the dock's space goes (the dock is hidden then). Only pad for
        // the keyboard when the space we were given did not already make
        // room for it.
        child: LayoutBuilder(builder: (context, box) {
          // From the window: the Scaffold zeroes viewInsets for its body
          // once it has lifted it, so the body's own MediaQuery says 0.
          final view = View.of(context);
          final kb = view.viewInsets.bottom / view.devicePixelRatio;
          final typing = kb > 0;
          final lifted = box.maxHeight < MediaQuery.of(context).size.height - kb / 2;
          // Clear of the dock AND the stop orb that rises 38 dp above it —
          // a fixed 120 put the orb over this bar on phones with 3-button
          // navigation (the dock grows by the system inset).
          final bottomPad = typing
              ? (lifted ? 12.0 : 12.0 + kb)
              : Dock.clearance(context, gap: 12);
          // The height actually available to this screen's content.
          final avail = lifted || !typing ? box.maxHeight : box.maxHeight - kb;
          return Container(
          // FULLY OPAQUE. At 0.82, and still at 0.94, the page ghosted
          // through: Home's headings and calendar sat faintly behind the
          // orb and read as broken layering. The session is a place, not
          // a tint — a deep night in the accent's own hue, darkest at the
          // middle where the orb glows.
          decoration: BoxDecoration(gradient: _sessionGround()),
          // The bottom padding clears the dock; while typing the dock is
          // hidden and the bar sits just above the keyboard.
          padding: EdgeInsets.fromLTRB(28, 14, 28, bottomPad),
          child: Column(
            children: [
              // MUTE — read the answer instead of hearing it.
              Padding(
                padding: EdgeInsets.only(
                    top: MediaQuery.of(context).viewPadding.top, bottom: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [_MuteButton(engine: engine)],
                ),
              ),
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
              // double.infinity, or the Stack shrinks to the orb and the
              // backdrop's edges showed as a box around it.
              SizedBox(
                width: double.infinity,
                // Smaller while typing, so everything fits above the
                // keyboard; on a short phone it gives up height to the words.
                height: typing
                    ? math.min(190.0, avail * 0.42)
                    : math.min(330.0, avail * 0.38),
                child: ValueListenableBuilder<double>(
                  valueListenable: engine.micLevelListenable,
                  builder: (_, rawLevel, __) {
                    final mood = _mood(micPaused);
                    // The level still arrives while paused (it is measured
                    // before the mute) — the orb must not react to it.
                    final level = micPaused ? 0.0 : rawLevel;
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
              SizedBox(height: typing ? 6 : 24),
              // AN ERROR SAYS WHAT WENT WRONG. The caption below maps every
              // phase it does not name to "Connecting…" — including error —
              // so a denied microphone, a failed upload and a timeout all
              // looked like a connection that never finished, and a tap on
              // the orb (which reads error as "running") just stopped it.
              if (engine.phase == AssistantPhase.error)
                Expanded(
                  flex: 7,
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: _ErrorCaption(engine: engine),
                  ),
                )
              // THE WORDS — under the orb, lyrics-style. Before any words
              // exist, the state itself is the caption: the user must
              // never stare at an empty black area wondering if it heard.
              else if (lines.isEmpty)
                Expanded(
                  flex: 7,
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 250),
                      child: Text(
                        _status(micPaused),
                        key: ValueKey(_status(micPaused)),
                        textAlign: TextAlign.center,
                        style: GoogleFonts.spaceGrotesk(
                          // Readable on the night ground (was 0.45).
                          color: Colors.white.withValues(alpha: 0.66),
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
                // Clipped to its own space: long replies once ran down over
                // the text box while the keyboard was up (2026-09-24).
                child: LayoutBuilder(
                builder: (context, area) => ShaderMask(
                // A soft top edge: when a reply is taller than its space the
                // OLDEST words fade out up there — never a hard slice.
                blendMode: BlendMode.dstIn,
                shaderCallback: (r) => const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Colors.black],
                  stops: [0.0, 1.0],
                ).createShader(Rect.fromLTWH(0, 0, r.width, 14)),
                child: ClipRect(
                // Taller than its space (a long reply, keyboard up): cut at
                // the TOP. The line being spoken now — often the question
                // the user has to answer — is the last one, so it must be
                // the one that stays; top-aligned, it was the one cut off.
                child: SingleChildScrollView(
                reverse: true,
                physics: const NeverScrollableScrollPhysics(),
                child: ConstrainedBox(
                  // Short replies still sit right under the orb.
                  constraints: BoxConstraints(minHeight: area.maxHeight),
                  child: Align(
                  alignment: Alignment.topCenter,
                  child: Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: AnimatedSize(
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOut,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // While typing there is little room: the line
                        // being spoken, nothing older.
                        for (final l in typing ? const <String>[] : previous)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: Text(
                              l,
                              textAlign: TextAlign.center,
                              style: GoogleFonts.spaceGrotesk(
                                // Older lines stay readable (was 0.38 —
                                // under 4.5:1 on the night ground).
                                color: Colors.white.withValues(alpha: 0.56),
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
                            maxLines: typing ? 3 : 6,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.spaceGrotesk(
                              color: _fromUser
                                  ? Colors.white.withValues(alpha: 0.62)
                                  : Colors.white,
                              fontSize: typing ? 17 : (_fromUser ? 19 : 24),
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
                ),
              ),
              ),
              ),
              ),
              ),
              // While captions fill the space the status line is gone, so
              // a paused mic says so right above the box it is paused for.
              if (micPaused && lines.isNotEmpty) const _MicPausedChip(),
              // TYPE INSTEAD OF TALKING. Not on the error screen, where it
              // sat under "Try again / Close" and made the screen ambiguous.
              if (engine.phase != AssistantPhase.error)
                _TypeBar(engine: engine),
            ],
          ),
          );
        }),
      ),
    );
  }
}

/// The session's ground: opaque, deep, tinted by the user's accent so it
/// belongs to their theme. Always dark — the orb and captions are drawn
/// for night, in both app themes.
LinearGradient _sessionGround() {
  final h = HSLColor.fromColor(Neon.violet);
  Color ink(double l, double s) =>
      h.withLightness(l).withSaturation(s).toColor();
  return LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [ink(0.09, 0.45), ink(0.035, 0.40), ink(0.06, 0.40)],
    stops: const [0.0, 0.5, 1.0],
  );
}

/// Mute the assistant's voice without ending the conversation — for the
/// people who would rather read the captions (his words, 2026-09-21:
/// "some will just read the caption"). It is deliberately NOT a
/// microphone mute: the session keeps listening, it just stops talking
/// back out loud.
/// What went wrong, and the one thing that fixes it. A permission problem
/// is fixed in Settings; anything else by starting over.
class _ErrorCaption extends StatelessWidget {
  const _ErrorCaption({required this.engine});
  final AssistantEngine engine;

  @override
  Widget build(BuildContext context) {
    final message = (engine.errorMessage ?? '').trim().isEmpty
        ? 'Something went wrong.'
        : engine.errorMessage!.trim();
    final needsSettings = message.toLowerCase().contains('permission');
    // Scrolls rather than overflows: under the 330 px orb, a small phone or
    // large system text leaves little height for a message and two buttons.
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            needsSettings ? Icons.mic_off_rounded : Icons.error_outline_rounded,
            color: Neon.error,
            size: 26,
            semanticLabel: 'Problem',
          ),
          const SizedBox(height: 10),
          Text(
            message,
            textAlign: TextAlign.center,
            style: GoogleFonts.spaceGrotesk(
              color: Colors.white.withValues(alpha: 0.88),
              fontSize: 16,
              height: 1.3,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 18),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 10,
            runSpacing: 10,
            children: [
              if (needsSettings)
                _PillButton(
                  label: 'Open settings',
                  primary: true,
                  onTap: () => openAppSettings(),
                )
              else
                _PillButton(
                  label: 'Try again',
                  primary: true,
                  onTap: () async {
                    await engine.endInlineConversation();
                    engine.dismissError();
                    await engine.beginInlineConversation(
                        name: AuthService.instance.user?.name);
                  },
                ),
              _PillButton(
                label: 'Close',
                onTap: () async {
                  await engine.endInlineConversation();
                  engine.dismissError();
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PillButton extends StatelessWidget {
  const _PillButton({required this.label, required this.onTap, this.primary = false});
  final String label;
  final VoidCallback onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        child: Container(
          // 48 dp tall: a comfortable target, as every tap target should be.
          constraints: const BoxConstraints(minHeight: 48, minWidth: 96),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: primary
                ? Neon.violet.withValues(alpha: 0.22)
                : Colors.white.withValues(alpha: 0.07),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: primary
                  ? Neon.violet.withValues(alpha: 0.7)
                  : Colors.white.withValues(alpha: 0.16),
            ),
          ),
          child: Text(
            label,
            style: GoogleFonts.spaceGrotesk(
              color: primary ? Colors.white : Colors.white.withValues(alpha: 0.8),
              fontSize: 14.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}

class _MuteButton extends StatelessWidget {
  const _MuteButton({required this.engine});
  final AssistantEngine engine;

  @override
  Widget build(BuildContext context) {
    final muted = engine.speakerMuted;
    return Semantics(
      button: true,
      label: muted ? 'Unmute the assistant' : 'Mute the assistant',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          HapticFeedback.selectionClick();
          engine.setSpeakerMuted(!muted);
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          // 44 dp tall: a comfortable target (was ~36).
          constraints: const BoxConstraints(minHeight: 44),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            color: muted
                ? Neon.violet.withValues(alpha: 0.20)
                : Colors.white.withValues(alpha: 0.07),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: muted
                  ? Neon.violet.withValues(alpha: 0.65)
                  : Colors.white.withValues(alpha: 0.14),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(
                muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                size: 18,
                color: muted ? Neon.violet : Colors.white.withValues(alpha: 0.75),
              ),
              const SizedBox(width: 7),
              Text(
                // "Sound" alone read as either a state or an action.
                muted ? 'Muted' : 'Sound on',
                style: GoogleFonts.spaceGrotesk(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.1,
                  color: muted ? Neon.violet : Colors.white.withValues(alpha: 0.75),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shown above the text box while the microphone is paused for typing and
/// captions have pushed the status line off the screen.
class _MicPausedChip extends StatelessWidget {
  const _MicPausedChip();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.mic_off_rounded,
              size: 15, color: Colors.white.withValues(alpha: 0.66)),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              'Mic paused while you type',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.spaceGrotesk(
                color: Colors.white.withValues(alpha: 0.66),
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Type a message into a live conversation.
///
/// His ask, 2026-09-21: "add a beautiful text bar where user can type and
/// send instead of speaking into the app". For a name the mic keeps
/// mishearing, a long number, or a room where you cannot speak.
///
/// It goes down the SAME live socket the voice uses, not a second
/// conversation beside it — see AssistantEngine.sendTypedMessage.
class _TypeBar extends StatefulWidget {
  const _TypeBar({required this.engine});
  final AssistantEngine engine;

  @override
  State<_TypeBar> createState() => _TypeBarState();
}

class _TypeBarState extends State<_TypeBar> with WidgetsBindingObserver {
  final _c = TextEditingController();
  final _focus = FocusNode();
  bool _has = false;
  double _lastKb = 0;

  AssistantEngine get _engine => widget.engine;

  /// Connecting: a message sent now would start a second, classic
  /// conversation beside the live one that is still coming up.
  bool get _connecting => _engine.starting && !_engine.liveActive;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _c.addListener(() {
      final has = _c.text.trim().isNotEmpty;
      if (has != _has) setState(() => _has = has);
      WidgetsBinding.instance.addPostFrameCallback((_) => _report());
    });
    _focus.addListener(() {
      _engine.setTyping(_focus.hasFocus);
      if (mounted) setState(() {}); // the pill lights up while typing
    });
    _engine.addListener(_onEngine);
  }

  /// THE MIC COMES BACK WITH THE SESSION'S END. The overlay stays mounted
  /// (it only fades out), so a focused field used to outlive the session:
  /// the keyboard stayed up over Home typing into nothing, and the paused
  /// mic carried into the next session.
  void _onEngine() {
    if (!mounted) return;
    if (_focus.hasFocus && !voiceSessionOnScreen(_engine)) _focus.unfocus();
    setState(() {}); // connecting ↔ live changes the hint
  }

  /// Back closes the keyboard without taking the focus away — and the
  /// focus is what holds the mic paused. Keyboard gone = done typing.
  @override
  void didChangeMetrics() {
    if (!mounted) return;
    final view = View.maybeOf(context);
    if (view == null) return;
    final kb = view.viewInsets.bottom;
    if (_lastKb > 0 && kb == 0 && _focus.hasFocus) _focus.unfocus();
    _lastKb = kb;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _engine.removeListener(_onEngine);
    _engine.setTyping(false);
    _c.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Publishes where this box reaches (see InlineCaptionOverlay
  /// .typeBarReach), and the toast margin that keeps a toast above it.
  void _report() {
    if (!mounted) return;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize || !box.attached) return;
    final view = View.of(context);
    final kb = view.viewInsets.bottom / view.devicePixelRatio;
    final bodyBottom = view.physicalSize.height / view.devicePixelRatio - kb;
    // The pill starts below this widget's 14 dp top gap.
    final top = box.localToGlobal(Offset.zero).dy + 14;
    final reach = bodyBottom - top;
    if (reach <= 0) return;
    InlineCaptionOverlay.typeBarReach.value = reach;
    // A floating toast stands on the mic's top edge (or, with the keyboard
    // up and the mic hidden, on the keyboard): lift it past the box.
    final base = kb > 0 ? 0.0 : MediaQuery.paddingOf(context).bottom + Dock.orbRise;
    AppFeedback.sessionMargin = math.max(10.0, reach - base + 8);
  }

  void _send() {
    final t = _c.text.trim();
    if (t.isEmpty || _connecting) return;
    HapticFeedback.lightImpact();
    _c.clear();
    // The keyboard stays up: people type two things in a row far more
    // often than they type one and walk away.
    _engine.sendTypedMessage(t);
  }

  /// ENTER SENDS. A multi-line field tells Android it is multi-line, and
  /// the keyboard's Send key then types a newline instead (2026-09-24,
  /// s5.png). The field is declared single-line text (it still wraps to
  /// four lines on screen); a newline that arrives anyway — a keyboard
  /// that ignores the action, or pasted text — is handled here: typed, it
  /// sends; pasted, it becomes a space so the message stays one message.
  late final TextInputFormatter _enterSends =
      TextInputFormatter.withFunction((oldV, newV) {
    if (!newV.text.contains('\n') && !newV.text.contains('\r')) return newV;
    final typedOne = newV.text.length == oldV.text.length + 1 &&
        !oldV.text.contains('\n');
    if (typedOne) {
      // The text is unchanged, so nothing else asks for a frame: ask for
      // one, or the send would wait for the next cursor blink.
      WidgetsBinding.instance
        ..addPostFrameCallback((_) {
          if (mounted) _send();
        })
        ..ensureVisualUpdate();
      return oldV;
    }
    final flat = newV.text.replaceAll(RegExp(r'[\r\n]+'), ' ');
    return TextEditingValue(
      text: flat,
      selection: TextSelection.collapsed(offset: flat.length),
    );
  });

  @override
  Widget build(BuildContext context) {
    // ONE PILL. The field used to draw a second box inside this one: the
    // app theme gives every TextField a fill and an outline, and
    // `border: none` alone does not switch off the enabled/focused ones.
    final focused = _focus.hasFocus;
    final connecting = _connecting;
    final canSend = _has && !connecting;
    WidgetsBinding.instance.addPostFrameCallback((_) => _report());
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        constraints: const BoxConstraints(minHeight: 54),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: focused ? 0.10 : 0.07),
          borderRadius: BorderRadius.circular(28),
          border: Border.all(
            color: focused
                ? Neon.violet.withValues(alpha: 0.55)
                : Colors.white.withValues(alpha: 0.10),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(16, 3, 3, 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Icon(Icons.keyboard_alt_outlined,
                  size: 20, color: Colors.white.withValues(alpha: 0.40)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: _c,
                focusNode: _focus,
                minLines: 1,
                maxLines: 4,
                // Single-line text to the keyboard: Enter is Send.
                keyboardType: TextInputType.text,
                textInputAction: TextInputAction.send,
                textCapitalization: TextCapitalization.sentences,
                inputFormatters: [_enterSends],
                onSubmitted: (_) => _send(),
                // Keeps the keyboard up after sending, like the arrow does.
                onEditingComplete: () {},
                keyboardAppearance: Brightness.dark,
                cursorColor: Neon.violet,
                style: GoogleFonts.spaceGrotesk(
                  color: Colors.white,
                  fontSize: 15.5,
                  fontWeight: FontWeight.w500,
                ),
                decoration: InputDecoration(
                  isDense: true,
                  filled: false,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  disabledBorder: InputBorder.none,
                  hintText: connecting ? 'Connecting…' : 'Type a message…',
                  hintStyle: GoogleFonts.spaceGrotesk(
                    color: Colors.white.withValues(alpha: 0.45),
                    fontSize: 15.5,
                    fontWeight: FontWeight.w500,
                  ),
                  contentPadding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
            const SizedBox(width: 5),
            // 48 dp to the finger, 42 dp to the eye.
            Semantics(
              button: true,
              enabled: canSend,
              label: 'Send',
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: canSend ? _send : null,
                child: SizedBox(
                  width: 48,
                  height: 48,
                  child: Center(
                    child: AnimatedScale(
                      duration: const Duration(milliseconds: 160),
                      scale: canSend ? 1 : 0.9,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 160),
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: canSend ? Neon.gBrand : null,
                          color: canSend
                              ? null
                              : Colors.white.withValues(alpha: 0.08),
                        ),
                        child: Icon(Icons.arrow_upward_rounded,
                            color: Colors.white
                                .withValues(alpha: canSend ? 1 : 0.35),
                            size: 21),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
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
  const AnswerAfterglow({super.key, this.dismissOn});

  /// Fires when the card no longer belongs on screen (HomeShell: a tab
  /// switch — the answer was about the screen being left).
  final Listenable? dismissOn;

  @override
  State<AnswerAfterglow> createState() => _AnswerAfterglowState();
}

class _AnswerAfterglowState extends State<AnswerAfterglow> {
  final engine = AssistantEngine.instance;
  bool _wasActive = false;
  String? _text;
  Timer? _hide;

  /// THIS session's last answer, from its captions. A live reply is shown
  /// as captions and never written to the transcript, so reading the
  /// transcript re-showed an OLDER answer (or a relayed message) after
  /// every live session.
  String? _lastAnswer;
  int _transcriptMark = 0;

  @override
  void initState() {
    super.initState();
    engine.addListener(_sync);
    engine.caption.addListener(_onCaption);
    widget.dismissOn?.addListener(_close);
    AppFeedback.changes.addListener(_onToast);
  }

  @override
  void didUpdateWidget(AnswerAfterglow old) {
    super.didUpdateWidget(old);
    if (old.dismissOn != widget.dismissOn) {
      old.dismissOn?.removeListener(_close);
      widget.dismissOn?.addListener(_close);
    }
  }

  @override
  void dispose() {
    engine.removeListener(_sync);
    engine.caption.removeListener(_onCaption);
    widget.dismissOn?.removeListener(_close);
    AppFeedback.changes.removeListener(_onToast);
    _hide?.cancel();
    super.dispose();
  }

  void _onToast() {
    if (mounted) setState(() {});
  }

  void _close() {
    _hide?.cancel();
    if (mounted && _text != null) setState(() => _text = null);
  }

  void _onCaption() {
    final c = engine.caption.value;
    if (c == null || c.speaker == 'you') return;
    final t = c.text.trim();
    if (t.isNotEmpty && voiceSessionOnScreen(engine)) _lastAnswer = t;
  }

  void _sync() {
    if (!mounted) return;
    final active = voiceSessionOnScreen(engine);
    if (active && !_wasActive) {
      // A new session: forget the last one's answer.
      _lastAnswer = null;
      _transcriptMark = engine.transcript.length;
    }
    if (active && _text != null) {
      // A new session replaces the old afterglow immediately.
      _close();
    }
    if (_wasActive && !active) {
      var last = _lastAnswer;
      if (last == null) {
        // Classic turns write to the transcript — but only THIS session's.
        final t = engine.transcript;
        for (var i = t.length - 1; i >= _transcriptMark && i >= 0; i--) {
          if (t[i].role == TranscriptRole.assistant &&
              t[i].text.trim().isNotEmpty) {
            last = t[i].text.trim();
            break;
          }
        }
      }
      _lastAnswer = null;
      // Only a real answer earns an afterglow — never the greeting alone.
      if (last != null && last.length > 12 && !last.endsWith('?')) {
        setState(() => _text = last);
        _hide?.cancel();
        _hide = Timer(const Duration(seconds: 12), () {
          if (mounted) setState(() => _text = null);
        });
      }
    }
    _wasActive = active;
    // A result card is showing: it is the answer on screen — one card.
    if (_text != null && _cardShowing) setState(() {});
  }

  bool get _cardShowing =>
      engine.pendingConfirmation != null ||
      engine.presentedText != null ||
      engine.searchResults.isNotEmpty ||
      engine.generatedImage != null;

  @override
  Widget build(BuildContext context) {
    final t = _cardShowing ? null : _text;
    // Above the dock and the mic, and above the toast while one is up.
    final bottom =
        AppFeedback.clearOfToast(Dock.clearance(context, gap: 12));
    return IgnorePointer(
      ignoring: t == null,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 300),
        opacity: t == null ? 0 : 1,
        child: Align(
          alignment: Alignment.bottomCenter,
          child: AnimatedPadding(
            duration: const Duration(milliseconds: 200),
            padding: EdgeInsets.only(left: 16, right: 16, bottom: bottom),
            child: t == null
                ? const SizedBox.shrink()
                : Container(
                    padding: const EdgeInsets.fromLTRB(14, 4, 2, 4),
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
                          padding: const EdgeInsets.only(top: 10),
                          child: Icon(Icons.auto_awesome,
                              size: 15, color: Neon.violet),
                        ),
                        const SizedBox(width: 9),
                        Flexible(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
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
                        ),
                        // A real target (was a 16 px icon, ~24 dp to tap).
                        IconButton(
                          tooltip: 'Dismiss',
                          constraints: const BoxConstraints(
                              minWidth: 44, minHeight: 44),
                          padding: EdgeInsets.zero,
                          onPressed: _close,
                          icon: Icon(Icons.close_rounded,
                              size: 18, color: Neon.textDim),
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
