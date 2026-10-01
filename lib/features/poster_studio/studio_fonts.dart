import 'dart:async';

import 'package:flutter/services.dart';

import '../../core/log.dart';
import '../poster/poster_fonts.dart';

/// THE POSTER'S FONTS SHIP INSIDE THE APP (2026-09-30), like the photo
/// cards': a poster leaves as a picture, so the words are drawn by faces
/// we know on every phone. Space Grotesk and Manrope are already bundled
/// for the app itself (assets/google_fonts, OFL); each weight is
/// registered here as its OWN family so a weight is never faked. The serif
/// faces and the Malayalam / Devanagari fallbacks are the photo cards'
/// ([PosterFonts]).
abstract final class StudioFonts {
  static const grotesk = 'StudioGroteskBold';
  static const groteskMedium = 'StudioGroteskMedium';
  static const heavy = 'StudioSansExtraBold';
  static const bold = 'StudioSansBold';
  static const semi = 'StudioSansSemiBold';
  static const medium = 'StudioSansMedium';
  static const serif = PosterFonts.displayBold;
  static const serifItalic = PosterFonts.displayItalic;
  static const serifRegular = PosterFonts.display;

  static const files = <String, String>{
    grotesk: 'assets/google_fonts/SpaceGrotesk-Bold.ttf',
    groteskMedium: 'assets/google_fonts/SpaceGrotesk-Medium.ttf',
    heavy: 'assets/google_fonts/Manrope-ExtraBold.ttf',
    bold: 'assets/google_fonts/Manrope-Bold.ttf',
    semi: 'assets/google_fonts/Manrope-SemiBold.ttf',
    medium: 'assets/google_fonts/Manrope-Medium.ttf',
  };

  /// Malayalam and Devanagari for letters the Latin faces lack.
  static List<String> fallback(bool strong) =>
      strong ? PosterFonts.fallbackBold : PosterFonts.fallbackRegular;

  static Future<void>? _loading;

  /// Loads every face once (and the photo cards' serif faces). Safe to
  /// call before every render; a face that fails leaves the phone's own.
  static Future<void> ensureLoaded([AssetBundle? bundle]) =>
      _loading ??= _load(bundle ?? rootBundle);

  static Future<void> _load(AssetBundle bundle) async {
    try {
      await Future.wait([
        PosterFonts.ensureLoaded(bundle),
        for (final e in files.entries)
          (FontLoader(e.key)..addFont(bundle.load(e.value))).load(),
      ]);
    } catch (e) {
      AppLog.add('poster', 'studio fonts failed to load: $e');
      _loading = null;
    }
  }
}
