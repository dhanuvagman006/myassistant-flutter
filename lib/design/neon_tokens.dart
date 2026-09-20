import 'package:flutter/material.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  MYASSISTANT · Design System V3.0 — "Daylight"
///  Light, professional re-skin (Sept 2026). Same token API as Neon V2 so
///  every screen re-skins without touching call sites.
///  Single source of truth for color, gradient, spacing, radius and glow.
///  Nothing outside lib/design + lib/theme should hardcode a hex value.
/// ─────────────────────────────────────────────────────────────────────────
class Neon {
  Neon._();

  /// THEME SWITCH. The token API stays the same everywhere; flipping this
  /// swaps every value below. Set ONLY through ThemeController, which
  /// persists the choice and rebuilds the app.
  static bool isDark = false;

  static void setDark(bool v) => isDark = v;

  // Core palette — deep, confident accents on white; PURE BLACK in the
  // dark (owner's call, 2026-09-18: "don't use grey"): true-black ground,
  // near-black surfaces with no blue-gray wash, and brighter accents so
  // the contrast carries the theme.
  // Purple brightened twice on 2026-09-19 (owner: "bit bright purple
  // colors", then "good but make it brighter") — a vivid, saturated
  // purple that stays classy on pure black; white button text still
  // passes on the light value.
  /// THE USER'S ACCENT, when they have chosen one (Settings → Theme).
  /// Null means the app's own violet. Set only through AccentController,
  /// which persists it and rebuilds the tree.
  static Color? _accent;
  static Color? _accentPartner;
  static Color? _accentInk;

  static void setAccent(Color? c) {
    _accent = c;
    if (c == null) {
      _accentPartner = null;
      _accentInk = null;
      return;
    }
    // Derived here rather than at every call site: these run inside
    // build() thousands of times a second on a scrolling list.
    final h = HSLColor.fromColor(c);
    // 22 DEGREES, NOT 42. A wide rotation turned warm accents into a
    // clashing second hue — amber paired with lime, which looked like a
    // mistake rather than a theme. A short analogous step keeps every
    // gradient in the same family whatever colour is chosen.
    _accentPartner = h
        .withHue((h.hue + 22) % 360)
        .withSaturation((h.saturation * 1.02).clamp(0.35, 1.0))
        .withLightness((h.lightness + 0.04).clamp(0.35, 0.80))
        .toColor();
    _accentInk = h
        .withSaturation((h.saturation * 1.05).clamp(0.45, 1.0))
        .withLightness((h.lightness * 0.52).clamp(0.24, 0.48))
        .toColor();
  }

  static Color get violet => _accent != null
      ? (isDark ? _accent! : _accentInk!)
      : (isDark ? const Color(0xFFC77DFF) : const Color(0xFFA855F7));
  // Whole accent set brightened with it ("entire app all colors") —
  // higher luminance, saturation kept, so black stays black and the
  // accents carry the energy.
  static Color get cyan =>
      isDark ? const Color(0xFF3FE3FD) : const Color(0xFF0891B2);
  /// The gradient partner — derived from the accent so every gradient in
  /// the app (orb, mic, tiles, quote card) stays in tune with one choice.
  static Color get pink => _accentPartner != null
      ? (isDark
          ? _accentPartner!
          : HSLColor.fromColor(_accentPartner!)
              .withLightness(
                  (HSLColor.fromColor(_accentPartner!).lightness * 0.55)
                      .clamp(0.26, 0.50))
              .toColor())
      : (isDark ? const Color(0xFFFF8AC8) : const Color(0xFFDB2777));
  static Color get lime =>
      isDark ? const Color(0xFFBDF64B) : const Color(0xFF65A30D);
  /// The page ground. In the dark it is a near-black carrying a trace of
  /// the theme colour rather than #000000 — flat black made every screen
  /// read as empty (2026-09-19). AmbientBackground lays the soft pools of
  /// light on top of this.
  static Color get bg {
    if (!isDark) return const Color(0xFFF7F7FB);
    final h = HSLColor.fromColor(violet);
    return h.withSaturation(0.42).withLightness(0.035).toColor();
  }
  // SURFACES CARRY THE BRAND, not a grey wash. The ground stays pure
  // black; the cards sitting on it are a violet-cast near-black, which
  // is what stops a dark theme reading as "charcoal sheets on nothing"
  // (2026-09-19 — "the colour combination is worst, it looks boring").
  static Color get surface => isDark
      ? HSLColor.fromColor(violet)
          .withSaturation(0.30)
          .withLightness(0.085)
          .toColor()
      : const Color(0xFFFFFFFF);
  static Color get surfaceHigh =>
      isDark ? const Color(0xFF1E1730) : const Color(0xFFEEEFF6);
  static Color get success =>
      isDark ? const Color(0xFF62F49B) : const Color(0xFF16A34A);
  static Color get warning =>
      isDark ? const Color(0xFFFFD03E) : const Color(0xFFD97706);
  static Color get error =>
      isDark ? const Color(0xFFFF8585) : const Color(0xFFEF4444);

  // Text — ink on paper; on pure black, brighter steps so secondary text
  // still reads instead of sinking into gray mud.
  static Color get textHi =>
      isDark ? const Color(0xFFFFFFFF) : const Color(0xFF1B1D28);
  static Color get textLo =>
      isDark ? const Color(0xFFD8D2EA) : const Color(0xFF585E70);
  static Color get textDim =>
      isDark ? const Color(0xFF9E96B8) : const Color(0xFF9BA0B0);

  /// The GROUND color for things painted in [textHi] — icon-on-ink tiles,
  /// text on the primary button. Tracks the theme so "white on ink" in
  /// light mode becomes "ink on chalk" in dark mode automatically.
  static Color get onInk => bg;

  // Hairlines on cards — a touch brighter on pure black, or cards lose
  // their edges entirely.
  static Color get line => isDark
      ? const Color(0xFFFFFFFF).withValues(alpha: 0.16)
      : const Color(0xFF141627).withValues(alpha: 0.08);
  static Color get lineBright => isDark
      ? const Color(0xFFFFFFFF).withValues(alpha: 0.20)
      : const Color(0xFF141627).withValues(alpha: 0.14);

  // Gradients
  static LinearGradient get gVioletCyan => LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [violet, cyan]);
  static LinearGradient get gPinkViolet => LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [pink, violet]);
  static LinearGradient get gCyanLime => LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [cyan, lime]);
  static LinearGradient get gVioletPink => LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [violet, pink]);

  /// THE BRAND GRADIENT — violet into magenta. Used for the mic, the
  /// active tab and anything that should feel like the app itself.
  static LinearGradient get gBrand => LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [violet, pink]);

  /// A tile gradient built from ONE accent: the colour, lifted. Every
  /// coloured icon tile in the app uses this, so a row of them reads as
  /// one family instead of a bag of unrelated app-store colours.
  static LinearGradient tile(Color c) {
    // Darken by pulling the COLOUR's own lightness down rather than
    // mixing toward a fixed violet-black: with a user-chosen accent a
    // hardcoded shadow hue turned every tile muddy.
    final h = HSLColor.fromColor(c);
    final deep = h
        .withLightness((h.lightness * 0.62).clamp(0.18, 0.55))
        .withSaturation((h.saturation * 1.05).clamp(0.3, 1.0))
        .toColor();
    return LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [Color.lerp(c, Colors.white, 0.16)!, deep],
    );
  }

  /// THE ACCENT FAMILY. Picking tile colours from this list (instead of
  /// inventing a hex per screen) is what keeps the app coherent: every
  /// one of them is a sibling of the brand violet.
  static Color get accentA => violet; // primary
  static Color get accentB => pink; // people / promises
  static Color get accentC => cyan; // documents / data
  static Color get accentD =>
      isDark ? const Color(0xFFFFB347) : const Color(0xFFD97706); // money
  static Color get accentE =>
      isDark ? const Color(0xFF7DF9C4) : const Color(0xFF0F9D58); // calls
  static Color get accentF =>
      isDark ? const Color(0xFF8BA9FF) : const Color(0xFF3B5BDB); // system

  /// Tri-color sweep used by the assistant orb — the app's signature.
  static SweepGradient get gOrb => SweepGradient(
        colors: [violet, cyan, pink, violet],
        stops: const [0.0, 0.4, 0.75, 1.0],
      );

  // Spacing scale
  static const s1 = 4.0, s2 = 8.0, s3 = 12.0, s4 = 16.0;
  static const s5 = 20.0, s6 = 24.0, s7 = 32.0, s8 = 40.0;

  // Radius scale
  static const rSm = 12.0, rMd = 16.0, rLg = 20.0, rXl = 28.0, rPill = 100.0;

  // Motion
  static const fast = Duration(milliseconds: 180);
  static const med = Duration(milliseconds: 300);
  static const slow = Duration(milliseconds: 600);

  /// Soft tinted elevation behind buttons / orbs / FABs — on the light
  /// system a "glow" is a colored drop shadow, quiet and grounded.
  static List<BoxShadow> glow(Color c,
          {double blur = 24, double spread = 0, double alpha = 0.22}) =>
      [
        BoxShadow(
            color: c.withValues(alpha: alpha),
            blurRadius: blur,
            spreadRadius: spread,
            offset: const Offset(0, 6)),
      ];

  /// Neutral card shadow — barely-there depth for light surfaces, a real
  /// black lift in the dark.
  static List<BoxShadow> get cardShadow => [
        BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.40 : 0.06),
            blurRadius: 18,
            offset: const Offset(0, 6)),
      ];

  /// Two-tone glow for gradient elements.
  static List<BoxShadow> glow2(Color a, Color b, {double blur = 26}) => [
        BoxShadow(
            color: a.withValues(alpha: 0.18),
            blurRadius: blur,
            offset: const Offset(-2, 6)),
        BoxShadow(
            color: b.withValues(alpha: 0.18),
            blurRadius: blur,
            offset: const Offset(2, 6)),
      ];
}
