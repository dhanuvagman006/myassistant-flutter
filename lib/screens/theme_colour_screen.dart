import 'package:flutter/material.dart';

import '../design/apple_kit.dart';
import '../design/accent_controller.dart';
import '../design/motion.dart';
import '../design/neon_tokens.dart';
import '../design/neon_widgets.dart';

/// THEME COLOUR — its own screen, reached from Settings → Appearance.
///
/// Kept off the settings page itself: a wall of colour circles is the
/// loudest thing on a screen that is otherwise a quiet list, and nobody
/// changes their theme twice a week. Same shape as Avatar face — a row
/// that says what is chosen, and a screen to change it.
class ThemeColourScreen extends StatefulWidget {
  const ThemeColourScreen({super.key});

  @override
  State<ThemeColourScreen> createState() => _ThemeColourScreenState();
}

class _ThemeColourScreenState extends State<ThemeColourScreen> {
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Color>(
      valueListenable: AccentController.seed,
      builder: (_, seed, __) => NeonScaffold(
        appBar: appleAppBar(context, 'Theme colour'),
        body: ListView(
          padding: EdgeInsets.fromLTRB(
              20, 12, 20, 40 + MediaQuery.paddingOf(context).bottom),
          children: [
            Text(
              'Your colour paints the orb, the mic, every icon tile and '
              'each highlight in the app. Tap one to see it straight away.',
              style: TextStyle(color: Neon.textLo, fontSize: 14, height: 1.5),
            ),
            const SizedBox(height: 22),
            Wrap(
              spacing: 16,
              runSpacing: 18,
              children: [
                for (final (name, c) in AccentController.swatches)
                  _swatch(name, c, seed.toARGB32() == c.toARGB32()),
              ],
            ),
            const SizedBox(height: 28),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                gradient: Neon.gBrand,
                borderRadius: BorderRadius.circular(Neon.rXl),
                boxShadow: Neon.glow2(Neon.violet, Neon.pink, blur: 26),
              ),
              // The accent's own ink (2026-09-30), not a fixed white: a
              // light pick (Mint, Sky) takes dark words, as its buttons do.
              child: Row(
                children: [
                  Icon(Icons.auto_awesome_rounded,
                      color: Neon.onAccent, size: 22),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'This is how your colour looks on buttons and the mic.',
                      style: TextStyle(
                          color: Neon.onAccent,
                          fontSize: 14,
                          height: 1.4,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Tappable (2026-09-30): the same dip and tick, and a screen reader now
  // hears the colour's name, that it is a button and which one is chosen.
  Widget _swatch(String name, Color c, bool selected) => Semantics(
        selected: selected,
        child: Tappable(
          tapHint: 'choose',
          onTap: () => AccentController.set(c),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: Neon.tile(c),
                  // The chosen one lit in its own colour (Neon.halo).
                  boxShadow: selected ? Neon.halo(c) : null,
                  border: Border.all(
                    color: selected ? Neon.textHi : Neon.line,
                    width: selected ? 3 : 1,
                  ),
                ),
                child: selected
                    ? Icon(Icons.check_rounded, size: 26, color: Neon.onTile(c))
                    : null,
              ),
              const SizedBox(height: 6),
              SizedBox(
                width: 62,
                child: Text(name,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: selected ? Neon.textHi : Neon.textLo,
                        fontSize: NeonType.caption,
                        fontWeight:
                            selected ? FontWeight.w700 : FontWeight.w500)),
              ),
            ],
          ),
        ),
      );
}
