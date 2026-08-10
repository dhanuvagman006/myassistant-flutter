import 'dart:async';

import 'package:sensors_plus/sensors_plus.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  GyroMotion · one shared, self-centering device-tilt signal.
///
///  Several widgets (aurora backdrop, assistant orb, tilt cards) react to
///  the gyroscope. Opening one sensor stream EACH would waste battery, so
///  they all read this singleton instead:
///
///    initState:  GyroMotion.instance.retain();
///    dispose:    GyroMotion.instance.release();
///    each frame: read  .x  and  .y   (−1.2 … 1.2, eases back to 0)
///
///  The stream only runs while at least one widget holds a retain, and
///  values integrate + decay so everything settles when the phone rests.
///  No gyroscope (emulator/desktop)? x and y just stay 0 — widgets render
///  their static look with zero extra cost.
/// ─────────────────────────────────────────────────────────────────────────
class GyroMotion {
  GyroMotion._();
  static final GyroMotion instance = GyroMotion._();

  /// Tilt around the screen's horizontal axis (pitch). −1.2 … 1.2.
  double x = 0;

  /// Tilt around the screen's vertical axis (roll). −1.2 … 1.2.
  double y = 0;

  /// 0 … 1 — how much the phone is moving right now (for glow/brightness).
  double get energy {
    final e = x.abs() + y.abs();
    return e > 1 ? 1 : e;
  }

  int _refs = 0;
  StreamSubscription<GyroscopeEvent>? _sub;

  void retain() {
    _refs++;
    if (_sub != null) return;
    try {
      _sub = gyroscopeEventStream(
        samplingPeriod: SensorInterval.gameInterval, // ~50 Hz
      ).listen((e) {
        // Integrate angular velocity, decay toward rest (self-centering).
        x = ((x + e.x * 0.028) * 0.985).clamp(-1.2, 1.2);
        y = ((y + e.y * 0.028) * 0.985).clamp(-1.2, 1.2);
      }, onError: (_) => _stop(), cancelOnError: true);
    } catch (_) {
      _stop();
    }
  }

  void release() {
    _refs--;
    if (_refs <= 0) _stop();
  }

  void _stop() {
    _refs = _refs < 0 ? 0 : _refs;
    _sub?.cancel();
    _sub = null;
    x = 0;
    y = 0;
  }
}
