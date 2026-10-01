import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../design/motion.dart';
import '../design/neon_tokens.dart';

/// Legacy color names, remapped onto the Neon V2 palette.
///
/// Twenty files still reference these identifiers; keeping the names (with
/// new values) re-skins every screen in one move. New code should import
/// `design/neon_tokens.dart` and use [Neon] directly — treat these as
/// deprecated aliases to be burned down screen by screen.
class AppColors {
  static final peacock = Neon.violet; // primary actions
  static const peacockDeep = Color(0xFF5B21B6); // pressed / emphasis violet
  static final peacockLight = Neon.cyan; // orb + info highlights
  static final marigold = Neon.warning; // voice & alerts (amber)
  static final ink = Neon.bg; // app background
  static final mist = Neon.textHi; // primary text on dark
  static final danger = Neon.error;
}

class AppTheme {
  /// Space Grotesk for display/headlines (techy, geometric), Manrope for
  /// body (clean, readable) — Neon Design System V2.0.
  ///
  /// WEIGHTS (2026-09-24). google_fonts registers every weight as its own
  /// family ("Manrope_700"), so a Text that only sets fontWeight keeps
  /// the regular file of the style it inherits from here. Until the fonts
  /// ship as a pubspec `fonts:` family, text that needs its weight takes
  /// it from NeonType.manrope. The lasting fix, once the .ttf files are in
  /// the app: declare family 'Manrope' (400, 500, 600, 700, 800) and
  /// 'SpaceGrotesk' (500, 600, 700) in pubspec, use
  /// `base.apply(fontFamily: 'Manrope', …)` and `ThemeData(fontFamily:
  /// 'Manrope')` here, and let NeonType.manrope return a plain TextStyle.
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

  /// THE NIGHT-SKY THEME (2026-09-30, the client's neon reference). The
  /// app is always dark now (ThemeController), so this is the one theme;
  /// the name `light()` stays because every caller and test uses it.
  ///
  /// EVERY ROLE SPELLED OUT. ColorScheme.fromSeed invents whatever it is
  /// not told, and it invented purple-grey: menus, pickers, tooltips, drag
  /// handles and chips all came out in a lilac slate beside the navy. Each
  /// role now names its token, and every component a screen can open
  /// (menus, pickers, dialogs, toasts) has its own block below, so nothing
  /// falls back to an SDK default.
  ///
  /// GLOW IS HIERARCHY: the primary button, the FAB and anything floating
  /// (a dialog, a menu, a toast) throw violet light; a secondary action
  /// has a rim; plain content is a dark raised surface with a hairline.
  static ThemeData light() {
    final dark = Neon.isDark;
    Color over(Color c, double a, [Color? ground]) =>
        Color.alphaBlend(c.withValues(alpha: a), ground ?? Neon.surface);
    // The lit edge of everything that floats over the page.
    final rim = BorderSide(
        color: dark ? Neon.violet.withValues(alpha: 0.45) : Neon.lineBright);
    final floating = RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Neon.rMd), side: rim);
    // Anything with elevation casts violet light at night, not a black
    // smudge on the navy (Material reads colorScheme.shadow).
    final glow = dark ? Neon.violet : Colors.black;
    final menuStyle = MenuStyle(
      backgroundColor: WidgetStatePropertyAll(Neon.surfaceHigh),
      surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
      shadowColor: WidgetStatePropertyAll(glow.withValues(alpha: 0.6)),
      elevation: const WidgetStatePropertyAll(10),
      side: WidgetStatePropertyAll(rim),
      shape: WidgetStatePropertyAll(floating),
    );
    TextStyle body(double size,
            [FontWeight weight = FontWeight.w400, Color? color]) =>
        GoogleFonts.manrope(
            fontSize: size, fontWeight: weight, color: color ?? Neon.textHi);
    final pickerButton = TextButton.styleFrom(
      foregroundColor: Neon.cyanInk,
      textStyle: body(NeonType.body, FontWeight.w700),
      minimumSize: const Size(64, 48),
    );
    bool on(Set<WidgetState> s) => s.contains(WidgetState.selected);

    final scheme = ColorScheme.fromSeed(
      seedColor: Neon.violet,
      brightness: dark ? Brightness.dark : Brightness.light,
      primary: Neon.violet,
      onPrimary: Neon.onInk,
      primaryContainer: over(Neon.violet, 0.22),
      onPrimaryContainer: Neon.textHi,
      secondary: Neon.cyan,
      // Words on bright cyan: white measured 1.6:1 at night.
      onSecondary: Neon.textOn(Neon.cyan),
      secondaryContainer: over(Neon.cyan, 0.22),
      onSecondaryContainer: Neon.textHi,
      tertiary: Neon.pink,
      onTertiary: Neon.textOn(Neon.pink),
      tertiaryContainer: over(Neon.pink, 0.22),
      onTertiaryContainer: Neon.textHi,
      error: Neon.error,
      onError: Neon.textOn(Neon.error),
      errorContainer: over(Neon.error, 0.22),
      onErrorContainer: Neon.textHi,
      surface: Neon.surface,
      onSurface: Neon.textHi,
      onSurfaceVariant: Neon.textLo,
      surfaceDim: Neon.bg,
      surfaceBright: Neon.surfaceHigh,
      surfaceContainerLowest: Neon.bg,
      surfaceContainerLow: Neon.surface,
      surfaceContainer: Neon.surface,
      surfaceContainerHigh: Neon.surfaceHigh,
      surfaceContainerHighest: over(Neon.violet, 0.08, Neon.surfaceHigh),
      // No M3 tint wash over raised surfaces: they are navy, not lilac.
      surfaceTint: Colors.transparent,
      outline: Neon.lineBright,
      outlineVariant: Neon.line,
      inverseSurface: Neon.surfaceHigh,
      onInverseSurface: Neon.textHi,
      inversePrimary: Neon.cyan,
      shadow: glow,
      scrim: Neon.scrim,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: Neon.bg,
      // The legacy dropdown and a few SDK sheets paint canvasColor: it
      // defaulted to grey[850] at night.
      canvasColor: Neon.surface,
      cardColor: Neon.surface,
      textTheme: _text(
          (dark ? ThemeData.dark() : ThemeData.light()).textTheme),
      splashFactory: InkSparkle.splashFactory,
      // FEEDBACK, EVERYWHERE. Every tap in the app answers with a soft
      // violet wash + the sparkle ripple, every route change glides
      // instead of jumping, and snackbars float — one theme block, the
      // whole app responds.
      splashColor: Neon.violet.withValues(alpha: 0.12),
      highlightColor: Neon.violet.withValues(alpha: 0.06),
      hoverColor: Neon.violet.withValues(alpha: 0.04),
      focusColor: Neon.cyan.withValues(alpha: 0.14),
      pageTransitionsTheme: const PageTransitionsTheme(builders: {
        TargetPlatform.android: AppPageTransitions(),
        TargetPlatform.iOS: AppPageTransitions(),
      }),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        foregroundColor: Neon.textHi,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: GoogleFonts.spaceGrotesk(
          fontSize: NeonType.title3,
          fontWeight: FontWeight.w700,
          color: Neon.textHi,
        ),
        iconTheme: IconThemeData(color: Neon.textHi),
        actionsIconTheme: IconThemeData(color: Neon.textHi),
      ),
      // Plain content: a dark raised surface with a lit hairline. No
      // glow — glow is kept for what matters most (GlowCard, halo).
      cardTheme: CardThemeData(
        elevation: 0,
        color: Neon.surface,
        surfaceTintColor: Colors.transparent,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Neon.rLg),
          side: BorderSide(color: Neon.lineBright),
        ),
      ),
      // THE ACCENT FILL, WITH ITS OWN INK (2026-09-29): Neon.accentFill is
      // the accent deepened just enough for Neon.onAccent words to pass
      // 4.5:1 — the plain violet under white was 3.95:1.
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: Neon.accentFill,
          foregroundColor: Neon.onAccent,
          // Lit at night: the button throws its own colour (2026-09-30).
          elevation: dark ? 8 : 0,
          shadowColor: Neon.violet,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 15),
          textStyle: GoogleFonts.manrope(
              fontWeight: FontWeight.w600, fontSize: NeonType.callout),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14)),
        ),
      ),
      // The secondary action: a lit rim, no fill, no glow.
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: Neon.textHi,
          side: BorderSide(color: Neon.cyan.withValues(alpha: 0.35)),
          textStyle: GoogleFonts.manrope(fontWeight: FontWeight.w600),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14)),
        ),
      ),
      // WORDS IN CYAN TAKE cyanInk (2026-09-24): every text button in the
      // light theme ("Try again", "Cancel", "Open app info") was #0891B2
      // on white, 3.7:1. The same hue, deep enough to read.
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: Neon.cyanInk,
          textStyle: GoogleFonts.manrope(fontWeight: FontWeight.w600),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: Neon.textHi,
          disabledForegroundColor: Neon.textDim,
          highlightColor: Neon.violet.withValues(alpha: 0.14),
        ),
      ),
      // A picked chip is lit violet glass with a cyan tick; a resting one
      // is a raised surface with a hairline.
      chipTheme: ChipThemeData(
        backgroundColor: Neon.surfaceHigh,
        selectedColor: over(Neon.violet, 0.26, Neon.surfaceHigh),
        secondarySelectedColor: over(Neon.violet, 0.26, Neon.surfaceHigh),
        disabledColor: Neon.surface,
        checkmarkColor: Neon.cyan,
        deleteIconColor: Neon.textLo,
        iconTheme: IconThemeData(color: Neon.textLo, size: 18),
        side: WidgetStateBorderSide.resolveWith((s) => BorderSide(
            color: on(s) ? Neon.violet.withValues(alpha: 0.70) : Neon.line)),
        labelStyle: body(NeonType.footnote, FontWeight.w500),
        secondaryLabelStyle: body(NeonType.footnote, FontWeight.w700),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Neon.rSm)),
      ),
      dividerTheme: DividerThemeData(color: Neon.line, thickness: 1),
      // Unused today (the shell draws its own dock), but never white
      // again: it was 0xF2FFFFFF, a trap for the first screen to use it.
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: over(Neon.violet, 0.07),
        surfaceTintColor: Colors.transparent,
        height: 68,
        indicatorColor: Neon.cyan.withValues(alpha: 0.16),
        indicatorShape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Neon.rPill)),
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            color: on(states) ? Neon.cyan : Neon.textDim,
          ),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => GoogleFonts.manrope(
            fontSize: NeonType.caption,
            fontWeight: FontWeight.w600,
            color: on(states) ? Neon.textHi : Neon.textDim,
          ),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          selectedBackgroundColor: Neon.violet.withValues(alpha: 0.22),
          selectedForegroundColor: Neon.cyanInk,
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
          borderSide: BorderSide(color: Neon.cyan, width: 1.6),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Neon.rMd),
          borderSide: BorderSide(color: Neon.error),
        ),
      ),
      // The caret and the selection handles in the app's cyan light.
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: Neon.cyan,
        selectionColor: Neon.cyan.withValues(alpha: 0.30),
        selectionHandleColor: Neon.cyan,
      ),
      // A dialog floats: a violet rim and the violet light under it, over
      // the night scrim.
      dialogTheme: DialogThemeData(
        backgroundColor: Neon.surface,
        surfaceTintColor: Colors.transparent,
        elevation: dark ? 16 : 6,
        shadowColor: glow.withValues(alpha: 0.7),
        barrierColor: Neon.scrim,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Neon.rXl),
          side: rim,
        ),
        titleTextStyle: GoogleFonts.spaceGrotesk(
            fontSize: NeonType.title3,
            fontWeight: FontWeight.w700,
            color: Neon.textHi),
        contentTextStyle: GoogleFonts.manrope(
            fontSize: NeonType.callout, color: Neon.textLo, height: 1.45),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: Neon.surface,
        modalBackgroundColor: Neon.surface,
        surfaceTintColor: Colors.transparent,
        modalBarrierColor: Neon.scrim,
        shadowColor: glow.withValues(alpha: 0.6),
        showDragHandle: true,
        dragHandleColor: Neon.textDim,
        shape: RoundedRectangleBorder(
          borderRadius:
              const BorderRadius.vertical(top: Radius.circular(Neon.rXl)),
          side: dark ? rim : BorderSide.none,
        ),
      ),
      // MENUS FLOAT TOO (2026-09-30): five PopupMenuButtons set their own
      // colour, and every other menu came out lilac-grey from the seed.
      popupMenuTheme: PopupMenuThemeData(
        color: Neon.surfaceHigh,
        surfaceTintColor: Colors.transparent,
        shadowColor: glow.withValues(alpha: 0.6),
        elevation: 10,
        shape: floating,
        iconColor: Neon.textHi,
        textStyle: body(NeonType.callout),
        labelTextStyle: WidgetStateProperty.resolveWith((s) => body(
            NeonType.callout,
            FontWeight.w500,
            s.contains(WidgetState.disabled) ? Neon.textDim : Neon.textHi)),
      ),
      menuTheme: MenuThemeData(style: menuStyle),
      dropdownMenuTheme: DropdownMenuThemeData(
        menuStyle: menuStyle,
        textStyle: body(NeonType.callout),
      ),
      // PICKERS (2026-09-30): the reminder's date and time pickers were the
      // SDK's lilac dialogs. Navy surfaces, the chosen day lit in the
      // accent with its own ink, today ringed in cyan.
      datePickerTheme: DatePickerThemeData(
        backgroundColor: Neon.surface,
        surfaceTintColor: Colors.transparent,
        elevation: dark ? 16 : 6,
        shadowColor: glow.withValues(alpha: 0.7),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Neon.rXl), side: rim),
        headerBackgroundColor: Neon.surfaceHigh,
        headerForegroundColor: Neon.textHi,
        headerHeadlineStyle: GoogleFonts.spaceGrotesk(
            fontSize: NeonType.title2, fontWeight: FontWeight.w700),
        headerHelpStyle: body(NeonType.footnote, FontWeight.w600),
        weekdayStyle: body(NeonType.caption, FontWeight.w600, Neon.textDim),
        dayStyle: body(NeonType.body, FontWeight.w500),
        dayForegroundColor: WidgetStateProperty.resolveWith((s) => on(s)
            ? Neon.onAccent
            : s.contains(WidgetState.disabled)
                ? Neon.textDim
                : Neon.textHi),
        dayBackgroundColor: WidgetStateProperty.resolveWith(
            (s) => on(s) ? Neon.accentFill : Colors.transparent),
        dayOverlayColor:
            WidgetStatePropertyAll(Neon.violet.withValues(alpha: 0.12)),
        todayForegroundColor: WidgetStateProperty.resolveWith(
            (s) => on(s) ? Neon.onAccent : Neon.cyanInk),
        todayBackgroundColor: WidgetStateProperty.resolveWith(
            (s) => on(s) ? Neon.accentFill : Colors.transparent),
        todayBorder: BorderSide(color: Neon.cyan, width: 1.4),
        yearStyle: body(NeonType.rowTitle, FontWeight.w500),
        yearForegroundColor: WidgetStateProperty.resolveWith(
            (s) => on(s) ? Neon.onAccent : Neon.textHi),
        yearBackgroundColor: WidgetStateProperty.resolveWith(
            (s) => on(s) ? Neon.accentFill : Colors.transparent),
        rangeSelectionBackgroundColor: Neon.violet.withValues(alpha: 0.22),
        dividerColor: Neon.line,
        cancelButtonStyle: pickerButton,
        confirmButtonStyle: pickerButton,
      ),
      timePickerTheme: TimePickerThemeData(
        backgroundColor: Neon.surface,
        elevation: dark ? 16 : 6,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Neon.rXl), side: rim),
        helpTextStyle: body(NeonType.footnote, FontWeight.w600, Neon.textLo),
        hourMinuteColor: WidgetStateColor.resolveWith((s) => on(s)
            ? over(Neon.violet, 0.30, Neon.surfaceHigh)
            : Neon.surfaceHigh),
        hourMinuteTextColor: WidgetStateColor.resolveWith(
            (s) => on(s) ? Neon.cyanInk : Neon.textHi),
        hourMinuteShape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Neon.rSm)),
        dayPeriodColor: WidgetStateColor.resolveWith((s) => on(s)
            ? over(Neon.violet, 0.30, Neon.surfaceHigh)
            : Colors.transparent),
        dayPeriodTextColor: WidgetStateColor.resolveWith(
            (s) => on(s) ? Neon.cyanInk : Neon.textLo),
        dayPeriodBorderSide: BorderSide(color: Neon.lineBright),
        dialBackgroundColor: Neon.surfaceHigh,
        dialHandColor: Neon.accentFill,
        dialTextColor: WidgetStateColor.resolveWith(
            (s) => on(s) ? Neon.onAccent : Neon.textHi),
        entryModeIconColor: Neon.textLo,
        timeSelectorSeparatorColor: WidgetStatePropertyAll(Neon.textHi),
        cancelButtonStyle: pickerButton,
        confirmButtonStyle: pickerButton,
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith(
            (s) => on(s) ? Neon.accentFill : Colors.transparent),
        checkColor: WidgetStatePropertyAll(Neon.onAccent),
        side: WidgetStateBorderSide.resolveWith((s) => on(s)
            ? BorderSide(color: Neon.accentFill, width: 2)
            : BorderSide(color: Neon.textLo, width: 2)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
        overlayColor:
            WidgetStatePropertyAll(Neon.violet.withValues(alpha: 0.12)),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith(
            (s) => on(s) ? Neon.violet : Neon.textLo),
        overlayColor:
            WidgetStatePropertyAll(Neon.violet.withValues(alpha: 0.12)),
      ),
      // A tooltip is a small floating surface like a menu, not the SDK's
      // inverted (near-white at night) slab.
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: Neon.surfaceHigh,
          borderRadius: BorderRadius.circular(10),
          border: Border.fromBorderSide(rim),
          boxShadow: Neon.halo(Neon.violet, strength: 0.4),
        ),
        textStyle: body(NeonType.footnote, FontWeight.w500),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.dragged)
                ? Neon.cyan
                : Neon.textDim.withValues(alpha: 0.55)),
        radius: const Radius.circular(8),
        thickness: const WidgetStatePropertyAll(4),
        crossAxisMargin: 2,
      ),
      // A count is an important state: the brand's magenta, with ink that
      // reads on it.
      badgeTheme: BadgeThemeData(
        backgroundColor: Neon.pink,
        textColor: Neon.textOn(Neon.pink),
        textStyle: body(NeonType.caption, FontWeight.w700),
      ),
      // Every toast goes through AppFeedback (which rims it in its tone);
      // these are the same rules as a safety net: a ✕ on every toast, and
      // a swipe either way closes it.
      snackBarTheme: SnackBarThemeData(
        backgroundColor: Neon.surfaceHigh,
        contentTextStyle: GoogleFonts.manrope(color: Neon.textHi),
        behavior: SnackBarBehavior.floating,
        elevation: 8,
        showCloseIcon: true,
        closeIconColor: Neon.textLo,
        actionTextColor: Neon.cyanInk,
        dismissDirection: DismissDirection.horizontal,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Neon.rMd),
          side: BorderSide(color: Neon.lineBright),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected) ? Neon.onInk : Neon.textDim),
        trackColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected)
                ? Neon.violet
                : Neon.surfaceHigh),
        // The accent is "on" (it follows the chosen theme colour); at
        // night the lit track also gets a cyan rim, like every lit edge.
        trackOutlineColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected)
                ? (dark ? Neon.cyan.withValues(alpha: 0.75) : Neon.violet)
                : Neon.lineBright),
        trackOutlineWidth: const WidgetStatePropertyAll(1.4),
        overlayColor:
            WidgetStatePropertyAll(Neon.violet.withValues(alpha: 0.12)),
      ),
      // A cyan stroke with round ends on a faint lit track, every spinner
      // and bar alike.
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: Neon.cyan,
        linearTrackColor: Neon.line,
        circularTrackColor: Neon.line,
        strokeCap: StrokeCap.round,
        linearMinHeight: 4,
        borderRadius: BorderRadius.circular(4),
      ),
      listTileTheme: ListTileThemeData(
        tileColor: Colors.transparent,
        iconColor: Neon.textLo,
        textColor: Neon.textHi,
        selectedColor: Neon.cyanInk,
        selectedTileColor: Neon.violet.withValues(alpha: 0.12),
        titleTextStyle: body(NeonType.rowTitle, FontWeight.w600),
        subtitleTextStyle:
            body(NeonType.footnote, FontWeight.w400, Neon.textLo),
        leadingAndTrailingTextStyle:
            body(NeonType.footnote, FontWeight.w500, Neon.textLo),
        minTileHeight: 48,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Neon.rMd)),
      ),
      // The primary action that floats: the accent fill, a magenta rim
      // and the violet light under it (colorScheme.shadow at night).
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: Neon.accentFill,
        foregroundColor: Neon.onAccent,
        elevation: dark ? 10 : 4,
        focusElevation: dark ? 12 : 6,
        highlightElevation: dark ? 14 : 8,
        splashColor: Neon.onAccent.withValues(alpha: 0.14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: dark
              ? BorderSide(
                  color: Neon.pink.withValues(alpha: 0.55), width: 1.2)
              : BorderSide.none,
        ),
      ),
    );
  }

  /// Always the one theme: there is no pale version of the night sky
  /// (owner, 2026-09-30), so no device setting can change the design.
  static ThemeData dark() => light();
}

/// EVERY PAGE MOVES AT THE SAME PACE, AND THROUGH SPACE (2026-09-29).
///
/// The owner: "navigation must feel spatial — do not use a fade as the
/// default screen transition; the new screen moves into place, and Back
/// moves the other way." The 2026-09-24 version slid a page only 8% and
/// dissolved the page under it, so it still read as a fade.
///
/// Now a page one step deeper PUSHES in from the right edge, over a soft
/// edge shadow, while the page it came from steps a quarter of the way to
/// the left — you see where you came from move aside. Back runs the same
/// path the other way: the page leaves to the right and the one under it
/// comes back from the left. Nothing dissolves; both pages stay solid on
/// the app's own ground. A full-screen modal (the document gallery, the
/// studio) rises from below instead and the page under it stays put,
/// because it is not a step deeper. On the app's clock (design/motion.dart:
/// [Motion.pageIn] in, [Motion.pageBack] back). With "Remove animations"
/// on, pages just fade.
class AppPageTransitions extends PageTransitionsBuilder {
  const AppPageTransitions();

  static const Duration forward = Motion.pageIn;
  static const Duration back = Motion.pageBack;

  @override
  Duration get transitionDuration => forward;

  @override
  Duration get reverseTransitionDuration => back;

  // A page one step deeper comes in from the right edge...
  static const Offset _drill = Offset(1, 0);
  // ...a full-screen modal rises from below, a short way, fading in.
  static const Offset _rise = Offset(0, 0.14);
  // The page underneath steps this far aside.
  static const Offset _aside = Offset(-0.26, 0);

  @override
  DelegatedTransitionBuilder? get delegatedTransition =>
      (context, animation, secondaryAnimation, allowSnapshotting, child) =>
          Motion.reduced(context)
              ? child
              : _underneath(context, secondaryAnimation, child);

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (Motion.reduced(context)) {
      return FadeTransition(opacity: animation, child: child);
    }
    if (route.fullscreenDialog) {
      // Nothing moves underneath a modal (the route does not ask it to).
      return _modal(animation, child);
    }
    return _page(animation, _underneath(context, secondaryAnimation, child));
  }

  /// The page itself: pushed in on the arrival curve, back out on the
  /// leaving one, solid all the way, with a shadow at its leading edge
  /// while it moves.
  static Widget _page(Animation<double> animation, Widget child) {
    return DualTransitionBuilder(
      animation: animation,
      forwardBuilder: (context, a, child) => SlideTransition(
        position: a.drive(Tween<Offset>(begin: _drill, end: Offset.zero)
            .chain(CurveTween(curve: Motion.easeEnter))),
        child: child,
      ),
      // Runs forward as the page leaves (Back).
      reverseBuilder: (context, a, child) => SlideTransition(
        position: a.drive(Tween<Offset>(begin: Offset.zero, end: _drill)
            .chain(CurveTween(curve: Motion.easeExit))),
        child: child,
      ),
      // Its ground and edge shadow travel WITH it; outside the slide they
      // covered the page it came from from the first frame.
      child: _Moving(animation: animation, shadow: true, child: child),
    );
  }

  /// A full-screen modal: rises a short way and fades in; sinks and fades
  /// out.
  static Widget _modal(Animation<double> animation, Widget child) {
    return DualTransitionBuilder(
      animation: animation,
      forwardBuilder: (context, a, child) => FadeTransition(
        opacity: a.drive(CurveTween(curve: const Interval(0, 0.5, curve: Motion.easeFadeIn))),
        child: SlideTransition(
          position: a.drive(Tween<Offset>(begin: _rise, end: Offset.zero)
              .chain(CurveTween(curve: Motion.easeEnter))),
          child: child,
        ),
      ),
      reverseBuilder: (context, a, child) => FadeTransition(
        opacity: a.drive(Tween<double>(begin: 1, end: 0)
            .chain(CurveTween(curve: Motion.easeFadeOut))),
        child: SlideTransition(
          position: a.drive(Tween<Offset>(begin: Offset.zero, end: _rise)
              .chain(CurveTween(curve: Motion.easeExit))),
          child: child,
        ),
      ),
      child: child,
    );
  }

  /// The page underneath, while another opens over it or closes off it:
  /// it steps aside to the left and comes back, solid.
  static Widget _underneath(
      BuildContext context, Animation<double> secondary, Widget? child) {
    final moving = DualTransitionBuilder(
      animation: ReverseAnimation(secondary),
      // The page above is closing: this one comes back from the left.
      forwardBuilder: (context, a, child) => SlideTransition(
        position: a.drive(Tween<Offset>(begin: _aside, end: Offset.zero)
            .chain(CurveTween(curve: Motion.easeEnter))),
        child: child,
      ),
      // A page is opening over this one: it steps aside.
      reverseBuilder: (context, a, child) => SlideTransition(
        position: a.drive(Tween<Offset>(begin: Offset.zero, end: _aside)
            .chain(CurveTween(curve: Motion.easeEnter))),
        child: child,
      ),
      child: child,
    );
    if (!(ModalRoute.opaqueOf(context) ?? true)) return moving;
    // On the app's ground while it moves, so nothing shows the black of an
    // empty window. Only while moving: at rest this draws nothing at all.
    return _Moving(animation: secondary, child: moving);
  }
}

/// While [animation] runs, [child] sits on the app's ground (and, with
/// [shadow], casts a soft shadow from its leading edge); at rest it is
/// drawn as it is. Rebuilds only when the animation starts or stops.
class _Moving extends StatefulWidget {
  const _Moving({required this.animation, required this.child, this.shadow = false});
  final Animation<double> animation;
  final Widget child;
  final bool shadow;

  @override
  State<_Moving> createState() => _MovingState();
}

class _MovingState extends State<_Moving> {
  bool _moving = false;

  void _status(AnimationStatus s) {
    final moving = s == AnimationStatus.forward || s == AnimationStatus.reverse;
    if (moving != _moving && mounted) setState(() => _moving = moving);
  }

  @override
  void initState() {
    super.initState();
    widget.animation.addStatusListener(_status);
    _status(widget.animation.status);
  }

  @override
  void didUpdateWidget(_Moving old) {
    super.didUpdateWidget(old);
    if (old.animation != widget.animation) {
      old.animation.removeStatusListener(_status);
      widget.animation.addStatusListener(_status);
      _status(widget.animation.status);
    }
  }

  @override
  void dispose() {
    widget.animation.removeStatusListener(_status);
    super.dispose();
  }

  /// The edge shadow is a strip of gradient beside the page, not a blurred
  /// box shadow on it (2026-09-30): a 24 dp blur under a whole moving page
  /// is a blur pass per frame, which the owner's phone showed as a stutter.
  /// The gradient is a flat fill.
  static const _edge = 28.0;

  @override
  Widget build(BuildContext context) {
    if (!_moving) return widget.child;
    final page = ColoredBox(color: Neon.bg, child: widget.child);
    if (!widget.shadow) return page;
    return Stack(
      clipBehavior: Clip.none,
      fit: StackFit.passthrough,
      children: [
        Positioned(
          left: -_edge,
          top: 0,
          bottom: 0,
          width: _edge,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: [
                    Colors.transparent,
                    Colors.black.withValues(alpha: Neon.isDark ? 0.4 : 0.12),
                  ],
                ),
              ),
            ),
          ),
        ),
        page,
      ],
    );
  }
}
