import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import 'motion.dart';
import 'neon_tokens.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  TAB DECK — the dock's four tabs as siblings in space (2026-09-29).
///
///  The owner: "when I click Home, Hub, Chat or You I need some animation
///  while opening", and "swipe left/right between sibling screens, the
///  next screen following the finger". Now:
///
///   * TAPPED in the dock (or chosen by voice, a notification), the new
///     tab comes THROUGH: a ring of the app's light bursts from the button
///     that was tapped, and the tab grows out of that button (from 90%),
///     fading in as it comes, while the old one falls back and fades away
///     under it. 520 ms — seen (owner, 2026-09-30: "was expecting some
///     kind of animation", then "too fast"), and a touch ends it at once.
///
///     It replaced the circle that grew from the button (2026-09-30, the
///     owner: "feels a bit laggy and old"). The circle clipped a whole
///     page of glass and glow through an anti-aliased path for 560 ms —
///     a repaint of everything on every frame, which his phone showed as
///     a stutter. The fade, lift and scale are compositor work: each tab
///     is its own layer (RepaintBoundary) and nothing is repainted.
///   * SWIPED sideways, the tabs move with the finger in dock order — the
///     next one comes in from the right, the previous from the left — and
///     letting go settles at the speed of the flick, or springs back when
///     the swipe was short. A horizontal list inside a tab keeps its own
///     swipe (the deepest scrollable wins the gesture).
///   * Every tab stays built — scroll position, a half-typed message, a
///     loaded list — and only what is on screen paints or ticks.
///   * The tab coming in takes touches at once, and a touch finishes the
///     move: it is what the user chose.
///   * Reduced motion: the switch is immediate; a swipe still switches,
///     without the tabs following the finger.
/// ─────────────────────────────────────────────────────────────────────────
class TabDeck extends StatefulWidget {
  const TabDeck({
    super.key,
    required this.index,
    required this.children,
    required this.onSwipe,
    this.origin,
    this.swipe = true,
    this.animate = false,
  });

  /// The tab on screen.
  final int index;
  final List<Widget> children;

  /// A swipe came to rest on another tab; the owner of [index] switches.
  final ValueChanged<int> onSwipe;

  /// Where (global coordinates) the tap that chose [index] landed: the tab
  /// grows into place from there. Null (voice, a notification): from its
  /// own centre.
  final Offset? origin;

  /// Whether sideways swipes move between tabs.
  final bool swipe;

  /// Whether a tap or voice switch animates; off by the owner's ask.
  final bool animate;

  @override
  State<TabDeck> createState() => _TabDeckState();
}

enum _Move { none, through, drag }

class _TabDeckState extends State<TabDeck> with TickerProviderStateMixin {
  late int _shown = widget.index;

  /// The tab coming in (through) or the neighbour a drag uncovers.
  int? _other;
  _Move _move = _Move.none;

  /// A swipe settled here and told the owner; its index change is expected.
  int? _swipedTo;

  /// The tab coming through: 0 = just chosen, 1 = in place.
  late final AnimationController _through =
      AnimationController(vsync: this, duration: Motion.tabSwitch)
        ..addStatusListener((s) {
          if (s == AnimationStatus.completed) _settle();
        });

  /// Where [_shown] sits sideways, in logical pixels (0 = in place).
  late final AnimationController _dx = AnimationController.unbounded(vsync: this);

  /// The pivot of the tab coming through, in the deck's coordinates.
  Offset? _pivot;
  double _width = 1;

  // The new tab is not seen until the old one has gone, so the two never
  // look like pages stacked (a frame of the phone's recording showed Hub
  // through Chat): out in the first 30%, in from there.
  static const _fadeOut = Interval(0.0, 0.35, curve: Motion.easeFadeOut);
  static const _fadeIn = Interval(0.3, 0.85, curve: Motion.easeFadeIn);
  static const _lift = 18.0;
  static const _scaleFrom = 0.86;
  static const _leaveScale = 0.96;

  @override
  void didUpdateWidget(TabDeck old) {
    super.didUpdateWidget(old);
    final to = widget.index;
    if (to == _shown && _move == _Move.none) return;
    if (_swipedTo == to) {
      // The swipe already moved it here.
      _swipedTo = null;
      _shown = to;
      _other = null;
      _move = _Move.none;
      _dx.value = 0;
      return;
    }
    _finishNow();
    if (to == _shown) return;
    // NO TAB ANIMATION (owner, 2026-10-04): a tap or voice switches tabs
    // instantly (no fade, scale or burst). A swipe still follows the finger.
    if (!widget.animate || Motion.reduced(context)) {
      _shown = to;
      return;
    }
    final origin = widget.origin;
    final box = context.findRenderObject() as RenderBox?;
    _pivot = origin != null && box != null && box.hasSize
        ? box.globalToLocal(origin)
        : null;
    _other = to;
    _move = _Move.through;
    _through.forward(from: 0);
  }

  /// A move still running is completed at once (a new one is starting).
  void _finishNow() {
    _through.stop();
    _dx.stop();
    if (_move == _Move.through) _shown = _other ?? _shown;
    _other = null;
    _move = _Move.none;
    _dx.value = 0;
  }

  /// A move finished: the tab that came in is the one shown.
  void _settle() {
    if (!mounted) return;
    setState(() {
      _shown = _other ?? _shown;
      _other = null;
      _move = _Move.none;
      _dx.value = 0;
    });
  }

  /// A swipe given up: the tab stays; the one it uncovered goes again.
  void _restore() {
    if (!mounted) return;
    setState(() {
      _other = null;
      _move = _Move.none;
      _dx.value = 0;
    });
  }

  void _springTo(double target, double velocity, {VoidCallback? then}) {
    // Done within half a pixel: the last thousandths of a critically
    // damped spring take longer than the whole visible move.
    final sim = SpringSimulation(Motion.swipeSpring, _dx.value, target, velocity,
        tolerance: const Tolerance(distance: 0.5, velocity: 20));
    _dx.animateWith(sim).whenCompleteOrCancel(() {
      if (_dx.value == target || (_dx.value - target).abs() < 0.5) then?.call();
    });
  }

  // ── swipes ─────────────────────────────────────────────────────────────

  bool get _reduced => Motion.reduced(context);

  void _dragStart(DragStartDetails d) {
    _finishNow();
    setState(() => _move = _Move.drag);
  }

  void _dragUpdate(DragUpdateDetails d) {
    if (_move != _Move.drag) return;
    var x = _dx.value + d.delta.dx;
    final next = x < 0 ? _shown + 1 : _shown - 1;
    final exists = next >= 0 && next < widget.children.length;
    if (!exists) {
      // The first and last tabs give a little, then stop.
      x = _dx.value + d.delta.dx * 0.25;
      x = x.clamp(-_width * 0.12, _width * 0.12);
    }
    final other = exists && x != 0 ? next : null;
    // The deck is rebuilt only when the neighbour changes; the finger's
    // movement itself goes through the controller (no page is rebuilt).
    if (other != _other) setState(() => _other = other);
    _dx.value = _reduced ? 0 : x;
    if (_reduced) _pendingDx += d.delta.dx;
  }

  /// Under reduced motion the tabs do not follow the finger; how far it
  /// went still decides.
  double _pendingDx = 0;

  void _dragEnd(DragEndDetails d) {
    if (_move != _Move.drag) return;
    final v = d.velocity.pixelsPerSecond.dx;
    final x = _reduced ? _pendingDx : _dx.value;
    _pendingDx = 0;
    final target = x < 0 ? _shown + 1 : _shown - 1;
    final exists = x != 0 && target >= 0 && target < widget.children.length;
    final far = x.abs() > _width * 0.3;
    final flung = v.abs() > 650 && v.sign == x.sign;
    if (exists && (far || flung)) {
      if (_reduced) {
        setState(() {
          _move = _Move.none;
          _other = null;
          _dx.value = 0;
        });
        _swipedTo = target;
        widget.onSwipe(target);
        return;
      }
      if (_other != target) setState(() => _other = target);
      _springTo(x < 0 ? -_width : _width, v, then: () {
        _swipedTo = target;
        widget.onSwipe(target);
      });
    } else {
      _springTo(0, v, then: _restore);
    }
  }

  void _dragCancel() {
    if (_move == _Move.drag) _springTo(0, 0, then: _restore);
  }

  // ── painting ───────────────────────────────────────────────────────────

  /// Which tab takes touches: the one on screen at rest, the one coming in
  /// while a tap or voice brings it (it is what the user chose), none while
  /// a finger is dragging the deck.
  bool _takesTouches(int i) => switch (_move) {
        _Move.none => i == _shown,
        _Move.through => i == _other,
        _Move.drag => false,
      };

  /// A touch while a tab comes through: the user is already using it, so
  /// the move ends now rather than holding the screen for the rest of it.
  void _touched(PointerDownEvent e) {
    if (_move != _Move.through) return;
    setState(_finishNow);
  }

  /// Sideways offset of tab [i] right now.
  double _offsetOf(int i) {
    if (_move == _Move.through) return 0;
    final dx = _dx.value;
    if (i == _shown) return dx;
    if (i == _other) return i > _shown ? _width + dx : dx - _width;
    return 0;
  }

  /// Tab [i] as it is this frame. [page] is built once per build and
  /// handed through: the move only changes the layer it sits on (opacity,
  /// a transform), never what is painted inside it. THE SAME TWO WIDGETS
  /// ALWAYS WRAP THE PAGE (an Opacity of 1 and an identity transform cost
  /// nothing): were they added for the move and taken away after, the
  /// page would be rebuilt from scratch each time and lose its state.
  Widget _frame(int i, Widget page, BoxConstraints box) {
    var opacity = 1.0;
    var transform = Matrix4.identity();
    Offset? origin;
    if (_move == _Move.through) {
      final t = _through.value;
      if (i == _other) {
        final k = Motion.easeEnter.transform(t);
        final s = _scaleFrom + (1 - _scaleFrom) * k;
        opacity = _fadeIn.transform(t);
        transform = Matrix4.identity()
          ..translateByDouble(0.0, _lift * (1 - k), 0.0, 1.0)
          ..scaleByDouble(s, s, 1.0, 1.0);
        origin = _pivot ?? Offset(box.maxWidth / 2, box.maxHeight / 2);
      } else if (i == _shown) {
        // Falls back a touch as it goes, so the new one reads as nearer.
        final k = Motion.easeExit.transform(t.clamp(0.0, 0.5) * 2);
        final s = 1 - (1 - _leaveScale) * k;
        opacity = 1 - _fadeOut.transform(t);
        transform = Matrix4.identity()..scaleByDouble(s, s, 1.0, 1.0);
        origin = Offset(box.maxWidth / 2, box.maxHeight / 2);
      }
    } else {
      final dx = _offsetOf(i);
      if (dx != 0) transform = Matrix4.translationValues(dx, 0, 0);
    }
    return Opacity(
      opacity: opacity.clamp(0.0, 1.0),
      child: Transform(transform: transform, origin: origin, child: page),
    );
  }

  @override
  Widget build(BuildContext context) {
    final visible = <int>{_shown, if (_other != null) _other!};
    // The tab coming in paints last, over the one leaving.
    final order = [
      for (var i = 0; i < widget.children.length; i++)
        if (!visible.contains(i)) i,
      _shown,
      if (_other != null) _other!,
    ];
    final deck = LayoutBuilder(builder: (context, box) {
      _width = box.maxWidth <= 0 ? 1 : box.maxWidth;
      return Stack(
        fit: StackFit.expand,
        children: [
          for (final i in order)
            KeyedSubtree(
              key: ValueKey<int>(i),
              child: Offstage(
                offstage: !visible.contains(i),
                child: TickerMode(
                  enabled: visible.contains(i),
                  // A hidden tab's heroes must not fly from where no one
                  // can see them.
                  child: HeroMode(
                    enabled: i == _shown,
                    child: IgnorePointer(
                      ignoring: !_takesTouches(i),
                      child: AnimatedBuilder(
                        animation: Listenable.merge([_through, _dx]),
                        // Its own layer: the move composites it, and does
                        // not repaint it.
                        child: RepaintBoundary(child: widget.children[i]),
                        builder: (_, page) => _frame(i, page!, box),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      );
    });
    final touched = Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _touched,
      child: Stack(
        fit: StackFit.expand,
        children: [
          deck,
          // The burst from the button, over everything, taking no touches.
          IgnorePointer(
            child: AnimatedBuilder(
              animation: _through,
              builder: (_, __) => _move == _Move.through && _pivot != null
                  ? CustomPaint(painter: _Burst(_pivot!, _through.value))
                  : const SizedBox.shrink(),
            ),
          ),
        ],
      ),
    );
    if (!widget.swipe) return touched;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragStart: _dragStart,
      onHorizontalDragUpdate: _dragUpdate,
      onHorizontalDragEnd: _dragEnd,
      onHorizontalDragCancel: _dragCancel,
      child: touched,
    );
  }

  @override
  void dispose() {
    _through.dispose();
    _dx.dispose();
    super.dispose();
  }
}

/// A RING OF THE APP'S LIGHT bursting from the tapped button: one stroked
/// circle, wide and bright at the button, thin and gone by the far edge.
/// A stroke is a flat fill — nothing is clipped or blurred.
class _Burst extends CustomPainter {
  const _Burst(this.center, this.t);
  final Offset center;
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    if (t <= 0 || t >= 1) return;
    final k = Curves.easeOutCubic.transform(t);
    final reach = size.longestSide * 1.1;
    final r = 12 + reach * k;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3 + 26 * (1 - k)
      ..shader = SweepGradient(
        center: Alignment.center,
        colors: [...Neon.rim, Neon.rim.first],
      ).createShader(Rect.fromCircle(center: center, radius: r))
      ..color = Colors.white.withValues(alpha: (1 - k) * 0.9);
    canvas.drawCircle(center, r, paint);
  }

  @override
  bool shouldRepaint(_Burst old) => old.t != t || old.center != center;
}
