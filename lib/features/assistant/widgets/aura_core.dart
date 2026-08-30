import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../design/neon_tokens.dart';
import '../state/assistant_state.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  AURA CORE — the assistant's living presence.
///
///  Not a spinner and not a sphere: an organic, liquid form drawn from
///  layered sine harmonics, so its silhouette is never the same twice.
///  It behaves like something alive:
///
///    idle       slow 4-second breath, deep violet
///    listening  cyan; the surface ripples WITH the user's voice level
///    speaking   pink-violet; pulses on Hari's own words
///    thinking   faster inner swirl, violet
///    in a call  calm green
///    error      dimmed red
///
///  Three blob layers drift out of phase for liquid depth, a soft bloom
///  sits behind, and a handful of sparks orbit slowly. Everything is one
///  CustomPainter — no images, no packages, cheap to render.
/// ─────────────────────────────────────────────────────────────────────────
class AuraCore extends StatefulWidget {
  const AuraCore({
    super.key,
    required this.size,
    required this.phase,
    this.level = 0,
  });

  final double size;
  final AssistantPhase phase;

  /// 0..1 — mic level while listening, voice pulse while speaking.
  final double level;

  @override
  State<AuraCore> createState() => _AuraCoreState();
}

class _AuraCoreState extends State<AuraCore>
    with SingleTickerProviderStateMixin {
  late final AnimationController _t;

  /// Smoothed level so the surface reacts fluidly, not twitchily.
  double _smooth = 0;

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

  (Color, Color, Color) get _palette => switch (widget.phase) {
        AssistantPhase.listening => (Neon.cyan, Neon.violet, const Color(0xFF60E1FF)),
        AssistantPhase.speaking => (Neon.pink, Neon.violet, const Color(0xFFFF9AD5)),
        AssistantPhase.inCall ||
        AssistantPhase.dialing ||
        AssistantPhase.ringing =>
          (Neon.success, Neon.cyan, const Color(0xFF86EFAC)),
        AssistantPhase.error => (Neon.error, const Color(0xFF7F1D1D), const Color(0xFFFCA5A5)),
        _ when widget.phase.busy => (Neon.violet, Neon.pink, const Color(0xFFB79CFF)),
        _ => (Neon.violet, const Color(0xFF3B2A73), const Color(0xFF8B7BD8)),
      };

  double get _energy => switch (widget.phase) {
        AssistantPhase.listening => 0.85,
        AssistantPhase.speaking => 1.0,
        _ when widget.phase.busy => 0.7,
        AssistantPhase.error => 0.35,
        _ => 0.45, // idle breath
      };

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _t,
      builder: (context, _) {
        _smooth += (widget.level.clamp(0.0, 1.0) - _smooth) * 0.25;
        final (a, b, hi) = _palette;
        return RepaintBoundary(
          child: CustomPaint(
            size: Size.square(widget.size),
            painter: _AuraPainter(
              t: _t.value * 60, // seconds
              colorA: a,
              colorB: b,
              highlight: hi,
              energy: _energy,
              level: _smooth,
              swirl: widget.phase.busy && widget.phase != AssistantPhase.listening,
            ),
          ),
        );
      },
    );
  }
}

class _AuraPainter extends CustomPainter {
  _AuraPainter({
    required this.t,
    required this.colorA,
    required this.colorB,
    required this.highlight,
    required this.energy,
    required this.level,
    required this.swirl,
  });

  final double t;
  final Color colorA;
  final Color colorB;
  final Color highlight;
  final double energy; // 0..1 phase intensity
  final double level; // 0..1 live audio
  final bool swirl;

  /// Organic silhouette: radius modulated by three drifting harmonics plus
  /// a voice-driven ripple. Never symmetric, never repeating.
  Path _blob(Offset c, double base, double seed, double speed) {
    final p = Path();
    const steps = 90;
    for (var i = 0; i <= steps; i++) {
      final th = i / steps * 2 * math.pi;
      final wobble = 0.055 * math.sin(3 * th + t * 0.9 * speed + seed) +
          0.035 * math.sin(5 * th - t * 1.3 * speed + seed * 2.1) +
          0.022 * math.sin(8 * th + t * 2.0 * speed + seed * 3.7) +
          // The user's (or Hari's) voice physically ripples the surface.
          0.10 * level * math.sin(11 * th - t * 7.0 + seed);
      final r = base * (1 + wobble * (0.5 + energy));
      final o = Offset(c.dx + r * math.cos(th), c.dy + r * math.sin(th));
      if (i == 0) {
        p.moveTo(o.dx, o.dy);
      } else {
        p.lineTo(o.dx, o.dy);
      }
    }
    p.close();
    return p;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    // Breath: slow at rest, quicker and deeper with energy + voice.
    final breath =
        1 + (0.02 + 0.03 * energy) * math.sin(t * (0.9 + energy)) + 0.10 * level;
    final base = size.width * 0.30 * breath;

    // Bloom — the room-light the aura throws.
    canvas.drawCircle(
      c,
      base * 2.1,
      Paint()
        ..shader = RadialGradient(colors: [
          colorA.withValues(alpha: 0.16 + 0.20 * (energy * (0.5 + level))),
          Colors.transparent,
        ]).createShader(Rect.fromCircle(center: c, radius: base * 2.1)),
    );

    // Back layer: larger, slower, translucent — depth.
    canvas.drawPath(
      _blob(c, base * 1.16, 11.0, 0.55),
      Paint()
        ..color = colorB.withValues(alpha: 0.30)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18),
    );

    // Main body with a drifting two-tone gradient.
    final ang = swirl ? t * 1.6 : t * 0.25;
    canvas.drawPath(
      _blob(c, base, 0.0, 1.0),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment(math.cos(ang), math.sin(ang)),
          end: Alignment(-math.cos(ang), -math.sin(ang)),
          colors: [colorA, colorB],
        ).createShader(Rect.fromCircle(center: c, radius: base * 1.3))
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );

    // Inner light: off-centre core that wanders — the "alive" glint.
    final wander = Offset(
      c.dx + base * 0.25 * math.sin(t * 0.7),
      c.dy - base * 0.22 * math.cos(t * 0.55),
    );
    canvas.drawCircle(
      wander,
      base * 0.62,
      Paint()
        ..shader = RadialGradient(colors: [
          highlight.withValues(alpha: 0.55 + 0.30 * level),
          Colors.transparent,
        ]).createShader(Rect.fromCircle(center: wander, radius: base * 0.62))
        ..blendMode = BlendMode.plus,
    );

    // Orbiting sparks — slow fireflies around the form.
    final sparkPaint = Paint()..blendMode = BlendMode.plus;
    for (var i = 0; i < 7; i++) {
      final ph = i * 0.9 + t * (0.12 + 0.02 * i) * (swirl ? 3.0 : 1.0);
      final rr = base * (1.35 + 0.18 * math.sin(t * 0.5 + i * 1.7));
      final pos = Offset(
        c.dx + rr * math.cos(ph),
        c.dy + rr * 0.82 * math.sin(ph),
      );
      final tw = 0.5 + 0.5 * math.sin(t * 2.2 + i * 2.3);
      sparkPaint.color =
          (i.isEven ? colorA : highlight).withValues(alpha: 0.28 + 0.45 * tw);
      canvas.drawCircle(pos, 1.6 + 1.6 * tw + 2.0 * level, sparkPaint);
    }
  }

  @override
  bool shouldRepaint(_AuraPainter old) => true;
}
