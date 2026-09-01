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

  // Core palette — deep, confident accents that hold contrast on white.
  static const violet = Color(0xFF6D28D9); // primary
  static const cyan = Color(0xFF0E7490); // secondary (deep teal)
  static const pink = Color(0xFFBE185D); // accent
  static const lime = Color(0xFF4D7C0F); // highlight (olive)
  static const bg = Color(0xFFF7F7FB); // app background: violet-tinted paper
  static const surface = Color(0xFFFFFFFF); // cards, sheets
  static const surfaceHigh = Color(0xFFEEEFF6); // raised wells, inputs
  static const success = Color(0xFF15803D);
  static const warning = Color(0xFFB45309);
  static const error = Color(0xFFDC2626);

  // Text — near-black ink with a violet undertone, not pure grey.
  static const textHi = Color(0xFF1B1D28); // headings, primary text
  static const textLo = Color(0xFF585E70); // secondary text
  static const textDim = Color(0xFF9BA0B0); // hints, disabled

  // Hairlines on cards
  static Color get line => const Color(0xFF141627).withValues(alpha: 0.08);
  static Color get lineBright =>
      const Color(0xFF141627).withValues(alpha: 0.14);

  // Gradients
  static const gVioletCyan = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [violet, cyan]);
  static const gPinkViolet = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [pink, violet]);
  static const gCyanLime = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [cyan, lime]);
  static const gVioletPink = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [violet, pink]);

  /// Tri-color sweep used by the assistant orb — the app's signature.
  static const gOrb = SweepGradient(
    colors: [violet, cyan, pink, violet],
    stops: [0.0, 0.4, 0.75, 1.0],
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

  /// Neutral card shadow — barely-there depth for white surfaces.
  static List<BoxShadow> get cardShadow => [
        BoxShadow(
            color: const Color(0xFF141627).withValues(alpha: 0.06),
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
