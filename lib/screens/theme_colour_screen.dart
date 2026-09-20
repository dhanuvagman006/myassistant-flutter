import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design/accent_controller.dart';
import '../design/motion.dart';
import '../design/neon_tokens.dart';

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
      builder: (_, seed, __) => Scaffold(
        backgroundColor: Neon.bg,
        appBar:
            AppBar(backgroundColor: Neon.bg, title: const Text('Theme colour')),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
          children: [
            Text(
              'Your colour paints the orb, the mic, every icon tile and '
              'each highlight in the app. Tap one to see it straight away.',
              style: TextStyle(color: Neon.textLo, fontSize: 13.5, height: 1.5),
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
              child: const Row(
                children: [
                  Icon(Icons.auto_awesome_rounded,
                      color: Colors.white, size: 22),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'This is how your colour looks on buttons and the mic.',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 13.5,
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

  Widget _swatch(String name, Color c, bool selected) => PressScale(
        child: GestureDetector(
          onTap: () {
            HapticFeedback.selectionClick();
            AccentController.set(c);
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: Neon.tile(c),
                  boxShadow: selected
                      ? [
                          BoxShadow(
                              color: c.withValues(alpha: 0.55),
                              blurRadius: 18,
                              spreadRadius: 1)
                        ]
                      : null,
                  border: Border.all(
                    color: selected ? Neon.textHi : Neon.line,
                    width: selected ? 3 : 1,
                  ),
                ),
                child: selected
                    ? const Icon(Icons.check_rounded,
                        size: 26, color: Colors.white)
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
                        color: selected ? Neon.textHi : Neon.textDim,
                        fontSize: 11.5,
                        fontWeight:
                            selected ? FontWeight.w700 : FontWeight.w500)),
              ),
            ],
          ),
        ),
      );
}
