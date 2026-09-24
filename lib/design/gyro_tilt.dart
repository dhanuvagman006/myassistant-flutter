import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:sensors_plus/sensors_plus.dart';

import 'motion.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  GyroTilt · Neon Design System V2.0
///
///  Wrap ANY widget to give it a device-motion 3D presence:
///    • the child tilts in perspective as the phone rotates (gyroscope)
///    • a soft shadow slides OPPOSITE the tilt, as if lit from above
///    • an optional light "sheen" sweeps across the surface toward the
///      light — the glass-catching-light effect
///
///  Design rules:
///    • Subtle by default (maxTilt ≈ 3.5°). This is depth, not a gimmick.
///    • Self-centering: tilt decays back to rest when the phone is still,
///      so the UI never sits crooked.
///    • Zero-cost degrade: no gyroscope (emulator, desktop, web) or a
///      sensor error → renders the child completely unchanged. So does
///      "Remove animations", which also never opens the sensor.
///    • Battery-aware: the sensor stream is cancelled while the app is
///      backgrounded and on dispose; the ticker only runs while moving.
///
///  CHEAPER ON THE PHONE (2026-09-24):
///    • ONE sensor stream for every card on screen (it was one 50 Hz
///      stream and one ticker per card: five search results, five of each).
///    • A still hand is still: readings under 0.05 rad/s are tremor and
///      are ignored, so the ticker really sleeps while the phone is simply
///      held. Before, tremor alone kept the app drawing 60 frames a second
///      for as long as a result card was on screen.
///    • The card is never rebuilt by the tilt. The tree used to change
///      shape the moment the phone started moving (the card moved under a
///      new shadow and sheen), which threw the card's whole subtree away
///      and built it again — its ripple, spinner and images with it —
///      every time the phone moved or settled. The shadow and sheen are
///      always there now, and draw nothing at rest.
///    • The card is drawn once on its own layer; a tilt frame only moves
///      that layer and redraws the shadow and sheen around it.
/// ─────────────────────────────────────────────────────────────────────────
class GyroTilt extends StatefulWidget {
  final Widget child;

  /// Maximum tilt in radians (default ≈ 3.5°). Keep it small.
  final double maxTilt;

  /// Corner radius of the child — used to clip the sheen so light never
  /// bleeds outside rounded cards. 0 = no clipping.
  final double radius;

  /// Paint the moving light reflection. Turn off for non-glass children.
  final bool sheen;

  /// Paint the dynamic drop shadow. Turn off if the child draws its own.
  final bool shadow;

  /// Shadow tint — pass a brand color (e.g. Neon.violet) for a neon glow
  /// that moves with the device, or leave black for realistic depth.
  final Color shadowColor;

  /// Multiplies the whole effect. 1.0 = default, 0 = off.
  final double intensity;

  const GyroTilt({
    super.key,
    required this.child,
    this.maxTilt = 0.06,
    this.radius = 0,
    this.sheen = true,
    this.shadow = true,
    this.shadowColor = Colors.black,
    this.intensity = 1.0,
  });

  @override
  State<GyroTilt> createState() => _GyroTiltState();
}

/// The one gyroscope stream every GyroTilt on screen shares.
class _SharedGyro {
  static final Set<_GyroTiltState> _tilts = {};
  static StreamSubscription<GyroscopeEvent>? _sub;

  /// False once the sensor has failed (no gyroscope): nothing listens again.
  static bool supported = true;

  /// Rates below this are hand tremor, not a gesture (rad/s).
  static const double deadband = 0.05;

  static void add(_GyroTiltState t) {
    if (!supported) return;
    _tilts.add(t);
    if (_sub != null) return;
    try {
      _sub = gyroscopeEventStream(
        samplingPeriod: SensorInterval.gameInterval, // ~50 Hz
      ).listen(
        (e) {
          final x = e.x.abs() < deadband ? 0.0 : e.x;
          final y = e.y.abs() < deadband ? 0.0 : e.y;
          for (final t in _tilts.toList(growable: false)) {
            t._onRate(x, y);
          }
        },
        onError: (_) => _fail(),
        cancelOnError: true,
      );
    } catch (_) {
      _fail();
    }
  }

  static void remove(_GyroTiltState t) {
    _tilts.remove(t);
    if (_tilts.isEmpty) {
      _sub?.cancel();
      _sub = null;
    }
  }

  static void _fail() {
    // No gyroscope (emulator/desktop) — every card degrades to static.
    supported = false;
    _sub?.cancel();
    _sub = null;
    final was = _tilts.toList(growable: false);
    _tilts.clear();
    for (final t in was) {
      t._onUnsupported();
    }
  }
}

class _GyroTiltState extends State<GyroTilt>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final Ticker _ticker;

  // Tilt state lives in a ValueNotifier, not in setState: only the thin
  // Transform/sheen/shadow layer listens and repaints each frame, while
  // the (potentially expensive) child is built ONCE. Value is (tx, ty).
  final ValueNotifier<Offset> _tilt = ValueNotifier(Offset.zero);

  // Angular velocity from the last gyro event, tremor removed (rad/s).
  double _vx = 0, _vy = 0;
  Duration _lastTick = Duration.zero;
  bool _supported = _SharedGyro.supported;
  bool _still = false; // "Remove animations"
  bool _foreground = true;

  double get _tx => _tilt.value.dx;
  double get _ty => _tilt.value.dy;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ticker = createTicker(_onTick);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _still = Motion.reduced(context);
    _listen();
  }

  /// Listen exactly when a tilt could be seen.
  void _listen() {
    final want = _supported &&
        !_still &&
        _foreground &&
        widget.intensity > 0;
    if (want) {
      _SharedGyro.add(this);
    } else {
      _SharedGyro.remove(this);
      _rest();
    }
  }

  void _rest() {
    _ticker.stop();
    _vx = 0;
    _vy = 0;
    _tilt.value = Offset.zero;
  }

  void _onRate(double x, double y) {
    if (!mounted) return;
    _vx = x;
    _vy = y;
    if ((x != 0 || y != 0) && !_ticker.isActive) {
      _lastTick = Duration.zero;
      _ticker.start();
    }
  }

  void _onUnsupported() {
    if (mounted) setState(() => _supported = false);
    _rest();
  }

  void _onTick(Duration elapsed) {
    final dt = _lastTick == Duration.zero
        ? 0.016
        : ((elapsed - _lastTick).inMicroseconds / 1e6).clamp(0.0, 0.05);
    _lastTick = elapsed;

    final cap = widget.maxTilt * widget.intensity;

    // Integrate angular velocity into tilt, then decay toward rest so the
    // card always settles flat. Velocity itself is bled off too, which
    // filters hand tremor into a smooth glide.
    var tx = ((_tx + _vx * dt * 0.9) * math.pow(0.06, dt)).clamp(-cap, cap);
    var ty = ((_ty + _vy * dt * 0.9) * math.pow(0.06, dt)).clamp(-cap, cap);
    _vx *= math.pow(0.001, dt).toDouble();
    _vy *= math.pow(0.001, dt).toDouble();

    // Asleep? Stop ticking (and repainting) until the next real movement.
    if (tx.abs() < 0.0005 &&
        ty.abs() < 0.0005 &&
        _vx.abs() < 0.02 &&
        _vy.abs() < 0.02) {
      tx = 0;
      ty = 0;
      _vx = 0;
      _vy = 0;
      _ticker.stop();
    }
    if (mounted) _tilt.value = Offset(tx, ty);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _listen();
  }

  @override
  void didUpdateWidget(GyroTilt old) {
    super.didUpdateWidget(old);
    if (old.intensity != widget.intensity) _listen();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _SharedGyro.remove(this);
    _ticker.dispose();
    _tilt.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_supported || widget.intensity <= 0 || _still) {
      return widget.child;
    }

    // The child is built ONCE and captured; only the transform layer below
    // rebuilds per frame via the ValueListenable. Its own layer, so a tilt
    // frame moves it instead of drawing it again.
    final card = RepaintBoundary(child: widget.child);
    return RepaintBoundary(
      child: ValueListenableBuilder<Offset>(
        valueListenable: _tilt,
        child: card,
        builder: (context, tilt, child) => _paint(tilt, child!),
      ),
    );
  }

  /// ALWAYS THE SAME TREE: Transform > shadow > Stack[card, sheen]. At
  /// rest the shadow and the sheen simply draw nothing.
  Widget _paint(Offset tilt, Widget card) {
    final tx = tilt.dx, ty = tilt.dy;
    final cap = widget.maxTilt * widget.intensity;
    // Normalized tilt −1..1 — drives light and shadow direction.
    final nx = cap == 0 ? 0.0 : (ty / cap); // horizontal (screen X)
    final ny = cap == 0 ? 0.0 : (tx / cap); // vertical   (screen Y)
    final active = nx.abs() > 0.001 || ny.abs() > 0.001;
    final strength = math.max(nx.abs(), ny.abs());

    // Moving light sheen — a soft white radial that drifts toward the
    // raised edge, clipped to the card's corners.
    final Widget content = widget.sheen
        ? Stack(
            children: [
              card,
              Positioned.fill(
                child: IgnorePointer(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(widget.radius),
                    clipBehavior: active ? Clip.antiAlias : Clip.none,
                    child: DecoratedBox(
                      decoration: active
                          ? BoxDecoration(
                              gradient: RadialGradient(
                                center: Alignment(-nx * 1.2, -ny * 1.2),
                                radius: 1.4,
                                colors: [
                                  Colors.white.withValues(
                                      alpha: 0.10 *
                                          strength *
                                          widget.intensity),
                                  Colors.white.withValues(alpha: 0.0),
                                ],
                              ),
                            )
                          : const BoxDecoration(),
                    ),
                  ),
                ),
              ),
            ],
          )
        : card;

    // Dynamic shadow — slides opposite the light, stronger with the tilt.
    // One blur size: a blur that changed every frame was a new blur to
    // draw every frame.
    final Widget shadowed = DecoratedBox(
      decoration: widget.shadow && active
          ? BoxDecoration(
              borderRadius: BorderRadius.circular(widget.radius),
              boxShadow: [
                BoxShadow(
                  color: widget.shadowColor.withValues(
                      alpha:
                          (0.30 * strength * widget.intensity).clamp(0.0, 0.5)),
                  blurRadius: 24,
                  offset: Offset(nx * 10, 6 + ny * 10),
                ),
              ],
            )
          : const BoxDecoration(),
      child: content,
    );

    return Transform(
      alignment: Alignment.center,
      transform: Matrix4.identity()
        ..setEntry(3, 2, 0.0016) // perspective
        ..rotateX(-tx)
        ..rotateY(-ty),
      child: shadowed,
    );
  }
}
