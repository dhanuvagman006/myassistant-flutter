import 'package:flutter/material.dart';

import 'neon_tokens.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  Reusable UI atoms for the Neon design system. Every screen builds from
///  these instead of ad-hoc containers, so the look stays consistent.
/// ─────────────────────────────────────────────────────────────────────────

/// Empty state — icon in a glowing gradient ring + guidance copy.
class NeonEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? body;
  final Widget? action;

  const NeonEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.body,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Neon.s7),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: Neon.gVioletCyan,
                boxShadow: Neon.glow(Neon.violet, blur: 34, alpha: 0.35),
              ),
              padding: const EdgeInsets.all(2),
              child: Container(
                decoration: BoxDecoration(
                    shape: BoxShape.circle, color: Neon.surface),
                child: Icon(icon, size: 34, color: Neon.cyan),
              ),
            ),
            const SizedBox(height: Neon.s5),
            Text(title,
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
            if (body != null) ...[
              const SizedBox(height: Neon.s2),
              Text(body!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Neon.textLo, height: 1.4)),
            ],
            if (action != null) ...[
              const SizedBox(height: Neon.s5),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

/// Error state with a retry affordance.
class NeonErrorState extends StatelessWidget {
  final String message;
  final VoidCallback? onRetry;
  const NeonErrorState({super.key, required this.message, this.onRetry});

  @override
  Widget build(BuildContext context) {
    return NeonEmptyState(
      icon: Icons.bolt_rounded,
      title: 'Something broke the circuit',
      body: message,
      // Was a gradient CTA. The gradient/glass atoms were removed with the
      // rest of the unused Neon set, and this is the app's current button:
      // the same FilledButton the Studio and settings screens use, so a
      // retry here looks like every other primary action.
      action: onRetry == null
          ? null
          : FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Try again'),
              style: FilledButton.styleFrom(
                backgroundColor: Neon.textHi,
                foregroundColor: Neon.onInk,
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
              ),
            ),
    );
  }
}

/// Gradient loading spinner (ring sweep).
class NeonLoader extends StatefulWidget {
  final double size;
  const NeonLoader({super.key, this.size = 42});

  @override
  State<NeonLoader> createState() => _NeonLoaderState();
}

class _NeonLoaderState extends State<NeonLoader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1100))
    ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RotationTransition(
      turns: _c,
      child: Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
            shape: BoxShape.circle, gradient: Neon.gOrb),
        padding: const EdgeInsets.all(3),
        child: DecoratedBox(
          decoration: BoxDecoration(shape: BoxShape.circle, color: Neon.bg),
        ),
      ),
    );
  }
}

/// Ambient background — deep space with two soft radial neon washes.
/// Wrap any Scaffold body with this for the signature backdrop.
class NeonBackdrop extends StatelessWidget {
  final Widget child;
  const NeonBackdrop({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(color: Neon.bg),
      child: Stack(
        children: [
          Positioned(
            top: -120,
            left: -80,
            child: _wash(Neon.violet, 340),
          ),
          Positioned(
            bottom: -140,
            right: -100,
            child: _wash(Neon.cyan, 380),
          ),
          child,
        ],
      ),
    );
  }

  Widget _wash(Color c, double size) => IgnorePointer(
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(colors: [
              c.withValues(alpha: 0.07),
              c.withValues(alpha: 0.0),
            ]),
          ),
        ),
      );
}
