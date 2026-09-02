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

  // Core palette — deep, confident accents on white; brighter siblings on
  // ink so contrast holds in the dark.
  static Color get violet =>
      isDark ? const Color(0xFF9B85F5) : const Color(0xFF6D28D9);
  static Color get cyan =>
      isDark ? const Color(0xFF4CC9E8) : const Color(0xFF0E7490);
  static Color get pink =>
      isDark ? const Color(0xFFF472B6) : const Color(0xFFBE185D);
  static Color get lime =>
      isDark ? const Color(0xFFA3D65C) : const Color(0xFF4D7C0F);
  static Color get bg =>
      isDark ? const Color(0xFF0F1118) : const Color(0xFFF7F7FB);
  static Color get surface =>
      isDark ? const Color(0xFF181B25) : const Color(0xFFFFFFFF);
  static Color get surfaceHigh =>
      isDark ? const Color(0xFF232734) : const Color(0xFFEEEFF6);
  static Color get success =>
      isDark ? const Color(0xFF4ADE80) : const Color(0xFF15803D);
  static Color get warning =>
      isDark ? const Color(0xFFFBBF24) : const Color(0xFFB45309);
  static Color get error =>
      isDark ? const Color(0xFFF87171) : const Color(0xFFDC2626);

  // Text — ink on paper, chalk on ink.
  static Color get textHi =>
      isDark ? const Color(0xFFF2F3F8) : const Color(0xFF1B1D28);
  static Color get textLo =>
      isDark ? const Color(0xFFA9AEC0) : const Color(0xFF585E70);
  static Color get textDim =>
      isDark ? const Color(0xFF6B7080) : const Color(0xFF9BA0B0);

  /// The GROUND color for things painted in [textHi] — icon-on-ink tiles,
  /// text on the primary button. Tracks the theme so "white on ink" in
  /// light mode becomes "ink on chalk" in dark mode automatically.
  static Color get onInk => bg;

  // Hairlines on cards
  static Color get line => isDark
      ? const Color(0xFFEAEBF5).withValues(alpha: 0.10)
      : const Color(0xFF141627).withValues(alpha: 0.08);
  static Color get lineBright => isDark
      ? const Color(0xFFEAEBF5).withValues(alpha: 0.16)
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
