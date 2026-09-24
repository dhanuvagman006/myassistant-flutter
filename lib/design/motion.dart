import 'dart:async';

import 'package:flutter/gestures.dart' show kTouchSlop;
import 'package:flutter/material.dart';

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
///   * Navigation is at most 350 ms. Pages take 240 ms in, 200 ms back.
///   * Nothing bounces. The one exception is the "connected" tick on the
///     email setup screen, the app's single success moment.
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

  /// Switching tabs in the dock: a fade-through, no slide (tabs are peers).
  static const Duration tab = Duration(milliseconds: 180);

  /// A page opening.
  static const Duration pageIn = Duration(milliseconds: 240);

  /// A page closing (Back).
  static const Duration pageBack = Duration(milliseconds: 200);

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

/// PRESS FEEDBACK: the child dips to 97% under a finger that RESTS on it.
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
class PressScale extends StatefulWidget {
  final Widget child;
  const PressScale({super.key, required this.child});

  @override
  State<PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<PressScale> {
  bool _down = false;
  int? _pointer;
  Offset _origin = Offset.zero;
  Timer? _hold;
  Timer? _blip;

  void _set(bool down) {
    if (mounted && _down != down) setState(() => _down = down);
  }

  void _onDown(PointerDownEvent e) {
    if (_pointer != null || Motion.reduced(context)) return;
    _pointer = e.pointer;
    _origin = e.position;
    _blip?.cancel();
    _hold?.cancel();
    _hold = Timer(Motion.pressDelay, () => _set(true));
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
        scale: _down ? 0.97 : 1.0,
        duration: _down ? Motion.press : Motion.release,
        curve: _down ? Curves.easeOut : Motion.easeMove,
        // A snapshot while it moves (see the rules above).
        filterQuality: FilterQuality.medium,
        child: widget.child,
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
  });

  /// True while there is nothing to show yet.
  final bool loading;

  /// What to show once loaded (the list, the empty state, the error).
  final Widget child;

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
        ? KeyedSubtree(key: const ValueKey('loaded'), child: widget.child)
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
      child: shown,
    );
  }
}

/// THE APP'S BOTTOM SHEET. The SDK's sheet is fine but belongs to another
/// family (250 ms on a legacy curve) and ignores "Remove animations". Same
/// signature as [showModalBottomSheet], on the app's clock: 300 ms in on
/// the arrival curve, 200 ms out on the leaving one.
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
        duration: Motion.enter,
        reverseDuration: Motion.pageBack,
        curve: Motion.easeEnter,
        // Reverse runs the clock backwards: flipped, it eases off and goes.
        reverseCurve: Motion.easeExit.flipped,
      );

/// THE APP'S DIALOG. The SDK's 150 ms fade blinked in; this one takes
/// 200 ms in and 150 ms out. Same signature as [showDialog].
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
  return showDialog<T>(
    context: context,
    builder: builder,
    barrierDismissible: barrierDismissible,
    barrierColor: barrierColor,
    barrierLabel: barrierLabel,
    useSafeArea: useSafeArea,
    useRootNavigator: useRootNavigator,
    routeSettings: routeSettings,
    animationStyle: Motion.reduced(context)
        ? const AnimationStyle(
            duration: Motion.out, reverseDuration: Motion.out)
        : const AnimationStyle(
            duration: Motion.short,
            reverseDuration: Motion.micro,
            curve: Motion.easeFadeIn,
            reverseCurve: Motion.easeFadeIn,
          ),
  );
}
