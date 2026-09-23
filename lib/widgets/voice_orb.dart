import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../design/neon_tokens.dart';

/// ─────────────────────────────────────────────────────────────────────
///  THE LISTENING ORB — built from the reference design on his phone.
///
///  A glossy mint sphere with a white microphone in it, floating in a
///  tunnel of concentric rings that runs off both edges of the screen —
///  teal on the left, magenta on the right — with thin waveform lines
///  crossing behind it.
///
///  EVERY NUMBER HERE WAS MEASURED OFF THE REFERENCE, not guessed:
///  the sphere is 35% of the screen's width; the light falls from the
///  upper left (#64EED6 where it lands, #078778 at the shaded bottom);
///  the rings sit at 1.02, 1.39, 1.56, 1.91 and 2.2 times the sphere's
///  radius. Copying a design by eye is how you end up with something
///  that is nearly it and reads as wrong.
///
///  WHAT IT STILL HAS TO DO. The old orb showed the session's state in
///  colour — cyan listening, violet thinking, pink speaking — and that
///  was worth keeping when the picture itself is now one fixed mint. So
///  the SPHERE is the design and never changes, and the state lives in
///  the movement around it: a liquid ring ripples with the voice and
///  pulses roll outward while it listens or speaks, and comets circle it
///  while it thinks. The caption under the orb still says the word.
/// ─────────────────────────────────────────────────────────────────────

/// How the orb is behaving, in the only terms the painting cares about.
enum OrbMood { idle, listening, thinking, speaking }

class VoiceOrb extends StatefulWidget {
  const VoiceOrb({
    super.key,
    required this.size,
    this.mood = OrbMood.idle,
    this.level = 0,
  });

  /// The sphere's diameter. The backdrop is drawn by [VoiceOrbBackdrop].
  final double size;
  final OrbMood mood;

  /// 0..1 — mic loudness while listening, voice loudness while speaking.
  final double level;

  @override
  State<VoiceOrb> createState() => _VoiceOrbState();
}

class _VoiceOrbState extends State<VoiceOrb>
    with SingleTickerProviderStateMixin {
  /// One slow breath, always running. TickerMode stops it off-screen.
  late final AnimationController _t = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 6),
  )..repeat();

  /// The level jumps frame to frame; following it directly makes the orb
  /// judder. Chase it instead — fast to swell, slow to settle, the way a
  /// physical thing with mass would move.
  double _smooth = 0;

  @override
  void dispose() {
    _t.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final target = widget.level.clamp(0.0, 1.0);
    _smooth += (target - _smooth) * (target > _smooth ? 0.35 : 0.08);
    final d = widget.size;

    return AnimatedBuilder(
      animation: _t,
      builder: (_, __) {
        // A 2% breath at rest; up to 7% more when a voice is behind it.
        final breath = 1 + 0.02 * math.sin(_t.value * 2 * math.pi);
        final swell = widget.mood == OrbMood.idle ? 0.0 : _smooth * 0.07;
        return SizedBox(
          width: d * 1.6, // room for the glow
          height: d * 1.6,
          child: Center(
            child: Transform.scale(
              scale: breath + swell,
              child: CustomPaint(
                size: Size(d, d),
                painter: _SpherePainter(t: _t.value, glow: _smooth),
                child: SizedBox(
                  width: d,
                  height: d,
                  // The glyph is a child rather than a painted path so it
                  // stays crisp at every density and matches the mic the
                  // rest of the app already uses.
                  child: Icon(Icons.mic_rounded,
                      color: Colors.white, size: d * 0.36),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The sphere: lit from the upper left, shaded at the bottom, with a
/// specular highlight, a soft teal glow around it, and the small sparkle
/// the reference puts at its upper right.
class _SpherePainter extends CustomPainter {
  _SpherePainter({required this.t, required this.glow});
  final double t;
  final double glow;

  /// THE REFERENCE'S LIGHTING, THE APP'S COLOUR.
  ///
  /// His correction: "the exact same design and background but in current
  /// app's theme". So the SHAPE of the light is copied precisely — the
  /// reference runs from L=0.85 where the light lands to L=0.26 in the
  /// shade, over one hue — and that same ramp is rebuilt on the app's
  /// accent instead of the mint it was drawn in.
  ///
  /// Read from the tokens, never hardcoded: the accent is the user's own
  /// choice (Settings → theme colour), and a fixed violet here would be
  /// the one thing on screen that ignored it.
  static Color _ramp(Color base, double lightness, [Color? toward, double mix = 0]) {
    final c = toward == null ? base : Color.lerp(base, toward, mix)!;
    final h = HSLColor.fromColor(c);
    return h
        .withLightness(lightness.clamp(0.0, 1.0))
        .withSaturation((h.saturation * 1.05).clamp(0.35, 1.0))
        .toColor();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;

    // The light it throws, in the accent's own hue.
    canvas.drawCircle(
      c,
      r * 0.96,
      Paint()
        ..color = Neon.violet.withValues(alpha: 0.22 + glow * 0.16)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.16),
    );

    // THE BODY. The focal point is up and to the left, which is where the
    // reference puts its light; everything else follows from that.
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.38, -0.42),
          radius: 0.95,
          colors: [
            // The same four stops the reference has, re-hued: lit, body,
            // and a shaded underside pulled toward the gradient partner
            // so the ball carries the brand's violet-into-magenta.
            _ramp(Neon.violet, 0.86),
            _ramp(Neon.violet, 0.70),
            _ramp(Neon.violet, 0.54, Neon.pink, 0.25),
            _ramp(Neon.violet, 0.33, Neon.pink, 0.40),
          ],
          stops: const [0.0, 0.34, 0.72, 1.0],
        ).createShader(Rect.fromCircle(center: c, radius: r)),
    );

    // The shaded underside, so it reads as a ball and not a disc.
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(0.25, 0.85),
          radius: 0.8,
          colors: [
            _ramp(Neon.violet, 0.20, Neon.pink, 0.3).withValues(alpha: 0.55),
            _ramp(Neon.violet, 0.20, Neon.pink, 0.3).withValues(alpha: 0.0),
          ],
          stops: const [0.0, 1.0],
        ).createShader(Rect.fromCircle(center: c, radius: r)),
    );

    // LIGHT INSIDE IT — a soft glow drifting round within the ball, a
    // touch brighter with the voice, so the sphere itself looks alive.
    final orbit = t * 2 * math.pi;
    final inner = c +
        Offset(math.cos(orbit) * r * 0.38, math.sin(orbit) * r * 0.30 + r * 0.18);
    canvas.save();
    canvas.clipPath(Path()..addOval(Rect.fromCircle(center: c, radius: r)));
    canvas.drawCircle(
      inner,
      r * 0.75,
      Paint()
        ..shader = RadialGradient(colors: [
          Color.lerp(Neon.pink, Colors.white, 0.25)!
              .withValues(alpha: 0.28 + glow * 0.30),
          Neon.pink.withValues(alpha: 0),
        ]).createShader(Rect.fromCircle(center: inner, radius: r * 0.75)),
    );
    canvas.restore();

    // THE HIGHLIGHT — a soft oval where the light lands, not a hard dot.
    final hl = Rect.fromCenter(
      center: c + Offset(-r * 0.32, -r * 0.46),
      width: r * 0.76,
      height: r * 0.50,
    );
    canvas.drawOval(
      hl,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.42)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.16),
    );

    // THE SPARKLE at the upper right: a four-point star and two dots,
    // exactly where the reference has them.
    final star = c + Offset(r * 0.44, -r * 0.50);
    _star(canvas, star, r * 0.17, Colors.white.withValues(alpha: 0.95));
    canvas.drawCircle(c + Offset(r * 0.68, -r * 0.40), r * 0.035,
        Paint()..color = Colors.white.withValues(alpha: 0.85));
    canvas.drawCircle(c + Offset(r * 0.30, -r * 0.26), r * 0.022,
        Paint()..color = Colors.white.withValues(alpha: 0.60));
  }

  /// A four-point star with concave sides — the "sparkle" shape.
  void _star(Canvas canvas, Offset c, double r, Color color) {
    final p = Path();
    const inner = 0.30;
    for (var i = 0; i < 4; i++) {
      final a = -math.pi / 2 + i * math.pi / 2;
      final tip = c + Offset(math.cos(a) * r, math.sin(a) * r);
      final nb = a + math.pi / 4;
      final waist =
          c + Offset(math.cos(nb) * r * inner, math.sin(nb) * r * inner);
      if (i == 0) {
        p.moveTo(tip.dx, tip.dy);
      } else {
        p.lineTo(tip.dx, tip.dy);
      }
      p.lineTo(waist.dx, waist.dy);
    }
    p.close();
    canvas.drawPath(p, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_SpherePainter old) => old.t != t || old.glow != glow;
}

/// The space behind the orb. Same two brand hues as before, rebuilt to
/// feel alive rather than busy:
///
///  * an AURORA — two soft clouds of the accent (left) and its partner
///    (right) drifting slowly, brightening with the voice;
///  * DUST — faint motes floating outward from the orb, the way sound
///    carries;
///  * the reference's ring TUNNEL, kept for depth but pulled right back;
///  * and the part that says "I hear you": a LIQUID RING hugging the orb
///    that ripples with the voice, and pulses that roll outward faster the
///    louder it gets. Thinking swaps both for comets circling the orb.
///
/// Paint it full-width — it reaches both screen edges.
class VoiceOrbBackdrop extends StatefulWidget {
  const VoiceOrbBackdrop({
    super.key,
    required this.orbSize,
    this.mood = OrbMood.idle,
    this.level = 0,
  });

  final double orbSize;
  final OrbMood mood;
  final double level;

  @override
  State<VoiceOrbBackdrop> createState() => _VoiceOrbBackdropState();
}

class _VoiceOrbBackdropState extends State<VoiceOrbBackdrop>
    with SingleTickerProviderStateMixin {
  /// Drives the repaints. Time is the ticker's total elapsed time, not the
  /// controller's 0..1 value, so nothing jumps when the value wraps.
  late final AnimationController _t = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  )..repeat();
  double _last = 0;

  /// Integrated, not derived from the clock: the pulses speed up with the
  /// voice, and a speed change must never make them jump backwards.
  double _pulse = 0;

  // Everything the mood changes is eased in and out, never switched.
  double _level = 0, _pulseAmt = 0, _think = 0;

  @override
  void dispose() {
    _t.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _t,
        builder: (_, __) {
          final now = (_t.lastElapsedDuration?.inMicroseconds ?? 0) / 1e6;
          final dt = (now - _last).clamp(0.0, 0.1);
          _last = now;
          double ease(double v, double to, double rate) =>
              v + (to - v) * (1 - math.exp(-dt * rate));

          final target = widget.level.clamp(0.0, 1.0);
          _level = ease(_level, target, target > _level ? 18 : 4);
          final mood = widget.mood;
          _pulseAmt = ease(
              _pulseAmt,
              switch (mood) {
                OrbMood.idle => 0.35,
                OrbMood.thinking => 0.0,
                _ => 1.0,
              },
              3);
          _think = ease(_think, mood == OrbMood.thinking ? 1 : 0, 4);
          // Pulses per second: a slow heartbeat at rest, quicker as the
          // voice gets louder.
          _pulse += dt * (0.30 + _level * 0.55);

          return CustomPaint(
            painter: _BackdropPainter(
              sec: now,
              pulse: _pulse,
              orbRadius: widget.orbSize / 2,
              level: _level,
              pulseAmt: _pulseAmt,
              think: _think,
            ),
            child: const SizedBox.expand(),
          );
        },
      );
}

/// One mote of dust: where it starts, how fast it drifts, how it twinkles.
class _Mote {
  const _Mote(this.angle, this.offset, this.speed, this.size, this.twinkle);
  final double angle, offset, speed, size, twinkle;
}

final List<_Mote> _motes = () {
  final rnd = math.Random(7); // fixed: the same sky every time
  return List.generate(
      42,
      (_) => _Mote(
            rnd.nextDouble() * 2 * math.pi,
            rnd.nextDouble(),
            0.035 + rnd.nextDouble() * 0.05,
            0.7 + rnd.nextDouble() * 1.3,
            1.5 + rnd.nextDouble() * 2.5,
          ));
}();

class _BackdropPainter extends CustomPainter {
  _BackdropPainter({
    required this.sec,
    required this.pulse,
    required this.orbRadius,
    required this.level,
    required this.pulseAmt,
    required this.think,
  });

  final double sec, pulse, orbRadius, level, pulseAmt, think;

  /// Where the reference's rings sit, as multiples of the sphere's radius
  /// — fewer than before; they are depth now, not the subject.
  static const _rings = [1.39, 1.91, 2.42, 2.9, 3.4];

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = orbRadius;
    final violet = Neon.violet;
    final pink = Neon.pink;
    final bounds = Offset.zero & size;

    // Left-to-right sweep for the tunnel: accent, ink, partner.
    final sweep = LinearGradient(
      colors: [
        HSLColor.fromColor(violet).withLightness(0.46).toColor(),
        HSLColor.fromColor(violet)
            .withSaturation(0.35)
            .withLightness(0.18)
            .toColor(),
        HSLColor.fromColor(pink).withLightness(0.44).toColor(),
      ],
    ).createShader(bounds);
    // Round-the-orb sweep for the rings that hug it, turning slowly.
    final around = SweepGradient(
      colors: [violet, pink, Color.lerp(violet, pink, 0.4)!, violet],
      stops: const [0.0, 0.4, 0.75, 1.0],
      transform: GradientRotation(sec * 0.35),
    ).createShader(Rect.fromCircle(center: c, radius: r * 3));

    // Everything but the vignette fades out toward the top and bottom, so
    // it melts into the overlay instead of ending at the box's edge. ONE
    // offscreen layer per frame — per-element layers are how a pretty orb
    // becomes a stuttering one on a mid-range phone.
    canvas.saveLayer(bounds, Paint());

    // 1. AURORA — squashed into ovals so it stays inside the box.
    void cloud(Offset at, double radius, Color col, double a) {
      canvas.save();
      canvas.translate(at.dx, at.dy);
      canvas.scale(1, 0.62);
      canvas.drawCircle(
        Offset.zero,
        radius,
        Paint()
          ..shader = RadialGradient(
            colors: [
              col.withValues(alpha: a),
              col.withValues(alpha: a * 0.35),
              col.withValues(alpha: 0),
            ],
            stops: const [0.0, 0.45, 1.0],
          ).createShader(Rect.fromCircle(center: Offset.zero, radius: radius)),
      );
      canvas.restore();
    }

    cloud(
        c +
            Offset(-r * 0.95 + math.cos(sec * 0.21) * r * 0.3,
                math.sin(sec * 0.17) * r * 0.18),
        r * 2.7,
        violet,
        0.34 + level * 0.16);
    cloud(
        c +
            Offset(r * 0.95 + math.cos(sec * 0.19 + 2.1) * r * 0.3,
                math.sin(sec * 0.23 + 1.3) * r * 0.18),
        r * 2.5,
        pink,
        0.27 + level * 0.14);
    cloud(c, r * 1.8, Color.lerp(violet, pink, 0.45)!, 0.16 + level * 0.20);

    // 2. DUST drifting outward.
    final maxD = size.width * 0.56;
    for (final m in _motes) {
      final life = (m.offset + sec * m.speed) % 1.0;
      final dist = r * 1.3 + life * (maxD - r * 1.3);
      final a = m.angle + sec * 0.025;
      final pos = c + Offset(math.cos(a) * dist, math.sin(a) * dist * 0.7);
      final fade = math.sin(life * math.pi);
      final tw = 0.55 + 0.45 * math.sin(sec * m.twinkle + m.offset * 6.3);
      final hue =
          Color.lerp(violet, pink, (pos.dx / size.width).clamp(0.0, 1.0))!;
      canvas.drawCircle(
        pos,
        m.size,
        Paint()
          ..color = Color.lerp(hue, Colors.white, 0.55)!
              .withValues(alpha: 0.5 * fade * tw),
      );
    }

    // 3. The TUNNEL, breathing very slightly.
    final breathe = 1 + 0.025 * math.sin(sec * 0.7) + level * 0.04;
    for (var i = 0; i < _rings.length; i++) {
      final rx = r * _rings[i] * breathe;
      final ry = r * (1.3 + i * 0.16) * breathe;
      canvas.drawOval(
        Rect.fromCenter(center: c, width: rx * 2, height: ry * 2),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..shader = sweep
          ..color = Colors.white.withValues(alpha: 0.30 * (1 - i / 5)),
      );
    }

    // 4. PULSES rolling out from the orb.
    if (pulseAmt > 0.01) {
      for (var i = 0; i < 3; i++) {
        final ph = (pulse + i / 3) % 1.0;
        final fade = (1 - ph) * (1 - ph);
        canvas.drawCircle(
          c,
          r * (1.08 + ph * 0.95),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 0.6 + 2.2 * (1 - ph)
            ..shader = around
            ..color = Colors.white
                .withValues(alpha: fade * pulseAmt * (0.35 + level * 0.55)),
        );
      }
    }

    // 5. The LIQUID RING — hugs the orb and ripples with the voice. Two
    // strands out of step read as liquid; one reads as a wobbly circle.
    final calm = 1 - think * 0.7;
    final amp = r * (0.018 + level * 0.12) * calm;
    for (var j = 0; j < 2; j++) {
      final path = _liquid(
          c, r * (1.12 + j * 0.035), amp * (1 - j * 0.4), sec * 2.1 + j * 1.9);
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 8
          ..shader = around
          ..color = Colors.white.withValues(alpha: 0.10 + level * 0.10),
      );
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = j == 0 ? 2.0 : 1.2
          ..shader = around
          ..color = Colors.white.withValues(alpha: j == 0 ? 0.9 : 0.5),
      );
    }

    // 6. THINKING — two comets chasing round the orb.
    if (think > 0.01) {
      final rect = Rect.fromCircle(center: c, radius: r * 1.26);
      for (var k = 0; k < 2; k++) {
        final start = sec * 2 * math.pi * 0.55 + k * math.pi;
        final shader = SweepGradient(
          colors: [
            violet.withValues(alpha: 0),
            violet,
            Color.lerp(pink, Colors.white, 0.3)!,
          ],
          stops: const [0.0, 0.3, 0.42],
          transform: GradientRotation(start),
        ).createShader(rect);
        canvas.drawArc(
          rect,
          start,
          math.pi * 0.84,
          false,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.6
            ..strokeCap = StrokeCap.round
            ..shader = shader
            ..color = Colors.white.withValues(alpha: think * (1 - k * 0.45)),
        );
      }
    }

    canvas.drawRect(
      bounds,
      Paint()
        ..blendMode = BlendMode.dstIn
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.transparent,
            Colors.white,
            Colors.white,
            Colors.transparent,
          ],
          stops: [0.0, 0.22, 0.78, 1.0],
        ).createShader(bounds),
    );
    // No vignette. It was a black rectangle's worth of shading, and over
    // the session's tinted ground its edges drew a box round the orb; the
    // fade above already lets everything melt away top and bottom.
    canvas.restore();
  }

  /// A closed ring whose radius wanders with three harmonics moving at
  /// different speeds, so the ripple never visibly repeats.
  Path _liquid(Offset c, double base, double amp, double phase) {
    final p = Path();
    const n = 120;
    for (var k = 0; k <= n; k++) {
      final th = k / n * 2 * math.pi;
      final d = base +
          amp *
              (0.55 * math.sin(3 * th + phase * 1.3) +
                  0.30 * math.sin(5 * th - phase * 1.7) +
                  0.15 * math.sin(8 * th + phase * 2.3));
      final pt = c + Offset(math.cos(th) * d, math.sin(th) * d);
      if (k == 0) {
        p.moveTo(pt.dx, pt.dy);
      } else {
        p.lineTo(pt.dx, pt.dy);
      }
    }
    return p..close();
  }

  @override
  bool shouldRepaint(_BackdropPainter old) => true; // it is an animation
}

