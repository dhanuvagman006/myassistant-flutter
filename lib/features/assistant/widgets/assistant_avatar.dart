import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../design/gyro_motion.dart';
import '../../../design/neon_tokens.dart';
import '../state/assistant_state.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  AssistantAvatar — the assistant's FACE. Replaces the AI orb.
///
///  Client spec: after sign-up we know the user's gender; the assistant
///  shows the OPPOSITE-gender face — a male user talks to a girl's face,
///  a female user to a boy's. Unset/other → the female face.
///
///  A stylized neon-line portrait (matches the design system — this is
///  Hari's brand look, not a photo):
///    • eyes track the device tilt (GyroMotion) and the head leans subtly,
///      so the face follows you as you move the phone
///    • natural blinking on an organic timer
///    • the mouth ANIMATES while the assistant speaks its reply aloud —
///      the face is the one answering you
///    • listening: eyes widen, brows lift — visibly paying attention
///    • thinking: eyes glance up-side, mouth small
///    • error: flat mouth, brows tilt in
/// ─────────────────────────────────────────────────────────────────────────
class AssistantAvatar extends StatefulWidget {
  final AssistantPhase phase;

  /// Live mic level 0..1 while listening; drives subtle head energy.
  final double micLevel;

  /// The USER's gender ('male' | 'female' | other/null). The avatar renders
  /// the opposite.
  final String? userGender;

  final VoidCallback? onTap;

  const AssistantAvatar({
    super.key,
    required this.phase,
    this.micLevel = 0,
    this.userGender,
    this.onTap,
  });

  bool get avatarIsMale => userGender == 'female';

  @override
  State<AssistantAvatar> createState() => _AssistantAvatarState();
}

class _AssistantAvatarState extends State<AssistantAvatar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  final _gyro = GyroMotion.instance;

  // Blink state — organic randomized timer.
  double _nextBlinkAt = 1.5;
  double _blink = 0; // 0 open .. 1 closed
  double _lastT = 0;
  final _rand = math.Random();

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: const Duration(seconds: 60))
      ..addListener(_step)
      ..repeat();
    _gyro.retain();
  }

  void _step() {
    // Continuous clock in seconds (controller loops over 60s).
    final now = _c.value * 60;
    var dt = now - _lastT;
    if (dt < 0) dt += 60; // wrapped
    _lastT = now;

    // Blink: quick close-open around _nextBlinkAt.
    _nextBlinkAt -= dt;
    if (_nextBlinkAt <= 0) {
      _blink = 1;
      _nextBlinkAt = 2.2 + _rand.nextDouble() * 3.5; // every ~2–6s
    } else if (_blink > 0) {
      _blink = (_blink - dt * 9).clamp(0.0, 1.0); // reopen in ~110ms
    }
    setState(() {});
  }

  @override
  void dispose() {
    _gyro.release();
    _c.dispose();
    super.dispose();
  }

  Color get _accent => switch (widget.phase) {
        AssistantPhase.listening => Neon.cyan,
        AssistantPhase.error => Neon.error,
        AssistantPhase.inCall ||
        AssistantPhase.dialing ||
        AssistantPhase.ringing =>
          Neon.success,
        _ => Neon.violet,
      };

  @override
  Widget build(BuildContext context) {
    final t = _c.value * 60;
    final energy = _gyro.energy;
    final speaking = widget.phase == AssistantPhase.speaking;
    final breathe = 1 + 0.015 * math.sin(t * 2 * math.pi / 3) + 0.01 * energy;

    return GestureDetector(
      onTap: widget.onTap,
      child: SizedBox(
        width: 210,
        height: 210,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Ambient glow behind the face, phase-colored.
            Container(
              width: 175,
              height: 175,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: _accent.withValues(alpha: 0.35 + 0.12 * energy),
                    blurRadius: 46 + 12 * energy,
                    spreadRadius: 4,
                  ),
                ],
              ),
            ),
            // State ring (kept from the orb design language).
            AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              width: 176,
              height: 176,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: _accent.withValues(
                      alpha:
                          widget.phase == AssistantPhase.idle ? 0.25 : 0.7),
                  width: 2.5,
                ),
              ),
            ),
            // The face itself — head leans with the tilt.
            Transform.scale(
              scale: breathe,
              child: Transform.rotate(
                angle: (_gyro.y * 0.06).clamp(-0.09, 0.09),
                child: Container(
                  width: 160,
                  height: 160,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      center: Alignment(
                        (-0.3 - _gyro.y * 0.3).clamp(-0.8, 0.8),
                        (-0.4 - _gyro.x * 0.3).clamp(-0.8, 0.8),
                      ),
                      colors: [
                        Neon.surfaceHigh,
                        Neon.bg.withValues(alpha: 0.95),
                      ],
                    ),
                    border: Border.all(color: Neon.lineBright, width: 1),
                  ),
                  child: ClipOval(
                    child: CustomPaint(
                      painter: _FacePainter(
                        male: widget.avatarIsMale,
                        phase: widget.phase,
                        t: t,
                        blink: _blink,
                        gx: _gyro.x,
                        gy: _gyro.y,
                        speaking: speaking,
                        micLevel: widget.micLevel,
                        accent: _accent,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FacePainter extends CustomPainter {
  final bool male;
  final AssistantPhase phase;
  final double t;
  final double blink; // 0 open .. 1 closed
  final double gx, gy; // device tilt
  final bool speaking;
  final double micLevel;
  final Color accent;

  _FacePainter({
    required this.male,
    required this.phase,
    required this.t,
    required this.blink,
    required this.gx,
    required this.gy,
    required this.speaking,
    required this.micLevel,
    required this.accent,
  });

  @override
  void paint(Canvas canvas, Size s) {
    final w = s.width, h = s.height;
    final cx = w / 2;

    // Gaze: eyes chase the tilt (clamped so pupils stay in the eyes).
    final look = Offset(
      (-gy * 6).clamp(-5.0, 5.0),
      (-gx * 5).clamp(-4.0, 4.0) +
          (phase == AssistantPhase.thinking ? -2.5 : 0),
    );

    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 3.2
      ..shader = const LinearGradient(
              colors: [Neon.violet, Neon.cyan, Neon.pink])
          .createShader(Rect.fromLTWH(0, 0, w, h));

    final soft = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 2.2
      ..color = Neon.textLo.withValues(alpha: 0.85);

    // ---------------- HAIR (the gender read) ----------------
    final hair = Path();
    if (male) {
      // Boy: short swept crop with a sharp side part.
      hair.moveTo(w * 0.14, h * 0.40);
      hair.cubicTo(w * 0.10, h * 0.16, w * 0.36, h * 0.06, w * 0.56, h * 0.10);
      hair.cubicTo(w * 0.74, h * 0.13, w * 0.88, h * 0.24, w * 0.87, h * 0.40);
      hair.moveTo(w * 0.22, h * 0.30);
      hair.quadraticBezierTo(w * 0.42, h * 0.18, w * 0.66, h * 0.22);
    } else {
      // Girl: long flowing hair down both sides.
      hair.moveTo(w * 0.16, h * 0.78);
      hair.cubicTo(w * 0.06, h * 0.48, w * 0.12, h * 0.14, w * 0.50, h * 0.08);
      hair.cubicTo(w * 0.88, h * 0.14, w * 0.94, h * 0.48, w * 0.84, h * 0.78);
      hair.moveTo(w * 0.28, h * 0.24);
      hair.quadraticBezierTo(w * 0.50, h * 0.14, w * 0.72, h * 0.24);
    }
    canvas.drawPath(hair, stroke);

    // ---------------- BROWS ----------------
    final browLift = phase == AssistantPhase.listening
        ? -3.0
        : phase == AssistantPhase.error
            ? 2.0
            : 0.0;
    final browTilt = phase == AssistantPhase.error ? 2.5 : 0.0;
    final by = h * 0.40 + browLift;
    canvas.drawLine(Offset(w * 0.28, by + browTilt),
        Offset(w * 0.42, by - browTilt), soft);
    canvas.drawLine(Offset(w * 0.58, by - browTilt),
        Offset(w * 0.72, by + browTilt), soft);

    // ---------------- EYES ----------------
    final open = (1 - blink).clamp(0.0, 1.0) *
        (phase == AssistantPhase.listening ? 1.15 : 1.0);
    final eyeH = 7.5 * open;
    for (final ex in [w * 0.35, w * 0.65]) {
      final c = Offset(ex, h * 0.50);
      if (eyeH < 1.2) {
        canvas.drawLine(Offset(ex - 8, c.dy), Offset(ex + 8, c.dy), soft);
      } else {
        canvas.drawOval(
            Rect.fromCenter(center: c, width: 22, height: eyeH * 2), soft);
        // Pupil follows the gaze; tiny sparkle highlight.
        final p = c + look;
        canvas.drawCircle(
            p, 4.2, Paint()..color = accent.withValues(alpha: 0.95));
        canvas.drawCircle(p.translate(-1.4, -1.4), 1.3,
            Paint()..color = Colors.white.withValues(alpha: 0.9));
      }
    }

    // ---------------- NOSE ----------------
    canvas.drawLine(
        Offset(cx, h * 0.55), Offset(cx - 3, h * 0.63), soft..strokeWidth = 2.0);

    // ---------------- MOUTH — the reply animation ----------------
    final my = h * 0.74;
    final mouth = Path();
    if (speaking) {
      // Talking: openness oscillates fast, like syllables.
      final openAmt =
          4 + 7 * (0.5 + 0.5 * math.sin(t * 2 * math.pi * 4.6)).abs();
      mouth.addOval(Rect.fromCenter(
          center: Offset(cx, my), width: 26, height: openAmt * 2));
      canvas.drawPath(mouth, soft..strokeWidth = 2.6);
    } else if (phase == AssistantPhase.error) {
      canvas.drawLine(Offset(cx - 12, my), Offset(cx + 12, my), soft);
    } else if (phase == AssistantPhase.listening) {
      // Slightly open — attentive.
      mouth.moveTo(cx - 11, my);
      mouth.quadraticBezierTo(cx, my + 6 + micLevel * 4, cx + 11, my);
      canvas.drawPath(mouth, soft);
    } else {
      // Idle/thinking: gentle smile.
      mouth.moveTo(cx - 13, my - 2);
      mouth.quadraticBezierTo(cx, my + 8, cx + 13, my - 2);
      canvas.drawPath(mouth, soft);
    }

    // Girl: small lash accents; boy: light jaw line.
    if (!male) {
      for (final ex in [w * 0.35, w * 0.65]) {
        canvas.drawLine(Offset(ex - 12, h * 0.47), Offset(ex - 15, h * 0.44),
            soft..strokeWidth = 1.8);
        canvas.drawLine(Offset(ex + 12, h * 0.47), Offset(ex + 15, h * 0.44),
            soft..strokeWidth = 1.8);
      }
    } else {
      canvas.drawArc(
          Rect.fromCenter(
              center: Offset(cx, h * 0.72), width: w * 0.52, height: h * 0.38),
          0.5,
          2.14,
          false,
          soft..strokeWidth = 1.6);
    }
  }

  @override
  bool shouldRepaint(covariant _FacePainter old) => true;
}
