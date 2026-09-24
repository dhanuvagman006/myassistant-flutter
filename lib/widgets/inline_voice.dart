
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:permission_handler/permission_handler.dart';

import '../design/dock_metrics.dart';
import '../design/motion.dart';
import '../design/neon_tokens.dart';
import '../features/assistant/state/assistant_engine.dart';
import '../features/assistant/state/assistant_state.dart';
import '../services/app_feedback.dart';
import '../services/auth_service.dart';
import 'overflow_fade.dart';
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

  bool get _active =>
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
                      _still ? 0.25 : _halo.value,
                      _still
                          ? 1.0
                          : ((_halo.lastElapsedDuration?.inMilliseconds ?? 0) /
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
                  scale: Tween<double>(begin: 0.85, end: 1.0).animate(a),
                  filterQuality: FilterQuality.medium,
                  child: child,
                ),
              ),
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
                  : Container(
                      key: const ValueKey('idle'),
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
                      // Dark ink on the evening theme's pastel accent,
                      // where white measured 2.4:1 (Neon.onBrand).
                      child: Icon(Icons.mic_rounded,
                          color: Neon.onBrand, size: 30),
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
  final double t;

  /// 0..1: how far the rings have faded in.
  final double strength;
  _HaloPainter(this.t, [this.strength = 1.0]);

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
          ..color = Neon.violet.withValues(alpha: alpha),
      );
    }
  }

  @override
  bool shouldRepaint(_HaloPainter old) =>
      old.t != t || old.strength != strength;
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

/// The sphere's diameter on the voice screen, and the square its glow
/// needs round it.
const double _orbSize = 168;
const double _orbBox = _orbSize * 1.6;

class _InlineCaptionOverlayState extends State<InlineCaptionOverlay>
    with SingleTickerProviderStateMixin {
  final engine = AssistantEngine.instance;
  String _text = '';
  bool _fromUser = false;

  /// Counts turns (bumped where the paced release restarts), so the line
  /// being spoken can be told apart from the same line of the last turn.
  int _turn = 0;

  /// The spotlight line of the last build ('turn|index'): the line that
  /// was being spoken, which shrinks into the older lines when the next
  /// one starts.
  String? _lastSpot;

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
        _lastTick = DateTime.now();
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
    // Which line was in the spotlight last time: if it is now among the
    // older lines, it shrinks into them instead of snapping.
    final wasSpot = _lastSpot;
    _lastSpot = '$_turn|${lines.length - 1}';
    // Which line is in the spotlight: speaker, turn and line number — not
    // its words (see the spotlight below).
    final spotKey = '$_fromUser|$_turn|${lines.length}';
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
          final lifted = box.maxHeight < MediaQuery.of(context).size.height - kb / 2;
          // Clear of the dock AND the stop orb that rises 38 dp above it —
          // a fixed 120 put the orb over this bar on phones with 3-button
          // navigation (the dock grows by the system inset).
          final bottomPad = typing
              ? (lifted ? 12.0 : 12.0 + kb)
              : Dock.clearance(context, gap: 12);
          // The height actually available to this screen's content.
          final avail = lifted || !typing ? box.maxHeight : box.maxHeight - kb;
          // The orb's slot: smaller while typing, so everything fits above
          // the keyboard; on a short phone it gives up height to the words.
          final restSlot = math.min(330.0, avail * 0.38);
          final typingSlot = math.min(190.0, avail * 0.42);
          // How much smaller the orb is DRAWN to sit in it: while typing,
          // the whole glow fits the slot; at rest, the sphere does (as it
          // always has — only a very short screen ever shrinks it).
          final restScale = math.min(1.0, restSlot / _orbSize);
          final typingScale = math.min(1.0, typingSlot / _orbBox);
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
              //
              // THE ORB SHRINKS BY SCALE, NOT BY LAYOUT (2026-09-24: one
              // 83 ms frame as the keyboard came up, with the orb resizing
              // while the keyboard moved). The slot still gives up height
              // while typing, but the sphere inside it is laid out ONCE, at
              // full size, in a box that never changes — and only DRAWN
              // smaller, through a transform eased over 220 ms. A keyboard
              // frame therefore never lays the orb out again. The backdrop
              // is a bare canvas that fills the slot and draws its rings to
              // the same scale.
              //
              // THE VOICE IS READ BY THE PAINTERS, not passed down by a
              // rebuild: this screen used to rebuild the orb for every mic
              // reading, and in a screen measured by a LayoutBuilder every
              // such rebuild re-ran the layout up to the page. The orb and
              // its backdrop read the live level on their own frames.
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
              TweenAnimationBuilder<double>(
                tween: Tween<double>(end: typing ? 1.0 : 0.0),
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
                    // The level still arrives while paused (it is measured
                    // before the mute) — the orb must not react to it.
                    final level = micPaused ? null : engine.micLevelListenable;
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
                            active: show,
                          ),
                        ),
                        OverflowBox(
                          minWidth: _orbBox,
                          maxWidth: _orbBox,
                          minHeight: _orbBox,
                          maxHeight: _orbBox,
                          child: Transform.scale(
                            key: const ValueKey('orb-scale'),
                            scale: scale,
                            child: VoiceOrb(
                              size: _orbSize,
                              mood: mood,
                              levelListenable: level,
                              active: show,
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
                        // Readable on the night ground (was 0.45).
                        style: _VoiceType.status,
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
                builder: (context, area) => TopFadeWhenOverflowing(
                // A soft top edge: when a reply is taller than its space the
                // OLDEST words fade out up there — never a hard slice. Only
                // then: a mask over words that fit was a full-size layer on
                // every frame of the orb (2026-09-24, see the widget).
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
                    curve: Motion.easeMove,
                    child: Builder(builder: (context) {
                    final ambient = DefaultTextStyle.of(context).style;
                    final spot = ambient.merge(GoogleFonts.spaceGrotesk(
                      color: _fromUser
                          ? Colors.white.withValues(alpha: 0.62)
                          : Colors.white,
                      fontSize: typing ? 17 : (_fromUser ? 19 : 24),
                      height: 1.3,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.4,
                    ));
                    final older = ambient.merge(GoogleFonts.spaceGrotesk(
                      // Older lines stay readable (was 0.38 —
                      // under 4.5:1 on the night ground).
                      color: Colors.white.withValues(alpha: 0.56),
                      // 15 on the type scale (was 15.5); Space Grotesk like the
                      // spotlight, so the shrink into place never swaps font.
                      fontSize: NeonType.callout,
                      height: 1.3,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.2,
                    ));
                    // Was line [i] in the spotlight a moment ago?
                    bool promoted(int i) => wasSpot == '$_turn|$i';
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // While typing there is little room: the line
                        // being spoken, nothing older.
                        //
                        // A FINISHED LINE SHRINKS INTO PLACE (2026-09-24).
                        // It used to snap in one frame from the 24 pt
                        // white spotlight to a 15.5 pt older line. The
                        // line that was just being spoken now eases down
                        // to the older size and dims; lines that were
                        // already older stay exactly as they were.
                        //
                        // AS A PICTURE (2026-09-24, review): it first did
                        // that by tweening its text style, which laid the
                        // line out again at a new font size on every frame
                        // of the move, while the orb was animating. It is
                        // now laid out once, in the older style (weight,
                        // spacing and wrap taken at once), and only DRAWN
                        // larger and brighter at first.
                        for (final (k, l) in (typing
                                ? const <String>[]
                                : previous)
                            .indexed)
                          Padding(
                            key: ValueKey('$_turn|${start + k}'),
                            padding: const EdgeInsets.only(bottom: 12),
                            child: TextResize(
                              size: older.fontSize!,
                              from: promoted(start + k) ? spot.fontSize : null,
                              child: _DimInto(
                                text: l,
                                style: older,
                                from: promoted(start + k) ? spot.color : null,
                              ),
                            ),
                          ),
                        // The line being spoken RIGHT NOW — the spotlight.
                        //
                        // WORDS APPEND, THE LINE DOES NOT FLICKER
                        // (2026-09-24). This was keyed by its whole text,
                        // so every word the pacer released (and every
                        // partial transcript of his own words) cross-faded
                        // the ENTIRE line into an almost identical copy,
                        // two or three times a second: the centred line
                        // shifted by half a word, the two copies overlapped
                        // offset, and the line shimmered for as long as
                        // anyone spoke. It is now keyed by WHICH line it is
                        // (speaker, turn, index), so words simply appear at
                        // its end. A new line fades in under the one that
                        // just finished; a new turn cross-fades, quickly
                        // out, then in, from the top.
                        // Full width, so a leaving line keeps its own
                        // wrap while the new one fades in over it.
                        SizedBox(
                          width: double.infinity,
                          child: AnimatedSwitcher(
                          duration: Motion.short,
                          reverseDuration: Motion.out,
                          switchInCurve: Motion.easeFadeIn,
                          switchOutCurve: Motion.easeFadeOut,
                          // A line that just finished is not faded out
                          // here: it lives on above, shrinking into the
                          // older lines, and a second fading copy of it
                          // would be exactly the ghosting this replaced.
                          // Only a new turn (or speaker) fades the old
                          // line out.
                          transitionBuilder: (child, a) {
                            final k = (child.key as ValueKey<String>?)?.value;
                            final promoted = k != null &&
                                k != spotKey &&
                                k.startsWith('$_fromUser|$_turn|');
                            if (promoted) return const SizedBox.shrink();
                            return FadeTransition(opacity: a, child: child);
                          },
                          // The leaving line does not hold the space open
                          // (no size wobble): only the new one is laid out.
                          layoutBuilder: (current, previous) => Stack(
                            alignment: Alignment.topCenter,
                            clipBehavior: Clip.none,
                            children: [
                              for (final p in previous)
                                Positioned(
                                    top: 0, left: 0, right: 0, child: p),
                              if (current != null) current,
                            ],
                          ),
                          // The keyboard coming up eases the size down
                          // instead of jumping it, on the orb's 220 ms —
                          // as a picture: the line is laid out once at its
                          // new size on the keyboard's first frame, never
                          // again on the frames after it (2026-09-24,
                          // review: a font-size tween re-laid it out on
                          // every one of them).
                          child: TextResize(
                            key: ValueKey(spotKey),
                            size: spot.fontSize!,
                            duration: const Duration(milliseconds: 220),
                            curve: Curves.easeOutCubic,
                            child: Text(
                              current,
                              style: spot,
                              textAlign: TextAlign.center,
                              maxLines: typing ? 3 : 6,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          ),
                        ),
                      ],
                    );
                    }),
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
      ),
    );
  }
}

/// THE VOICE SCREEN'S TYPE (2026-09-24, the clarity pass).
///
/// Space Grotesk, the display face, is kept for the one line being spoken
/// (the spotlight) and nothing else. Its quirky y and g made the status
/// line, the older lines, the typed message and the buttons at 13–15.5 sp
/// read worse than Manrope, and look like another app beside Home and
/// Hub. Built once: the pacer rebuilds this screen five times a second,
/// and every GoogleFonts call made a new style and a font-load future.
abstract final class _VoiceType {
  static final TextStyle status =
      NeonType.manrope(NeonType.callout, FontWeight.w600).copyWith(
          color: Colors.white.withValues(alpha: 0.66), letterSpacing: 0.3);
  static final TextStyle error =
      NeonType.manrope(NeonType.rowTitle, FontWeight.w600).copyWith(
          color: Colors.white.withValues(alpha: 0.88), height: 1.3);
  static final TextStyle input =
      NeonType.manrope(NeonType.rowTitle, FontWeight.w500)
          .copyWith(color: Colors.white);

  /// 52% white (was 45%, 4.4:1): 5.3:1 on the text box, pinned by
  /// test/contrast_test.dart.
  static final TextStyle hint =
      NeonType.manrope(NeonType.rowTitle, FontWeight.w500)
          .copyWith(color: Colors.white.withValues(alpha: 0.52));
  static final TextStyle chip =
      NeonType.manrope(NeonType.footnote, FontWeight.w600)
          .copyWith(color: Colors.white.withValues(alpha: 0.66));
  static final TextStyle button =
      NeonType.manrope(NeonType.callout, FontWeight.w700);
  static final TextStyle mute =
      NeonType.manrope(NeonType.footnote, FontWeight.w700);
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

/// An older line of the words. The one that was just being spoken DIMS
/// into the others (2026-09-24, review): it is drawn in the spotlight's
/// colour and faded, as a layer, down to the older lines' brightness —
/// tweening the text's own colour would build and shape its paragraph
/// again on every frame. Once there it is plain text in the older colour,
/// with no layer, which looks exactly the same. Only a lighter colour of
/// the same hue can be faded down this way (the captions are all white on
/// the night ground); anything else, and "Remove animations", takes the
/// older colour at once.
class _DimInto extends StatefulWidget {
  const _DimInto({required this.text, required this.style, this.from});
  final String text;

  /// The older lines' style: where it ends up.
  final TextStyle style;

  /// The spotlight's colour it starts from; null: it is already older.
  final Color? from;

  @override
  State<_DimInto> createState() => _DimIntoState();
}

class _DimIntoState extends State<_DimInto>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: Motion.short, value: 1.0)
        ..addStatusListener((s) {
          // Arrived: back to plain text (one build, no more frames).
          if (s == AnimationStatus.completed && mounted) setState(() {});
        });
  Animation<double>? _fade;
  bool _begun = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_begun) return;
    _begun = true;
    final from = widget.from;
    final to = widget.style.color;
    if (from == null || to == null || Motion.reduced(context)) return;
    final sameHue = from.r == to.r && from.g == to.g && from.b == to.b;
    if (!sameHue || from.a <= to.a) return;
    _fade = _c.drive(Tween<double>(begin: 1.0, end: to.a / from.a)
        .chain(CurveTween(curve: Motion.easeMove)));
    _c.forward(from: 0.0);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fade = _fade;
    if (fade == null || !_c.isAnimating) {
      return Text(widget.text, textAlign: TextAlign.center, style: widget.style);
    }
    return FadeTransition(
      opacity: fade,
      child: Text(
        widget.text,
        textAlign: TextAlign.center,
        style: widget.style.copyWith(color: widget.from),
      ),
    );
  }
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
            style: _VoiceType.button.copyWith(
              color: primary ? Colors.white : Colors.white.withValues(alpha: 0.8),
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
          // 48 dp tall, like every other target on this screen (was 44).
          constraints: const BoxConstraints(minHeight: 48),
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
                style: _VoiceType.mute.copyWith(
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
          // The resting outline at 22% white: at 10% it was 1.26:1 and the
          // box all but vanished when not focused.
          border: Border.all(
            color: focused
                ? Neon.violet.withValues(alpha: 0.55)
                : Colors.white.withValues(alpha: 0.22),
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
                style: _VoiceType.input,
                decoration: InputDecoration(
                  isDense: true,
                  filled: false,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  disabledBorder: InputBorder.none,
                  hintText: connecting ? 'Connecting…' : 'Type a message…',
                  hintStyle: _VoiceType.hint,
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
                        // Neon.onBrand on the gradient: white was 2.4:1 on
                        // the evening theme's pastel accent.
                        child: Icon(Icons.arrow_upward_rounded,
                            color: canSend
                                ? Neon.onBrand
                                : Colors.white.withValues(alpha: 0.35),
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
    if (t != null) _shown = t;
    final shown = _shown;
    // Above the dock and the mic, and above the toast while one is up.
    final bottom =
        AppFeedback.clearOfToast(Dock.clearance(context, gap: 12));
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
