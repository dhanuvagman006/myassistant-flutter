import 'package:flutter/material.dart';

import '../design/neon_tokens.dart';

/// THE ROOM THE APP SITS IN.
///
/// A flat page reads as "nothing rendered yet" — screens float on a void
/// with no depth. This paints the ground the whole app stands on: the
/// theme's own colour, bled through the page.
///
/// Three layers, in order:
///   1. a vertical wash, so the page is never one flat value top to
///      bottom — this is what stops it reading as black;
///   2. two large pools of light, top-left and bottom-right, giving the
///      page a direction;
///   3. a wide, very faint pool through the middle, because the first
///      two leave the centre of a tall phone screen dead.
///
/// Deliberately restrained: no visible edges, no second hue competing
/// with content. You should feel the colour without being able to point
/// at where it begins.
class AmbientBackground extends StatelessWidget {
  final Widget child;
  const AmbientBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final dark = Neon.isDark;
    final tint = Neon.violet;
    final partner = Neon.pink;
    final size = MediaQuery.sizeOf(context);
    final w = size.width;
    final h = size.height;

    return Stack(
      children: [
        // 1 — the wash. Lifted at the top where the greeting sits,
        // settling to the page ground by the dock.
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color.alphaBlend(
                      tint.withValues(alpha: dark ? 0.13 : 0.07), Neon.bg),
                  Color.alphaBlend(
                      tint.withValues(alpha: dark ? 0.05 : 0.03), Neon.bg),
                  Neon.bg,
                ],
                stops: const [0.0, 0.42, 1.0],
              ),
            ),
          ),
        ),
        // 2 — the two pools, sized to the screen so a tall phone and a
        // small one get the same picture rather than the same pixels.
        Positioned(
          left: -w * 0.35,
          top: -h * 0.12,
          child: _pool(tint, dark ? 0.26 : 0.13, w * 1.25),
        ),
        Positioned(
          right: -w * 0.42,
          bottom: -h * 0.10,
          child: _pool(partner, dark ? 0.20 : 0.10, w * 1.30),
        ),
        // 3 — the middle, which the corner pools never reach.
        Positioned(
          left: w * 0.10,
          top: h * 0.34,
          child: _pool(partner, dark ? 0.10 : 0.05, w * 1.05),
        ),
        child,
      ],
    );
  }

  /// One soft circle of light. A RadialGradient fading to fully
  /// transparent costs nothing to paint — a real blur filter over the
  /// whole page would cost a frame on a mid-range phone, every frame.
  static Widget _pool(Color c, double alpha, double size) => IgnorePointer(
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: [
                c.withValues(alpha: alpha),
                c.withValues(alpha: alpha * 0.55),
                c.withValues(alpha: alpha * 0.18),
                c.withValues(alpha: 0),
              ],
              stops: const [0.0, 0.34, 0.62, 1.0],
            ),
          ),
        ),
      );
}
