import 'dart:math' as math;

import 'package:flutter/painting.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  POSTER STUDIO COLOURS (2026-09-30). The studio's token file: an event
///  poster is artwork that leaves the app as a picture, so its inks are
///  its own (a white page for "Corporate Clean", gold for "Festive") and
///  do not follow the app's night palette. Every raw colour the studio
///  draws with lives here; the rest of the studio names these.
/// ─────────────────────────────────────────────────────────────────────────
abstract final class StudioInk {
  static const night = Color(0xFF05060F);
  static const nightHigh = Color(0xFF0B1030);
  static const nightPanel = Color(0xFF070A1C);
  static const white = Color(0xFFF6F8FF);
  static const paper = Color(0xFFF7F9FC);
  static const paperLine = Color(0xFFDCE3EE);
  static const navy = Color(0xFF0B1B3F);
  static const navyHigh = Color(0xFF16306B);
  static const slate = Color(0xFF3A4760);
  static const maroon = Color(0xFF2A0A12);
  static const cocoa = Color(0xFF3B1A0E);
  static const cream = Color(0xFFFFF4DC);
  static const gold = Color(0xFFF2C45A);
  static const goldLight = Color(0xFFFFE7A3);
  static const goldDeep = Color(0xFFB9791A);
  static const minimal = Color(0xFF0B0C14);

  /// The dark ink for words on a light fill.
  static const dark = Color(0xFF0A0D1F);
  static const black = Color(0xFF000000);
  static const clear = Color(0x00000000);
}

/// One colour set a poster is drawn in: [primary] leads (rims, the accent
/// bar), [secondary] partners it, [accent] is the call to action, [ink]
/// the words on the poster's own ground.
class StudioPalette {
  const StudioPalette({
    required this.id,
    required this.name,
    required this.primary,
    required this.secondary,
    required this.accent,
    required this.ink,
    this.brand = false,
  });

  final String id;
  final String name;
  final Color primary;
  final Color secondary;
  final Color accent;
  final Color ink;

  /// From his own brand colour (or the brand the request named).
  final bool brand;

  /// The colours the server's design proposed (`design.palette`).
  static StudioPalette? fromJson(Object? j, {String id = 'design', String name = 'Suggested'}) {
    if (j is! Map) return null;
    final p = parseHex(j['primary']);
    if (p == null) return null;
    final s = parseHex(j['secondary']) ?? _turn(p, 40);
    final a = parseHex(j['accent']) ?? _turn(p, 180);
    final ink = parseHex(j['ink']) ?? studioInkOn(p);
    return StudioPalette(id: id, name: name, primary: p, secondary: s, accent: a, ink: ink);
  }

  Map<String, String> toJson() => {
        'primary': toHex(primary),
        'secondary': toHex(secondary),
        'accent': toHex(accent),
        'ink': toHex(ink),
      };

  /// A whole set from one brand colour: a neighbouring hue partners it and
  /// the opposite hue carries the call to action.
  factory StudioPalette.fromBrand(Color c, {String? name}) => StudioPalette(
        id: 'brand-${toHex(c)}',
        name: name ?? 'Your brand',
        primary: c,
        secondary: _turn(c, 38),
        accent: _turn(c, 180, saturation: 0.85, lightness: 0.6),
        ink: studioInkOn(c),
        brand: true,
      );

  @override
  bool operator ==(Object other) =>
      other is StudioPalette &&
      other.id == id &&
      other.primary == primary &&
      other.secondary == secondary &&
      other.accent == accent &&
      other.ink == ink;

  @override
  int get hashCode => Object.hash(id, primary, secondary, accent, ink);
}

/// The ready-made sets on the Colours sheet. 'neon' is the app's own
/// light: cyan, magenta and electric blue.
const studioPalettes = <StudioPalette>[
  StudioPalette(
      id: 'neon',
      name: 'Neon',
      primary: Color(0xFF22E4FF),
      secondary: Color(0xFFE040FB),
      accent: Color(0xFF4D8BFF),
      ink: StudioInk.white),
  StudioPalette(
      id: 'electric',
      name: 'Electric',
      primary: Color(0xFF4D8BFF),
      secondary: Color(0xFF8B5CFF),
      accent: Color(0xFF22E4FF),
      ink: StudioInk.white),
  StudioPalette(
      id: 'aurora',
      name: 'Aurora',
      primary: Color(0xFF2BF5A0),
      secondary: Color(0xFF22E4FF),
      accent: Color(0xFFC6FF3D),
      ink: StudioInk.white),
  StudioPalette(
      id: 'sunset',
      name: 'Sunset',
      primary: Color(0xFFFF7A45),
      secondary: Color(0xFFE040FB),
      accent: Color(0xFFFFB020),
      ink: StudioInk.white),
  StudioPalette(
      id: 'gold',
      name: 'Gold',
      primary: StudioInk.gold,
      secondary: Color(0xFFFF7A45),
      accent: StudioInk.goldLight,
      ink: StudioInk.cream),
  StudioPalette(
      id: 'royal',
      name: 'Royal',
      primary: Color(0xFF2F6BFF),
      secondary: StudioInk.navy,
      accent: Color(0xFFFF5A6E),
      ink: StudioInk.white),
  StudioPalette(
      id: 'rose',
      name: 'Rose',
      primary: Color(0xFFFF5A9E),
      secondary: Color(0xFF8B5CFF),
      accent: Color(0xFFFFD1E6),
      ink: StudioInk.white),
  StudioPalette(
      id: 'mono',
      name: 'Mono',
      primary: Color(0xFFFFFFFF),
      secondary: Color(0xFF9AA3B5),
      accent: Color(0xFF22E4FF),
      ink: StudioInk.white),
];

StudioPalette studioPalette(String id) =>
    studioPalettes.firstWhere((p) => p.id == id, orElse: () => studioPalettes.first);

/// '#22E4FF' / '22e4ff' / '#2EF' → the colour; null for anything else.
Color? parseHex(Object? v) {
  if (v is! String) return null;
  var s = v.trim().replaceFirst('#', '');
  if (s.length == 3) s = s.split('').map((c) => '$c$c').join();
  if (s.length != 6 || !RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(s)) return null;
  return Color(0xFF000000 | int.parse(s, radix: 16));
}

String toHex(Color c) {
  int ch(double v) => (v * 255).round().clamp(0, 255);
  return '#${[ch(c.r), ch(c.g), ch(c.b)].map((v) => v.toRadixString(16).padLeft(2, '0')).join().toUpperCase()}';
}

/// WCAG contrast between two opaque colours (1–21).
double contrastRatio(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  final hi = math.max(la, lb), lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

/// White or near-black words on [fill]: whichever reads better.
Color studioInkOn(Color fill) =>
    contrastRatio(StudioInk.white, fill) >= contrastRatio(StudioInk.dark, fill)
        ? StudioInk.white
        : StudioInk.dark;

/// [c], lightened or darkened (its hue kept) until it reaches [ratio]
/// against [ground] — a pale brand colour still reads on white paper.
Color ensureContrast(Color c, Color ground, double ratio) {
  if (contrastRatio(c, ground) >= ratio) return c;
  final darker = ground.computeLuminance() > 0.35;
  final hsl = HSLColor.fromColor(c);
  var l = hsl.lightness;
  for (var i = 0; i < 40; i++) {
    l = darker ? l - 0.025 : l + 0.025;
    if (l <= 0 || l >= 1) break;
    final next = hsl.withLightness(l).toColor();
    if (contrastRatio(next, ground) >= ratio) return next;
  }
  return darker ? StudioInk.dark : StudioInk.white;
}

/// [c] at another lightness (hue and saturation kept).
Color studioShade(Color c, double lightness) =>
    HSLColor.fromColor(c).withLightness(lightness.clamp(0.0, 1.0)).toColor();

Color _turn(Color c, double degrees, {double? saturation, double? lightness}) {
  final h = HSLColor.fromColor(c);
  return h
      .withHue((h.hue + degrees) % 360)
      .withSaturation(saturation ?? math.max(h.saturation, 0.55))
      .withLightness(lightness ?? h.lightness.clamp(0.42, 0.66))
      .toColor();
}
