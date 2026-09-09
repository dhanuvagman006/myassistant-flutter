import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import 'neon_tokens.dart';

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
abstract final class AppleColors {
  static const blue = Color(0xFF007AFF);
  static const green = Color(0xFF34C759);
  static const red = Color(0xFFFF3B30);
  static const orange = Color(0xFFFF9500);
  static const purple = Color(0xFFAF52DE);
  static const teal = Color(0xFF30B0C7);
  static const indigo = Color(0xFF5856D6);
  static const gray = Color(0xFF8E8E93);
}

/// Large leading title for a top-level screen ("Hub", "Finance").
class LargeTitle extends StatelessWidget {
  final String text;
  const LargeTitle(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 20),
      child: Text(
        text,
        style: GoogleFonts.spaceGrotesk(
          fontSize: 32,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.6,
          color: Neon.textHi,
        ),
      ),
    );
  }
}

/// Detail-screen app bar: plain ground, centered title, no elevation.
PreferredSizeWidget appleAppBar(BuildContext context, String title,
    {List<Widget>? actions, Widget? leading}) {
  return AppBar(
    backgroundColor: Neon.bg,
    surfaceTintColor: Colors.transparent,
    elevation: 0,
    centerTitle: true,
    leading: leading,
    title: Text(
      title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: Neon.textHi,
        fontSize: 17,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.2,
      ),
    ),
    actions: actions,
  );
}

/// The uppercase section label above a group.
class GroupLabel extends StatelessWidget {
  final String text;
  const GroupLabel(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 16, bottom: 7, top: 4),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          color: Neon.textDim,
          fontSize: 13,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
        ),
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
    return Material(
      color: Neon.surface,
      borderRadius: BorderRadius.circular(14),
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
  }
}

/// iOS Settings-style small solid-color icon square.
class IconTile extends StatelessWidget {
  final IconData icon;
  final Color color;
  final double size;
  const IconTile(this.icon, this.color, {super.key, this.size = 30});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(size * 0.23),
      ),
      child: Icon(icon, color: Colors.white, size: size * 0.6),
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

  const AppleRow({
    super.key,
    this.leading,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.titleColor,
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
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: titleColor ?? Neon.textHi,
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                    letterSpacing: -0.2,
                  ),
                ),
                if (subtitle != null && subtitle!.isNotEmpty) ...[
                  const SizedBox(height: 1),
                  Text(
                    subtitle!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: Neon.textLo, fontSize: 12.5),
                  ),
                ],
              ],
            ),
          ),
          trailing ??
              (onTap != null
                  ? Icon(Icons.chevron_right_rounded,
                      color: Neon.textDim, size: 20)
                  : const SizedBox.shrink()),
        ],
      ),
    );
    if (onTap == null) return row;
    return InkWell(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap!();
      },
      child: row,
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
      backgroundColor: Neon.violet,
      foregroundColor: Colors.white,
      minimumSize: const Size.fromHeight(50),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
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
