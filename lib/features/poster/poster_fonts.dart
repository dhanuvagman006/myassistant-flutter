import 'dart:async';

import 'package:flutter/services.dart';

import '../../core/log.dart';

/// THE CARD'S FONTS SHIP INSIDE THE APP.
///
/// A card is shared as a picture, so the words must be drawn by a font we
/// know, the same on every phone: Noto Serif Display for the English
/// wording, Noto Serif Malayalam and Devanagari for his own language
/// ("ജന്മദിനാശംസകൾ" must not depend on what the phone happens to have).
/// Kannada, Tamil and Telugu fall back to the phone's own Noto fonts.
///
/// Every face is registered as its OWN family, so no style is ever faked:
/// asking for italic Malayalam would otherwise slant an upright font.
/// All OFL (assets/poster_fonts/OFL-Noto.txt); Manrope is already bundled
/// for the app itself and is reused for the playful balloon lettering.
abstract final class PosterFonts {
  static const display = 'PosterDisplay';
  static const displayItalic = 'PosterDisplayItalic';
  static const displayBold = 'PosterDisplayBold';
  static const malayalam = 'PosterMalayalam';
  static const malayalamBold = 'PosterMalayalamBold';
  static const devanagari = 'PosterDevanagari';
  static const devanagariBold = 'PosterDevanagariBold';
  static const round = 'PosterRound';

  static const files = <String, String>{
    display: 'assets/poster_fonts/NotoSerifDisplay-Regular.ttf',
    displayItalic: 'assets/poster_fonts/NotoSerifDisplay-Italic.ttf',
    displayBold: 'assets/poster_fonts/NotoSerifDisplay-Bold.ttf',
    malayalam: 'assets/poster_fonts/NotoSerifMalayalam-Regular.ttf',
    malayalamBold: 'assets/poster_fonts/NotoSerifMalayalam-Bold.ttf',
    devanagari: 'assets/poster_fonts/NotoSerifDevanagari-Regular.ttf',
    devanagariBold: 'assets/poster_fonts/NotoSerifDevanagari-Bold.ttf',
    round: 'assets/google_fonts/Manrope-ExtraBold.ttf',
  };

  static const licence = 'assets/poster_fonts/OFL-Noto.txt';

  /// Indic faces tried, in order, for any letter the Latin face lacks.
  static const fallbackRegular = [malayalam, devanagari];
  static const fallbackBold = [malayalamBold, devanagariBold];

  static Future<void>? _loading;
  static bool _loaded = false;
  static bool get loaded => _loaded;

  /// Loads every face once. Safe to call before every render.
  static Future<void> ensureLoaded([AssetBundle? bundle]) =>
      _loading ??= _load(bundle ?? rootBundle);

  static Future<void> _load(AssetBundle bundle) async {
    try {
      await Future.wait([
        for (final e in files.entries)
          (FontLoader(e.key)..addFont(bundle.load(e.value))).load(),
      ]);
      _loaded = true;
    } catch (e) {
      // A missing face must not stop the card: the phone's fonts stand in.
      AppLog.add('poster', 'fonts failed to load: $e');
      _loading = null;
    }
  }

  /// Letters no bundled face (nor the phone's Indic Noto fonts) draws —
  /// shown as a gentle warning in the editor instead of a blank box on the
  /// shared card. Emoji are fine: the phone draws them.
  static String uncovered(String text) {
    final out = StringBuffer();
    for (final r in text.runes) {
      if (_covered(r)) continue;
      final ch = String.fromCharCode(r);
      if (!out.toString().contains(ch)) out.write(ch);
    }
    return out.toString();
  }

  static bool _covered(int r) =>
      r < 0x250 || // Latin, Latin-1, Latin Extended-A/B
      (r >= 0x2000 && r <= 0x206F) || // punctuation
      r == 0x20B9 || // ₹
      (r >= 0x0900 && r <= 0x097F) || // Devanagari
      (r >= 0x0B80 && r <= 0x0BFF) || // Tamil
      (r >= 0x0C00 && r <= 0x0C7F) || // Telugu
      (r >= 0x0C80 && r <= 0x0CFF) || // Kannada
      (r >= 0x0D00 && r <= 0x0D7F) || // Malayalam
      (r >= 0x1E00 && r <= 0x1EFF) || // Latin Extended Additional
      (r >= 0x1F000 && r <= 0x1FAFF) || // emoji
      (r >= 0x2600 && r <= 0x27BF) || // symbols, dingbats (hearts)
      r == 0xFE0F ||
      r == 0x200D;
}
