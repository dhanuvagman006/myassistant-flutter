import 'package:flutter/material.dart';

import '../design/neon_tokens.dart';
import '../design/neon_widgets.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  THE LIT PRIMARY ACTION (2026-09-30, the client's neon brief). Each
///  page has ONE action that glows — the brand's fill with its halo — so
///  the next step is never in doubt; secondary actions stay rim-only (the
///  theme's OutlinedButton / TextButton). Used by the first-run pages
///  (sign-in, phone check, permissions, setup, guide, Welcome), which stand
///  under Home's sky ([NeonScaffold]), and by the full-page flows that end
///  in one decision (Style Studio's consent, the video recorder's Save).
/// ─────────────────────────────────────────────────────────────────────────

/// The page's primary action: full width, the accent fill, the brand's
/// halo under it. [busy] keeps it lit with the app's loader in place of the
/// label (a spinner in a grey, disabled button read as "broken").
class GlowCta extends StatelessWidget {
  const GlowCta({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.busy = false,
    this.busyLabel = 'Please wait',
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool busy;

  /// What a screen reader hears while [busy].
  final String busyLabel;

  @override
  Widget build(BuildContext context) {
    final lit = onPressed != null || busy;
    final style = FilledButton.styleFrom(
      minimumSize: const Size.fromHeight(52),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      textStyle: NeonType.manrope(NeonType.rowTitle, FontWeight.w600),
      // Busy is still the lit button, only waiting.
      disabledBackgroundColor: busy ? Neon.accentFill : null,
      disabledForegroundColor: busy ? Neon.onAccent : null,
    );
    final Widget child = busy
        ? NeonLoader.inline(semanticLabel: busyLabel)
        : icon == null
            ? Text(label, textAlign: TextAlign.center)
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 18),
                  const SizedBox(width: 8),
                  Flexible(child: Text(label, textAlign: TextAlign.center)),
                ],
              );
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        boxShadow: lit ? Neon.halo(Neon.violet) : null,
      ),
      child: FilledButton(
        style: style,
        onPressed: busy ? null : onPressed,
        child: child,
      ),
    );
  }
}

/// The app's mark on a first-run page: the brand gradient in a rounded
/// tile, lit. (It was a flat white square: "no motion, no glow" was the
/// light-first look.)
class BrandMark extends StatelessWidget {
  const BrandMark(
      {super.key, this.size = 54, this.icon = Icons.auto_awesome_rounded});

  final double size;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: Neon.gBrand,
        borderRadius: BorderRadius.circular(size * 0.3),
        boxShadow: Neon.halo(Neon.violet, strength: 0.8),
      ),
      child: Icon(icon, color: Neon.onBrand, size: size * 0.48),
    );
  }
}
