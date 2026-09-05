import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../design/neon_tokens.dart';
import '../../features/assistant/state/assistant_state.dart';
import '../../features/assistant/widgets/siri_orb.dart';
import '../../services/assistant_identity.dart';
import '../../services/auth_service.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  WELCOME — the payoff moment, shown ONCE right after onboarding.
///
///  Registration is work (form, OTP, naming); this is the reward. A brief
///  confetti burst, the assistant's orb visibly alive for the first time,
///  and their own name in big type. Staged reveals, one button out.
///
///  Deliberately still on-brand: plain ground, ink button, no glass — the
///  delight comes from motion and personalisation, not decoration.
/// ─────────────────────────────────────────────────────────────────────────
class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key, required this.onDone});

  final VoidCallback onDone;

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen>
    with TickerProviderStateMixin {
  late final AnimationController _in;
  late final AnimationController _confetti;
  late final List<_Particle> _particles;

  @override
  void initState() {
    super.initState();
    _in = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1400))
      ..forward();
    _confetti = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 2600))
      ..forward();
    final rnd = math.Random();
    _particles = List.generate(90, (_) => _Particle.random(rnd));
    HapticFeedback.mediumImpact();
  }

  @override
  void dispose() {
    _in.dispose();
    _confetti.dispose();
    super.dispose();
  }

  /// Staged entrance: each element fades up in its own window.
  Widget _stage(double from, double to, Widget child) {
    final a = CurvedAnimation(
      parent: _in,
      curve: Interval(from, to, curve: Curves.easeOutCubic),
    );
    return FadeTransition(
      opacity: a,
      child: SlideTransition(
        position:
            Tween(begin: const Offset(0, 0.10), end: Offset.zero).animate(a),
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final first =
        (AuthService.instance.user?.name ?? '').trim().split(RegExp(r'\s+')).first;
    final who = first.isEmpty ? 'aboard' : first;
    final assistant = AssistantIdentity.name;

    return Scaffold(
      backgroundColor: Neon.bg,
      body: Stack(
        fit: StackFit.expand,
        children: [
          SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 28),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Spacer(),
                      _stage(
                        0.0,
                        0.45,
                        // Alive from the very first frame — this is the
                        // moment the product stops being a form.
                        const Center(
                          child: SiriOrb(
                            size: 132,
                            phase: AssistantPhase.listening,
                            level: 0.3,
                          ),
                        ),
                      ),
                      const SizedBox(height: 34),
                      _stage(
                        0.25,
                        0.7,
                        Text(
                          first.isEmpty
                              ? 'Welcome aboard!'
                              : 'You\'re all set, $who!',
                          textAlign: TextAlign.center,
                          style: GoogleFonts.spaceGrotesk(
                            fontSize: 30,
                            fontWeight: FontWeight.w700,
                            color: Neon.textHi,
                            letterSpacing: -0.6,
                            height: 1.15,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      _stage(
                        0.45,
                        0.85,
                        Text(
                          '$assistant is ready — calls, reminders, messages '
                          'and your day, all handled by voice.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: Neon.textLo,
                              fontSize: 15,
                              height: 1.5),
                        ),
                      ),
                      const Spacer(),
                      _stage(
                        0.6,
                        1.0,
                        FilledButton(
                          onPressed: () {
                            HapticFeedback.lightImpact();
                            widget.onDone();
                          },
                          style: FilledButton.styleFrom(
                              backgroundColor: Neon.textHi,
                              foregroundColor: Neon.onInk),
                          child: Text('Meet $assistant'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          // Confetti on top of everything, taps pass straight through.
          IgnorePointer(
            child: AnimatedBuilder(
              animation: _confetti,
              builder: (_, __) => CustomPaint(
                painter: _ConfettiPainter(
                    t: _confetti.value, particles: _particles),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One confetti piece: spawn point across the top, a lateral drift, spin,
/// and gravity. All parameters fixed at spawn so the fall is deterministic
/// per frame value.
class _Particle {
  _Particle({
    required this.x0,
    required this.vx,
    required this.vy,
    required this.size,
    required this.spin,
    required this.phase,
    required this.color,
    required this.delay,
  });

  final double x0; // 0..1 across the width
  final double vx; // lateral drift, fraction of width per second
  final double vy; // initial downward speed, fraction of height per second
  final double size;
  final double spin; // radians per second
  final double phase;
  final Color color;
  final double delay; // 0..0.3 of the timeline

  static final _palette = [
    Neon.violet,
    Neon.cyan,
    Neon.pink,
    Neon.lime,
    Color(0xFFF59E0B),
  ];

  factory _Particle.random(math.Random r) => _Particle(
        x0: r.nextDouble(),
        vx: (r.nextDouble() - 0.5) * 0.25,
        vy: 0.25 + r.nextDouble() * 0.45,
        size: 5 + r.nextDouble() * 5,
        spin: (r.nextDouble() - 0.5) * 12,
        phase: r.nextDouble() * math.pi * 2,
        color: _palette[r.nextInt(_palette.length)],
        delay: r.nextDouble() * 0.3,
      );
}

class _ConfettiPainter extends CustomPainter {
  _ConfettiPainter({required this.t, required this.particles});

  final double t; // 0..1 overall timeline
  final List<_Particle> particles;

  @override
  void paint(Canvas canvas, Size size) {
    if (t >= 1) return;
    final paint = Paint();
    for (final p in particles) {
      final local = ((t - p.delay) / (1 - p.delay)).clamp(0.0, 1.0);
      if (local <= 0) continue;
      final seconds = local * 2.6;
      final x = (p.x0 + p.vx * seconds +
              0.02 * math.sin(seconds * 5 + p.phase)) *
          size.width;
      final y =
          (p.vy * seconds + 0.35 * seconds * seconds) * size.height - 12;
      if (y > size.height + 20) continue;
      // Fade out over the last third of each piece's life.
      final alpha = local < 0.66 ? 1.0 : (1 - (local - 0.66) / 0.34);
      paint.color = p.color.withValues(alpha: alpha.clamp(0.0, 1.0));
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(p.phase + p.spin * seconds);
      // Squash one axis over time — reads as a tumbling paper rectangle.
      final squash =
          0.4 + 0.6 * math.sin(seconds * 7 + p.phase).abs();
      canvas.drawRect(
        Rect.fromCenter(
            center: Offset.zero, width: p.size, height: p.size * squash),
        paint,
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_ConfettiPainter old) => old.t != t;
}
