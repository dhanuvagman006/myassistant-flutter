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

  /// The one true theme — "Daylight": light-first, professional.
  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(
      seedColor: Neon.violet,
      brightness: Neon.isDark ? Brightness.dark : Brightness.light,
      primary: Neon.violet,
      onPrimary: Neon.onInk,
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
      textTheme: _text(
          (Neon.isDark ? ThemeData.dark() : ThemeData.light()).textTheme),
      splashFactory: InkSparkle.splashFactory,
      // FEEDBACK, EVERYWHERE. Every tap in the app answers with a soft
      // violet wash + the sparkle ripple, every route change glides
      // instead of jumping, and snackbars float — one theme block, the
      // whole app responds.
      splashColor: Neon.violet.withValues(alpha: 0.12),
      highlightColor: Neon.violet.withValues(alpha: 0.06),
      hoverColor: Neon.violet.withValues(alpha: 0.04),
      pageTransitionsTheme: const PageTransitionsTheme(builders: {
        TargetPlatform.android: AppPageTransitions(),
        TargetPlatform.iOS: AppPageTransitions(),
      }),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: GoogleFonts.spaceGrotesk(
          fontSize: NeonType.title3,
          fontWeight: FontWeight.w700,
          color: Neon.textHi,
        ),
        iconTheme: IconThemeData(color: Neon.textHi),
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
          foregroundColor: Neon.onInk,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 15),
          textStyle: GoogleFonts.manrope(
              fontWeight: FontWeight.w600, fontSize: NeonType.callout),
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
      // WORDS IN CYAN TAKE cyanInk (2026-09-24): every text button in the
      // light theme ("Try again", "Cancel", "Open app info") was #0891B2
      // on white, 3.7:1. The same hue, deep enough to read.
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: Neon.cyanInk,
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
            fontSize: NeonType.caption,
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
      dialogTheme: DialogThemeData(
        backgroundColor: Neon.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Neon.rXl),
          side: BorderSide(color: Neon.lineBright),
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
        showDragHandle: true,
        dragHandleColor: Neon.textDim,
        shape: const RoundedRectangleBorder(
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(Neon.rXl)),
        ),
      ),
      // Every toast goes through AppFeedback; these are the same rules as
      // a safety net: a ✕ on every toast, and a swipe either way closes it.
      snackBarTheme: SnackBarThemeData(
        backgroundColor: Neon.surfaceHigh,
        contentTextStyle: GoogleFonts.manrope(color: Neon.textHi),
        behavior: SnackBarBehavior.floating,
        showCloseIcon: true,
        closeIconColor: Neon.textLo,
        actionTextColor: Neon.violet,
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
      ),
      progressIndicatorTheme:
          ProgressIndicatorThemeData(color: Neon.cyan),
      listTileTheme: ListTileThemeData(
        iconColor: Neon.textLo,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Neon.rMd)),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: Neon.violet,
        foregroundColor: Neon.onInk,
      ),
    );
  }

  /// Light-first product: "dark" returns the same Daylight theme so no
  /// device setting can drop the app back into the retired neon design.
  static ThemeData dark() => light();
}

/// EVERY PAGE MOVES AT THE SAME PACE (2026-09-24, "need more smoothness
/// while using the app").
///
/// On the app's own clock: 240 ms in and 200 ms back, where the stock
/// route took 300 ms both ways — slower than the voice screen, the cards
/// and the toasts around it, so opening a page felt like waiting for it.
/// Every MaterialPageRoute in the app reads its timing from here (and the
/// numbers themselves from design/motion.dart).
///
/// AND IN THE SAME DIRECTION (2026-09-24). That fade-and-rise was the
/// Android 8 transition: every page floated up a quarter of the screen
/// (about 220 dp on his phone) as a ghost, only a third opaque half-way,
/// while the page under it sat still — and Back dropped it 220 dp again.
/// On a phone running One UI 6 it read dated and floaty. Now a page slides
/// in a short way from the side (8%) and is solid within half its time,
/// while the page underneath steps back 4% and fades out of the way — onto
/// the app's own ground, so the two never show through each other. Back
/// plays it in reverse, easing off and then going. A full-screen modal
/// (the document gallery, the studio) rises a little instead, because it
/// is not a step deeper. With "Remove animations" on, pages just fade.
class AppPageTransitions extends PageTransitionsBuilder {
  const AppPageTransitions();

  static const Duration forward = Motion.pageIn;
  static const Duration back = Motion.pageBack;

  @override
  Duration get transitionDuration => forward;

  @override
  Duration get reverseTransitionDuration => back;

  // A page one step deeper comes in from the side...
  static const Offset _drill = Offset(0.08, 0);
  // ...a full-screen modal rises a little instead.
  static const Offset _rise = Offset(0, 0.06);

  // Solid within the first half of the way in; dissolves on the way out.
  static final Animatable<double> _fadeIn =
      CurveTween(curve: const Interval(0.0, 0.5, curve: Motion.easeFadeIn));
  static final Animatable<double> _fadeOut = Tween<double>(begin: 1, end: 0)
      .chain(CurveTween(curve: Motion.easeFadeOut));

  // The page underneath: out of the way quickly as a page opens over it,
  // back in quickly as that page closes.
  static final Animatable<double> _underLeaveFade = Tween<double>(
          begin: 1, end: 0)
      .chain(CurveTween(curve: const Interval(0.0, 0.3)));
  static final Animatable<double> _underReturnFade =
      CurveTween(curve: const Interval(0.0, 0.6, curve: Motion.easeFadeIn));
  static final Animatable<Offset> _underLeaveSlide =
      Tween<Offset>(begin: Offset.zero, end: const Offset(-0.04, 0))
          .chain(CurveTween(curve: Motion.easeEnter));
  static final Animatable<Offset> _underReturnSlide =
      Tween<Offset>(begin: const Offset(-0.04, 0), end: Offset.zero)
          .chain(CurveTween(curve: Motion.easeEnter));

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
      return _page(animation, _rise, child);
    }
    return _page(
        animation, _drill, _underneath(context, secondaryAnimation, child));
  }

  /// The page itself: in on the arrival curve, out on the leaving one.
  static Widget _page(Animation<double> animation, Offset from, Widget child) {
    return DualTransitionBuilder(
      animation: animation,
      forwardBuilder: (context, a, child) => FadeTransition(
        opacity: a.drive(_fadeIn),
        child: SlideTransition(
          position: a.drive(Tween<Offset>(begin: from, end: Offset.zero)
              .chain(CurveTween(curve: Motion.easeEnter))),
          child: child,
        ),
      ),
      // Runs forward as the page leaves (Back).
      reverseBuilder: (context, a, child) => FadeTransition(
        opacity: a.drive(_fadeOut),
        child: SlideTransition(
          position: a.drive(Tween<Offset>(begin: Offset.zero, end: from)
              .chain(CurveTween(curve: Motion.easeExit))),
          child: child,
        ),
      ),
      child: child,
    );
  }

  /// The page underneath, while another opens over it or closes off it.
  static Widget _underneath(
      BuildContext context, Animation<double> secondary, Widget? child) {
    final moving = DualTransitionBuilder(
      animation: ReverseAnimation(secondary),
      // The page above is closing: this one comes back.
      forwardBuilder: (context, a, child) => FadeTransition(
        opacity: a.drive(_underReturnFade),
        child: SlideTransition(
            position: a.drive(_underReturnSlide), child: child),
      ),
      // A page is opening over this one: it steps back and fades.
      reverseBuilder: (context, a, child) => FadeTransition(
        opacity: a.drive(_underLeaveFade),
        child:
            SlideTransition(position: a.drive(_underLeaveSlide), child: child),
      ),
      child: child,
    );
    if (!(ModalRoute.opaqueOf(context) ?? true)) return moving;
    // On the app's ground while it moves, so a fading page shows the
    // ground behind it and not the black of an empty window. Only while
    // moving: at rest this draws nothing at all.
    return DecoratedBox(
      decoration: secondary.isAnimating
          ? BoxDecoration(color: Neon.bg)
          : const BoxDecoration(),
      child: moving,
    );
  }
}
