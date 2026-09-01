import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../state/assistant_state.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  SIRI ORB — the one control that always tells the truth.
///
///  A dark glass disc with a living waveform inside. The user reads the
///  state from ACROSS THE ROOM, without words:
///
///    stopped     a dim, almost-flat grey line. Nothing moves. Clearly off.
///    connecting  a slow violet breath — something is coming, not here yet.
///    listening   bright cyan/blue waves that surge WITH the user's voice.
///    thinking    a tight, fast violet shimmer — working, not hearing.
///    speaking    pink/violet waves rolling with Hari's own voice.
///    error       a dim red line.
///
///  The disc stays dark in the light theme on purpose: neon waves on ink
///  are unmistakable at a glance, which was the entire complaint with the
///  old flat mic button.
/// ─────────────────────────────────────────────────────────────────────────
class SiriOrb extends StatefulWidget {
  const SiriOrb({
    super.key,
    required this.size,
    required this.phase,
    this.level = 0,
    this.connected = true,
  });

  final double size;
  final AssistantPhase phase;

  /// 0..1 — mic loudness while listening, TTS loudness while speaking.
  final double level;

  /// False while no session is reachable — shows the "connecting" breath.
  final bool connected;

  @override
  State<SiriOrb> createState() => _SiriOrbState();
}

enum _OrbMode { idle, connecting, listening, thinking, speaking, error }

class _SiriOrbState extends State<SiriOrb> with SingleTickerProviderStateMixin {
  late final AnimationController _t;
  double _smooth = 0; // smoothed level, so waves flow instead of twitch

  @override
  void initState() {
    super.initState();
    _t = AnimationController(vsync: this, duration: const Duration(seconds: 60))
      ..repeat();
  }

  @override
  void dispose() {
    _t.dispose();
    super.dispose();
  }

  _OrbMode get _mode {
    if (widget.phase == AssistantPhase.error) return _OrbMode.error;
    if (!widget.connected) return _OrbMode.connecting;
    return switch (widget.phase) {
      AssistantPhase.listening => _OrbMode.listening,
      AssistantPhase.speaking => _OrbMode.speaking,
      _ when widget.phase.busy => _OrbMode.thinking,
      _ => _OrbMode.idle,
    };
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _t,
      builder: (context, _) {
        _smooth += (widget.level.clamp(0.0, 1.0) - _smooth) * 0.22;
        return RepaintBoundary(
          child: CustomPaint(
            size: Size.square(widget.size),
            painter: _OrbPainter(
              t: _t.value * 60, // seconds
              mode: _mode,
              level: _smooth,
            ),
          ),
        );
      },
    );
  }
}

class _OrbPainter extends CustomPainter {
  _OrbPainter({required this.t, required this.mode, required this.level});

  final double t;
  final _OrbMode mode;
  final double level;

  // Wave colours per state — three layers, front to back.
  List<Color> get _waveColors => switch (mode) {
        _OrbMode.listening => const [
            Color(0xFF3EE8FF),
            Color(0xFF4F8BFF),
            Color(0xFF2DD4BF),
          ],
        _OrbMode.speaking => const [
            Color(0xFFFF6FB0),
            Color(0xFFB388FF),
            Color(0xFFFF9AD5),
          ],
        _OrbMode.thinking || _OrbMode.connecting => const [
            Color(0xFFB79CFF),
            Color(0xFF8B5CF6),
            Color(0xFF7C6AE0),
          ],
        _OrbMode.error => const [
            Color(0xFFFF7A85),
            Color(0xFFE5484D),
            Color(0xFFFF9AA2),
          ],
        _OrbMode.idle => const [
            Color(0xFF6F7396),
            Color(0xFF565A78),
            Color(0xFF6F7396),
          ],
      };

  Color get _halo => switch (mode) {
        _OrbMode.listening => const Color(0xFF22D3EE),
        _OrbMode.speaking => const Color(0xFFEC4899),
        _OrbMode.thinking || _OrbMode.connecting => const Color(0xFF8B5CF6),
        _OrbMode.error => const Color(0xFFE5484D),
        _OrbMode.idle => const Color(0xFF6F7396),
      };

  /// Base wave amplitude as a fraction of the orb height. This is what
  /// makes "listening" unmistakably MOVING and "stopped" unmistakably not.
  double get _amp => switch (mode) {
        _OrbMode.listening => 0.10 + 0.20 * level,
        // Live-mode speaking has no local TTS level — synthesise a pulse so
        // the orb still visibly talks along.
        _OrbMode.speaking =>
          0.09 + 0.16 * (level > 0.02 ? level : 0.4 + 0.3 * math.sin(t * 7.0)),
        _OrbMode.thinking => 0.05,
        _OrbMode.connecting => 0.030,
        _OrbMode.error => 0.020,
        _OrbMode.idle => 0.018,
      };

  double get _speed => switch (mode) {
        _OrbMode.listening => 5.5,
        _OrbMode.speaking => 6.5,
        _OrbMode.thinking => 9.0, // tight fast shimmer = "working"
        _OrbMode.connecting => 1.6,
        _ => 0.7, // idle drifts almost imperceptibly
      };

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width * 0.42;
    final active = mode == _OrbMode.listening || mode == _OrbMode.speaking;

    // 1. Halo — the room-glow that says "on" from a distance.
    final haloStrength = switch (mode) {
      _OrbMode.listening => 0.30 + 0.35 * level,
      _OrbMode.speaking => 0.30 + 0.25 * level,
      _OrbMode.thinking => 0.22,
      // Connecting breathes: the only state whose glow oscillates.
      _OrbMode.connecting => 0.10 + 0.10 * (0.5 + 0.5 * math.sin(t * 2.4)),
      _OrbMode.error => 0.18,
      _OrbMode.idle => 0.0,
    };
    if (haloStrength > 0.01) {
      canvas.drawCircle(
        c,
        r * 1.55,
        Paint()
          ..shader = RadialGradient(colors: [
            _halo.withValues(alpha: haloStrength),
            Colors.transparent,
          ]).createShader(Rect.fromCircle(center: c, radius: r * 1.55)),
      );
    }

    // 2. The dark glass disc. Ink, not theme-dependent — the waves need it.
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(0, -0.5),
          radius: 1.2,
          colors: [Color(0xFF262A4B), Color(0xFF101226)],
        ).createShader(Rect.fromCircle(center: c, radius: r)),
    );

    // 3. Waves, clipped to the disc.
    canvas.save();
    canvas.clipPath(Path()..addOval(Rect.fromCircle(center: c, radius: r * 0.94)));
    final colors = _waveColors;
    final amp = _amp * size.height;
    final layers = mode == _OrbMode.idle || mode == _OrbMode.error ? 1 : 3;
    for (var i = 0; i < layers; i++) {
      final seed = i * 2.1;
      final layerAmp = amp * (1.0 - i * 0.22);
      _wave(
        canvas,
        c,
        r,
        amp: layerAmp,
        freq: 2.0 + i * 0.9,
        speed: _speed * (1.0 + i * 0.18) * (i.isEven ? 1 : -1),
        seed: seed,
        color: colors[i % colors.length],
        alpha: active ? 0.95 - i * 0.25 : 0.75 - i * 0.2,
        width: size.width * (0.030 - i * 0.006),
      );
    }
    canvas.restore();

    // 4. Rim — state-coloured ring plus a glassy top highlight.
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..color = _halo.withValues(alpha: active ? 0.65 : 0.35),
    );
    canvas.drawArc(
      Rect.fromCircle(center: c, radius: r - 2.5),
      -math.pi * 0.85,
      math.pi * 0.7,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0
        ..strokeCap = StrokeCap.round
        ..color = Colors.white.withValues(alpha: 0.14),
    );
  }

  /// One flowing waveform across the disc: two summed harmonics under a
  /// sine envelope, so it pinches to nothing at the edges — the Siri look.
  void _wave(
    Canvas canvas,
    Offset c,
    double r, {
    required double amp,
    required double freq,
    required double speed,
    required double seed,
    required Color color,
    required double alpha,
    required double width,
  }) {
    final path = Path();
    const steps = 56;
    final left = c.dx - r;
    final w = r * 2;
    for (var i = 0; i <= steps; i++) {
      final f = i / steps;
      final env = math.sin(math.pi * f); // 0 at edges, 1 in the middle
      final y = c.dy +
          env *
              (amp * math.sin(freq * f * 2 * math.pi + speed * t + seed) +
                  amp *
                      0.45 *
                      math.sin(freq * 1.7 * f * 2 * math.pi -
                          speed * 1.35 * t +
                          seed * 2.3));
      final x = left + f * w;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    // Soft glow pass underneath, crisp line on top.
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width * 2.6
        ..strokeCap = StrokeCap.round
        ..color = color.withValues(alpha: alpha * 0.35)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round
        ..color = color.withValues(alpha: alpha),
    );
  }

  @override
  bool shouldRepaint(_OrbPainter old) => true;
}
