import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../design/neon_tokens.dart';
import '../state/assistant_state.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  PRESENCE ORB — what the user looks at when there is no video.
///
///  WHY THIS REPLACED A PHOTOGRAPH
///  A static portrait sitting still on the screen reads as a broken video
///  call: the user cannot tell whether the assistant is connecting, has
///  frozen, or is listening to them. It also promises a face and then does
///  not move it, which feels worse than showing no face at all.
///
///  An orb has none of that problem. It is honest about not being a person,
///  and — the point — it can SHOW STATE. Every phase has its own colour and
///  motion, so a glance answers "is it listening to me, or thinking?"
///    connecting  slow, dim, unhurried
///    listening   bright cyan, breathing WITH the user's voice
///    thinking    violet, rotating — visibly working
///    speaking    warm pink, pulsing in time with speech
///
///  It is presentation only: it holds no logic and makes no calls, it just
///  renders whatever state it is handed.
/// ─────────────────────────────────────────────────────────────────────────
class PresenceOrb extends StatefulWidget {
  final double size;

  /// Current assistant phase — chooses colour and motion.
  final AssistantPhase phase;

  /// 0..1 microphone level, so the orb answers to the user's own voice
  /// while listening. This is the detail that makes it feel alive rather
  /// than animated.
  final double level;

  const PresenceOrb({
    super.key,
    required this.size,
    required this.phase,
    this.level = 0,
  });

  @override
  State<PresenceOrb> createState() => _PresenceOrbState();
}

class _PresenceOrbState extends State<PresenceOrb>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  /// Smoothed level. The raw microphone value is jittery frame to frame,
  /// and following it exactly makes the orb twitch instead of breathe.
  double _smooth = 0;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  /// The palette per phase. Two colours: core and halo.
  (Color, Color) get _colors => switch (widget.phase) {
        AssistantPhase.listening => (Neon.cyan, Neon.violet),
        AssistantPhase.speaking => (Neon.pink, Neon.violet),
        AssistantPhase.thinking ||
        AssistantPhase.searching ||
        AssistantPhase.transcribing ||
        AssistantPhase.generatingVoice ||
        AssistantPhase.preparingMessage =>
          (Neon.violet, Neon.cyan),
        AssistantPhase.dialing ||
        AssistantPhase.ringing ||
        AssistantPhase.inCall =>
          (Neon.success, Neon.cyan),
        AssistantPhase.error => (Neon.error, Neon.warning),
        _ => (Neon.violet, Neon.cyan),
      };

  bool get _busy =>
      widget.phase.busy && widget.phase != AssistantPhase.listening;

  @override
  Widget build(BuildContext context) {
    _smooth = _smooth * 0.75 + widget.level.clamp(0.0, 1.0) * 0.25;
    final (core, halo) = _colors;

    return AnimatedBuilder(
      animation: _c,
      builder: (_, __) => CustomPaint(
        size: Size.square(widget.size),
        painter: _OrbPainter(
          t: _c.value,
          core: core,
          halo: halo,
          level: _smooth,
          busy: _busy,
          listening: widget.phase == AssistantPhase.listening,
        ),
      ),
    );
  }
}

class _OrbPainter extends CustomPainter {
  final double t; // 0..1 loop position
  final Color core;
  final Color halo;
  final double level;
  final bool busy;
  final bool listening;

  _OrbPainter({
    required this.t,
    required this.core,
    required this.halo,
    required this.level,
    required this.busy,
    required this.listening,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2;

    final breath = 0.5 + 0.5 * math.sin(t * 2 * math.pi);
    final voice = listening ? level : 0.0;
    // Energy drives everything below: how fast things move, how bright they
    // burn, how far they throw light. Idle still has a floor of motion — a
    // completely still orb reads as a frozen screen — but speaking and
    // listening should visibly surge.
    final energy = busy ? 0.75 : (listening ? 0.35 + voice * 0.65 : 0.28);
    final base = r * (0.40 + breath * 0.035 + voice * 0.17);

    // ---- OUTER BLOOM ------------------------------------------------
    canvas.drawCircle(
      c,
      base * (2.0 + energy * 0.35),
      Paint()
        ..shader = RadialGradient(
          colors: [
            halo.withValues(alpha: 0.16 + energy * 0.34),
            core.withValues(alpha: 0.10 + energy * 0.16),
            halo.withValues(alpha: 0.0),
          ],
          stops: const [0.0, 0.45, 1.0],
        ).createShader(
            Rect.fromCircle(center: c, radius: base * (2.0 + energy * 0.35)))
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 30),
    );

    // ---- AURORA SWEEP ------------------------------------------------
    // A rotating conic wash behind the core. This is what stops the orb
    // looking like a flat disc with rings drawn on it: the light itself
    // moves, so the whole shape feels powered rather than decorated.
    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.rotate(t * 2 * math.pi * (0.6 + energy));
    canvas.drawCircle(
      Offset.zero,
      base * 1.55,
      Paint()
        ..shader = SweepGradient(
          colors: [
            core.withValues(alpha: 0.0),
            core.withValues(alpha: 0.30 + energy * 0.35),
            halo.withValues(alpha: 0.22 + energy * 0.30),
            Colors.white.withValues(alpha: 0.10 + energy * 0.18),
            core.withValues(alpha: 0.0),
          ],
          stops: const [0.0, 0.28, 0.52, 0.70, 1.0],
        ).createShader(Rect.fromCircle(center: Offset.zero, radius: base * 1.55))
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 16),
    );
    canvas.restore();

    // ---- ORBIT ARCS ---------------------------------------------------
    // Counter-rotating at different rates so the motion reads as a system
    // in flight rather than one spinning wheel.
    for (var i = 0; i < 4; i++) {
      final dir = i.isEven ? 1.0 : -1.0;
      final speed = (0.5 + i * 0.45) * (busy ? 2.4 : 1.0) * (1 + energy);
      final rr = base * (1.14 + i * 0.17);
      final sweep = 0.5 + energy * 1.4 + i * 0.18;
      canvas.drawArc(
        Rect.fromCircle(center: c, radius: rr),
        t * 2 * math.pi * speed * dir + i * 1.7,
        sweep,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = (2.6 - i * 0.45).clamp(0.8, 2.6)
          ..shader = LinearGradient(
            colors: [
              (i.isEven ? core : halo).withValues(alpha: 0.0),
              (i.isEven ? core : halo)
                  .withValues(alpha: (0.55 + energy * 0.45).clamp(0.0, 1.0)),
              Colors.white.withValues(alpha: 0.5 * energy),
            ],
          ).createShader(Rect.fromCircle(center: c, radius: rr)),
      );
    }

    // ---- ORBITING SPARKS ---------------------------------------------
    // Small bright points on their own orbits. Cheap, and they carry most
    // of the perceived liveliness.
    const sparks = 7;
    for (var i = 0; i < sparks; i++) {
      final phase = i / sparks;
      final ang = (t * (1.1 + energy * 1.6) + phase) * 2 * math.pi;
      final rr = base * (1.20 + 0.30 * math.sin((t * 1.7 + phase) * 2 * math.pi));
      final p = c + Offset(math.cos(ang) * rr, math.sin(ang) * rr * 0.82);
      final a = (0.30 + energy * 0.6) *
          (0.45 + 0.55 * math.sin((t * 2.2 + phase) * 2 * math.pi).abs());
      canvas.drawCircle(
        p,
        1.6 + energy * 2.2,
        Paint()
          ..color = Color.lerp(core, Colors.white, 0.6)!
              .withValues(alpha: a.clamp(0.0, 1.0))
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
      );
    }

    // ---- CORE ---------------------------------------------------------
    canvas.drawCircle(
      c,
      base,
      Paint()
        ..shader = RadialGradient(
          colors: [
            Color.lerp(core, Colors.white, 0.45 + voice * 0.35)!,
            core,
            Color.lerp(core, Neon.bg, 0.60)!,
          ],
          stops: const [0.0, 0.52, 1.0],
        ).createShader(Rect.fromCircle(center: c, radius: base)),
    );

    // Inner shimmer — a second, faster sweep clipped to the core, so the
    // surface looks like it has something happening inside it.
    canvas.save();
    canvas.clipPath(Path()..addOval(Rect.fromCircle(center: c, radius: base)));
    canvas.translate(c.dx, c.dy);
    canvas.rotate(-t * 2 * math.pi * (1.2 + energy * 1.5));
    canvas.drawCircle(
      Offset.zero,
      base,
      Paint()
        ..shader = SweepGradient(
          colors: [
            Colors.white.withValues(alpha: 0.0),
            Colors.white.withValues(alpha: 0.16 + energy * 0.22),
            Colors.white.withValues(alpha: 0.0),
          ],
          stops: const [0.30, 0.50, 0.70],
        ).createShader(Rect.fromCircle(center: Offset.zero, radius: base)),
    );
    canvas.restore();

    // Specular highlight for depth.
    canvas.drawCircle(
      c.translate(-base * 0.28, -base * 0.32),
      base * 0.30,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.24)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18),
    );

    // ---- VOICE RINGS --------------------------------------------------
    // Two expanding rings while the user speaks, so the orb answers back
    // the instant it hears them.
    if (listening && level > 0.05) {
      for (var i = 0; i < 2; i++) {
        final grow = ((t * 2.2 + i * 0.5) % 1.0);
        canvas.drawCircle(
          c,
          base * (1.1 + grow * (0.7 + level * 0.6)),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.0 * (1 - grow)
            ..color = core.withValues(
                alpha: ((1 - grow) * level * 0.85).clamp(0.0, 0.85)),
        );
      }
    }
  }

  @override
  bool shouldRepaint(_OrbPainter o) =>
      o.t != t ||
      o.level != level ||
      o.core != core ||
      o.busy != busy ||
      o.listening != listening;
}
