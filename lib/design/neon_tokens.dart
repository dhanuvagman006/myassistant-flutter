import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'neon_palette.dart';

export 'neon_palette.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  MYASSISTANT · Design System — "Night sky neon" (2026-09-30)
///  The client's reference: a deep navy ground, cyan / electric blue /
///  violet / magenta light, luminous rims, and glow used for HIERARCHY
///  (the primary action glows, a secondary one has a rim, content sits on
///  a dark raised surface). The app is always dark (ThemeController); the
///  light values below are kept only so the token API stays whole.
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

  /// A WHOLE SCHEME, when one is chosen ([NeonPalette]): ground, cards,
  /// words and accents together. Null — the default — leaves every token
  /// below exactly as it was, the user's accent included.
  static NeonPalette? _palette;
  static NeonPalette? get palette => _palette;

  static void usePalette(NeonPalette? p) {
    _palette = p;
    if (p != null) isDark = p.dark;
  }

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
    // THE SIGNATURE PAIR (2026-09-30, the client's neon direction): the
    // default electric blue goes with a purple-magenta — the blue-to-
    // magenta light the reference is made of — not its analogous
    // neighbour. Every other accent keeps the rule below.
    final signature = _signaturePartners[c.toARGB32()];
    // 22 DEGREES, NOT 42. A wide rotation turned warm accents into a
    // clashing second hue — amber paired with lime, which looked like a
    // mistake rather than a theme. A short analogous step keeps every
    // gradient in the same family whatever colour is chosen.
    _accentPartner = signature ??
        h
            .withHue((h.hue + 22) % 360)
            .withSaturation((h.saturation * 1.02).clamp(0.35, 1.0))
            .withLightness((h.lightness + 0.04).clamp(0.35, 0.80))
            .toColor();
    _accentInk = h
        .withSaturation((h.saturation * 1.05).clamp(0.45, 1.0))
        .withLightness((h.lightness * 0.52).clamp(0.24, 0.48))
        .toColor();
  }

  /// Accents with a partner chosen by hand rather than by hue rotation.
  static const _signaturePartners = <int, Color>{
    0xFF3D8BFF: Color(0xFFE04BF5), // Electric (the default) → magenta
  };

  static Color get violet => _palette?.primary ?? _violet;
  static Color get _violet => _accent != null
      ? (isDark ? _accent! : _accentInk!)
      : (isDark ? const Color(0xFFC77DFF) : const Color(0xFFA855F7));
  // Whole accent set brightened with it ("entire app all colors") —
  // higher luminance, saturation kept, so black stays black and the
  // accents carry the energy.
  static Color get cyan => _palette?.secondary ??
      (isDark ? const Color(0xFF22E4FF) : const Color(0xFF0891B2));
  /// The gradient partner — derived from the accent so every gradient in
  /// the app (orb, mic, tiles, quote card) stays in tune with one choice.
  static Color get pink => _palette?.partner ?? _pink;
  static Color get _pink => _accentPartner != null
      ? (isDark
          ? _accentPartner!
          : HSLColor.fromColor(_accentPartner!)
              .withLightness(
                  (HSLColor.fromColor(_accentPartner!).lightness * 0.55)
                      .clamp(0.26, 0.50))
              .toColor())
      : (isDark ? const Color(0xFFFF8AC8) : const Color(0xFFDB2777));
  static Color get lime => _palette?.tertiary ??
      (isDark ? const Color(0xFFBDF64B) : const Color(0xFF65A30D));
  /// The page ground. In the dark it is a near-black carrying a trace of
  /// the theme colour rather than #000000 — flat black made every screen
  /// read as empty (2026-09-19). AmbientBackground lays the soft pools of
  /// light on top of this.
  static Color get bg {
    final p = _palette;
    if (p != null) return p.bg;
    if (!isDark) return const Color(0xFFF7F7FB);
    // DEEP INDIGO-NAVY (2026-09-30, sampled from the client's reference:
    // #150D48 top-left, #081353 middle, #001B4A low): one night-sky ground
    // under every accent, so the neon reads as light in the dark rather
    // than as a tinted page. The ambient pools and ribbons light it.
    return const Color(0xFF070B2B);
  }
  // SURFACES CARRY THE BRAND, not a grey wash. The ground stays pure
  // black; the cards sitting on it are a violet-cast near-black, which
  // is what stops a dark theme reading as "charcoal sheets on nothing"
  // (2026-09-19 — "the colour combination is worst, it looks boring").
  // Navy cards on the blue-black ground (2026-09-30): lifted by a step of
  // blue, never grey.
  static Color get surface => _palette?.surface ??
      (isDark ? const Color(0xFF0C1440) : const Color(0xFFFFFFFF));
  static Color get surfaceHigh => _palette?.surfaceHigh ??
      (isDark ? const Color(0xFF121B4E) : const Color(0xFFEEEFF6));
  static Color get success => _palette?.success ??
      (isDark ? const Color(0xFF62F49B) : const Color(0xFF16A34A));
  static Color get warning => _palette?.warning ??
      (isDark ? const Color(0xFFFFD03E) : const Color(0xFFD97706));
  static Color get error => _palette?.error ??
      (isDark ? const Color(0xFFFF8585) : const Color(0xFFEF4444));

  // Text — ink on paper; on pure black, brighter steps so secondary text
  // still reads instead of sinking into gray mud.
  // Blue-white words on the night ground (2026-09-30).
  static Color get textHi => _palette?.textHi ??
      (isDark ? const Color(0xFFF3F6FF) : const Color(0xFF1B1D28));
  static Color get textLo => _palette?.textLo ??
      (isDark ? const Color(0xFFBAC4E3) : const Color(0xFF585E70));
  // Light mode was #9BA0B0 — 2.4:1 on the page, unreadable for the
  // timestamps, hints and footnotes it is used for. Now 4.5:1.
  static Color get textDim => _palette?.textDim ??
      (isDark ? const Color(0xFF8E9AC2) : const Color(0xFF6B7185));

  /// The GROUND color for things painted in [textHi] — icon-on-ink tiles,
  /// text on the primary button. Tracks the theme so "white on ink" in
  /// light mode becomes "ink on chalk" in dark mode automatically.
  static Color get onInk => bg;

  /// Text and icons ON the accent (a filled button, a sent bubble, a badge).
  /// White on the dark theme's pastel accents measured 1.3–2.8:1; those
  /// get near-black ink. The light theme's deep accents keep white (above
  /// 3:1 there, and the brand look).
  static Color get onAccent => violet.computeLuminance() > 0.3
      ? const Color(0xFF14121C)
      : const Color(0xFFFFFFFF);

  /// THE ACCENT AS A FILL THAT CARRIES WORDS (2026-09-29, UI pass): every
  /// primary button, FAB, selected chip, badge and sent bubble — anything
  /// painted in the accent with [onAccent] words or icons on top. White on
  /// the light theme's violet #A855F7 measured 3.95:1 (the dark theme's
  /// Indigo 3.78:1); words need 4.5:1. This is the same accent, stepped
  /// darker in HSL lightness only as far as white needs to pass, so the
  /// button still reads as the brand colour. Unchanged wherever [onAccent]
  /// is near-black (6:1 or better on any accent that light) or white
  /// already passes. Keep [violet] for icons, borders, gradients and the
  /// orb; test/contrast_test.dart checks every accent and palette.
  static Color get accentFill {
    final a = violet;
    final key = a.toARGB32();
    // Read in build() on every list row: worked out once per accent.
    if (key != _fillKey) {
      _fillKey = key;
      _fill = _deepenForWhite(a);
    }
    return _fill!;
  }

  static int? _fillKey;
  static Color? _fill;

  /// The gradient partner as a fill that carries words — [pink] stepped
  /// darker exactly as [accentFill] is, so a button painted accent →
  /// partner keeps white words at 4.5:1 along its whole length
  /// (2026-10-01, the fluorescent primary button).
  static Color get partnerFill {
    final a = pink;
    final key = a.toARGB32();
    if (key != _partnerKey) {
      _partnerKey = key;
      _partner = _deepenForWhite(a);
    }
    return _partner!;
  }

  static int? _partnerKey;
  static Color? _partner;

  static Color _deepenForWhite(Color a) {
    // The same rule as onAccent: above 0.3 the words are near-black.
    if (a.computeLuminance() > 0.3) return a;
    // White passes at 4.5:1 while the fill's luminance is 0.1833 or less.
    const maxLum = 1.05 / 4.5 - 0.05;
    var h = HSLColor.fromColor(a);
    var c = a;
    while (c.computeLuminance() > maxLum && h.lightness > 0) {
      h = h.withLightness((h.lightness - 0.01).clamp(0.0, 1.0));
      c = h.toColor();
    }
    return c;
  }

  // WORDS IN A COLOUR (2026-09-24, the clarity pass). An accent that is
  // fine for an icon, a border or a fill is often too light for text: on
  // the light theme cyan #0891B2 measured 2.5–3.2:1 as words on Home's
  // tinted chips and cards, amber #D97706 2.8–3.2:1 on the most urgent
  // labels in the app (a promise due, an expiring passport, an overdue
  // reminder), and the reds and greens 3.3–3.8:1 on white. These are the
  // same hues, deep enough to read (4.5:1 or better where each is used —
  // test/contrast_test.dart measures them). Colour words with the *Ink
  // token; keep the plain one for icons, borders and fills.
  static Color get cyanInk {
    final p = _palette;
    if (p != null) {
      // The palette's info colour, deep enough to read as words by day.
      if (p.dark) return p.secondary;
      final h = HSLColor.fromColor(p.secondary);
      return h.withLightness((h.lightness * 0.62).clamp(0.18, 0.40)).toColor();
    }
    return isDark ? const Color(0xFF3FE3FD) : const Color(0xFF155E75);
  }
  static Color get warningInk =>
      isDark ? const Color(0xFFFFD03E) : const Color(0xFFA14A07);
  static Color get errorInk =>
      isDark ? const Color(0xFFFF8585) : const Color(0xFFC62828);
  static Color get successInk =>
      isDark ? const Color(0xFF62F49B) : const Color(0xFF137333);

  static const Color _nightInk = Color(0xFF14121C);

  /// Ink for a GLYPH on [ground]: white unless the ground is light enough
  /// that white falls under 3:1 (the WCAG minimum for icons), then the
  /// same near-black [onAccent] uses. White stays wherever it passes —
  /// that is the brand look by day.
  static Color glyphOn(Color ground) =>
      ground.computeLuminance() > 0.3 ? _nightInk : const Color(0xFFFFFFFF);

  /// Ink for WORDS on [ground]: whichever of white and near-black reads
  /// better. Text needs 4.5:1, so this flips to dark sooner than
  /// [glyphOn] does.
  static Color textOn(Color ground) {
    final l = ground.computeLuminance();
    final white = 1.05 / (l + 0.05);
    final dark = (l + 0.05) / (_nightInk.computeLuminance() + 0.05);
    return dark > white ? _nightInk : const Color(0xFFFFFFFF);
  }

  /// The glyph on a [tile] of [c] (IconTile, the Hub rows, Home's section
  /// headers). In the evening the dark theme's pastels put white glyphs at
  /// 1.4–2.3:1 on the cyan, amber and mint tiles, so those get dark ink;
  /// every light-theme tile keeps its white glyph (3.3–4.6:1), so nothing
  /// changes by day. Read at the point the glyph sits on the gradient.
  static Color onTile(Color c) {
    final g = tile(c);
    return glyphOn(Color.lerp(g.colors.first, g.colors.last, 0.35)!);
  }

  /// The glyph on the brand gradient (the mic, the send arrow). White on
  /// the dark theme's pastel accent measured 2.4–2.5:1, and about 1.3:1
  /// with Lime, Mint or Amber; decided by the LIGHTER of the two stops so
  /// the glyph reads across the whole disc.
  static Color get onBrand {
    final a = violet.computeLuminance(), b = pink.computeLuminance();
    return glyphOn(a > b ? violet : pink);
  }

  // Hairlines on cards — a touch brighter on pure black, or cards lose
  // their edges entirely.
  // Blue-lit edges in the dark (2026-09-30): a card's rim catches the
  // ground's light instead of drawing a grey pencil line.
  static Color get line => isDark
      ? const Color(0xFF7FA2FF).withValues(alpha: 0.22)
      : const Color(0xFF141627).withValues(alpha: 0.08);
  static Color get lineBright => isDark
      ? const Color(0xFF7FA2FF).withValues(alpha: 0.34)
      : const Color(0xFF141627).withValues(alpha: 0.14);

  /// THE SCRIM under a dialog, a sheet or a menu (2026-09-30): the night
  /// ground, deepened — not the SDK's grey-black, which turned the navy
  /// page under a dialog into a muddy slate.
  static Color get scrim => isDark
      ? const Color(0xFF02041A).withValues(alpha: 0.66)
      : const Color(0xFF141627).withValues(alpha: 0.40);

  /// HALO (2026-09-30, the client's neon direction): the light a lit edge
  /// throws — two soft layers of [c], all round (where [glow] is a tinted
  /// drop shadow). Only in the dark; on white it is a faint lift.
  /// HIERARCHY DECIDES WHO GLOWS: the Now card, the primary button, the
  /// selected tab, the mic. Not every row — a screen where everything
  /// glows has no focus.
  static List<BoxShadow> halo(Color c, {double strength = 1}) => isDark
      ? [
          BoxShadow(
              color: c.withValues(alpha: 0.34 * strength),
              blurRadius: 18,
              spreadRadius: -4),
          BoxShadow(
              color: c.withValues(alpha: 0.18 * strength),
              blurRadius: 44,
              spreadRadius: -10),
        ]
      : [
          BoxShadow(
              color: c.withValues(alpha: 0.14 * strength),
              blurRadius: 18,
              offset: const Offset(0, 6)),
        ];

  /// The lit edge's colours: the brand's two (a card's gradient rim).
  static List<Color> get rim => [violet, pink];

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

  // THE GLASS SCALE (2026-09-30, Home's premium pass): one radius per
  // level — a card, a panel inside it, an icon tile — so nested corners
  // stay concentric instead of each card picking its own.
  static const rCard = 24.0, rInner = 16.0, rTile = 12.0;

  /// A GLASS CARD'S FILL: lit a touch from above, deepening downwards. A
  /// quiet vertical gradient — not a tone wash — so the words carry the
  /// colour, not the panel.
  static LinearGradient get glassFill => LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: isDark
            ? [
                Color.alphaBlend(
                    const Color(0xFFB4C6FF).withValues(alpha: 0.07), surfaceHigh)
                    .withValues(alpha: 0.94),
                surface.withValues(alpha: 0.94),
              ]
            : [const Color(0xFFFFFFFF), const Color(0xFFF8F8FC)],
      );

  /// THE HAIRLINE EDGE of a glass card: brightest where the light falls
  /// (the top), fading down the sides — 1 px, low alpha, never a neon rim.
  static List<Color> get glassEdge => isDark
      ? [
          const Color(0xFFDCE4FF).withValues(alpha: 0.20),
          const Color(0xFF7FA2FF).withValues(alpha: 0.07),
        ]
      : [
          const Color(0xFF141627).withValues(alpha: 0.10),
          const Color(0xFF141627).withValues(alpha: 0.06),
        ];

  /// A hairline between rows inside a glass card.
  static Color get hairline => isDark
      ? const Color(0xFFB4C6FF).withValues(alpha: 0.10)
      : const Color(0xFF141627).withValues(alpha: 0.07);

  /// THE LIFT under a glass card: a soft, low drop shadow that sets it on
  /// the page — depth, not light. Light is [halo], for one thing a screen.
  static List<BoxShadow> get lift => [
        BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.30 : 0.07),
            blurRadius: 28,
            spreadRadius: -10,
            offset: const Offset(0, 8)),
      ];

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

/// ─────────────────────────────────────────────────────────────────────────
///  THE TYPE SCALE (2026-09-24, the clarity pass).
///
///  The app had 28 font sizes, many half a point apart (12.5 beside 13,
///  13.5 beside 14). Steps that small cannot be told apart, so they read
///  as untidy rather than as hierarchy, and 44 labels sat under 12 sp.
///  These are the sizes text should use, and 12 is the floor.
///
///  REAL WEIGHTS. The fonts come through google_fonts, which gives every
///  weight its own family ("Manrope_700"). A bare TextStyle(fontWeight:
///  w700) keeps the theme's REGULAR family and draws from the 400 file:
///  on build 106 a w700 tab label and w500 text had the same 3 px stems,
///  so titles, the selected tab and today's date lost the weight step the
///  code asks for. [manrope] asks google_fonts for the weight itself.
///  Once the fonts are bundled as a pubspec family, only this class needs
///  to change.
///
///  NEW WEIGHT FILES, AND WHEN THEY ARRIVE. Build 107 only ever asked for
///  Manrope Regular and SemiBold, so those are the two files a phone has
///  cached. This pass also asks for Medium, Bold and ExtraBold. Until the
///  fonts ship inside the app (branch ux-fonts: ship it WITH or BEFORE
///  this one), those three come from the network, so the first launch
///  after the update, or any launch offline, would draw the section
///  titles, the dock, the chips and the calendar in the phone's fallback
///  font, then swap each weight as it lands. [preload] asks for all of
///  them together at startup.
/// ─────────────────────────────────────────────────────────────────────────
abstract final class NeonType {
  static const double caption = 12; // the floor: meta, badges, the dock
  static const double footnote = 13; // subtitles, section labels, chips
  static const double body = 14; // list and card text
  static const double callout = 15; // Home section titles
  static const double rowTitle = 16; // a row's title
  static const double headline = 17; // a card's title, detail bars
  static const double title3 = 20;
  static const double title2 = 26; // Home's greeting
  static const double largeTitle = 32; // a tab's title

  static final Map<int, TextStyle> _cache = {};

  /// Manrope at [size], drawn in its real [weight] (see above). Cached:
  /// one style, and one font lookup, per size and weight for the run —
  /// these sit in rows that rebuild while a list scrolls.
  static TextStyle manrope(double size, [FontWeight weight = FontWeight.w400]) =>
      _cache[weight.value * 1000 + (size * 10).round()] ??=
          GoogleFonts.manrope(fontSize: size, fontWeight: weight);

  /// Every weight [manrope] is asked for anywhere in lib/ (clarity_test
  /// fails if a call site uses one that is not here).
  static const List<FontWeight> weights = [
    FontWeight.w400,
    FontWeight.w500,
    FontWeight.w600,
    FontWeight.w700,
    FontWeight.w800,
  ];

  /// Starts every Manrope weight in [weights] loading AT ONCE, and
  /// completes when they are all in or when [wait] runs out, whichever is
  /// first. Never throws: offline, a failed fetch only means the fallback
  /// font, which is what the screen would have drawn anyway.
  ///
  /// main() starts this before the other startup work and waits for it
  /// just before runApp. On a normal launch the files are already on the
  /// phone and load while Firebase starts, so it costs nothing and the
  /// first frame is already in the real weights, with no swap. On the
  /// first launch after the update it holds the splash for at most [wait],
  /// and a file that is still downloading lands behind the splash, not
  /// under a reader on Home. Still worth doing once the fonts are bundled:
  /// a bundled file loads asynchronously too.
  static Future<void> preload(
      {Duration wait = const Duration(milliseconds: 400)}) {
    for (final w in weights) {
      GoogleFonts.manrope(fontWeight: w);
    }
    return GoogleFonts.pendingFonts()
        .timeout(wait)
        .then<void>((_) {}, onError: (Object _) {});
  }

  /// A row's title — Hub, You and every AppleRow.
  static final TextStyle row =
      manrope(rowTitle, FontWeight.w600).copyWith(letterSpacing: -0.2);

  /// The small uppercase label over a group. ONE style on every tab: Hub
  /// had its own (accent, 11.5, heavy, wide) next to You's.
  static final TextStyle sectionLabel =
      manrope(footnote, FontWeight.w700).copyWith(letterSpacing: 0.6);

  /// A Home section header ("Today's agenda") and the calendar's month.
  static final TextStyle sectionTitle =
      manrope(callout, FontWeight.w700).copyWith(letterSpacing: 0.1);

  /// A card's own title ("One-time permission", "Missed calls").
  static final TextStyle cardTitle = manrope(headline, FontWeight.w700);

  /// THE EYEBROW over a glass card's title or group ("Tomorrow", "Try
  /// asking"): small, sentence case, a little tracked.
  static final TextStyle eyebrow =
      manrope(footnote, FontWeight.w700).copyWith(letterSpacing: 0.3);

  /// A glass card's title: 20, bold, slightly tight.
  static final TextStyle glassTitle =
      manrope(title3, FontWeight.w700).copyWith(letterSpacing: -0.2, height: 1.25);

  /// Times and temperatures: figures that line up down a column.
  static const List<FontFeature> figures = [FontFeature.tabularFigures()];
}

/// WHAT A LIT EDGE MEANS (2026-09-30, the client's neon reference). The
/// neon on a card says what kind of thing it is — the same everywhere,
/// never a colour picked per screen: green is done and well, blue is
/// information, magenta-to-orange is something to act on, purple is
/// something to discover, cyan is the assistant suggesting. [brand] is the
/// app's own light, for the one thing that matters most on a screen.
enum NeonTone { brand, success, info, action, discovery, tip, warning, danger }

extension NeonToneLight on NeonTone {
  /// The rim's two colours, start → end.
  List<Color> get rim => switch (this) {
        NeonTone.brand => Neon.rim,
        NeonTone.success => const [Color(0xFF2BF5A0), Color(0xFF22E4FF)],
        NeonTone.info => const [Color(0xFF4D8BFF), Color(0xFF8B5CFF)],
        NeonTone.action => const [Color(0xFFE040FB), Color(0xFFFF7A45)],
        NeonTone.discovery => const [Color(0xFF8B5CFF), Color(0xFFE040FB)],
        NeonTone.tip => const [Color(0xFF22E4FF), Color(0xFF8B5CFF)],
        NeonTone.warning => const [Color(0xFFFFB020), Color(0xFFFF7A45)],
        NeonTone.danger => const [Color(0xFFFF5A6E), Color(0xFFE040FB)],
      };

  /// The card's ground: the surface, tinted by its rim (glass lit from
  /// the edge).
  ///
  /// 2026-09-30 visual QA: amber is navy's opposite, so at 20% it mixed to
  /// a muddy brown-grey panel (the confirmation card, Documents' renewal
  /// card). Warning keeps a lighter tint; its rim and halo carry the light.
  Color get fill => Color.alphaBlend(
      rim.first.withValues(
          alpha: Neon.isDark ? (this == NeonTone.warning ? 0.09 : 0.20) : 0.05),
      Neon.surface);

  /// Words and icons drawn in the tone (a pill's label): the rim's first
  /// colour at night; its deep ink by day, where the neon is too light to
  /// read on white.
  Color get ink => Neon.isDark
      ? rim.first
      : HSLColor.fromColor(rim.first)
          .withLightness(
              (HSLColor.fromColor(rim.first).lightness * 0.55).clamp(0.22, 0.42))
          .toColor();
}
