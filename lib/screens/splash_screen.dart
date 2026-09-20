import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../design/neon_tokens.dart';
import '../design/neon_widgets.dart';
import '../features/assistant/state/assistant_state.dart';
import '../features/assistant/widgets/siri_orb.dart';
import '../services/assistant_identity.dart';

/// Shown while the session restores. The splash IS the product now: the
/// assistant's living orb waking up, the name the user gave it, and a
/// line that rotates through what it actually does — not a generic
/// "booting…" under a static logo.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  late final AnimationController _rings = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 2400))
    ..repeat();

  /// One entrance, three beats: the orb springs in, the name rises,
  /// the tagline and loader settle last.
  late final AnimationController _in = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 900))
    ..forward();
  late final Animation<double> _orbIn = CurvedAnimation(
      parent: _in,
      curve: const Interval(0.0, 0.55, curve: Curves.easeOutBack));
  late final Animation<double> _nameIn = CurvedAnimation(
      parent: _in,
      curve: const Interval(0.30, 0.80, curve: Curves.easeOutCubic));
  late final Animation<double> _restIn = CurvedAnimation(
      parent: _in,
      curve: const Interval(0.55, 1.0, curve: Curves.easeOutCubic));

  /// What the assistant does, one truth at a time.
  static const _lines = [
    'Just say it — it handles it.',
    'Understands your calls.',
    'Remembers your promises.',
    'Plans your day.',
  ];
  int _line = 0;
  Timer? _cycle;

  @override
  void initState() {
    super.initState();
    _cycle = Timer.periodic(const Duration(milliseconds: 1600), (_) {
      if (mounted) setState(() => _line = (_line + 1) % _lines.length);
    });
  }

  @override
  void dispose() {
    _cycle?.cancel();
    _rings.dispose();
    _in.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: NeonBackdrop(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // The orb, already breathing — the same one the user will
              // talk to two seconds from now, with soft rings washing
              // outward while the session restores.
              ScaleTransition(
                scale: _orbIn,
                child: SizedBox(
                  width: 190,
                  height: 190,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      AnimatedBuilder(
                        animation: _rings,
                        builder: (_, __) => CustomPaint(
                          size: const Size(190, 190),
                          painter: _SplashRings(_rings.value),
                        ),
                      ),
                      const SiriOrb(
                        size: 128,
                        phase: AssistantPhase.idle,
                        connected: false, // the waking violet breath
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: Neon.s6),
              // The name the USER chose — their assistant, not our brand.
              // Falls back to the product name before first sign-in.
              AnimatedBuilder(
                animation: _nameIn,
                builder: (_, child) => Opacity(
                  opacity: _nameIn.value,
                  child: Transform.translate(
                      offset: Offset(0, 16 * (1 - _nameIn.value)),
                      child: child),
                ),
                child: ValueListenableBuilder<String>(
                  valueListenable: AssistantIdentity.notifier,
                  builder: (_, name, __) => Text(
                    name == AssistantIdentity.fallback ? 'MyAssistant' : name,
                    style: GoogleFonts.spaceGrotesk(
                      color: Neon.textHi,
                      fontSize: 26,
                      letterSpacing: -0.4,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: Neon.s2),
              AnimatedBuilder(
                animation: _restIn,
                builder: (_, child) =>
                    Opacity(opacity: _restIn.value, child: child),
                child: Column(
                  children: [
                    // One rotating truth about what it does.
                    SizedBox(
                      height: 20,
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 350),
                        switchInCurve: Curves.easeOut,
                        switchOutCurve: Curves.easeIn,
                        child: Text(
                          _lines[_line],
                          key: ValueKey(_line),
                          style:
                              TextStyle(color: Neon.textLo, fontSize: 13.5),
                        ),
                      ),
                    ),
                    const SizedBox(height: Neon.s7),
                    const NeonLoader(size: 26),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Soft rings washing outward from the orb — quiet, slow, no strobe.
class _SplashRings extends CustomPainter {
  final double t;
  _SplashRings(this.t);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final s = size.shortestSide / 2;
    for (final phase in const [0.0, 0.33, 0.66]) {
      final p = (t + phase) % 1.0;
      final radius = s * (0.68 + p * 0.46);
      final alpha = (1 - p) * 0.22 * math.sin(math.pi * p.clamp(0.05, 1.0));
      canvas.drawCircle(
        c,
        radius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6 - p * 1.0
          ..color = Neon.violet.withValues(alpha: alpha.clamp(0.0, 1.0)),
      );
    }
  }

  @override
  bool shouldRepaint(_SplashRings old) => old.t != t;
}
