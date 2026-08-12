import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:sensors_plus/sensors_plus.dart';

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
///      sensor error → renders the child completely unchanged.
///    • Battery-aware: the sensor stream is cancelled while the app is
///      backgrounded and on dispose; the ticker only runs while moving.
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

class _GyroTiltState extends State<GyroTilt>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  StreamSubscription<GyroscopeEvent>? _sub;
  late final Ticker _ticker;

  // Tilt state lives in a ValueNotifier, not in setState: only the thin
  // Transform/sheen/shadow layer listens and repaints each frame, while
  // the (potentially expensive) child is built ONCE. Value is (tx, ty).
  final ValueNotifier<Offset> _tilt = ValueNotifier(Offset.zero);

  // Raw angular velocity from the last gyro event (rad/s).
  double _vx = 0, _vy = 0;
  Duration _lastTick = Duration.zero;
  bool _supported = true;

  double get _tx => _tilt.value.dx;
  double get _ty => _tilt.value.dy;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ticker = createTicker(_onTick);
    _listen();
  }

  void _listen() {
    _sub?.cancel();
    try {
      _sub = gyroscopeEventStream(
        samplingPeriod: SensorInterval.gameInterval, // ~50 Hz
      ).listen(
        (e) {
          _vx = e.x;
          _vy = e.y;
          if (!_ticker.isActive && mounted) {
            _lastTick = Duration.zero;
            _ticker.start();
          }
        },
        onError: (_) {
          // No gyroscope (emulator/desktop) — degrade to a static child.
          if (mounted) setState(() => _supported = false);
          _sub?.cancel();
        },
        cancelOnError: true,
      );
    } catch (_) {
      _supported = false;
    }
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

    // Asleep? Stop ticking (and repainting) until the next gyro event.
    if (tx.abs() < 0.0005 &&
        ty.abs() < 0.0005 &&
        _vx.abs() < 0.02 &&
        _vy.abs() < 0.02) {
      tx = 0;
      ty = 0;
      _ticker.stop();
    }
    if (mounted) _tilt.value = Offset(tx, ty);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_supported) _listen();
    } else {
      _sub?.cancel();
      _ticker.stop();
      _tilt.value = Offset.zero;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sub?.cancel();
    _ticker.dispose();
    _tilt.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_supported ||
        widget.intensity <= 0 ||
        MediaQuery.maybeDisableAnimationsOf(context) == true) {
      return widget.child;
    }

    // The child is built ONCE and captured; only the transform layer below
    // rebuilds per frame via the ValueListenable.
    return RepaintBoundary(
      child: ValueListenableBuilder<Offset>(
        valueListenable: _tilt,
        child: widget.child,
        builder: (context, tilt, child) => _paint(tilt, child!),
      ),
    );
  }

  Widget _paint(Offset tilt, Widget child) {
    final tx = tilt.dx, ty = tilt.dy;
    final cap = widget.maxTilt * widget.intensity;
    // Normalized tilt −1..1 — drives light and shadow direction.
    final nx = cap == 0 ? 0.0 : (ty / cap); // horizontal (screen X)
    final ny = cap == 0 ? 0.0 : (tx / cap); // vertical   (screen Y)
    final active = nx.abs() > 0.001 || ny.abs() > 0.001;

    Widget content = child;

    // Moving light sheen — a soft white radial that drifts toward the
    // raised edge, clipped to the card's corners.
    if (widget.sheen && active) {
      content = Stack(
        children: [
          content,
          Positioned.fill(
            child: IgnorePointer(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(widget.radius),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: Alignment(-nx * 1.2, -ny * 1.2),
                      radius: 1.4,
                      colors: [
                        Colors.white.withValues(
                            alpha: 0.10 *
                                math.max(nx.abs(), ny.abs()) *
                                widget.intensity),
                        Colors.white.withValues(alpha: 0.0),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    }

    // Dynamic shadow — slides opposite the light, grows with the tilt.
    if (widget.shadow && active) {
      final strength = math.max(nx.abs(), ny.abs());
      content = DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(widget.radius),
          boxShadow: [
            BoxShadow(
              color: widget.shadowColor.withValues(
                  alpha: (0.30 * strength * widget.intensity).clamp(0.0, 0.5)),
              blurRadius: 18 + 14 * strength,
              offset: Offset(nx * 10, 6 + ny * 10),
            ),
          ],
        ),
        child: content,
      );
    }

    return Transform(
      alignment: Alignment.center,
      transform: Matrix4.identity()
        ..setEntry(3, 2, 0.0016) // perspective
        ..rotateX(-tx)
        ..rotateY(-ty),
      child: content,
    );
  }
}
