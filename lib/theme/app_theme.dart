import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../design/neon_tokens.dart';

/// Legacy color names, remapped onto the Neon V2 palette.
///
/// Twenty files still reference these identifiers; keeping the names (with
/// new values) re-skins every screen in one move. New code should import
/// `design/neon_tokens.dart` and use [Neon] directly — treat these as
/// deprecated aliases to be burned down screen by screen.
class AppColors {
  static const peacock = Neon.violet; // primary actions
  static const peacockDeep = Color(0xFF5B21B6); // pressed / emphasis violet
  static const peacockLight = Neon.cyan; // orb + info highlights
  static const marigold = Neon.warning; // voice & alerts (amber)
  static const ink = Neon.bg; // app background
  static const mist = Neon.textHi; // primary text on dark
  static const danger = Neon.error;
}

class AppTheme {
  /// Space Grotesk for display/headlines (techy, geometric), Manrope for
  /// body (clean, readable) — Neon Design System V2.0.
  static TextTheme _text(TextTheme base) {
    final body = GoogleFonts.manropeTextTheme(base).apply(
      bodyColor: Neon.textHi,
      displayColor: Neon.textHi,
    );
    TextStyle display(TextStyle? s, {double? spacing}) => GoogleFonts.spaceGrotesk(
        textStyle: s, fontWeight: FontWeight.w700, letterSpacing: spacing);
    return body.copyWith(
      displayLarge: display(body.displayLarge, spacing: -1),
      displayMedium: display(body.displayMedium, spacing: -0.5),
      displaySmall: display(body.displaySmall),
      headlineLarge: display(body.headlineLarge),
      headlineMedium: display(body.headlineMedium),
      headlineSmall: display(body.headlineSmall),
      titleLarge: display(body.titleLarge),
      labelLarge: GoogleFonts.manrope(
          textStyle: body.labelLarge, fontWeight: FontWeight.w600),
    );
  }

  /// The one true theme — "Daylight": light-first, professional.
  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(
      seedColor: Neon.violet,
      brightness: Brightness.light,
      primary: Neon.violet,
      onPrimary: Colors.white,
      secondary: Neon.cyan,
      onSecondary: Colors.white,
      tertiary: Neon.pink,
      surface: Neon.surface,
      onSurface: Neon.textHi,
      error: Neon.error,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: Neon.bg,
      textTheme: _text(ThemeData.light().textTheme),
      splashFactory: InkSparkle.splashFactory,
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: GoogleFonts.spaceGrotesk(
          fontSize: 21,
          fontWeight: FontWeight.w700,
          color: Neon.textHi,
        ),
        iconTheme: const IconThemeData(color: Neon.textHi),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: Neon.surface,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Neon.rLg),
          side: BorderSide(color: Neon.line),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: Neon.violet,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 15),
          textStyle: GoogleFonts.manrope(
              fontWeight: FontWeight.w600, fontSize: 15.5),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: Neon.textHi,
          side: BorderSide(color: Neon.cyan.withValues(alpha: 0.35)),
          textStyle: GoogleFonts.manrope(fontWeight: FontWeight.w600),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: Neon.cyan,
          textStyle: GoogleFonts.manrope(fontWeight: FontWeight.w600),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: Neon.surfaceHigh,
        side: BorderSide(color: Neon.line),
        labelStyle: GoogleFonts.manrope(fontSize: 13, color: Neon.textHi),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Neon.rSm)),
      ),
      dividerTheme: DividerThemeData(color: Neon.line, thickness: 1),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: const Color(0xF2FFFFFF),
        height: 68,
        indicatorColor: Neon.violet.withValues(alpha: 0.22),
        indicatorShape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Neon.rPill)),
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            color: states.contains(WidgetState.selected)
                ? Neon.cyan
                : Neon.textDim,
          ),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => GoogleFonts.manrope(
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            color: states.contains(WidgetState.selected)
                ? Neon.textHi
                : Neon.textDim,
          ),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          selectedBackgroundColor: Neon.violet.withValues(alpha: 0.22),
          selectedForegroundColor: Neon.cyan,
          foregroundColor: Neon.textLo,
          side: BorderSide(color: Neon.line),
          textStyle: GoogleFonts.manrope(fontWeight: FontWeight.w600),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Neon.surfaceHigh,
        hintStyle: GoogleFonts.manrope(color: Neon.textDim),
        labelStyle: GoogleFonts.manrope(color: Neon.textLo),
        prefixIconColor: Neon.textLo,
        suffixIconColor: Neon.textLo,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Neon.rMd),
          borderSide: BorderSide(color: Neon.line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Neon.rMd),
          borderSide: BorderSide(color: Neon.line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Neon.rMd),
          borderSide: const BorderSide(color: Neon.cyan, width: 1.6),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Neon.rMd),
          borderSide: const BorderSide(color: Neon.error),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: Neon.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Neon.rXl),
          side: BorderSide(color: Neon.lineBright),
        ),
        titleTextStyle: GoogleFonts.spaceGrotesk(
            fontSize: 19, fontWeight: FontWeight.w700, color: Neon.textHi),
        contentTextStyle:
            GoogleFonts.manrope(fontSize: 14.5, color: Neon.textLo, height: 1.45),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: Neon.surface,
        modalBackgroundColor: Neon.surface,
        showDragHandle: true,
        dragHandleColor: Neon.textDim,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(Neon.rXl)),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: Neon.surfaceHigh,
        contentTextStyle: GoogleFonts.manrope(color: Neon.textHi),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Neon.rMd),
          side: BorderSide(color: Neon.lineBright),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected) ? Colors.white : Neon.textDim),
        trackColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected)
                ? Neon.violet
                : Neon.surfaceHigh),
      ),
      progressIndicatorTheme:
          const ProgressIndicatorThemeData(color: Neon.cyan),
      listTileTheme: ListTileThemeData(
        iconColor: Neon.textLo,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Neon.rMd)),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: Neon.violet,
        foregroundColor: Colors.white,
      ),
    );
  }

  /// Light-first product: "dark" returns the same Daylight theme so no
  /// device setting can drop the app back into the retired neon design.
  static ThemeData dark() => light();
}
