import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'gyro_motion.dart';
import 'gyro_tilt.dart';
import 'neon_tokens.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  Reusable UI atoms for the Neon design system. Every screen builds from
///  these instead of ad-hoc containers, so the look stays consistent.
/// ─────────────────────────────────────────────────────────────────────────

/// Primary CTA — gradient fill, glow, press-scale feedback.
class GradientButton extends StatefulWidget {
  final String label;
  final VoidCallback? onPressed;

  /// null → the signature violet-cyan (resolved at build so it themes).
  final Gradient? gradient;
  final IconData? icon;
  final bool busy;
  final EdgeInsets padding;

  const GradientButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.gradient,
    this.icon,
    this.busy = false,
    this.padding = const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
  });

  @override
  State<GradientButton> createState() => _GradientButtonState();
}

class _GradientButtonState extends State<GradientButton> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null && !widget.busy;
    return AnimatedScale(
      scale: _down ? 0.97 : 1,
      duration: Neon.fast,
      child: GestureDetector(
        onTapDown: enabled ? (_) => setState(() => _down = true) : null,
        onTapCancel: () => setState(() => _down = false),
        onTapUp: enabled
            ? (_) {
                setState(() => _down = false);
                HapticFeedback.lightImpact();
                widget.onPressed!();
              }
            : null,
        child: AnimatedOpacity(
          duration: Neon.fast,
          opacity: enabled ? 1 : 0.5,
          child: Builder(builder: (context) {
            final g = widget.gradient ?? Neon.gVioletCyan;
            return Container(
            padding: widget.padding,
            decoration: BoxDecoration(
              gradient: g,
              borderRadius: BorderRadius.circular(16),
              boxShadow: enabled
                  ? Neon.glow2(g.colors.first, g.colors.last)
                  : null,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (widget.busy) ...[
                  SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2.2, color: Neon.onInk),
                  ),
                  SizedBox(width: 10),
                ] else if (widget.icon != null) ...[
                  Icon(widget.icon, size: 19, color: Colors.white),
                  SizedBox(width: 8),
                ],
                Text(
                  widget.label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15.5,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.2,
                  ),
                ),
              ],
            ),
          );
          }),
        ),
      ),
    );
  }
}

/// Secondary action — outlined ghost with a subtle neon border.
class GhostButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final Widget? leading;

  /// null → Neon.cyan, resolved at build so it follows the theme.
  final Color? accent;

  const GhostButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.leading,
    this.accent,
  });

  @override
  Widget build(BuildContext context) {
    final a = accent ?? Neon.cyan;
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: Neon.textHi,
        side: BorderSide(color: a.withValues(alpha: 0.4)),
        padding: EdgeInsets.symmetric(horizontal: 22, vertical: 15),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (leading != null) ...[leading!, SizedBox(width: 10)],
          Text(label,
              style:
                  TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

/// Frosted glassmorphism card — the default container of the app.
class GlassCard extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  final EdgeInsets? margin;
  final double radius;
  final Color? tint;
  final Gradient? borderGradient;
  final VoidCallback? onTap;

  /// Gyroscope 3D presence — perspective tilt + moving light sheen +
  /// sliding shadow (see design/gyro_tilt.dart). Off by default.
  final bool tilt;

  GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(Neon.s4),
    this.margin,
    this.radius = Neon.rLg,
    this.tint,
    this.borderGradient,
    this.onTap,
    this.tilt = false,
  });

  @override
  Widget build(BuildContext context) {
    // Daylight: solid white card, hairline + soft neutral shadow. (The old
    // frosted BackdropFilter was invisible on a light ground AND cost a
    // full-screen blur per card — dropping it is also a jank fix.)
    final card = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: tint == null
            ? Neon.surface
            : Color.alphaBlend(tint!.withValues(alpha: 0.06), Neon.surface),
        borderRadius: BorderRadius.circular(radius),
        border: borderGradient == null ? Border.all(color: Neon.line) : null,
        boxShadow: Neon.cardShadow,
      ),
      child: child,
    );

    final bordered0 = borderGradient == null
        ? card
        : Container(
            padding: EdgeInsets.all(1.2),
            decoration: BoxDecoration(
              gradient: borderGradient,
              borderRadius: BorderRadius.circular(radius + 1.2),
            ),
            child: card,
          );

    // Gyro tilt wraps the card itself (inside the margin) so the layout
    // box never moves — only the painted card floats.
    final bordered = tilt
        ? GyroTilt(radius: radius, shadowColor: Neon.violet, child: bordered0)
        : bordered0;

    final content = margin == null
        ? bordered
        : Padding(padding: margin!, child: bordered);
    if (onTap == null) return content;
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap!();
      },
      child: content,
    );
  }
}

/// Small neon label chip / badge.
class NeonChip extends StatelessWidget {
  final String label;

  /// null → Neon.cyan, resolved at build so it follows the theme.
  final Color? color;
  final IconData? icon;
  final bool filled;

  const NeonChip({
    super.key,
    required this.label,
    this.color,
    this.icon,
    this.filled = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = color ?? Neon.cyan;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: c.withValues(alpha: filled ? 0.22 : 0.10),
        borderRadius: BorderRadius.circular(Neon.rPill),
        border: Border.all(color: c.withValues(alpha: 0.45)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: c),
            SizedBox(width: 5),
          ],
          Text(label,
              style: TextStyle(
                  color: color, fontSize: 12.5, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

/// Gradient-text brand / heading treatment.
class GradientText extends StatelessWidget {
  final String text;
  final TextStyle style;

  /// null → the signature violet-cyan, resolved at build.
  final Gradient? gradient;

  const GradientText(this.text,
      {super.key, required this.style, this.gradient});

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (bounds) =>
          (gradient ?? Neon.gVioletCyan).createShader(bounds),
      child: Text(text, style: style.copyWith(color: Colors.white)),
    );
  }
}

/// Section header with a tiny gradient tick — replaces plain bold labels.
class SectionHeader extends StatelessWidget {
  final String title;
  final Widget? trailing;
  const SectionHeader(this.title, {super.key, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Neon.s1, Neon.s5, Neon.s1, Neon.s3),
      child: Row(
        children: [
          Container(
            width: 4,
            height: 16,
            decoration: BoxDecoration(
              gradient: Neon.gVioletPink,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              title,
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

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
      action: onRetry == null
          ? null
          : GradientButton(
              label: 'Try again',
              icon: Icons.refresh_rounded,
              gradient: Neon.gPinkViolet,
              onPressed: onRetry,
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

/// ─────────────────────────────────────────────────────────────────────────
///  Liquid Glass layer — aurora backdrop + frosted modal sheets.
/// ─────────────────────────────────────────────────────────────────────────

/// Animated aurora-mesh background: three neon blobs drifting slowly on the
/// deep-space base. Pure gradients — no BackdropFilter — so it stays cheap.
class AuroraBackdrop extends StatefulWidget {
  final Widget child;
  const AuroraBackdrop({super.key, required this.child});

  @override
  State<AuroraBackdrop> createState() => _AuroraBackdropState();
}

class _AuroraBackdropState extends State<AuroraBackdrop>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(seconds: 18))
        ..repeat();

  // Gyro reactivity via the SHARED GyroMotion signal — tilting slides
  // the aurora blobs in parallax and morphs their colors, easing back
  // when the phone rests. The 18s repeating controller already repaints
  // every frame, so we just read the current values in the painter.
  final _gyro = GyroMotion.instance;

  @override
  void initState() {
    super.initState();
    _gyro.retain();
  }

  @override
  void dispose() {
    _gyro.release();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(color: Neon.bg),
      child: Stack(
        fit: StackFit.expand,
        children: [
          AnimatedBuilder(
            animation: _c,
            builder: (context, _) => CustomPaint(
              painter: _AuroraPainter(_c.value, _gyro.x, _gyro.y),
            ),
          ),
          widget.child,
        ],
      ),
    );
  }
}

class _AuroraPainter extends CustomPainter {
  final double t;
  final double gx, gy; // device tilt, −1.2..1.2, self-centering
  _AuroraPainter(this.t, [this.gx = 0, this.gy = 0]);

  void _blob(Canvas canvas, Size s, Color c, double phase, double dx,
      double dy, double r, double depth) {
    final a = 2 * 3.14159265 * (t + phase);
    // Parallax: each blob slides with the tilt; nearer blobs (bigger
    // depth) slide further, which reads as real depth behind the glass.
    final center = Offset(
      s.width * (dx + 0.10 * (0.5 + 0.5 * math.cos(a))) + gy * 46 * depth,
      s.height * (dy + 0.08 * (0.5 + 0.5 * math.sin(a * 0.8))) + gx * 46 * depth,
    );
    // Tilt also brightens the wash a touch, so motion feels alive.
    final motion = math.min(1.0, gx.abs() + gy.abs());
    // Daylight: the aurora is a whisper of color on paper, not a light
    // show — enough to feel alive, never enough to fight the content.
    final paint = Paint()
      ..shader = RadialGradient(colors: [
        c.withValues(alpha: 0.08 + 0.04 * motion),
        c.withValues(alpha: 0.0),
      ]).createShader(Rect.fromCircle(center: center, radius: r));
    canvas.drawCircle(center, r, paint);
  }

  @override
  void paint(Canvas canvas, Size size) {
    // Palette morph: tilting one way slides every blob's color toward the
    // next neon in the cycle (violet→pink→cyan→violet), the other way
    // toward the previous — the whole background changes hue with the
    // phone, then settles back.
    final shift = ((gx + gy) * 0.5).clamp(-1.0, 1.0);
    Color morph(Color base, Color fwd, Color back) => shift >= 0
        ? Color.lerp(base, fwd, shift)!
        : Color.lerp(base, back, -shift)!;

    _blob(canvas, size, morph(Neon.violet, Neon.pink, Neon.cyan),
        0.00, 0.10, 0.05, 260, 1.0);
    _blob(canvas, size, morph(Neon.cyan, Neon.violet, Neon.lime),
        0.33, 0.85, 0.80, 300, 0.55);
    _blob(canvas, size, morph(Neon.pink, Neon.cyan, Neon.violet),
        0.66, 0.75, 0.20, 210, 1.45);
  }

  @override
  bool shouldRepaint(covariant _AuroraPainter old) =>
      old.t != t || old.gx != gx || old.gy != gy;
}



/// Frosted glass modal bottom sheet — the ONLY navigation surface of the
/// single-page app. Everything secondary opens through this.
Future<T?> showGlassSheet<T>(
  BuildContext context, {
  required Widget child,
  String? title,
  double heightFactor = 0.88,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    builder: (ctx) {
      final h = MediaQuery.of(ctx).size.height * heightFactor;
      return ClipRRect(
        borderRadius:
            const BorderRadius.vertical(top: Radius.circular(Neon.rXl)),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Container(
            height: h,
            decoration: BoxDecoration(
              color: Neon.surface.withValues(alpha: 0.94),
              border: Border(top: BorderSide(color: Neon.lineBright)),
            ),
            child: Column(
              children: [
                const SizedBox(height: 10),
                Container(
                  width: 44,
                  height: 4,
                  decoration: BoxDecoration(
                    gradient: Neon.gVioletCyan,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                if (title != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                        Neon.s5, Neon.s4, Neon.s5, Neon.s1),
                    child: Row(
                      children: [
                        Expanded(
                          child: GradientText(
                            title,
                            style:
                                Theme.of(ctx).textTheme.titleLarge!,
                          ),
                        ),
                        IconButton(
                          icon: Icon(Icons.close_rounded,
                              color: Neon.textLo),
                          onPressed: () => Navigator.pop(ctx),
                        ),
                      ],
                    ),
                  )
                else
                  const SizedBox(height: 6),
                Expanded(child: child),
              ],
            ),
          ),
        ),
      );
    },
  );
}
