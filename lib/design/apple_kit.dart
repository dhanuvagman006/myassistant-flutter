import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import 'neon_tokens.dart';
import 'motion.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  APPLE KIT — the app's shared iOS-style building blocks.
///
///  The approved reference is the Hub screen: plain ground, large title,
///  white rounded groups, rows with small solid-color icon tiles, inset
///  hairlines, chevrons. Structure over decoration; the violet brand accent
///  survives as the tint color, the rest of the palette is Apple's system
///  colors. Nothing here owns behavior — visual building blocks only.
/// ─────────────────────────────────────────────────────────────────────────

/// Apple system palette (light). Use for icon tiles and semantic accents.
/// THE ACCENT NAMES, RE-POINTED AT OUR OWN PALETTE (2026-09-19).
///
/// These were literal iOS system colours, so a settings screen showed an
/// Apple blue next to an Apple orange next to a grey — six unrelated
/// hues with no relationship to the app's violet. The NAMES stay (every
/// screen already calls them) but each now resolves to a sibling of the
/// brand, and `gray` is gone in all but name: a grey tile was the exact
/// thing the owner called out. Theme-aware, like every other token.
abstract final class AppleColors {
  static Color get blue => Neon.accentF;
  static Color get green => Neon.accentE;
  static Color get red => Neon.error;
  static Color get orange => Neon.accentD;
  static Color get purple => Neon.accentA;
  static Color get teal => Neon.accentC;
  static Color get indigo => Neon.accentF;
  static Color get gray => Neon.accentB;
}

/// Large leading title for a top-level screen ("Hub", "Finance").
class LargeTitle extends StatelessWidget {
  final String text;
  const LargeTitle(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    final title = Text(
      text,
      style: GoogleFonts.spaceGrotesk(
        fontSize: 32,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.6,
        color: Neon.isDark ? Colors.white : Neon.textHi,
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 20),
      // A TAB'S NAME IN THE APP'S LIGHT at night (2026-09-30, the client's
      // neon reference): cyan into magenta, as Home's greeting name.
      child: Neon.isDark
          ? ShaderMask(
              blendMode: BlendMode.srcIn,
              shaderCallback: (r) =>
                  LinearGradient(colors: [Neon.cyan, Neon.pink]).createShader(r),
              child: title,
            )
          : title,
    );
  }
}

/// Detail-screen app bar: plain ground, centered title, no elevation.
PreferredSizeWidget appleAppBar(BuildContext context, String title,
    {List<Widget>? actions, Widget? leading}) {
  return AppBar(
    // Clear (2026-09-30): on a NeonScaffold the sky runs up behind the
    // title instead of stopping at a flat navy band; on a plain Neon.bg
    // page it looks exactly as before.
    backgroundColor: Colors.transparent,
    surfaceTintColor: Colors.transparent,
    elevation: 0,
    centerTitle: true,
    leading: leading,
    // A BARE TextStyle, ON PURPOSE (2026-09-24). This is the one place
    // where the "bare fontWeight draws the regular file" rule does not
    // hold: AppBar wraps its title in the theme's titleTextStyle, which is
    // GoogleFonts.spaceGrotesk(w700), so this title inherits the family
    // "SpaceGrotesk_700" and already draws from the bold file. Only size,
    // colour and spacing are set here, so all 20 detail bars keep the one
    // app-bar face the plain AppBars and LargeTitle use. (The clarity pass
    // had switched it to Manrope SemiBold: a lighter, different face.)
    // The row that opened this page (Hub) flies its title into this one.
    title: Hero(
      tag: titleHeroTag(title),
      flightShuttleBuilder: titleFlight,
      child: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: Neon.textHi,
          fontSize: NeonType.headline,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.2,
        ),
      ),
    ),
    actions: actions,
  );
}

/// The uppercase section label above a group — the ONE label style on
/// every tab (Hub had its own, in the accent at 11.5 sp, beside You's).
///
/// textLo, not textDim (2026-09-24): the labels at the top of You and Hub
/// sit on the ambient wash, where textDim measured 3.6:1.
class GroupLabel extends StatelessWidget {
  final String text;
  const GroupLabel(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 16, bottom: 7, top: 4),
      child: Text(
        text.toUpperCase(),
        style: NeonType.sectionLabel.copyWith(color: Neon.textLo),
      ),
    );
  }
}

/// A white rounded group of rows with inset hairlines between them.
class GroupedCard extends StatelessWidget {
  final List<Widget> children;

  /// Left inset of the separators (60 aligns past an icon tile, 16 for
  /// text-only rows).
  final double dividerInset;
  const GroupedCard({super.key, required this.children, this.dividerInset = 16});

  @override
  Widget build(BuildContext context) {
    final group = Material(
      color: Neon.isDark
          ? Color.alphaBlend(Neon.violet.withValues(alpha: 0.06), Neon.surface)
          : Neon.surface,
      // A hairline edge, as every other card in the app has: white on the
      // #F7F7FB detail ground is 1.07:1, so without it the group had no
      // visible edge (the "I never" card, 2026-09-24).
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Neon.isDark ? 16.6 : 14),
        side: Neon.isDark ? BorderSide.none : BorderSide(color: Neon.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0)
              Padding(
                padding: EdgeInsets.only(left: dividerInset),
                child: Divider(height: 1, thickness: 0.5, color: Neon.line),
              ),
            children[i],
          ],
        ],
      ),
    );
    if (!Neon.isDark) return group;
    // LIT AT NIGHT (2026-09-30): the app's rim, softened so a screen of
    // groups stays calm, and a faint halo — every list on every screen
    // sits in the same light as Home's cards.
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            for (final c in Neon.rim) c.withValues(alpha: 0.55),
          ],
        ),
        boxShadow: Neon.halo(Neon.violet, strength: 0.22),
      ),
      child: Padding(padding: const EdgeInsets.all(1.4), child: group),
    );
  }
}

/// iOS Settings-style small solid-color icon square.
class IconTile extends StatelessWidget {
  final IconData icon;
  final Color color;
  final double size;
  const IconTile(this.icon, this.color, {super.key, this.size = 34});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      // Same rule as every other tile in the app: a gradient built from
      // the accent, with its own light underneath.
      decoration: BoxDecoration(
        gradient: Neon.tile(color),
        borderRadius: BorderRadius.circular(size * 0.3),
      ),
      // Lit glass: a sheen on the top half (2026-09-30).
      foregroundDecoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.3),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.white.withValues(alpha: 0.24),
            Colors.white.withValues(alpha: 0),
          ],
          stops: const [0, 0.55],
        ),
      ),
      // White by day; dark ink on the evening theme's pastels, where
      // white fell to 1.4–2.3:1 (Neon.onTile).
      child: Icon(icon, color: Neon.onTile(color), size: size * 0.55),
    );
  }
}

/// One row inside a [GroupedCard]: optional icon tile, title, optional
/// subtitle, optional trailing (defaults to a chevron when tappable).
class AppleRow extends StatelessWidget {
  final Widget? leading;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final Color? titleColor;

  /// Lines the title may use before it is cut (a note or a summary shown
  /// as the title needs more than one).
  final int titleMaxLines;

  const AppleRow({
    super.key,
    this.leading,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.titleColor,
    this.titleMaxLines = 1,
  });

  @override
  Widget build(BuildContext context) {
    final row = Padding(
      padding: const EdgeInsets.fromLTRB(16, 11, 12, 11),
      child: Row(
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: 14)],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // The title in its real weight (see NeonType): it drew
                // from the regular file, level with its own subtitle.
                Text(
                  title,
                  maxLines: titleMaxLines,
                  overflow: TextOverflow.ellipsis,
                  style: NeonType.row
                      .copyWith(color: titleColor ?? Neon.textHi),
                ),
                if (subtitle != null && subtitle!.isNotEmpty) ...[
                  const SizedBox(height: 1),
                  Text(
                    subtitle!,
                    // Room for a longer line at large text sizes; with
                    // nothing on the right it may run as long as it needs.
                    maxLines: trailing == null && onTap == null ? null : 3,
                    overflow: trailing == null && onTap == null
                        ? null
                        : TextOverflow.ellipsis,
                    style: TextStyle(
                        color: Neon.textLo, fontSize: NeonType.footnote),
                  ),
                ],
              ],
            ),
          ),
          // A gap before whatever sits on the right: subtitles used to run
          // right up to the colour dot, the voice name and the switches.
          if (trailing != null || onTap != null) const SizedBox(width: 12),
          trailing ??
              (onTap != null
                  ? Icon(Icons.chevron_right_rounded,
                      color: Neon.textDim, size: 20)
                  : const SizedBox.shrink()),
        ],
      ),
    );
    if (onTap == null) return row;
    // The row dips a little under the finger as well as rippling
    // (2026-09-30): 0.985, since a full-width row moves its edges three
    // times as far as a card does for the same dip.
    return PressScale(
      scale: 0.985,
      child: InkWell(
        onTap: () {
          HapticFeedback.selectionClick();
          onTap!();
        },
        // 48 dp to the finger (2026-09-29): a one-line row with a small
        // leading icon ("Add a habit") came out at 46.
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: row,
        ),
      ),
    );
  }
}

/// iOS-style search field.
class AppleSearchField extends StatelessWidget {
  final String hint;
  final ValueChanged<String> onChanged;
  final TextEditingController? controller;
  const AppleSearchField({
    super.key,
    required this.hint,
    required this.onChanged,
    this.controller,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      onChanged: onChanged,
      style: TextStyle(color: Neon.textHi, fontSize: 15),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: Neon.textDim, fontSize: 15),
        prefixIcon: Icon(Icons.search_rounded, color: Neon.textDim, size: 20),
        isDense: true,
        filled: true,
        fillColor: Neon.surfaceHigh,
        contentPadding: const EdgeInsets.symmetric(vertical: 9),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}

/// Full-width primary action button (the app's violet tint, radius 12).
class ApplePrimaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  const ApplePrimaryButton(
      {super.key, required this.label, required this.onPressed, this.icon});

  @override
  Widget build(BuildContext context) {
    final style = FilledButton.styleFrom(
      backgroundColor: Neon.accentFill,
      foregroundColor: Neon.onAccent,
      minimumSize: const Size.fromHeight(50),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      // Manrope, in its real weight. A bare TextStyle here REPLACES the
      // theme's button font, so this label was drawn in the phone's
      // default font, not the app's.
      textStyle: NeonType.manrope(NeonType.rowTitle, FontWeight.w600),
    );
    return icon == null
        ? FilledButton(style: style, onPressed: onPressed, child: Text(label))
        : FilledButton.icon(
            style: style,
            onPressed: onPressed,
            icon: Icon(icon, size: 18),
            label: Text(label));
  }
}
