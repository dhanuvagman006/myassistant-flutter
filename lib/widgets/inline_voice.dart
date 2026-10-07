import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart' show ImageSource;
import 'package:permission_handler/permission_handler.dart';

import '../core/log.dart';
import '../design/dock_metrics.dart';
import '../design/motion.dart';
import '../design/neon_tokens.dart';
import '../features/assistant/state/assistant_engine.dart';
import '../features/assistant/state/assistant_state.dart';
import '../services/app_feedback.dart';
import '../services/assistant_identity.dart';
import '../services/auth_service.dart';
import 'caption_scroll.dart';
import 'streaming_caption.dart';
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
      AssistantPhase.responding ||
      AssistantPhase.searching ||
      AssistantPhase.findingContact ||
      AssistantPhase.preparingMessage ||
      AssistantPhase.generatingVoice =>
        true,
      _ => false,
    };

/// The orb's state for what the engine is doing (2026-09-30, the six
/// states). A tool at work is RESPONDING, working the answer out is
/// THINKING, a turn that landed on the fast voice is DONE for its 450 ms,
/// and the mic paused for typing holds still.
OrbMood orbMoodFor(AssistantEngine e, {bool micPaused = false}) {
  final p = e.phase;
  // HER HELLO COVERS THE CONNECT (2026-10-04): while it plays she is
  // speaking; after it, the orb is awake, never the dim "waiting" rest.
  if (e.greetingPlaying) return OrbMood.speaking;
  if (p == AssistantPhase.speaking) return OrbMood.speaking;
  // Until her first word (2026-10-06, the owner: "add the connecting
  // animation"): the ~1.5 s GPT-Live takes to start shows as connecting.
  if (e.connecting || e.openingPending) return OrbMood.connecting;
  if (p == AssistantPhase.responding ||
      p == AssistantPhase.searching ||
      p == AssistantPhase.findingContact) {
    return OrbMood.responding;
  }
  if (_waitingForVoice(p) ||
      p == AssistantPhase.dialing ||
      p == AssistantPhase.ringing) {
    return OrbMood.thinking;
  }
  if (p == AssistantPhase.completed && e.liveActive) return OrbMood.done;
  // Paused for typing: the orb rests instead of pulsing with room noise.
  if (micPaused) return OrbMood.paused;
  if (p == AssistantPhase.listening) return OrbMood.listening;
  return e.liveActive ? OrbMood.listening : OrbMood.idle;
}

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

  // NO BREATHING AT REST (2026-09-24). The resting mic used to breathe
  // ±2% forever. Its own layer kept that cheap to paint, but a ticker that
  // never stops still makes the phone draw a whole frame 60 times a
  // second — the idle Home was measured doing exactly that. The mic now
  // moves when something happens: the halo while a session runs, and a
  // dip under the finger.

  // Matches the shell's tap rule: whenever a tap would STOP, the orb looks
  // live — never a resting mic that secretly ends a session.
  bool get _active =>
      engine.starting ||
      engine.inlineVoice ||
      engine.liveActive ||
      (engine.phase != AssistantPhase.idle &&
          engine.phase != AssistantPhase.completed);

  /// "Remove animations" is on: the halo is a still ring, not a loop.
  bool _still = false;

  @override
  void initState() {
    super.initState();
    engine.addListener(_sync);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _still = Motion.reduced(context);
    _sync();
  }

  void _sync() {
    if (!mounted) return;
    final loop = _active && !_still;
    if (loop && !_halo.isAnimating) _halo.repeat();
    if (!loop && _halo.isAnimating) {
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
    // The halo wears the state's colour (2026-09-30): cyan listening,
    // violet thinking, magenta working, pink speaking, green done.
    final tone =
        orbMoodColor(orbMoodFor(engine, micPaused: engine.micPausedForTyping));
    // The app's main control had no label for screen readers.
    return Semantics(
      button: true,
      label: active ? 'Stop talking to the assistant' : 'Talk to the assistant',
      child: GestureDetector(
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        // Its own layer: the halo animates for a whole session, and without
        // a boundary every frame of that repainted the dock and the screen
        // behind it.
        child: RepaintBoundary(
          // BACK INTO ITS NOTCH QUIETLY (2026-09-24). The mic leaves while the
          // keyboard is up; it used to come back through the Scaffold's stock
          // entrance, spinning 45° as it grew. It now fades in as it grows
          // from 85%, once, when it returns (and at launch).
          child: EnterOnce(
            duration: Motion.short,
            scaleFrom: 0.85,
            // The press is the acknowledgement: it dips under the finger (a
            // Listener, so the tap and the hold above still get the gesture).
            child: PressScale(
              child: SizedBox(
                width: 76,
                height: 76,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    if (active)
                      AnimatedBuilder(
                        animation: _halo,
                        // The rings fade in over their first 250 ms instead of
                        // popping in at full strength (the loop is one long run,
                        // so its elapsed time is the time since the session began).
                        builder: (_, __) => CustomPaint(
                            size: const Size(76, 76),
                            painter: _HaloPainter(
                              tone,
                              _still ? 0.25 : _halo.value,
                              _still
                                  ? 1.0
                                  : ((_halo.lastElapsedDuration
                                                  ?.inMilliseconds ??
                                              0) /
                                          250)
                                      .clamp(0.0, 1.0),
                            )),
                      ),
                    // MIC TO STOP: one grows out as the other fades (2026-09-24).
                    // It was a linear 250 ms cross-fade between a gradient disc
                    // and a grey one, which looked muddy half-way.
                    AnimatedSwitcher(
                      duration: Motion.short,
                      switchInCurve: Motion.easeEnter,
                      switchOutCurve: Motion.easeFadeOut,
                      transitionBuilder: (child, a) => FadeTransition(
                        opacity: a,
                        child: ScaleTransition(
                          scale:
                              Tween<double>(begin: 0.85, end: 1.0).animate(a),
                          filterQuality: FilterQuality.medium,
                          child: child,
                        ),
                      ),
                      child: active
                          // The big centre orb carries the session now; a second
                          // waveform down here was redundant noise. During a
                          // session this button has ONE job and now looks like
                          // it: stop. A lit rim in the state's colour, the stop
                          // glyph on the night inside it (2026-09-30).
                          ? Container(
                              key: const ValueKey('live'),
                              width: 64,
                              height: 64,
                              padding: const EdgeInsets.all(2.2),
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                gradient: SweepGradient(colors: [
                                  tone,
                                  Neon.violet,
                                  Neon.pink,
                                  tone
                                ]),
                                boxShadow: Neon.halo(tone, strength: 0.9),
                              ),
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: Neon.surfaceHigh,
                                ),
                                child: Icon(Icons.stop_rounded,
                                    color: Neon.textHi, size: 30),
                              ),
                            )
                          : Container(
                              key: const ValueKey('idle'),
                              width: 64,
                              height: 64,
                              // THE MIC IS THE APP. A plain white puck was the
                              // single biggest piece of "this looks unfinished"
                              // on every screen — it now wears the brand
                              // gradient and throws its own light.
                              // A RING OF LIGHT (2026-09-30, the client's
                              // reference): cyan through the accent into magenta
                              // round a deep-navy centre, glowing.
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                gradient: SweepGradient(colors: [
                                  Neon.cyan,
                                  Neon.violet,
                                  Neon.pink,
                                  Neon.cyan,
                                ]),
                                boxShadow: [
                                  ...Neon.halo(Neon.violet, strength: 1.2),
                                  BoxShadow(
                                    color: Neon.pink.withValues(alpha: 0.30),
                                    blurRadius: 18,
                                    offset: const Offset(0, 2),
                                  ),
                                ],
                              ),
                              padding: const EdgeInsets.all(3.5),
                              // The deep-navy centre from the tokens (2026-09-30:
                              // it was two hard-coded navies), lit a touch by the
                              // accent where the light falls.
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  gradient: RadialGradient(
                                    center: const Alignment(-0.3, -0.4),
                                    colors: [
                                      Color.alphaBlend(
                                          Neon.violet.withValues(alpha: 0.16),
                                          Neon.surfaceHigh),
                                      Neon.surface,
                                    ],
                                  ),
                                ),
                                child: Icon(Icons.mic_rounded,
                                    color: Neon.textHi, size: 30),
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
    );
  }
}

/// Two staggered rings breathing outward from the orb. Radii scale with
/// the painted size, so the same painter serves the 76 px dock orb and
/// the large centre-screen orb.
class _HaloPainter extends CustomPainter {
  /// The state's colour (see [orbMoodColor]).
  final Color color;
  final double t;

  /// 0..1: how far the rings have faded in.
  final double strength;
  _HaloPainter(this.color, this.t, [this.strength = 1.0]);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final s = size.shortestSide / 2;
    for (final phase in const [0.0, 0.5]) {
      final p = (t + phase) % 1.0;
      final radius = s * (0.79 + p * 0.68);
      final alpha = (1 - p) * 0.35 * strength;
      canvas.drawCircle(
        c,
        radius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.2 - p * 1.4
          ..color = color.withValues(alpha: alpha),
      );
    }
  }

  @override
  bool shouldRepaint(_HaloPainter old) =>
      old.t != t || old.strength != strength || old.color != color;
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

  /// True while the session covers the page completely: faded all the way
  /// in, and not yet fading out. The session's ground is opaque, so the
  /// page under it cannot be seen — HomeShell stops PAINTING it then (the
  /// tabs, their blurred glass cards, the ambient light), which the phone
  /// used to redraw on every frame of the orb for nothing. It turns false
  /// on the very frame the session starts to leave, so the page is back
  /// before any of it shows through.
  static final ValueNotifier<bool> covering = ValueNotifier<bool>(false);

  @override
  State<InlineCaptionOverlay> createState() => _InlineCaptionOverlayState();
}

/// The disc's diameter on the voice screen, and the square the disc and
/// its rim's light are laid out in. The rings round it need
/// [VoiceOrbBackdrop.reach] times the disc (see the slot below).
const double _orbSize = 168;
const double _orbBox = _orbSize * 1.08;

class _InlineCaptionOverlayState extends State<InlineCaptionOverlay>
    with SingleTickerProviderStateMixin {
  final engine = AssistantEngine.instance;
  String _text = '';
  bool _fromUser = false;

  /// Counts turns (bumped where the paced release restarts): a new turn is
  /// a new passage, which cross-fades in over the last one.
  int _turn = 0;

  /// SPEECH-PACED REVEAL. The transcript arrives at GENERATION speed —
  /// seconds ahead of the audio — so showing it raw makes the lyrics run
  /// ahead of the voice. Instead the assistant's text is released at
  /// speaking rate, only while the voice is actually playing, and snapped
  /// to complete when the turn ends. The user's own words are already
  /// real-time and bypass pacing.
  static const double _charsPerSecond = 15;
  double _budget = 0; // characters released so far
  static const Duration _pace = Duration(milliseconds: 200);
  int _ticksSeen = 0;
  Timer? _pacer;

  void _ensurePacer() {
    _pacer ??= Timer.periodic(_pace, (t) {
      // Counted in the timer's own ticks, not by the wall clock: a late
      // tick still reports every interval it covers (Timer.tick), and the
      // pace is the same on the phone and under test.
      final dt = (t.tick - _ticksSeen) * _pace.inMilliseconds / 1000.0;
      _ticksSeen = t.tick;
      if (!mounted) return;
      final speaking = engine.phase == AssistantPhase.speaking;
      if (!_fromUser && speaking && _budget < _text.length) {
        _budget =
            (_budget + dt * _releaseRate()).clamp(0, _text.length.toDouble());
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

  /// Characters a second to release the reply at: speaking rate, until the
  /// whole reply has arrived — then just fast enough that the last word
  /// lands with the last of the voice (2026-09-25, streaming captions).
  /// Whatever the pace left over used to wait for the silence and then
  /// appear all at once: a burst of words after she had stopped talking.
  double _releaseRate() {
    if (!engine.replyComplete) return _charsPerSecond;
    final left = _text.length - _budget;
    // What is still to be heard, less a beat so the words finish first.
    final secs =
        math.max(engine.speakingRemaining.inMilliseconds / 1000 - 0.2, 0.3);
    return (left / secs).clamp(_charsPerSecond, _charsPerSecond * 3).toDouble();
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
    // The tool's own words while one runs ("Checking your calendar…")
    // can change without the phase changing.
    engine.activityLabel.addListener(_onEngine);
    // Built mid-session (a theme flip rebuilds the whole app): it starts
    // fully in, with no fade to end, so it says so itself.
    if (_active) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _active) InlineCaptionOverlay.covering.value = true;
      });
    }
  }

  @override
  void dispose() {
    engine.caption.removeListener(_onCaption);
    engine.removeListener(_onEngine);
    engine.activityLabel.removeListener(_onEngine);
    _pacer?.cancel();
    // Never leave the page behind it unpainted.
    InlineCaptionOverlay.covering.value = false;
    super.dispose();
  }

  /// The fade has finished: fully in covers the page, fully out does not.
  void _onFadeEnd() {
    if (mounted) InlineCaptionOverlay.covering.value = _active;
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
        _ticksSeen = _pacer?.tick ?? 0;
        _turn++;
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
    // Session over → the words leave with it, and the page underneath is
    // painted again before the fade-out starts to show it.
    if (!_active) {
      if (_text.isNotEmpty) _text = '';
      InlineCaptionOverlay.covering.value = false;
    }
    setState(() {});
  }

  /// What the session is doing, in words — every phase, not just four.
  /// While a tool runs, the tool's own words (engine.phaseLabel:
  /// "Checking your calendar…"); a landed turn on the fast voice is "Done"
  /// for its moment (2026-09-30).
  String _status(bool micPaused) {
    final p = engine.phase;
    // The cached hello is already playing while the realtime socket catches
    // up; leave the status quiet for that first spoken moment.
    if (engine.greetingPlaying) return '';
    // Connecting… until her first word (2026-10-06, the owner asked for it).
    if ((engine.connecting || engine.openingPending) && p != AssistantPhase.speaking) {
      return 'Connecting…';
    }
    if (micPaused && !_waitingForVoice(p) && p != AssistantPhase.speaking) {
      return 'Mic paused while you type';
    }
    return switch (p) {
      AssistantPhase.speaking => '',
      // The fast voice still connecting is not listening yet.
      AssistantPhase.listening =>
        engine.liveActive && !engine.micOpen ? 'One moment…' : 'Listening…',
      AssistantPhase.completed => engine.liveActive ? 'Done' : 'One moment…',
      // "Listening…" only while the microphone is actually open (client,
      // 1 Oct: it said Listening when it was not).
      AssistantPhase.idle => engine.liveActive
          ? (engine.micOpen ? 'Listening…' : 'One moment…')
          : 'One moment…',
      _ => engine.phaseLabel,
    };
  }

  OrbMood _mood(bool micPaused) => orbMoodFor(engine, micPaused: micPaused);

  /// The turn whose words outgrew their space: for the rest of that turn
  /// the orb steps back and the words get the room (2026-09-26, the owner:
  /// "if we have long output it's getting hidden… the full response should
  /// be visible"). Kept for the whole turn, so the orb does not bounce
  /// between sizes as the extra room makes the words fit again.
  int _roomyTurn = -1;

  bool get _roomy => _roomyTurn == _turn;

  /// This turn's words, streaming in (see StreamingCaption). The newest
  /// line stays in view as they arrive, and the whole reply can be scrolled
  /// back through (see CaptionScroll): nothing of it is ever cut off.
  Widget _passage(String words, bool typing) {
    // Her words large and bright, his own softer; smaller while typing,
    // when there is little room, and a step smaller once a long reply has
    // taken the orb's room, so more of it is in view at once.
    final size = typing ? 17.0 : (_fromUser ? 19.0 : (_roomy ? 19.0 : 22.0));
    // HERS BRIGHT AND LIT, HIS SOFTER (2026-09-30): her words in the
    // brightest ink beside a soft lit edge in the state's colour; his own
    // (shown as he speaks, interim words included) a step dimmer, beside a
    // plain one.
    final style = _VoiceType.spoken(size).copyWith(
      color: _fromUser ? Neon.textHi.withValues(alpha: 0.62) : Neon.textHi,
    );
    final turn = _turn;
    return CaptionScroll(
      onOverflow: () {
        if (mounted && _turn == turn && _roomyTurn != turn) {
          setState(() => _roomyTurn = turn);
        }
      },
      child: CustomPaint(
        painter: _SpeakerEdge(
          _fromUser ? null : orbMoodColor(_mood(engine.micPausedForTyping)),
        ),
        child: Padding(
          padding: const EdgeInsets.only(top: 14, bottom: 8, left: 14),
          // The keyboard coming up eases the size down as a picture, on the
          // orb's 220 ms: laid out once at the new size, never again on the
          // keyboard's frames (2026-09-24, review).
          child: TextResize(
            size: size,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topLeft,
            child: StreamingCaption(
              text: words,
              style: style,
              // Earlier sentences stay readable on the night ground: 60% white
              // for hers, 80% of his own softer white for his.
              earlierOpacity: _fromUser ? 0.8 : 0.6,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final show = _active;
    final micPaused = engine.micPausedForTyping;
    final words = _visibleText().trim();
    // AN INVISIBLE OVERLAY MUST NEVER EAT A TAP.
    //
    // This was IgnorePointer(always) because nothing in it was
    // touchable. It now carries a mute button and a text field, so it
    // has to accept taps — and an AnimatedOpacity at 0 still hit-tests,
    // which would have made every card on Home unclickable the moment a
    // session ended. It ignores pointers exactly while it is invisible.
    //
    // ITS OWN LAYER. The captions change several times a second while a
    // reply is spoken; without a boundary each change re-recorded the
    // whole page underneath as well.
    return RepaintBoundary(
      child: IgnorePointer(
        ignoring: !show,
        child: AnimatedOpacity(
          // In step with the app's page transitions (200–250 ms).
          duration: const Duration(milliseconds: 240),
          // In fast; out easing off and then going (2026-09-24: closing used
          // the opening curve backwards, so it started abruptly).
          curve: show ? Curves.easeOut : Motion.easeExit,
          opacity: show ? 1 : 0,
          onEnd: _onFadeEnd,
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
            final lifted =
                box.maxHeight < MediaQuery.of(context).size.height - kb / 2;
            // Clear of the dock AND the stop orb that rises 38 dp above it —
            // a fixed 120 put the orb over this bar on phones with 3-button
            // navigation (the dock grows by the system inset).
            final bottomPad = typing
                ? (lifted ? 12.0 : 12.0 + kb)
                : Dock.clearance(context, gap: 12);
            // The height actually available to this screen's content.
            final avail =
                lifted || !typing ? box.maxHeight : box.maxHeight - kb;
            // The orb's slot: smaller while typing, so everything fits above
            // the keyboard; on a short phone it gives up height to the words.
            final restSlot = math.min(330.0, avail * 0.38);
            final typingSlot = math.min(190.0, avail * 0.42);
            // How much smaller the orb is DRAWN to sit in it. The rings are
            // whole circles now (the client's picture; 2026-09-25), never
            // cut off at the slot's edge, so the WHOLE ring system fits the
            // slot: at rest on his phone that is full size (168 dp disc,
            // 311 dp of rings in a 330 dp slot); while typing, 0.61 of it.
            const rings = _orbSize * VoiceOrbBackdrop.reach;
            final restScale = math.min(1.0, restSlot / rings);
            final typingScale = math.min(1.0, typingSlot / rings);
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
                  // ABOVE THE ORB, the room eases away for a long reply too
                  // (2026-09-26), so its words get most of the screen: the
                  // same 5 : 7 split as always, counted in hundredths so it can
                  // glide instead of jump.
                  TweenAnimationBuilder<double>(
                    tween: Tween<double>(end: _roomy ? 1.0 : 0.0),
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOutCubic,
                    builder: (_, r, __) =>
                        Spacer(flex: math.max(1, (500 * (1 - r)).round())),
                  ),
                  // THE PRESENCE — the client's picture (2026-09-25): a dark
                  // disc with the mic and the assistant's name, still, inside
                  // rings that push out and back with the voice like a
                  // speaker ("only the speaker should move forward and
                  // backwards"), and light-wave ribbons running out to both
                  // sides. See widgets/voice_orb.dart.
                  //
                  // FULL WIDTH ON PURPOSE. The ribbons run out toward both
                  // edges; the padding the overlay puts on its text does not
                  // apply here, so the backdrop is pulled out to the screen
                  // edges. double.infinity, or the Stack shrinks to the orb
                  // and the backdrop's edges showed as a box around it.
                  //
                  // THE ORB SHRINKS BY SCALE, NOT BY LAYOUT (2026-09-24: one
                  // 83 ms frame as the keyboard came up, with the orb resizing
                  // while the keyboard moved). The slot still gives up height
                  // while typing, but the disc inside it is laid out ONCE, at
                  // full size, in a box that never changes — and only DRAWN
                  // smaller, through a transform eased over 220 ms. A keyboard
                  // frame therefore never lays the orb out again. The backdrop
                  // is a bare canvas that fills the slot and draws its rings to
                  // the same scale.
                  //
                  // THE VOICE IS READ BY THE PAINTER, not passed down by a
                  // rebuild: this screen used to rebuild the orb for every mic
                  // reading, and in a screen measured by a LayoutBuilder every
                  // such rebuild re-ran the layout up to the page. The rings
                  // read his mic level, or her voice's, on their own frames;
                  // the disc in the middle never moves at all.
                  //
                  // THE WORDS MOVE WITH THE ORB (2026-09-24). The orb eased
                  // smaller over 220 ms, but on the keyboard's first frame its
                  // slot dropped from up to 330 dp to 190, the gap under it
                  // from 24 to 6, and the words jumped up ~140 dp while the orb
                  // was still shrinking (and down again on the way back). The
                  // slot and the gap now ease on the same 220 ms as the orb.
                  // The keyboard lays this column out on every one of its
                  // frames anyway, so this adds no new kind of work; the orb
                  // itself is still laid out once, in its fixed box.
                  // A LONG REPLY TAKES THE ORB'S ROOM (2026-09-26): the same
                  // compact orb as while typing, eased the same way, for the
                  // rest of the turn whose words outgrew their space.
                  TweenAnimationBuilder<double>(
                    tween: Tween<double>(end: typing || _roomy ? 1.0 : 0.0),
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOutCubic,
                    builder: (_, k, __) {
                      final scale = restScale + (typingScale - restScale) * k;
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: double.infinity,
                            height: restSlot + (typingSlot - restSlot) * k,
                            child: Builder(
                              builder: (_) {
                                final mood = _mood(micPaused);
                                // A tap only does something while she speaks or works
                                // on the answer; the rest of the time the orb is not
                                // a button, so a screen reader does not offer one.
                                // ONE TAP ON THE ORB ENDS IT (client, 1 Oct: "I have to
                                // tap twice, it looks stuck"). It used to interrupt
                                // while she spoke and do NOTHING while listening — so
                                // a tap on the big orb left "Listening…" on screen and
                                // only the dock mic got them out. Now any tap on it
                                // stops the conversation and hands Home back; to
                                // interrupt her, they simply start speaking.
                                const canStop = true;
                                final level = micPaused
                                    ? null
                                    : engine.micLevelListenable;
                                return Stack(
                                  alignment: Alignment.center,
                                  clipBehavior: Clip.none,
                                  children: [
                                    // Built even while hidden (and still then), so the
                                    // frame the screen opens on does not build it from
                                    // nothing.
                                    Positioned(
                                      left: -28,
                                      right: -28,
                                      top: 0,
                                      bottom: 0,
                                      child: VoiceOrbBackdrop(
                                        orbSize: _orbSize * scale,
                                        mood: mood,
                                        levelListenable: level,
                                        // Her voice's loudness as it comes out of the
                                        // speaker: the rings move with what is heard.
                                        speakerLevel: engine.speakerLevelNow,
                                        active: show,
                                      ),
                                    ),
                                    // THE WAKE-UP (2026-10-04): every tap, a bloom of
                                    // light and three rings rolling out from the orb
                                    // while it pops into place — the 2 s her session
                                    // takes to open read as her waking, not a wait.
                                    Positioned.fill(
                                      child: IgnorePointer(
                                        child: _WakeBurst(
                                          wake: engine.wake,
                                          orbSize: _orbSize * scale,
                                        ),
                                      ),
                                    ),
                                    OverflowBox(
                                      minWidth: _orbBox,
                                      maxWidth: _orbBox,
                                      minHeight: _orbBox,
                                      maxHeight: _orbBox,
                                      child: _WakePop(
                                        wake: engine.wake,
                                        child: Transform.scale(
                                          key: const ValueKey('orb-scale'),
                                          scale: scale,
                                          // The assistant's own name under the mic
                                          // ("My Assistant" until it has one); a rename
                                          // rebuilds only this.
                                          // TAP TO INTERRUPT: while she speaks (or is
                                          // still working on the answer) a tap stops her
                                          // and the conversation listens (barge-in).
                                          child: Semantics(
                                            button: canStop,
                                            label: 'Stop and go back',
                                            child: GestureDetector(
                                              behavior: HitTestBehavior.opaque,
                                              onTap: () {
                                                HapticFeedback.mediumImpact();
                                                AppLog.add('orb',
                                                    'big orb tap → stop');
                                                unawaited(engine
                                                    .endInlineConversation());
                                              },
                                              child: ValueListenableBuilder<
                                                  String>(
                                                valueListenable:
                                                    AssistantIdentity.notifier,
                                                builder: (_, name, __) =>
                                                    VoiceOrb(
                                                  size: _orbSize,
                                                  label: orbLabelFor(name),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                );
                              },
                            ),
                          ),
                          SizedBox(height: 24 - 18 * k),
                        ],
                      );
                    },
                  ),
                  // AN ERROR SAYS WHAT WENT WRONG. The caption below maps every
                  // phase it does not name to "Connecting…" — including error —
                  // so a denied microphone, a failed upload and a timeout all
                  // looked like a connection that never finished, and a tap on
                  // the orb (which reads error as "running") just stopped it.
                  if (engine.phase == AssistantPhase.error)
                    Expanded(
                      flex: 700,
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: _ErrorCaption(engine: engine),
                      ),
                    )
                  // THE WORDS — under the orb, streaming in as they are said
                  // (see StreamingCaption). Before any words exist, the state
                  // itself is the caption: the user must never stare at an
                  // empty black area wondering if it heard.
                  //
                  // ONE SWITCHER FOR BOTH (2026-09-25): "Listening…", his words,
                  // "Thinking…" and her reply cross-fade into each other; a new
                  // turn is a new passage fading in over the last. Each fills
                  // the space, so a leaving passage fades out exactly where it
                  // was — its newest lines — instead of jumping to its top.
                  else
                    Expanded(
                      flex: 700,
                      child: AnimatedSwitcher(
                        duration: Motion.short,
                        reverseDuration: Motion.out,
                        switchInCurve: Motion.easeFadeIn,
                        switchOutCurve: Motion.easeFadeOut,
                        layoutBuilder: (current, previous) => Stack(
                          fit: StackFit.expand,
                          children: [...previous, if (current != null) current],
                        ),
                        child: words.isEmpty
                            ? Align(
                                key: ValueKey('status|${_status(micPaused)}'),
                                alignment: Alignment.topCenter,
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    // CONNECTING IS VISIBLY NOT LISTENING (2026-10-02).
                                    Text(
                                      _status(micPaused),
                                      textAlign: TextAlign.center,
                                      // In the state's colour (2026-09-30), lifted
                                      // toward white so it reads at AA on the night.
                                      style: _VoiceType.statusFor(
                                          _mood(micPaused)),
                                    ),
                                  ],
                                ),
                              )
                            : KeyedSubtree(
                                key: ValueKey('turn|$_fromUser|$_turn'),
                                child: _passage(words, typing),
                              ),
                      ),
                    ),
                  // While captions fill the space the status line is gone, so
                  // a paused mic says so right above the box it is paused for.
                  if (micPaused && words.isNotEmpty) const _MicPausedChip(),
                  // TYPE INSTEAD OF TALKING. Not on the error screen, where it
                  // sat under "Try again / Close" and made the screen ambiguous.
                  if (engine.phase != AssistantPhase.error)
                    _TypeBar(engine: engine),
                ],
              ),
            );
          }),
        ),
      ),
    );
  }
}

/// THE VOICE SCREEN'S TYPE (2026-09-24, the clarity pass).
///
/// Space Grotesk, the display face, is kept for the words being spoken
/// ([spoken]) and nothing else. Its quirky y and g made the status
/// line, the older lines, the typed message and the buttons at 13–15.5 sp
/// read worse than Manrope, and look like another app beside Home and
/// Hub. Built once: the pacer rebuilds this screen five times a second,
/// and every GoogleFonts call made a new style and a font-load future.
/// THE TEXT BOX ON A NIGHT SCREEN — the voice screen's "Type a message…"
/// and Quick task's (2026-09-29: Quick task drew a light box with a faint
/// hint on its black screen). One pill, and a field with no fill or
/// outline of its own: the app theme gives every TextField a fill (light
/// by day) and an outline, and `border: none` alone does not switch off
/// the enabled/focused ones.
/// The orb pops into place on each wake: 0.8 → 1.06 → 1.
class _WakePop extends StatefulWidget {
  const _WakePop({required this.wake, required this.child});
  final ValueListenable<int> wake;
  final Widget child;

  @override
  State<_WakePop> createState() => _WakePopState();
}

class _WakePopState extends State<_WakePop>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 750), value: 1);
  late final Animation<double> _s = TweenSequence<double>([
    TweenSequenceItem(
        tween: Tween(begin: 0.8, end: 1.06)
            .chain(CurveTween(curve: Curves.easeOutCubic)),
        weight: 60),
    TweenSequenceItem(
        tween: Tween(begin: 1.06, end: 1.0)
            .chain(CurveTween(curve: Curves.easeInOutSine)),
        weight: 40),
  ]).animate(_c);

  @override
  void initState() {
    super.initState();
    widget.wake.addListener(_go);
    // Built by the very tap that woke it: play this wake too.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (DateTime.now().difference(AssistantEngine.instance.wokeAt) <
          const Duration(milliseconds: 700)) _go();
    });
  }

  void _go() {
    if (mounted && !Motion.reduced(context)) _c.forward(from: 0);
  }

  @override
  void dispose() {
    widget.wake.removeListener(_go);
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      ScaleTransition(scale: _s, child: widget.child);
}

/// A bloom of light behind the orb and three rings rolling out from it,
/// 2.4 s, once per wake.
class _WakeBurst extends StatefulWidget {
  const _WakeBurst({required this.wake, required this.orbSize});
  final ValueListenable<int> wake;
  final double orbSize;

  @override
  State<_WakeBurst> createState() => _WakeBurstState();
}

class _WakeBurstState extends State<_WakeBurst>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 2400));

  @override
  void initState() {
    super.initState();
    widget.wake.addListener(_go);
    // Built by the very tap that woke it: play this wake too.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (DateTime.now().difference(AssistantEngine.instance.wokeAt) <
          const Duration(milliseconds: 700)) _go();
    });
  }

  void _go() {
    if (mounted && !Motion.reduced(context)) _c.forward(from: 0);
  }

  @override
  void dispose() {
    widget.wake.removeListener(_go);
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _c,
        builder: (_, __) => !_c.isAnimating
            ? const SizedBox.shrink()
            : CustomPaint(
                painter: _WakePainter(_c.value, widget.orbSize, Neon.cyan,
                    Neon.violet, Neon.pink),
              ),
      );
}

class _WakePainter extends CustomPainter {
  _WakePainter(this.t, this.orb, this.a, this.b, this.c);
  final double t, orb;
  final Color a, b, c;

  @override
  void paint(Canvas canvas, Size size) {
    final o = size.center(Offset.zero);
    final r0 = orb / 2;
    // The bloom: up fast, then settles away.
    final bloom = t < 0.15 ? t / 0.15 : (1 - (t - 0.15) / 0.85);
    final br = r0 * (1.4 + 1.2 * Curves.easeOutCubic.transform(t));
    canvas.drawCircle(
      o,
      br,
      Paint()
        ..shader = RadialGradient(colors: [
          Colors.white.withValues(alpha: 0.55 * bloom),
          b.withValues(alpha: 0.75 * bloom),
          a.withValues(alpha: 0.35 * bloom),
          a.withValues(alpha: 0),
        ], stops: const [
          0.0,
          0.35,
          0.7,
          1.0
        ]).createShader(Rect.fromCircle(center: o, radius: br)),
    );
    // Three rings, 0.35 of the run apart, each rolling out and fading.
    for (var i = 0; i < 3; i++) {
      final k = ((t - i * 0.2) / 0.6).clamp(0.0, 1.0);
      if (k <= 0 || k >= 1) continue;
      final e = Curves.easeOutCubic.transform(k);
      final r = r0 * (1.0 + 2.2 * e);
      final fade = 1 - e;
      // A soft glow under a bright, thick line.
      canvas.drawCircle(
        o,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 22 * fade + 4
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10)
          ..color = b.withValues(alpha: 0.55 * fade),
      );
      canvas.drawCircle(
        o,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 7 * fade + 1.5
          ..shader = SweepGradient(colors: [a, b, c, Colors.white, a])
              .createShader(Rect.fromCircle(center: o, radius: r))
          ..color = Colors.white.withValues(alpha: fade),
      );
    }
  }

  @override
  bool shouldRepaint(_WakePainter old) => old.t != t || old.orb != orb;
}

abstract final class NightField {
  static BoxDecoration pill({required bool focused}) => BoxDecoration(
        color: Neon.textHi.withValues(alpha: focused ? 0.10 : 0.07),
        borderRadius: BorderRadius.circular(28),
        // The resting outline at 22% white: at 10% it was 1.26:1 and the
        // box all but vanished when not focused. Focused, a lit cyan rim
        // (2026-09-30: the assistant's own colour, where you talk to it).
        border: Border.all(
          color: focused
              ? NeonTone.tip.rim.first.withValues(alpha: 0.75)
              : Neon.textHi.withValues(alpha: 0.22),
        ),
        boxShadow:
            focused ? Neon.halo(NeonTone.tip.rim.first, strength: 0.45) : null,
      );

  static InputDecoration decoration(String hint) => InputDecoration(
        isDense: true,
        filled: false,
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        disabledBorder: InputBorder.none,
        hintText: hint,
        hintStyle: _VoiceType.hint,
        contentPadding: const EdgeInsets.symmetric(vertical: 14),
      );

  static TextStyle get input => _VoiceType.input;
}

abstract final class _VoiceType {
  static final TextStyle status =
      NeonType.manrope(NeonType.callout, FontWeight.w600)
          .copyWith(color: Neon.textLo, letterSpacing: 0.3);

  /// The status line in its state's colour (2026-09-30), lifted a third of
  /// the way to white so the darkest (violet) still reads at AA on the
  /// night, with a faint light of its own. Idle and paused stay quiet.
  /// One style per state, made once.
  static final Map<OrbMood, TextStyle> _status = {};
  static TextStyle statusFor(OrbMood m) => _status[m] ??= switch (m) {
        OrbMood.idle || OrbMood.paused => status,
        _ => status.copyWith(
            color: Color.lerp(orbMoodColor(m), Neon.textHi, 0.35),
            shadows: [
              Shadow(
                  color: orbMoodColor(m).withValues(alpha: 0.55),
                  blurRadius: 12),
            ],
          ),
      };
  static final TextStyle error =
      NeonType.manrope(NeonType.rowTitle, FontWeight.w600)
          .copyWith(color: Neon.textHi, height: 1.3);
  static final TextStyle input =
      NeonType.manrope(NeonType.rowTitle, FontWeight.w500)
          .copyWith(color: Neon.textHi);

  /// 52% of the text white (was 45%, 4.4:1): 5.3:1 on the text box,
  /// pinned by test/contrast_test.dart.
  static final TextStyle hint =
      NeonType.manrope(NeonType.rowTitle, FontWeight.w500)
          .copyWith(color: Neon.textHi.withValues(alpha: 0.52));
  static final TextStyle chip =
      NeonType.manrope(NeonType.footnote, FontWeight.w600)
          .copyWith(color: Neon.textLo);
  static final TextStyle button =
      NeonType.manrope(NeonType.callout, FontWeight.w700);
  static final TextStyle mute =
      NeonType.manrope(NeonType.footnote, FontWeight.w700);

  /// The words being said (2026-09-25, streaming captions). A passage
  /// rather than one line now, so a touch lighter and smaller than the
  /// 24 pt w700 spotlight was. One style per size, made once.
  static final Map<double, TextStyle> _spoken = {};
  static TextStyle spoken(double size) =>
      _spoken[size] ??= GoogleFonts.spaceGrotesk(
        fontSize: size,
        height: 1.34,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.3,
      );
}

/// The session's ground: opaque, deep, always dark — the orb and captions
/// are drawn for night. THE APP'S NAVY NIGHT (2026-09-30, the client's
/// neon reference: deep navy to black), not a purple cast of the accent:
/// the page ground with a trace of the accent at the top, deepest at the
/// middle where the orb glows.
LinearGradient _sessionGround() {
  final bg = Neon.bg;
  final h = HSLColor.fromColor(bg);
  return LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [
      Color.alphaBlend(Neon.violet.withValues(alpha: 0.10), bg),
      // Deeper at the middle — at night only (the app is always dark; a
      // day page would turn grey here).
      Neon.isDark ? h.withLightness(h.lightness * 0.62).toColor() : bg,
      Color.alphaBlend(NeonTone.tip.rim.first.withValues(alpha: 0.04), bg),
    ],
    stops: const [0.0, 0.5, 1.0],
  );
}

/// THE SPEAKER'S EDGE (2026-09-30): a soft lit line down the left of her
/// words, in the state's colour — a bright core and two faint, wider
/// strokes for its light (no blur: the captions repaint several times a
/// second). His own words get a plain hairline.
class _SpeakerEdge extends CustomPainter {
  _SpeakerEdge(this.color);

  /// Hers: the state's colour. Null: his (a plain hairline).
  final Color? color;

  @override
  void paint(Canvas canvas, Size size) {
    const top = 18.0;
    final bottom = math.max(top, size.height - 10);
    if (bottom - top < 4) return;
    final a = const Offset(1.5, top), b = Offset(1.5, bottom);
    final c = color;
    if (c == null) {
      canvas.drawLine(
          a,
          b,
          Paint()
            ..strokeWidth = 1.2
            ..strokeCap = StrokeCap.round
            ..color = Neon.lineBright);
      return;
    }
    for (final (width, alpha) in const [
      (9.0, 0.08),
      (5.0, 0.18),
      (2.2, 0.95)
    ]) {
      canvas.drawLine(
          a,
          b,
          Paint()
            ..strokeWidth = width
            ..strokeCap = StrokeCap.round
            ..shader = LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                c.withValues(alpha: alpha),
                Neon.violet.withValues(alpha: alpha * 0.4)
              ],
            ).createShader(Rect.fromPoints(a, b)));
    }
  }

  @override
  bool shouldRepaint(_SpeakerEdge old) => old.color != color;
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
        ? "Sorry, something didn't work on my side. Let's try that again."
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
            style: _VoiceType.error,
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
  const _PillButton(
      {required this.label, required this.onTap, this.primary = false});
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
        // HIERARCHY BY LIGHT (2026-09-30): the way forward is the brand
        // gradient with its full glow; the other is a rim and nothing more.
        child: PressScale(
          scale: 0.96,
          child: Container(
            // 48 dp tall: a comfortable target, as every tap target should be.
            constraints: const BoxConstraints(minHeight: 48, minWidth: 96),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              gradient: primary ? Neon.gBrand : null,
              color: primary ? null : Neon.textHi.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(24),
              border: primary ? null : Border.all(color: Neon.lineBright),
              boxShadow: primary ? Neon.halo(Neon.violet, strength: 1.1) : null,
            ),
            child: Text(
              label,
              style: _VoiceType.button.copyWith(
                color: primary ? Neon.onBrand : Neon.textLo,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// INTERRUPT — one small round icon beside the send button (the owner,
/// 2026-10-02: "remove interruption completely and add a button … one
/// small round icon, near the text box"). Shown only while she is thinking
/// or speaking, taking no room otherwise; a tap stops her and she listens.
class _InterruptButton extends StatelessWidget {
  const _InterruptButton({required this.engine});
  final AssistantEngine engine;

  static const _shownIn = {
    AssistantPhase.thinking,
    AssistantPhase.responding,
    AssistantPhase.searching,
    AssistantPhase.generatingVoice,
    AssistantPhase.speaking,
  };

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: engine,
      builder: (context, _) {
        final shown = _shownIn.contains(engine.phase);
        return AnimatedSize(
          duration: const Duration(milliseconds: 160),
          curve: Motion.easeMove,
          child: !shown
              ? const SizedBox.shrink()
              : Semantics(
                  button: true,
                  label: 'Interrupt the assistant',
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      HapticFeedback.mediumImpact();
                      engine.bargeIn();
                    },
                    // 48 dp to the finger, 36 dp to the eye.
                    child: SizedBox(
                      width: 48,
                      height: 48,
                      child: Center(
                        child: Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Neon.textHi.withValues(alpha: 0.10),
                            border: Border.all(color: Neon.lineBright),
                          ),
                          child: Icon(Icons.stop_rounded,
                              size: 20, color: Neon.textHi),
                        ),
                      ),
                    ),
                  ),
                ),
        );
      },
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
        // MUTED IS A WARNING (2026-09-30): she will not be heard, so the
        // control lights amber with its own glow; sound on is a quiet rim.
        child: PressScale(
          scale: 0.95,
          child: AnimatedContainer(
            curve: Motion.easeMove,
            duration: const Duration(milliseconds: 180),
            // 48 dp tall, like every other target on this screen (was 44).
            constraints: const BoxConstraints(minHeight: 48),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            decoration: BoxDecoration(
              color: muted
                  ? NeonTone.warning.fill
                  : Neon.textHi.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                color: muted
                    ? NeonTone.warning.rim.first.withValues(alpha: 0.9)
                    : Neon.lineBright,
                width: muted ? 1.6 : 1,
              ),
              boxShadow: muted
                  ? Neon.halo(NeonTone.warning.rim.first, strength: 0.8)
                  : null,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Icon(
                  muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                  size: 18,
                  color: muted ? NeonTone.warning.ink : Neon.textLo,
                ),
                const SizedBox(width: 7),
                Text(
                  // "Sound" alone read as either a state or an action.
                  muted ? 'Muted' : 'Sound on',
                  style: _VoiceType.mute.copyWith(
                    color: muted ? NeonTone.warning.ink : Neon.textLo,
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

/// Shown above the text box while the microphone is paused for typing and
/// captions have pushed the status line off the screen.
/// Camera or gallery, for the type bar's "+".
class _PhotoSourceSheet extends StatelessWidget {
  const _PhotoSourceSheet();

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    Widget row(IconData icon, String title, String hint, ImageSource src) =>
        ListTile(
          leading: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: Neon.gBrand,
            ),
            child: Icon(icon, color: Neon.onBrand, size: 22),
          ),
          title: Text(title,
              style: NeonType.manrope(NeonType.rowTitle, FontWeight.w700)
                  .copyWith(color: Neon.textHi)),
          subtitle: Text(hint,
              style:
                  TextStyle(color: Neon.textLo, fontSize: NeonType.footnote)),
          onTap: () => Navigator.of(context).pop(src),
        );
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      padding: EdgeInsets.fromLTRB(4, 12, 4, 8 + bottom),
      decoration: BoxDecoration(
        color: Neon.surface,
        borderRadius: BorderRadius.circular(Neon.rLg),
        border: Border.all(color: Neon.hairline),
        boxShadow: Neon.lift,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('Ask about a picture',
                  style: NeonType.eyebrow.copyWith(color: Neon.textLo)),
            ),
          ),
          row(Icons.photo_camera_rounded, 'Take a photo',
              'A bill, a label, a sign, a whiteboard', ImageSource.camera),
          row(Icons.photo_library_rounded, 'Choose from gallery',
              'A screenshot or a saved picture', ImageSource.gallery),
        ],
      ),
    );
  }
}

class _MicPausedChip extends StatelessWidget {
  const _MicPausedChip();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.mic_off_rounded, size: 15, color: Neon.textLo),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              'Mic paused while you type',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: _VoiceType.chip,
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
/// It is a turn of the SAME conversation the voice is in (the brain's),
/// not a second one beside it — see AssistantEngine.sendTypedMessage.
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
    final base =
        kb > 0 ? 0.0 : MediaQuery.paddingOf(context).bottom + Dock.orbRise;
    AppFeedback.sessionMargin = math.max(10.0, reach - base + 8);
  }

  /// THE "+": a photo to ask about, from the camera or the gallery; what
  /// is typed goes with it as the question (owner, 2026-09-30).
  Future<void> _attach() async {
    if (_connecting) return;
    HapticFeedback.selectionClick();
    final source = await showAppSheet<ImageSource>(
      context: context,
      backgroundColor: Neon.textHi.withValues(alpha: 0),
      builder: (_) => const _PhotoSourceSheet(),
    );
    if (source == null || !mounted) return;
    final q = _c.text.trim();
    _c.clear();
    final ok = await _engine.askWithPhoto(source, question: q);
    if (!ok && mounted) {
      if (q.isNotEmpty) _c.text = q;
      AppFeedback.show("Couldn't get that picture. Try again.",
          context: context);
    }
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
    final typedOne =
        newV.text.length == oldV.text.length + 1 && !oldV.text.contains('\n');
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
        curve: Motion.easeMove,
        duration: const Duration(milliseconds: 180),
        constraints: const BoxConstraints(minHeight: 54),
        decoration: NightField.pill(focused: focused),
        padding: const EdgeInsets.fromLTRB(3, 3, 3, 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // "+" — a picture to ask about (camera or gallery). 48 dp to
            // the finger, in the place the keyboard glyph used to sit.
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Semantics(
                button: true,
                label: 'Add a photo',
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: connecting ? null : _attach,
                  child: SizedBox(
                    width: 48,
                    height: 48,
                    child: Center(
                      child: Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Neon.textHi.withValues(alpha: 0.08),
                          border: Border.all(
                              color: NeonTone.tip.rim.first
                                  .withValues(alpha: 0.55)),
                        ),
                        child: Icon(Icons.add_rounded,
                            size: 20,
                            color: connecting ? Neon.textDim : Neon.textHi),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 2),
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
                cursorColor: NeonTone.tip.rim.first,
                style: NightField.input,
                decoration: NightField.decoration(
                    connecting ? 'Or type a message…' : 'Type a message…'),
              ),
            ),
            const SizedBox(width: 5),
            _InterruptButton(engine: widget.engine),
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
                      curve: Motion.easeMove,
                      duration: const Duration(milliseconds: 160),
                      scale: canSend ? 1 : 0.9,
                      child: AnimatedContainer(
                        curve: Motion.easeMove,
                        duration: const Duration(milliseconds: 160),
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: canSend ? Neon.gBrand : null,
                          color: canSend
                              ? null
                              : Neon.textHi.withValues(alpha: 0.08),
                          // Ready to send: the primary action glows.
                          boxShadow: canSend
                              ? Neon.halo(Neon.violet, strength: 0.9)
                              : null,
                        ),
                        // Neon.onBrand on the gradient: white was 2.4:1 on
                        // the evening theme's pastel accent.
                        child: Icon(Icons.arrow_upward_rounded,
                            color: canSend ? Neon.onBrand : Neon.textDim,
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

  /// What the card shows — kept through its fade-out. The words used to be
  /// swapped for nothing the moment it was dismissed, so the fade had
  /// nothing to fade and the card blinked out instead.
  String? _shown;

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
    if (_wasActive && !active && engine.takeQuietEnd()) {
      // Closed for a task, not by the owner: "On it, doing this in
      // Swiggy…" is no answer to keep on screen (2026-09-26).
      _lastAnswer = null;
    } else if (_wasActive && !active) {
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
      engine.searchSuggestions.isNotEmpty ||
      engine.generatedImage != null;

  @override
  Widget build(BuildContext context) {
    final t = _cardShowing ? null : _text;
    if (t != null) _shown = t;
    final shown = _shown;
    // Above the dock and the mic, and above the toast while one is up.
    final bottom = AppFeedback.clearOfToast(Dock.clearance(context, gap: 12));
    return IgnorePointer(
      ignoring: t == null,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 240),
        // In on the arrival curve (with the rise below); out easing in.
        // Both were linear.
        curve: t == null ? Motion.easeFadeOut : Motion.easeEnter,
        opacity: t == null ? 0 : 1,
        // Faded all the way out: now the words can go.
        onEnd: () {
          final gone = _cardShowing || _text == null;
          if (mounted && gone && _shown != null) {
            setState(() => _shown = null);
          }
        },
        child: Align(
          alignment: Alignment.bottomCenter,
          child: AnimatedPadding(
            duration: const Duration(milliseconds: 200),
            curve: Motion.easeMove,
            padding: EdgeInsets.only(left: 16, right: 16, bottom: bottom),
            child: shown == null
                ? const SizedBox.shrink()
                // It rises 8 dp as it fades in, like every other card that
                // comes out of the mic (the fade itself is above).
                : EnterOnce(
                    key: ValueKey(shown),
                    duration: const Duration(milliseconds: 240),
                    fade: false,
                    rise: 8,
                    child: Container(
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
                                shown,
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
                                minWidth: 48, minHeight: 48),
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
      ),
    );
  }
}
