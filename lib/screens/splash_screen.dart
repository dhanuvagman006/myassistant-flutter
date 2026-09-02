import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../design/neon_tokens.dart';
import '../design/neon_widgets.dart';

/// Shown while the session restores — pulsing orb logo on the neon backdrop.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 2200))
    ..repeat();

  @override
  void dispose() {
    _c.dispose();
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
              AnimatedBuilder(
                animation: _c,
                builder: (context, _) {
                  final pulse =
                      0.5 + 0.5 * math.sin(_c.value * 2 * math.pi);
                  return Container(
                    width: 108,
                    height: 108,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: Neon.gOrb,
                      boxShadow: [
                        BoxShadow(
                          color: Neon.violet
                              .withValues(alpha: 0.25 + 0.30 * pulse),
                          blurRadius: 40 + 24 * pulse,
                          spreadRadius: 2 + 6 * pulse,
                        ),
                      ],
                    ),
                    padding: const EdgeInsets.all(3),
                    child: Container(
                      decoration: BoxDecoration(
                          shape: BoxShape.circle, color: Neon.bg),
                      child: Center(
                        child: Icon(Icons.auto_awesome_rounded,
                            size: 40, color: Neon.cyan),
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: Neon.s6),
              GradientText(
                'MYASSISTANT',
                style: Theme.of(context).textTheme.headlineSmall!.copyWith(
                    letterSpacing: 4, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: Neon.s2),
              Text('Booting your assistant…',
                  style: TextStyle(color: Neon.textLo, fontSize: 13.5)),
              const SizedBox(height: Neon.s7),
              const NeonLoader(size: 30),
            ],
          ),
        ),
      ),
    );
  }
}
