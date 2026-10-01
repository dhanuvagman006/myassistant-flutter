import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design/motion.dart';
import '../design/neon_tokens.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  THE QUIET CARDS OF THE NEON PAGES (2026-09-30, the client's neon
///  direction). Home's GlowCard is the LOUD card: one per screen, for the
///  thing that matters most. Everything else on Reminders, Calls, Call
///  notes, Meetings and the case files sits on these — the dark raised
///  surface, a soft rim of light, and a tone only where the item's state
///  says something (a missed call, a failed upload, a call on now).
/// ─────────────────────────────────────────────────────────────────────────

/// A SMALL LIT TILE: the icon in the tone's ink on glass tinted by it,
/// rimmed with the tone's own gradient. The section headers and list
/// badges of the detail pages — Home's kind tiles, quieter.
class ToneTile extends StatelessWidget {
  const ToneTile(this.icon, this.tone, {super.key, this.size = 28});

  final IconData icon;
  final NeonTone tone;
  final double size;

  @override
  Widget build(BuildContext context) {
    final rim = tone.rim;
    final r = size * 0.32;
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        padding: const EdgeInsets.all(1.2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(r),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [for (final c in rim) c.withValues(alpha: 0.85)],
          ),
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: tone.fill,
            borderRadius: BorderRadius.circular(r - 1.2),
          ),
          child: Icon(icon, size: size * 0.54, color: tone.ink),
        ),
      ),
    );
  }
}

/// A RAISED CARD WITH A SOFT RIM — the one-item version of GroupedCard's
/// night look. [tone] null is ordinary content (the app's rim, softened);
/// a tone lights the rim in its colour and tints the glass a touch: the
/// state reads before the words do. Give it [onTap] and it dips and ticks
/// ([Tappable]); give it [heroTag] and it flies into the page it opens
/// ([cardHero]).
class RimCard extends StatelessWidget {
  const RimCard({
    super.key,
    required this.child,
    this.tone,
    this.padding = const EdgeInsets.all(14),
    this.radius = Neon.rMd,
    this.onTap,
    this.onLongPress,
    this.semanticLabel,
    this.tapHint = 'open',
    this.heroTag,
    this.heroPageRadius = Neon.rLg,
  });

  final Widget child;
  final NeonTone? tone;
  final EdgeInsets padding;
  final double radius;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final String? semanticLabel;
  final String? tapHint;

  /// [cardHeroTag] of the item; the page it opens marks its header with
  /// [cardHero] and the same tag.
  final Object? heroTag;

  /// The corner radius of the block it opens into (see [cardHero]).
  final double heroPageRadius;

  @override
  Widget build(BuildContext context) {
    final t = tone;
    final rim = t == null
        ? [for (final c in Neon.rim) c.withValues(alpha: 0.42)]
        : [for (final c in t.rim) c.withValues(alpha: 0.75)];
    final fill = t == null
        ? Color.alphaBlend(Neon.violet.withValues(alpha: 0.06), Neon.surface)
        : Color.alphaBlend(
            t.rim.first.withValues(alpha: 0.08), Neon.surface);
    Widget card = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: rim,
        ),
        // Only a toned card throws light: a long list of haloed rows is a
        // screen where everything glows, and two blurs a row on the
        // budget phone's GPU while it scrolls.
        boxShadow: t == null ? null : Neon.halo(t.rim.first, strength: 0.3),
      ),
      child: Padding(
        padding: const EdgeInsets.all(1.2),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(radius - 1.2),
          ),
          child: child,
        ),
      ),
    );
    final tag = heroTag;
    if (tag != null) {
      card = cardHero(context, tag, card,
          cardRadius: radius, pageRadius: heroPageRadius);
    }
    return Tappable(
      onTap: onTap,
      onLongPress: onLongPress,
      semanticLabel: semanticLabel,
      tapHint: tapHint,
      // A full-width row dips less than a tile (the AppleRow rule).
      scale: 0.985,
      child: card,
    );
  }
}

/// A TITLED CARD ON A DETAIL PAGE (call notes, meeting minutes): a
/// [ToneTile] in the section's [tone], its [title], then [child] — on the
/// same raised surface as the lists ([RimCard]).
class NeonSection extends StatelessWidget {
  const NeonSection({
    super.key,
    required this.icon,
    required this.title,
    required this.child,
    this.tone = NeonTone.brand,
    this.trailing,
    this.lit = false,
  });

  final IconData icon;
  final String title;
  final Widget child;
  final NeonTone tone;
  final Widget? trailing;

  /// The rim in the section's own tone (the state that matters on the
  /// page), not the app's quiet one.
  final bool lit;

  @override
  Widget build(BuildContext context) {
    return RimCard(
      tone: lit ? tone : null,
      radius: Neon.rLg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            ToneTile(icon, tone),
            const SizedBox(width: 10),
            Expanded(
              child: Semantics(
                header: true,
                child: Text(title,
                    style: NeonType.manrope(NeonType.body, FontWeight.w700)
                        .copyWith(color: Neon.textHi)),
              ),
            ),
            if (trailing != null) trailing!,
          ]),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}

/// ─────────────────────────────────────────────────────────────────────────
///  GLASS (2026-09-30, Home's premium pass — owner: "some look very cheap
///  quality… we need a higher class"). The same night-sky system, said
///  quietly: a softly graded fill ([Neon.glassFill]), a 1 px hairline that
///  catches the light at the top ([Neon.glassEdge]), and a low drop shadow
///  for lift ([Neon.lift]). No neon rim. [glow] is for the ONE thing on a
///  screen that matters most (Home's Now card): its colour's halo, soft,
///  and a hairline tinted by it. [wash] tints the top-left corner a touch
///  (a state — "all clear" — felt rather than shouted).
/// ─────────────────────────────────────────────────────────────────────────
class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(Neon.s4),
    this.radius = Neon.rCard,
    this.glow,
    this.wash,
    this.minHeight = 0,
    this.clip = false,
  });

  final Widget child;
  final EdgeInsets padding;
  final double radius;

  /// The one lit card on the screen: its halo and edge in this colour.
  final Color? glow;

  /// A faint corner light in this colour (no halo).
  final Color? wash;
  final double minHeight;

  /// Clip the child to the card's corners (a painted sky inside).
  final bool clip;

  @override
  Widget build(BuildContext context) {
    final g = glow;
    final w = wash ?? g;
    final r = BorderRadius.circular(radius);
    Widget inner = Container(
      constraints: BoxConstraints(minHeight: minHeight),
      padding: padding,
      decoration: w == null
          ? null
          : BoxDecoration(
              borderRadius: r,
              gradient: RadialGradient(
                center: const Alignment(-1, -1),
                radius: 1.4,
                colors: [
                  w.withValues(alpha: Neon.isDark ? 0.12 : 0.05),
                  w.withValues(alpha: 0),
                ],
              ),
            ),
      child: child,
    );
    if (clip) inner = ClipRRect(borderRadius: r, child: inner);
    return CustomPaint(
      foregroundPainter: _HairlinePainter(
        radius: radius,
        colors: g == null
            ? Neon.glassEdge
            : [g.withValues(alpha: 0.55), g.withValues(alpha: 0.12)],
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: r,
          gradient: Neon.glassFill,
          boxShadow: [
            ...Neon.lift,
            if (g != null) ...Neon.halo(g, strength: 0.45),
          ],
        ),
        child: inner,
      ),
    );
  }
}

/// A GROUPED GLASS LIST: [children] as rows of one [GlassCard], split by
/// hairlines inset [indent] from the left — the iOS inset-grouped list,
/// in glass. Rows keep their own taps; the ink shows on the glass.
class GlassGroup extends StatelessWidget {
  const GlassGroup({
    super.key,
    required this.children,
    this.indent = Neon.s4,
  });

  final List<Widget> children;
  final double indent;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: EdgeInsets.zero,
      clip: true,
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (i, c) in children.indexed) ...[
              if (i > 0)
                Padding(
                  padding: EdgeInsets.only(left: indent),
                  child: Divider(height: 1, thickness: 1, color: Neon.hairline),
                ),
              c,
            ],
          ],
        ),
      ),
    );
  }
}

/// A QUIET TONAL ICON TILE: the icon in [color] on a low wash of it, a
/// thin rim of the same — the kind of thing, told softly (Home's cards).
class GlassTile extends StatelessWidget {
  const GlassTile(this.icon, this.color, {super.key, this.size = 40});

  final IconData icon;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final r = size >= 36 ? Neon.rTile : size * 0.32;
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(r),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              color.withValues(alpha: Neon.isDark ? 0.20 : 0.12),
              color.withValues(alpha: Neon.isDark ? 0.08 : 0.05),
            ],
          ),
          border: Border.all(color: color.withValues(alpha: 0.26)),
        ),
        child: Icon(icon, size: size * 0.5, color: color),
      ),
    );
  }
}

/// THE PRIMARY GLASS BUTTON (Home's Play): a glass pill with the brand's
/// gradient disc for its icon — the colour in one small place, the label
/// in the text colour. 48 dp to the finger; dips and ticks; one button
/// to a screen reader, with its [label].
class GlassButton extends StatelessWidget {
  const GlassButton({
    super.key,
    required this.label,
    required this.icon,
    this.onPressed,
    this.busy = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final press = onPressed;
    final enabled = press != null && !busy;
    Widget b = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: enabled
          ? () {
              HapticFeedback.selectionClick();
              press();
            }
          : null,
      child: CustomPaint(
        foregroundPainter:
            _HairlinePainter(radius: Neon.rPill, colors: Neon.glassEdge),
        child: Container(
          constraints: const BoxConstraints(minHeight: 48),
          padding: const EdgeInsets.fromLTRB(6, 6, 18, 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Neon.rPill),
            gradient: Neon.glassFill,
            boxShadow: Neon.lift,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: Neon.gBrand,
                ),
                child: busy
                    ? Padding(
                        padding: const EdgeInsets.all(10),
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Neon.onBrand),
                      )
                    : Icon(icon, size: 22, color: Neon.onBrand),
              ),
              const SizedBox(width: 10),
              Text(
                label,
                style: NeonType.manrope(NeonType.body, FontWeight.w700)
                    .copyWith(color: Neon.textHi),
              ),
            ],
          ),
        ),
      ),
    );
    if (enabled) b = PressScale(scale: 0.96, child: b);
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      onTap: enabled ? press : null,
      excludeSemantics: true,
      child: b,
    );
  }
}

/// A 1 px rounded edge in a top-to-bottom gradient, drawn over the card.
class _HairlinePainter extends CustomPainter {
  _HairlinePainter({required this.radius, required this.colors});
  final double radius;
  final List<Color> colors;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(0.5);
    final r = radius.clamp(0.0, size.shortestSide / 2).toDouble();
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(r)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: colors,
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_HairlinePainter old) =>
      old.radius != radius ||
      old.colors.length != colors.length ||
      [for (var i = 0; i < colors.length; i++) old.colors[i] != colors[i]]
          .contains(true);
}

/// THE PAGE'S END OF A CARD FLIGHT: [child] (the header a list card opens
/// into) marked with [tag] and the card shuttle, so the card grows into
/// it on the push and shrinks back on Back. Without Remove animations
/// only; both ends must use the same radii.
Widget cardHero(BuildContext context, Object tag, Widget child,
    {double cardRadius = Neon.rMd, double pageRadius = Neon.rLg}) {
  if (Motion.reduced(context)) return child;
  return Hero(
    tag: tag,
    flightShuttleBuilder:
        cardFlightFor(cardRadius: cardRadius, pageRadius: pageRadius),
    child: child,
  );
}
