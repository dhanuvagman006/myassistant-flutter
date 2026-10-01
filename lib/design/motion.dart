import 'dart:async';
import 'dart:ui' show lerpDouble;

import 'package:flutter/gestures.dart' show kTouchSlop;
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart' show SpringSimulation;
import 'package:flutter/services.dart' show HapticFeedback;

import 'neon_tokens.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  MOTION — one clock and one set of curves for the whole app
///  (2026-09-24, "need more smoothness while using the app").
///
///  The app did not feel slow, it felt INCONSISTENT: eleven different
///  durations (110 to 650 ms) and eight curves were typed by hand at each
///  call site, and six animations were silently linear because nobody gave
///  them a curve. A page rose, a card blinked in, the dock bounced and a
///  sheet slid, each on its own clock. Every moving thing now reads its
///  timing from here.
///
///  THE RULES
///   * Things ARRIVE on a decelerate curve ([Motion.easeEnter]) and LEAVE
///     on an accelerate one ([Motion.easeExit]): fast in, gone quickly,
///     nothing lingers at the end of a move.
///   * Things that simply CHANGE (a pill, a highlight, a size) use
///     [Motion.easeMove]. Fades use [Motion.easeFadeIn] / [Motion.easeFadeOut].
///   * Navigation is at most 350 ms. Pages push in from the side in
///     280 ms and go back in 240 ms (theme/app_theme.dart); tabs open in a
///     circle from the dock or follow a swipe (tab_deck.dart).
///   * A surface opened from something comes FROM it: a sheet rises from
///     the bottom edge, a dialog grows from 94% at the centre, a menu
///     unfolds from its button, and the same object on two screens flies
///     between them (a Hub row's title becomes the page's title).
///   * Nothing bounces, with two exceptions: the "connected" tick on the
///     email setup screen, the app's single success moment, and the sheet,
///     which rises on a spring damped to 0.72 ([Motion.sheetRise]) — a
///     3.8% lift and settle the owner asked to feel (2026-09-30).
///   * A stagger plays on FIRST APPEARANCE only, never on a rebuild or a
///     refresh — a page must not twitch because its data arrived again.
///   * Nothing keeps a ticker running once it has settled; an idle screen
///     asks the phone for no frames at all (see smoothness_test).
///   * "Remove animations" (Samsung: Accessibility › Visibility
///     enhancements) is honoured everywhere through [Motion.reduced]:
///     entrances become short fades or nothing, and nothing slides.
///   * A widget that SCALES text while it animates does so as a snapshot
///     (FilterQuality.medium, applied only while animating): on the phone's
///     renderer every new scale step of a glyph is otherwise a new glyph to
///     rasterise, which is a hitch on exactly the frame of a tap.
///   * Text never changes size by tweening its font size: that lays it out
///     again, at a new size, on every frame. It is laid out once at the new
///     size and drawn from the old one ([TextResize]).
/// ─────────────────────────────────────────────────────────────────────────
abstract final class Motion {
  // ── Durations ──────────────────────────────────────────────────────────
  /// A finger going down: the press dip.
  static const Duration press = Duration(milliseconds: 100);

  /// A finger lifting: the press dip coming back.
  static const Duration release = Duration(milliseconds: 150);

  /// How long a finger must rest before a press dips (as InkWell waits
  /// before it highlights) — so a scroll that starts on a tile never makes
  /// it flinch.
  static const Duration pressDelay = Duration(milliseconds: 80);

  /// Small state changes: an icon swap, a colour, a highlight.
  static const Duration micro = Duration(milliseconds: 150);

  /// The usual change: a pill, a size, a card swap.
  static const Duration short = Duration(milliseconds: 200);

  /// Something leaving: quicker than it arrived.
  static const Duration out = Duration(milliseconds: 120);

  /// A quick fade, where a switch needs one (reduced motion keeps it).
  static const Duration tab = Duration(milliseconds: 180);

  /// A tab chosen in the dock COMING THROUGH (tab_deck.dart): a ring of
  /// light bursts from the button, the new tab grows out of it and fades
  /// in, the old one falls back and fades away. Compositor work and one
  /// stroked circle, so it holds 60 fps on the owner's phone. It replaced a 560 ms circle grown from the button
  /// (2026-09-30, the owner: "feels a bit laggy and old" — the circle
  /// clipped and repainted the whole page every frame).
  // 520 ms (owner, 2026-09-30, after 320: "too fast, fix it or remove
  // it"): long enough to be seen, and a touch still ends it at once.
  static const Duration tabSwitch = Duration(milliseconds: 520);

  /// A page opening: pushed in from the right edge.
  static const Duration pageIn = Duration(milliseconds: 280);

  /// A page closing (Back).
  static const Duration pageBack = Duration(milliseconds: 240);

  /// A sheet, panel or card arriving over the page.
  static const Duration enter = Duration(milliseconds: 300);

  /// A section settling in the first time a screen is seen.
  static const Duration reveal = Duration(milliseconds: 280);

  /// The step between staggered sections...
  static const Duration stagger = Duration(milliseconds: 40);

  /// ...and the most any of them waits. The sent-email list staggered
  /// 30 ms a row with no cap: row twenty started 570 ms after the page.
  static const Duration staggerCap = Duration(milliseconds: 200);

  // ── Curves ─────────────────────────────────────────────────────────────
  /// Arriving: Material's emphasized decelerate. Fast, then settles.
  static const Curve easeEnter = Cubic(0.05, 0.7, 0.1, 1.0);

  /// Leaving: Material's emphasized accelerate. Eases off, then goes.
  static const Curve easeExit = Cubic(0.3, 0.0, 0.8, 0.15);

  /// Changing in place: Material's standard easing.
  static const Curve easeMove = Cubic(0.2, 0.0, 0.0, 1.0);

  /// Fading in.
  static const Curve easeFadeIn = Curves.easeOut;

  /// Fading out.
  static const Curve easeFadeOut = Curves.easeIn;

  // ── Springs ────────────────────────────────────────────────────────────
  /// What a swiped surface settles on after the finger lifts: critically
  /// damped (no bounce, as the rules say), carrying the flick's speed, done
  /// in about a quarter of a second.
  static const SpringDescription swipeSpring =
      SpringDescription(mass: 1, stiffness: 520, damping: 45.6);

  /// A SHEET RISES ON A SPRING (2026-09-30, motion audit): the old 300 ms
  /// on the arrival curve slid in like a drawer. The owner, same day:
  /// "add some more delay to get real effect" — the first spring (0.9,
  /// 360 ms) was too quick to feel. Now damping ratio 0.72
  /// (21.4 / (2·√220)): 80% of the way in 150 ms, a visible 3.8% lift past
  /// its rest at ~300 ms, settled by 600 ms.
  static const SpringDescription sheetSpring =
      SpringDescription(mass: 1, stiffness: 220, damping: 21.4);

  /// How long a sheet takes to rise: [sheetSpring]'s settling time.
  static const Duration sheetIn = Duration(milliseconds: 600);

  /// [sheetSpring] as a curve over [sheetIn] ([showAppSheet]). One
  /// instance: the SDK's sheet asserts its curve never changes.
  static final Curve sheetRise = SpringCurve(sheetSpring, settle: sheetIn);

  /// Has the owner turned animations off (Samsung "Remove animations")?
  /// Flutter reports it but does not act on it — every animation here has
  /// to ask. Default false, so tests and phones without it are unchanged.
  static bool reduced(BuildContext context) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;
}

/// ONE-SHOT ENTRANCE for anything that appears over the page: a card, a
/// sheet, a panel, the mic coming back. Fades in while it grows from
/// [scaleFrom] and/or rises [rise] dp (or shifts [shift] dp sideways), once,
/// when it is first built. A rebuild never replays it; a new key does.
///
/// Moves as a picture, not by being drawn again: the child sits on its own
/// layer, and the scale is applied to a snapshot only while it animates.
/// With "Remove animations" on it is a short fade with no movement.
class EnterOnce extends StatefulWidget {
  const EnterOnce({
    super.key,
    required this.child,
    this.duration = Motion.enter,
    this.delay = Duration.zero,
    this.curve = Motion.easeEnter,
    this.fade = true,
    this.fadeCurve = Motion.easeFadeIn,
    this.scaleFrom = 1.0,
    this.rise = 0.0,
    this.shift = 0.0,
    this.alignment = Alignment.center,
    this.origin = Offset.zero,
    this.yieldToPage = false,
  });

  final Widget child;
  final Duration duration;

  /// Waits this long before starting (for a stagger).
  final Duration delay;

  /// The curve of the movement (scale, rise, shift).
  final Curve curve;

  /// Fade in as well (on [fadeCurve]). Off when something above already
  /// fades this in (the answer card's own fade, for instance).
  final bool fade;
  final Curve fadeCurve;

  /// Starting scale, about [alignment]. 1 = no scale.
  final double scaleFrom;

  /// Starting offset below the resting place, in dp.
  final double rise;

  /// Starting horizontal offset, in dp (negative: from the left).
  final double shift;

  /// The point it grows from — bottomCenter for cards that come out of
  /// the mic...
  final Alignment alignment;

  /// ...moved by this many dp (for a sheet whose content ends above its
  /// own bottom edge, and must not move there while it grows).
  final Offset origin;

  /// Skip the entrance when the page this is on is itself sliding in: the
  /// page's own transition already brings it in, and a second drift on
  /// top of it left call detail and meeting detail still moving 600 ms
  /// after the tap. (A pushed page is built before its transition starts,
  /// at which point it is still fully transparent — so this is decided
  /// right after that first frame, before anything of it can be seen.)
  final bool yieldToPage;

  @override
  State<EnterOnce> createState() => _EnterOnceState();
}

class _EnterOnceState extends State<EnterOnce>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: widget.duration);
  late final Animation<double> _move =
      _c.drive(CurveTween(curve: widget.curve));
  late final Animation<double> _fade =
      _c.drive(CurveTween(curve: widget.fadeCurve));
  Timer? _wait;
  bool _started = false;
  bool _still = false; // reduced motion: fade only

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _still = Motion.reduced(context);
    if (_still) _c.duration = Motion.out;
    if (widget.delay <= Duration.zero || _still) {
      _c.forward();
    } else {
      _wait = Timer(widget.delay, () {
        if (mounted) _c.forward();
      });
    }
    if (widget.yieldToPage && !_still) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final page = ModalRoute.of(context)?.animation;
        if (page != null && page.status == AnimationStatus.forward) {
          _wait?.cancel();
          _c.value = 1.0; // already in place, moving with its page
        }
      });
    }
  }

  @override
  void dispose() {
    _wait?.cancel();
    _c.dispose();
    super.dispose();
  }

  bool get _moves =>
      !_still &&
      (widget.scaleFrom != 1.0 || widget.rise != 0.0 || widget.shift != 0.0);

  @override
  Widget build(BuildContext context) {
    Widget child = RepaintBoundary(child: widget.child);
    if (_moves) {
      final from = widget.scaleFrom;
      child = _Moving(
        animation: _move,
        alignment: widget.alignment,
        origin: widget.origin,
        // A snapshot while scaling, so text is not re-rasterised at every
        // step — only while animating.
        filterQuality: from != 1.0 ? FilterQuality.medium : null,
        onTransform: (v) {
          final k = 1.0 - v;
          final s = from + (1.0 - from) * v;
          return Matrix4.diagonal3Values(s, s, 1.0)
            ..setTranslationRaw(widget.shift * k, widget.rise * k, 0.0);
        },
        child: child,
      );
    }
    if (widget.fade || _still) {
      child = FadeTransition(
        opacity: _fade,
        child: child,
      );
    }
    return child;
  }
}

/// [MatrixTransition] with an [origin] as well: the transform is applied
/// about `alignment + origin`, and the snapshot quality only while moving.
class _Moving extends AnimatedWidget {
  const _Moving({
    required Animation<double> animation,
    required this.onTransform,
    required this.alignment,
    required this.origin,
    required this.filterQuality,
    required this.child,
  }) : super(listenable: animation);

  final Matrix4 Function(double) onTransform;
  final Alignment alignment;
  final Offset origin;
  final FilterQuality? filterQuality;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final a = listenable as Animation<double>;
    return Transform(
      transform: onTransform(a.value),
      alignment: alignment,
      origin: origin,
      filterQuality: a.isAnimating ? filterQuality : null,
      child: child,
    );
  }
}

/// TEXT THAT CHANGES SIZE MOVES AS A PICTURE (2026-09-24, review of the
/// voice screen). The spoken line grew and shrank by tweening its font
/// size — 24 to 17 pt as the keyboard came up, 24 to 15.5 pt as a finished
/// line joined the older ones — so every one of those frames shaped and
/// laid the words out again, and every in-between size was a new set of
/// glyphs for the phone to rasterise: on the very keyboard frames that
/// phaseB-smooth had just made cheap.
///
/// [child] is laid out ONCE, at its new [size]. The change is shown by
/// drawing that layout scaled from the size it was on screen a moment ago
/// to 1, about [alignment], as a snapshot while it moves (see the rules
/// above). At rest it is the plain child: no layer, no filter, no ticker.
/// A change in the middle of a move carries on from where it is drawn.
/// With "Remove animations" on, the new size is simply there.
class TextResize extends StatefulWidget {
  const TextResize({
    super.key,
    required this.size,
    required this.child,
    this.from,
    this.duration = Motion.short,
    this.curve = Motion.easeMove,
    this.alignment = Alignment.topCenter,
  });

  /// The font size [child] is laid out at.
  final double size;

  /// The size it was on screen before it was built here (a line moving in
  /// from a bigger style): it arrives from that. Read on the first build
  /// only; null arrives as it is.
  final double? from;

  final Duration duration;
  final Curve curve;

  /// The point that stays put while it resizes (the top of a line, so the
  /// lines under it do not see it move).
  final Alignment alignment;

  final Widget child;

  @override
  State<TextResize> createState() => _TextResizeState();
}

class _TextResizeState extends State<TextResize>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: widget.duration, value: 1.0);

  /// The scale drawn when the move started (1: nothing to move).
  double _start = 1.0;
  bool _still = false; // reduced motion: no move
  bool _begun = false;

  double get _scale =>
      _start + (1.0 - _start) * widget.curve.transform(_c.value);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _still = Motion.reduced(context);
    if (_still) _rest();
    if (_begun) return;
    _begun = true;
    final from = widget.from;
    if (from != null) _moveFrom(from);
  }

  @override
  void didUpdateWidget(TextResize old) {
    super.didUpdateWidget(old);
    _c.duration = widget.duration;
    // From the size it is drawn at now, not the size it was laid out at.
    if (widget.size != old.size) _moveFrom(old.size * _scale);
  }

  /// Move from [drawn] (the font size on screen now) to [TextResize.size].
  void _moveFrom(double drawn) {
    if (_still || drawn <= 0 || widget.size <= 0 || drawn == widget.size) {
      _rest();
      return;
    }
    _start = drawn / widget.size;
    _c.forward(from: 0.0);
  }

  void _rest() {
    _start = 1.0;
    if (_c.isAnimating || _c.value != 1.0) _c.value = 1.0;
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _c,
        // The child is built once; only the picture's scale moves.
        builder: (_, child) => Transform.scale(
          scale: _scale,
          alignment: widget.alignment,
          // A snapshot only while it moves: at rest the scale is exactly 1
          // and the text is drawn as it is, with no layer.
          filterQuality: _c.isAnimating ? FilterQuality.medium : null,
          child: child,
        ),
        child: widget.child,
      );
}

/// One-shot entrance for a section of a screen: fade in while drifting up
/// 14 dp. Plays when the widget first mounts (optionally after [delayMs],
/// for a stagger) and never replays on rebuilds — a refresh must not make
/// the page twitch.
///
/// CHEAPER THAN IT WAS (2026-09-24). It used to be an Opacity over two
/// Transforms driven by a builder: every one of its 380 ms re-recorded the
/// whole section — the month calendar included — and its 1.5% scale made
/// the phone rasterise the section's text at a new size on most frames,
/// right on Home's heaviest frames. It now fades a layer and slides the
/// section's own layer, which is drawn once; the scale that nobody could
/// see is gone.
///
/// No drift at all when "Remove animations" is on, or when the page it is
/// on is still sliding in (the page's own transition brings it in).
class Reveal extends StatefulWidget {
  final Widget child;
  final int delayMs;
  const Reveal({super.key, required this.child, this.delayMs = 0});

  @override
  State<Reveal> createState() => _RevealState();
}

class _RevealState extends State<Reveal> {
  // Decided once, on the first build: whether this section drifts in.
  bool? _animate;

  @override
  Widget build(BuildContext context) {
    _animate ??= !Motion.reduced(context);
    if (!_animate!) return widget.child;
    final wait = Duration(milliseconds: widget.delayMs);
    return EnterOnce(
      duration: Motion.reveal,
      yieldToPage: true,
      delay: wait > Motion.staggerCap ? Motion.staggerCap : wait,
      curve: Curves.easeOutCubic,
      fadeCurve: Curves.easeOutCubic,
      rise: 14,
      child: widget.child,
    );
  }
}

/// A SPRING AS A CURVE (2026-09-30): [spring] released at rest from 0
/// towards 1, sampled over [settle], for anything that takes a [Curve]
/// (an AnimationStyle, a CurvedAnimation). Starts at exactly 0 and ends at
/// exactly 1 (the spring is within a pixel of 1 by then).
class SpringCurve extends Curve {
  SpringCurve(this.spring, {required Duration settle})
      : _sim = SpringSimulation(spring, 0, 1, 0),
        _seconds = settle.inMicroseconds / Duration.microsecondsPerSecond;

  final SpringDescription spring;
  final SpringSimulation _sim;
  final double _seconds;

  @override
  double transformInternal(double t) => _sim.x(t * _seconds);
}

/// PRESS FEEDBACK: the child dips to [PressScale.scale] under a finger that
/// RESTS on it.
///
/// Uses a [Listener], so the child's own GestureDetector/InkWell still
/// receives the tap — this only watches the pointer, it never claims it.
///
/// NOT ON A SCROLL (2026-09-24). It used to dip on the raw pointer-down and
/// stay dipped until the finger lifted, so every scroll or swipe that
/// started on a tile held that tile at 96% for the whole drag and sprang it
/// back afterwards — on Home, most scrolls made something flinch. It now
/// waits 80 ms (as InkWell does before it highlights) and gives up the
/// moment the finger travels, so only a real press dips. A quick tap still
/// gets a short dip, after the fact. Off with "Remove animations".
///
/// AT ONCE WHERE NOTHING SCROLLS (2026-09-30, motion audit): the 80 ms
/// wait is only there so a scroll that starts on a tile does not make it
/// flinch. A dock button, a sheet's button or a card on a still page has
/// no scroll to protect, and there the wait made every tap feel late, so
/// it dips on the finger's first touch. Inside a [Scrollable] it still
/// waits.
class PressScale extends StatefulWidget {
  final Widget child;

  /// How far it dips: 0.97 for a card or a button; 0.985 for a full-width
  /// row, where the same dip moves the edges three times as far.
  final double scale;
  const PressScale({super.key, required this.child, this.scale = 0.97});

  @override
  State<PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<PressScale> {
  bool _down = false;
  int? _pointer;
  Offset _origin = Offset.zero;
  Timer? _hold;
  Timer? _blip;

  /// Inside something that scrolls: wait before dipping (see above).
  bool _inScroll = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _inScroll = Scrollable.maybeOf(context) != null;
  }

  void _set(bool down) {
    if (mounted && _down != down) setState(() => _down = down);
  }

  void _onDown(PointerDownEvent e) {
    if (_pointer != null || Motion.reduced(context)) return;
    _pointer = e.pointer;
    _origin = e.position;
    _blip?.cancel();
    _hold?.cancel();
    if (_inScroll) {
      _hold = Timer(Motion.pressDelay, () => _set(true));
    } else {
      _set(true);
    }
  }

  void _onMove(PointerMoveEvent e) {
    if (e.pointer != _pointer) return;
    // Travelled: this is a scroll or a swipe, not a press.
    if ((e.position - _origin).distance > kTouchSlop) _cancel();
  }

  void _onUp(PointerUpEvent e) {
    if (e.pointer != _pointer) return;
    _pointer = null;
    final pending = _hold?.isActive ?? false;
    _hold?.cancel();
    if (pending) {
      // A quick tap: acknowledge it with a short dip anyway.
      _set(true);
      _blip = Timer(Motion.press, () => _set(false));
    } else {
      _set(false);
    }
  }

  void _cancel() {
    _pointer = null;
    _hold?.cancel();
    _set(false);
  }

  @override
  void dispose() {
    _hold?.cancel();
    _blip?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onDown,
      onPointerMove: _onMove,
      onPointerUp: _onUp,
      onPointerCancel: (e) {
        if (e.pointer == _pointer) _cancel();
      },
      child: AnimatedScale(
        scale: _down ? widget.scale : 1.0,
        duration: _down ? Motion.press : Motion.release,
        curve: _down ? Curves.easeOut : Motion.easeMove,
        // A snapshot while it moves (see the rules above).
        filterQuality: FilterQuality.medium,
        child: widget.child,
      ),
    );
  }
}

/// THE APP'S TAPPABLE SURFACE (2026-09-30, promoted from Home's card tap):
/// a card, tile or thumbnail that does something when touched. It dips
/// under the finger ([PressScale], at [scale]), ticks once (a light
/// selection haptic), and tells a screen reader it is a button and what a
/// tap does ([semanticLabel], [tapHint]). Buttons inside it still win
/// their own taps. With neither [onTap] nor [onLongPress] it is [child],
/// untouched.
class Tappable extends StatelessWidget {
  const Tappable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.scale = 0.97,
    this.semanticLabel,
    this.tapHint = 'open',
    this.haptic = true,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// How far it dips ([PressScale.scale]): 0.985 for a full-width row.
  final double scale;

  /// What it is, for a screen reader, when [child]'s own words do not say.
  final String? semanticLabel;

  /// What a tap does ("open", "play"), read after the label.
  final String? tapHint;

  /// The light tick on a tap (a firmer one on a long press).
  final bool haptic;

  @override
  Widget build(BuildContext context) {
    final tap = onTap, hold = onLongPress;
    if (tap == null && hold == null) return child;
    return Semantics(
      button: true,
      label: semanticLabel,
      onTapHint: tap == null ? null : tapHint,
      child: PressScale(
        scale: scale,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: tap == null
              ? null
              : () {
                  if (haptic) HapticFeedback.selectionClick();
                  tap();
                },
          onLongPress: hold == null
              ? null
              : () {
                  if (haptic) HapticFeedback.mediumImpact();
                  hold();
                },
          child: child,
        ),
      ),
    );
  }
}

/// SPINNER TO CONTENT WITHOUT A FLASH (2026-09-24).
///
/// Lists used to swap spinner and content in one frame, and a fast or
/// cached load flashed a spinner for one to three frames in the middle of
/// the page sliding in. The spinner now shows only when loading takes
/// longer than 300 ms, and content fades in over whatever was there. Same
/// data, same states: this only changes how the switch looks.
class LoadSwitch extends StatefulWidget {
  const LoadSwitch({
    super.key,
    required this.loading,
    required this.child,
    this.spinner = const Center(child: CircularProgressIndicator()),
    this.state = 'loaded',
  });

  /// True while there is nothing to show yet.
  final bool loading;

  /// What to show once loaded (the list, the empty state, the error).
  final Widget child;

  /// Which of those [child] is ('list', 'empty', 'error'…): a change of
  /// state is shown as one (the old fades and sinks, the new fades and
  /// rises), where a list merely growing is not.
  final Object state;

  /// What to show when loading is slow.
  final Widget spinner;

  /// How long a load may take before the spinner appears.
  static const Duration spinnerDelay = Duration(milliseconds: 300);

  @override
  State<LoadSwitch> createState() => _LoadSwitchState();
}

class _LoadSwitchState extends State<LoadSwitch> {
  bool _slow = false;
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _arm();
  }

  @override
  void didUpdateWidget(LoadSwitch old) {
    super.didUpdateWidget(old);
    if (widget.loading != old.loading) _arm();
  }

  void _arm() {
    _t?.cancel();
    _slow = false;
    if (widget.loading) {
      _t = Timer(LoadSwitch.spinnerDelay, () {
        if (mounted) setState(() => _slow = true);
      });
    }
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Widget shown = !widget.loading
        ? KeyedSubtree(key: ValueKey<Object>(widget.state), child: widget.child)
        : _slow
            ? KeyedSubtree(key: const ValueKey('slow'), child: widget.spinner)
            : const SizedBox.shrink(key: ValueKey('wait'));
    if (Motion.reduced(context)) return shown;
    return AnimatedSwitcher(
      duration: Motion.short,
      reverseDuration: Motion.out,
      switchInCurve: Motion.easeFadeIn,
      switchOutCurve: Motion.easeFadeOut,
      layoutBuilder: (current, previous) => Stack(
        alignment: Alignment.topCenter,
        children: [...previous, if (current != null) current],
      ),
      transitionBuilder: stateTransition,
      child: shown,
    );
  }
}

/// THE APP'S BOTTOM SHEET. The SDK's sheet is fine but belongs to another
/// family (250 ms on a legacy curve) and ignores "Remove animations". Same
/// signature as [showModalBottomSheet], on the app's clock: it rises in
/// [Motion.sheetIn] (600 ms) on [Motion.sheetRise], a spring with a
/// visible settle, and leaves in [Motion.pageBack] (240 ms) on the leaving
/// curve. A sheet let go mid-drag carries on from where the finger left it.
Future<T?> showAppSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  Color? backgroundColor,
  ShapeBorder? shape,
  Clip? clipBehavior,
  BoxConstraints? constraints,
  Color? barrierColor,
  bool isScrollControlled = false,
  bool useRootNavigator = false,
  bool isDismissible = true,
  bool enableDrag = true,
  bool? showDragHandle,
  bool useSafeArea = false,
  RouteSettings? routeSettings,
}) {
  return showModalBottomSheet<T>(
    context: context,
    builder: builder,
    backgroundColor: backgroundColor,
    shape: shape,
    clipBehavior: clipBehavior,
    constraints: constraints,
    barrierColor: barrierColor,
    isScrollControlled: isScrollControlled,
    useRootNavigator: useRootNavigator,
    isDismissible: isDismissible,
    enableDrag: enableDrag,
    showDragHandle: showDragHandle,
    useSafeArea: useSafeArea,
    routeSettings: routeSettings,
    sheetAnimationStyle: appSheetAnimation(context),
  );
}

/// The sheet timing on its own, for sheets built by hand
/// ([ModalBottomSheetRoute]).
AnimationStyle appSheetAnimation(BuildContext context) => Motion.reduced(context)
    ? const AnimationStyle(
        duration: Motion.out, reverseDuration: Motion.out)
    : AnimationStyle(
        duration: Motion.sheetIn,
        reverseDuration: Motion.pageBack,
        curve: Motion.sheetRise,
        // Reverse runs the clock backwards: flipped, it eases off and goes.
        reverseCurve: Motion.easeExit.flipped,
      );

/// THE APP'S DIALOG. It grows from 94% at the centre as it fades in on the
/// arrival curve and shrinks back as it fades out on the leaving one, over
/// the night scrim — a surface that opens, not one that blinks in. Both
/// ways take [Motion.short] (200 ms): showGeneralDialog has one duration,
/// so the close is quicker only by its curve. Same signature as
/// [showDialog].
Future<T?> showAppDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  Color? barrierColor,
  String? barrierLabel,
  bool useSafeArea = true,
  bool useRootNavigator = true,
  RouteSettings? routeSettings,
}) {
  final reduced = Motion.reduced(context);
  final theme = Theme.of(context);
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierColor: barrierColor ?? theme.dialogTheme.barrierColor ?? Colors.black54,
    barrierLabel: barrierLabel ??
        (barrierDismissible ? MaterialLocalizations.of(context).modalBarrierDismissLabel : null),
    useRootNavigator: useRootNavigator,
    routeSettings: routeSettings,
    transitionDuration: reduced ? Motion.out : Motion.short,
    pageBuilder: (context, _, __) {
      final dialog = Builder(builder: builder);
      return useSafeArea ? SafeArea(child: dialog) : dialog;
    },
    transitionBuilder: (context, animation, _, child) {
      final fade = CurvedAnimation(
          parent: animation, curve: Motion.easeFadeIn, reverseCurve: Motion.easeFadeOut);
      if (reduced) return FadeTransition(opacity: fade, child: child);
      return FadeTransition(
        opacity: fade,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.94, end: 1).animate(CurvedAnimation(
              parent: animation, curve: Motion.easeEnter, reverseCurve: Motion.easeExit.flipped)),
          child: child,
        ),
      );
    },
  );
}

/// A popup menu's timing: it unfolds from its button on the arrival curve
/// and folds away quicker.
AnimationStyle appMenuAnimation(BuildContext context) => Motion.reduced(context)
    ? const AnimationStyle(duration: Motion.out, reverseDuration: Motion.out)
    : const AnimationStyle(
        duration: Motion.short,
        reverseDuration: Motion.out,
        curve: Motion.easeEnter,
        reverseCurve: Motion.easeExit,
      );

/// THE SAME OBJECT ON TWO SCREENS FLIES BETWEEN THEM. A page's title and
/// the row that opened it (Hub) carry the same tag; the words travel from
/// the row into the page's bar while the page pushes in, scaled whole
/// rather than laid out again at every size.
Object titleHeroTag(String title) => 'page-title:$title';

Widget titleFlight(BuildContext flightContext, Animation<double> animation,
    HeroFlightDirection direction, BuildContext fromContext, BuildContext toContext) {
  final to = (direction == HeroFlightDirection.push ? toContext : fromContext).widget as Hero;
  return Material(
    type: MaterialType.transparency,
    child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: to.child),
  );
}

/// A CARD OPENS INTO ITS PAGE (2026-09-30, motion audit). The card
/// (GlowCard(heroTag: cardHeroTag(id))) and the top of the page it opens
/// (Hero(tag: cardHeroTag(id), flightShuttleBuilder: cardFlight, …)) carry
/// the same tag; while the page pushes in, one surface grows from the
/// card's place and size to the page's, its corners straightening as it
/// goes, the card's content fading out as the page's fades in. Back runs
/// it the other way. Tags must be unique on a screen: use the item's id.
Object cardHeroTag(Object id) => ('card-hero', id);

/// The shuttle for a [cardHeroTag] flight: a card with the app's radius
/// ([Neon.rLg]) opening into a full-bleed block (radius 0). Give both
/// Heroes the same builder; [cardFlightFor] for other radii.
Widget cardFlight(BuildContext flightContext, Animation<double> animation,
        HeroFlightDirection direction, BuildContext fromContext, BuildContext toContext) =>
    _cardFlight(Neon.rLg, 0, animation, direction, fromContext, toContext);

/// [cardFlight] for a card of [cardRadius] opening into a block of
/// [pageRadius].
HeroFlightShuttleBuilder cardFlightFor({double cardRadius = Neon.rLg, double pageRadius = 0}) =>
    (flightContext, animation, direction, fromContext, toContext) =>
        _cardFlight(cardRadius, pageRadius, animation, direction, fromContext, toContext);

Widget _cardFlight(double cardRadius, double pageRadius, Animation<double> animation,
    HeroFlightDirection direction, BuildContext fromContext, BuildContext toContext) {
  // The flight's animation is the page's own: 0 is the card, 1 the page,
  // whichever way it flies.
  final push = direction == HeroFlightDirection.push;
  final card = push ? fromContext : toContext;
  final page = push ? toContext : fromContext;
  Size? sizeOf(BuildContext c) {
    final box = c.findRenderObject();
    return box is RenderBox && box.hasSize ? box.size : null;
  }

  return _CardFlight(
    animation: animation,
    card: (card.widget as Hero).child,
    page: (page.widget as Hero).child,
    cardSize: sizeOf(card),
    pageSize: sizeOf(page),
    cardRadius: cardRadius,
    pageRadius: pageRadius,
  );
}

class _CardFlight extends AnimatedWidget {
  const _CardFlight({
    required Animation<double> animation,
    required this.card,
    required this.page,
    required this.cardSize,
    required this.pageSize,
    required this.cardRadius,
    required this.pageRadius,
  }) : super(listenable: animation);

  final Widget card, page;
  final Size? cardSize, pageSize;
  final double cardRadius, pageRadius;

  // The card's words are gone by 45% of the way; the page's arrive from 35%.
  static const Curve _cardOut = Interval(0, 0.45, curve: Motion.easeFadeOut);
  static const Curve _pageIn = Interval(0.35, 1, curve: Motion.easeFadeIn);

  /// [child] laid out at its own [size] and drawn scaled to the flying
  /// surface's width, as a snapshot (the rules above): never laid out
  /// again at every size in between.
  static Widget _fit(Widget child, Size? size, double width) {
    if (size == null || size.isEmpty || !width.isFinite) return child;
    return OverflowBox(
      alignment: Alignment.topLeft,
      minWidth: size.width,
      maxWidth: size.width,
      minHeight: size.height,
      maxHeight: size.height,
      child: Transform.scale(
        scale: width / size.width,
        alignment: Alignment.topLeft,
        filterQuality: FilterQuality.medium,
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = (listenable as Animation<double>).value.clamp(0.0, 1.0);
    return Material(
      type: MaterialType.transparency,
      child: LayoutBuilder(
        builder: (context, box) => Stack(
          fit: StackFit.expand,
          clipBehavior: Clip.none,
          children: [
            // The surface that grows: size and place from the Hero, the
            // corners here, the ground from the card's to the page's.
            ClipRRect(
              borderRadius: BorderRadius.circular(lerpDouble(cardRadius, pageRadius, t)!),
              child: ColoredBox(
                color: Color.lerp(Neon.surface, Neon.bg, t)!,
                child: Opacity(opacity: _pageIn.transform(t), child: _fit(page, pageSize, box.maxWidth)),
              ),
            ),
            // The card itself, unclipped so its lit rim and halo are seen
            // leaving rather than cut off on the first frame.
            Opacity(opacity: 1 - _cardOut.transform(t), child: _fit(card, cardSize, box.maxWidth)),
          ],
        ),
      ),
    );
  }
}

/// EXPAND / COLLAPSE — a section that opens grows to its height where it
/// is and fades in; closing, it fades and shrinks away. What is below moves
/// with it instead of jumping. Pair it with [ExpandChevron] on its toggle.
class Collapse extends StatelessWidget {
  const Collapse({super.key, required this.open, required this.child});

  final bool open;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    const closed = SizedBox(key: ValueKey<bool>(false), width: double.infinity);
    if (Motion.reduced(context)) return open ? child : closed;
    return AnimatedSize(
      duration: Motion.short,
      curve: Motion.easeMove,
      alignment: Alignment.topCenter,
      child: AnimatedSwitcher(
        duration: Motion.micro,
        switchInCurve: Motion.easeFadeIn,
        switchOutCurve: Motion.easeFadeOut,
        layoutBuilder: (current, previous) => Stack(
          alignment: Alignment.topCenter,
          children: [...previous, if (current != null) current],
        ),
        child: open ? KeyedSubtree(key: const ValueKey<bool>(true), child: child) : closed,
      ),
    );
  }
}

/// The chevron of an expanding section: it turns to point the way the
/// section will go, rather than swapping for another icon.
class ExpandChevron extends StatelessWidget {
  const ExpandChevron({super.key, required this.open, this.color, this.size});

  final bool open;
  final Color? color;
  final double? size;

  @override
  Widget build(BuildContext context) => AnimatedRotation(
        turns: open ? 0.5 : 0,
        duration: Motion.reduced(context) ? Duration.zero : Motion.short,
        curve: Motion.easeMove,
        child: Icon(Icons.expand_more_rounded, color: color, size: size),
      );
}

/// A state replaced by another (loading → the list, the list → an error):
/// the new one fades in as it rises the last 8 dp into place; the old one
/// fades as it sinks. For [AnimatedSwitcher.transitionBuilder].
Widget stateTransition(Widget child, Animation<double> animation) => FadeTransition(
      opacity: animation,
      child: AnimatedBuilder(
        animation: animation,
        builder: (context, child) =>
            Transform.translate(offset: Offset(0, 8 * (1 - animation.value)), child: child),
        child: child,
      ),
    );

/// STATE SWITCH — [LoadSwitch]'s motion for a screen that already knows
/// its state: [state] names what [child] is ('loading', 'error', 'list'…),
/// and a new state replaces the old with [stateTransition].
class StateSwitch extends StatelessWidget {
  const StateSwitch({super.key, required this.state, required this.child});

  /// For a screen whose body is a different kind of widget in each state
  /// (a loader, an error, the list): the kind is the state.
  StateSwitch.of(Widget child, {Key? key}) : this(key: key, state: child.runtimeType, child: child);

  final Object state;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final shown = KeyedSubtree(key: ValueKey<Object>(state), child: child);
    if (Motion.reduced(context)) return shown;
    return AnimatedSwitcher(
      duration: Motion.short,
      reverseDuration: Motion.out,
      switchInCurve: Motion.easeEnter,
      switchOutCurve: Motion.easeFadeOut,
      layoutBuilder: (current, previous) => Stack(
        alignment: Alignment.topCenter,
        children: [...previous, if (current != null) current],
      ),
      transitionBuilder: stateTransition,
      child: shown,
    );
  }
}

/// A SURFACE THAT LEAVES, NOT VANISHES. Panels and cards arrive with their
/// own entrance ([EnterOnce]) but used to disappear in one frame when their
/// content went away. Give [child] null to take it away: the last one stays
/// for [Motion.out] while it fades and sinks [sink] dp, then is gone —
/// quick, so a Back or a ✕ still feels instant. It never takes taps once
/// leaving.
class ExitPresence extends StatefulWidget {
  const ExitPresence({super.key, required this.child, this.sink = 16});

  final Widget? child;
  final double sink;

  @override
  State<ExitPresence> createState() => _ExitPresenceState();
}

class _ExitPresenceState extends State<ExitPresence> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: Motion.out, value: 1);
  Widget? _last;

  @override
  void initState() {
    super.initState();
    _last = widget.child;
  }

  @override
  void didUpdateWidget(ExitPresence old) {
    super.didUpdateWidget(old);
    if (widget.child != null) {
      _last = widget.child;
      _c.value = 1;
    } else if (old.child != null) {
      if (Motion.reduced(context)) {
        _last = null;
      } else {
        _c.reverse(from: 1).whenCompleteOrCancel(() {
          if (mounted && widget.child == null) setState(() => _last = null);
        });
      }
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final present = widget.child;
    if (present != null) return present;
    final last = _last;
    if (last == null) return const SizedBox.shrink();
    return IgnorePointer(
      child: FadeTransition(
        opacity: CurvedAnimation(parent: _c, curve: Motion.easeFadeOut),
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, child) =>
              Transform.translate(offset: Offset(0, widget.sink * (1 - _c.value)), child: child),
          child: last,
        ),
      ),
    );
  }
}

