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
///  the movement around it: the rings drift outward steadily while it
///  listens, tighten and shimmer while it thinks, and swell with the
///  voice while it speaks. The caption under the orb still says the
///  word.
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

/// The tunnel behind the orb: concentric rings running off both edges,
/// teal on the left and magenta on the right, with waveform lines
/// through the middle. Paint it full-width — in the reference it reaches
/// both screen edges, and boxing it in is what makes a copy look small.
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
  late final AnimationController _t = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 9),
  )..repeat();

  @override
  void dispose() {
    _t.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _t,
        builder: (_, __) => CustomPaint(
          painter: _TunnelPainter(
            t: _t.value,
            orbRadius: widget.orbSize / 2,
            mood: widget.mood,
            level: widget.level.clamp(0.0, 1.0),
          ),
          child: const SizedBox.expand(),
        ),
      );
}

class _TunnelPainter extends CustomPainter {
  _TunnelPainter({
    required this.t,
    required this.orbRadius,
    required this.mood,
    required this.level,
  });

  final double t;
  final double orbRadius;
  final OrbMood mood;
  final double level;

  /// Where the reference's rings sit, as multiples of the sphere's radius.
  static const _rings = [1.02, 1.39, 1.56, 1.91, 2.12, 2.42, 2.78, 3.2];

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = orbRadius;

    // Teal on the left, ink through the middle, magenta on the right —
    // one shader across the whole canvas, so every ring picks up the
    // colour of the side it is on exactly as the reference does.
    // The reference runs teal on the left through ink in the middle to
    // magenta on the right. Same structure, the app's two brand hues:
    // the accent on the left, its gradient partner on the right, the
    // page's own ground between them.
    final left = HSLColor.fromColor(Neon.violet);
    final right = HSLColor.fromColor(Neon.pink);
    final sweep = LinearGradient(
      begin: Alignment.centerLeft,
      end: Alignment.centerRight,
      colors: [
        left.withLightness(0.34).toColor(),
        left.withLightness(0.46).toColor(),
        HSLColor.fromColor(Neon.violet)
            .withSaturation(0.35)
            .withLightness(0.16)
            .toColor(),
        right.withLightness(0.42).toColor(),
        right.withLightness(0.32).toColor(),
      ],
      stops: const [0.0, 0.22, 0.5, 0.78, 1.0],
    ).createShader(Offset.zero & size);

    // A slow outward drift; while it listens the whole tunnel breathes a
    // little wider with the voice.
    final drift = mood == OrbMood.thinking
        ? 0.03 * math.sin(t * 2 * math.pi * 3) // tight shimmer
        : 0.06 * math.sin(t * 2 * math.pi);
    final swell = mood == OrbMood.idle ? 0.0 : level * 0.10;

    canvas.saveLayer(Offset.zero & size, Paint());
    for (var i = 0; i < _rings.length; i++) {
      final k = _rings[i] * (1 + drift + swell);
      final rx = r * k;
      // A tunnel, not a pond. Measured off the reference: its outermost
      // visible ring is about 2.55 times the sphere's radius across and
      // 1.25 times that tall — the vertical radius has to grow with the
      // horizontal one or the rings flatten into ripples.
      final ry = r * (1.24 + i * 0.125);
      if (rx > size.width) continue;
      final fade = (1 - i / _rings.length);
      canvas.drawOval(
        Rect.fromCenter(center: c, width: rx * 2, height: ry * 2),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.0 - i * 0.16
          ..shader = sweep
          ..color = Colors.white.withValues(alpha: 0.95 * fade),
      );
    }

    // Fade the arcs out towards the top and bottom of the canvas, so the
    // rings read as a tunnel seen edge-on rather than as flat concentric
    // ovals.
    //
    // ONE saveLayer FOR ALL OF THEM. Doing this per ring cost eight
    // full-canvas offscreen buffers every frame for the whole session —
    // on the mid-range phones this app is for, that is how a beautiful
    // orb becomes a stuttering one.
    canvas.drawRect(
      Offset.zero & size,
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
          stops: [0.0, 0.30, 0.70, 1.0],
        ).createShader(Offset.zero & size),
    );
    canvas.restore();

    // THE WAVEFORM LINES crossing behind it — three long, very low
    // sine paths, drifting at different speeds so they never look like
    // one repeating pattern.
    for (var line = 0; line < 3; line++) {
      final amp = r * (0.10 + line * 0.05) * (1 + level * 0.8);
      final phase = t * 2 * math.pi * (0.6 + line * 0.25) + line * 1.7;
      final yBase = c.dy + (line - 1) * r * 0.22;
      final path = Path();
      for (double x = 0; x <= size.width; x += 6) {
        final k = x / size.width;
        // Damped at the edges so the lines fade out instead of stopping.
        final damp = math.sin(k * math.pi);
        final y = yBase +
            math.sin(k * math.pi * 3.2 + phase) * amp * damp;
        if (x == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..shader = sweep
          ..color = Colors.white.withValues(alpha: 0.30 - line * 0.07),
      );
    }

    // A vignette so the tunnel falls into the dark at the edges rather
    // than being cut off by them.
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = RadialGradient(
          center: Alignment.center,
          radius: 0.72,
          colors: [
            // BLACK, not Neon.bg. The overlay this sits on is a 94%
            // black scrim in BOTH themes, so a vignette that follows the
            // page ground would paint white corners over it the moment
            // somebody switched to the light theme.
            Colors.transparent,
            Colors.black.withValues(alpha: 0.35),
            Colors.black.withValues(alpha: 0.80),
          ],
          stops: const [0.5, 0.84, 1.0],
        ).createShader(Offset.zero & size),
    );
  }

  @override
  bool shouldRepaint(_TunnelPainter old) =>
      old.t != t || old.level != level || old.mood != mood;
}
