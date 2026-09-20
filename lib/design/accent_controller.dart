import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'neon_tokens.dart';

/// ACCENT COLOUR — the one choice that repaints the app.
///
/// Everything visibly coloured reads from [Neon.violet] (primary) and
/// [Neon.pink] (its partner in every gradient: the orb, the mic, tiles,
/// the dock). So a single seed colour, with its partner derived from it,
/// is enough to re-theme the whole product — no per-screen settings and
/// nothing to keep in sync.
///
/// The partner is the seed rotated around the colour wheel rather than a
/// second thing to pick: two hand-picked colours go wrong far more often
/// than one, and a fixed rotation keeps every gradient in tune.
class AccentController {
  AccentController._();

  static const _key = 'accent_seed_v1';

  /// The app's own violet — what everyone gets until they choose.
  static const defaultSeed = Color(0xFFC77DFF);

  /// Bumps whenever the accent changes; the app root rebuilds on it.
  static final ValueNotifier<Color> seed = ValueNotifier(defaultSeed);

  /// Named choices for the settings row. Deliberately short: a dozen
  /// swatches is a decision, thirty is a chore.
  static const swatches = <(String, Color)>[
    ('Violet', Color(0xFFC77DFF)),
    ('Indigo', Color(0xFF8B9CFF)),
    ('Ocean', Color(0xFF4FC3F7)),
    ('Teal', Color(0xFF3FE0C8)),
    ('Mint', Color(0xFF6EE7A8)),
    ('Lime', Color(0xFFBDF64B)),
    ('Amber', Color(0xFFFFC24B)),
    ('Coral', Color(0xFFFF8A65)),
    ('Rose', Color(0xFFFF7BA3)),
    ('Magenta', Color(0xFFFF6FD8)),
    ('Crimson', Color(0xFFFF6B6B)),
    ('Slate', Color(0xFF9FB3C8)),
  ];

  static Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final v = prefs.getInt(_key);
      if (v != null) seed.value = Color(v);
    } catch (_) {}
    _apply();
  }

  static Future<void> set(Color c) async {
    seed.value = c;
    _apply();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_key, c.toARGB32());
    } catch (_) {}
  }

  static void _apply() => Neon.setAccent(seed.value);

  /// The gradient partner: the seed, moved a third of the way round the
  /// wheel and lifted slightly, so light and dark both stay readable.
  static Color partnerOf(Color c) {
    final h = HSLColor.fromColor(c);
    return h
        .withHue((h.hue + 22) % 360)
        .withSaturation((h.saturation * 1.02).clamp(0.35, 1.0))
        .withLightness((h.lightness + 0.04).clamp(0.35, 0.80))
        .toColor();
  }

  /// The darker, denser version a light background needs.
  static Color inkOf(Color c) {
    final h = HSLColor.fromColor(c);
    return h
        .withSaturation((h.saturation * 1.05).clamp(0.45, 1.0))
        .withLightness((h.lightness * 0.52).clamp(0.24, 0.48))
        .toColor();
  }
}
