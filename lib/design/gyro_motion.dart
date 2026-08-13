import 'dart:async';
import 'dart:math' as math;

import 'package:sensors_plus/sensors_plus.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  GyroMotion · one shared, self-centering device-tilt signal.
///
///  Several widgets (aurora backdrop, assistant orb, tilt cards) react to
///  device motion. Opening one sensor stream EACH would waste battery, so
///  they all read this singleton instead:
///
///    initState:  GyroMotion.instance.retain();
///    dispose:    GyroMotion.instance.release();
///    each frame: read  .x  and  .y   (−1.2 … 1.2, eases back to 0)
///
///  SENSOR FALLBACK: many budget phones (several Galaxy A/F/M models among
///  them) ship WITHOUT a gyroscope. On those the gyroscope stream simply
///  never delivers an event, so every tilt effect in the app silently
///  rendered flat — the motion looked "missing" rather than broken. We now
///  probe for gyroscope events and, if none arrive shortly after start,
///  fall back to the ACCELEROMETER, deriving tilt from the gravity vector.
///  Every phone has an accelerometer, so the effect works everywhere.
///
///  The stream only runs while at least one widget holds a retain. On a
///  device with neither sensor (desktop/web) x and y stay 0 and widgets
///  render their static look with zero extra cost.
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

  /// Which sensor is currently driving the motion: 'gyroscope',
  /// 'accelerometer' or 'none'. Surfaced in Diagnostics so a device with no
  /// motion effect can be explained instead of guessed at.
  String get sensorSource =>
      _gyroEvents > 0 ? 'gyroscope' : (_accSub != null ? 'accelerometer' : 'none');

  int _refs = 0;
  StreamSubscription<GyroscopeEvent>? _sub;
  StreamSubscription<AccelerometerEvent>? _accSub;
  Timer? _probe;
  int _gyroEvents = 0;

  // Resting orientation for the accelerometer path. Whatever angle the user
  // naturally holds the phone at becomes "neutral"; it adapts slowly, so
  // tilting produces motion that always eases back to centre — matching the
  // self-centering feel of the gyroscope path.
  double _baseX = 0, _baseY = 0;
  bool _haveBase = false;

  void retain() {
    _refs++;
    if (_sub != null || _accSub != null) return;
    _gyroEvents = 0;
    try {
      _sub = gyroscopeEventStream(
        samplingPeriod: SensorInterval.gameInterval, // ~50 Hz
      ).listen((e) {
        _gyroEvents++;
        // Integrate angular velocity, decay toward rest (self-centering).
        x = ((x + e.x * 0.028) * 0.985).clamp(-1.2, 1.2);
        y = ((y + e.y * 0.028) * 0.985).clamp(-1.2, 1.2);
      }, onError: (_) => _startAccelerometer(), cancelOnError: true);
    } catch (_) {
      _startAccelerometer();
      return;
    }
    // No gyro events shortly after subscribing => no usable gyroscope.
    _probe?.cancel();
    _probe = Timer(const Duration(milliseconds: 1200), () {
      if (_refs > 0 && _gyroEvents == 0) _startAccelerometer();
    });
  }

  /// Gravity-based tilt for phones without a gyroscope.
  void _startAccelerometer() {
    if (_accSub != null) return;
    _sub?.cancel();
    _sub = null;
    _haveBase = false;
    try {
      _accSub = accelerometerEventStream(
        samplingPeriod: SensorInterval.gameInterval,
      ).listen((e) {
        final norm = math.sqrt(e.x * e.x + e.y * e.y + e.z * e.z);
        if (norm < 1) return; // free-fall / bogus sample
        // Direction of gravity in screen space: how far the phone is tipped.
        final rx = e.y / norm; // tipped forward/back  -> pitch
        final ry = e.x / norm; // tipped left/right    -> roll
        if (!_haveBase) {
          _baseX = rx;
          _baseY = ry;
          _haveBase = true;
        }
        // Slowly re-centre on however the phone is being held.
        _baseX = _baseX * 0.995 + rx * 0.005;
        _baseY = _baseY * 0.995 + ry * 0.005;
        // Scale the deviation up into the same −1.2..1.2 range the
        // gyroscope path produces, then smooth so it glides.
        final tx = ((rx - _baseX) * 3.2).clamp(-1.2, 1.2);
        final ty = ((ry - _baseY) * 3.2).clamp(-1.2, 1.2);
        x = x * 0.85 + tx * 0.15;
        y = y * 0.85 + ty * 0.15;
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
    _probe?.cancel();
    _probe = null;
    _sub?.cancel();
    _sub = null;
    _accSub?.cancel();
    _accSub = null;
    _gyroEvents = 0;
    _haveBase = false;
    x = 0;
    y = 0;
  }
}
