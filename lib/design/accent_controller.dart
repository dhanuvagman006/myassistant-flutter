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

  /// What everyone gets until they choose: Indigo. Owner, 2026-09-25:
  /// "set indigo as default theme" (it was the app's own violet) — now
  /// the fluorescent Indigo below. Anyone who already picked a colour
  /// keeps it (or its fluorescent twin, see [load]).
  static const defaultSeed = Color(0xFF6E73FF);

  /// Bumps whenever the accent changes; the app root rebuilds on it.
  static final ValueNotifier<Color> seed = ValueNotifier(defaultSeed);

  /// Named choices for the settings row. Deliberately short: a dozen
  /// swatches is a decision, thirty is a chore.
  ///
  /// FLUORESCENT, NOT PASTEL. The client, 2026-09-25, on a screenshot of
  /// this row: "These colors are not good; use some nice fluorescent
  /// colors." Twelve highlighter-bright hues round the wheel, each lit
  /// enough to read as text on the dark theme; the light theme draws text
  /// in each one's darker ink (Neon.violet), and bright ones get dark
  /// glyphs on top (Neon.onAccent) — test/contrast_test.dart checks every
  /// swatch in both themes.
  static const swatches = <(String, Color)>[
    ('Indigo', Color(0xFF6E73FF)),
    ('Violet', Color(0xFFB14DFF)),
    ('Magenta', Color(0xFFFF2BD6)),
    ('Pink', Color(0xFFFF3D8B)),
    ('Red', Color(0xFFFF3B3B)),
    ('Orange', Color(0xFFFF7A1A)),
    ('Lemon', Color(0xFFFFE81A)),
    ('Lime', Color(0xFFC6FF1A)),
    ('Green', Color(0xFF39FF14)),
    ('Mint', Color(0xFF1AFFB2)),
    ('Aqua', Color(0xFF1AF0FF)),
    ('Blue', Color(0xFF1A8CFF)),
  ];

  /// The pastel row this replaced, and the fluorescent colour each owner
  /// choice moves to — so a saved "Coral" becomes Orange, not a colour
  /// the picker can no longer show as selected.
  static const _pastelToFluorescent = <int, int>{
    0xFFC77DFF: 0xFFB14DFF, // Violet  → Violet
    0xFF8B9CFF: 0xFF6E73FF, // Indigo  → Indigo
    0xFF4FC3F7: 0xFF1A8CFF, // Ocean   → Blue
    0xFF3FE0C8: 0xFF1AF0FF, // Teal    → Aqua
    0xFF6EE7A8: 0xFF1AFFB2, // Mint    → Mint
    0xFFBDF64B: 0xFFC6FF1A, // Lime    → Lime
    0xFFFFC24B: 0xFFFFE81A, // Amber   → Lemon
    0xFFFF8A65: 0xFFFF7A1A, // Coral   → Orange
    0xFFFF7BA3: 0xFFFF3D8B, // Rose    → Pink
    0xFFFF6FD8: 0xFFFF2BD6, // Magenta → Magenta
    0xFFFF6B6B: 0xFFFF3B3B, // Crimson → Red
    0xFF9FB3C8: 0xFF1A8CFF, // Slate   → Blue
  };

  /// A saved colour from the old pastel row, as its fluorescent twin;
  /// anything else as it was.
  static Color migrate(Color c) {
    final to = _pastelToFluorescent[c.toARGB32()];
    return to == null ? c : Color(to);
  }

  static Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final v = prefs.getInt(_key);
      if (v != null) {
        final c = migrate(Color(v));
        seed.value = c;
        // Stored once, so the picker shows the new swatch as chosen.
        if (c.toARGB32() != v) await prefs.setInt(_key, c.toARGB32());
      }
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
