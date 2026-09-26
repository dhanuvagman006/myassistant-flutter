import 'package:flutter/material.dart';

/// A WHOLE COLOUR SCHEME, NOT JUST AN ACCENT (2026-09-26).
///
/// The client was offered twelve accent hues and liked none of them. An
/// accent laid on the same ground, the same cards and the same text cannot
/// change how the app FEELS; a palette sets all of them together — the
/// page, the cards, the words and the accents that play off each other.
///
/// [Neon.usePalette] applies one. With none set, every token is exactly
/// what it was, so nothing changes until a palette is chosen.
@immutable
class NeonPalette {
  const NeonPalette({
    required this.name,
    required this.dark,
    required this.bg,
    required this.surface,
    required this.surfaceHigh,
    required this.primary,
    required this.partner,
    required this.secondary,
    required this.tertiary,
    required this.textHi,
    required this.textLo,
    required this.textDim,
    this.success,
    this.warning,
    this.error,
  });

  final String name;

  /// A dark palette (light words on a dark page) or a light one.
  final bool dark;

  /// The page, the cards, and raised things on the cards (chips, fields).
  final Color bg, surface, surfaceHigh;

  /// The brand colour and its gradient partner: the orb, the mic, the
  /// active tab, the name in the greeting, buttons.
  final Color primary, partner;

  /// The supporting accents: information (messages, weather) and a third
  /// for variety in icon tiles.
  final Color secondary, tertiary;

  /// Words: headings and body, secondary lines, hints and timestamps.
  final Color textHi, textLo, textDim;

  /// Status colours, when the palette wants its own; otherwise the app's.
  final Color? success, warning, error;
}
