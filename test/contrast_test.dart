// CONTRAST — the key colour pairs, measured the way WCAG measures them.
//
// The clarity pass of 2026-09-24 found words and glyphs the owner could
// not read: cyan and amber words on Home at 2.5–3.2:1 by day, white mic
// and send glyphs on the dark theme's pastel accent at 2.4:1 every
// evening (1.3:1 with Lime, Mint or Amber), white day numbers on the busy
// calendar days, grey section labels on the ambient wash. Each pair below
// is computed on the ground it really sits on, in both themes and for
// every accent in Settings → Theme colour, so a future colour tweak that
// makes one of them unreadable fails here instead of on his phone.
//
// AA: 4.5:1 for words, 3:1 for glyphs and other non-text marks.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/design/accent_controller.dart';
import 'package:myassistant/design/neon_tokens.dart';
import 'package:myassistant/widgets/month_calendar.dart';

import 'palette_render_test.dart' show palettes;

double contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

/// [fg] at [alpha] laid over [ground] — what the eye actually sees.
Color over(Color fg, double alpha, Color ground) =>
    Color.alphaBlend(fg.withValues(alpha: alpha), ground);

const text = 4.5, glyph = 3.0;

/// The light ambient wash at its darkest (top-left, behind the greeting
/// and the first group label on You and Hub).
const lightAmbientDarkest = Color(0xFFDADDF5);

void main() {
  tearDown(() {
    Neon.setDark(false);
    Neon.setAccent(AccentController.defaultSeed);
  });

  /// Runs [check] in both themes with every accent the owner can pick.
  void everyTheme(void Function(String where) check) {
    for (final dark in [false, true]) {
      for (final (name, seed) in AccentController.swatches) {
        Neon.setDark(dark);
        Neon.setAccent(seed);
        check('${dark ? 'dark' : 'light'} / $name');
      }
    }
  }

  void atLeast(double ratio, double min, String what) =>
      expect(ratio, greaterThanOrEqualTo(min),
          reason: '$what is ${ratio.toStringAsFixed(2)}:1, needs $min:1');

  test('body text reads on every ground it sits on', () {
    everyTheme((where) {
      for (final (g, gName) in [
        (Neon.bg, 'bg'),
        (Neon.surface, 'surface'),
      ]) {
        atLeast(contrast(Neon.textHi, g), text, 'textHi on $gName ($where)');
        atLeast(contrast(Neon.textLo, g), text, 'textLo on $gName ($where)');
        atLeast(contrast(Neon.textDim, g), text, 'textDim on $gName ($where)');
      }
      atLeast(contrast(Neon.textHi, Neon.surfaceHigh), text,
          'textHi on surfaceHigh ($where)');
      atLeast(contrast(Neon.textLo, Neon.surfaceHigh), text,
          'textLo on surfaceHigh ($where)');
    });
  });

  test('group labels and helper text read on the light ambient wash', () {
    Neon.setDark(false);
    // textDim is 3.62:1 here, which is why GroupLabel and the helper lines
    // on You and "Nothing on …" moved to textLo.
    atLeast(contrast(Neon.textLo, lightAmbientDarkest), text,
        'textLo on the ambient wash');
  });

  test('coloured words use their *Ink token and pass', () {
    everyTheme((where) {
      // Home: the weather chip (cyan 10% over the ambient top), the
      // meeting time pill (cyan 14% over surfaceHigh), the message sender.
      final ambient = Neon.isDark ? Neon.bg : lightAmbientDarkest;
      atLeast(contrast(Neon.cyanInk, over(Neon.cyan, 0.10, ambient)), text,
          'cyanInk on the weather chip ($where)');
      atLeast(contrast(Neon.cyanInk, over(Neon.cyan, 0.14, Neon.surfaceHigh)),
          text, 'cyanInk on the agenda time pill ($where)');
      for (final (g, gName) in [
        (Neon.surface, 'surface'),
        (Neon.surfaceHigh, 'surfaceHigh'),
        (Neon.bg, 'bg'),
      ]) {
        atLeast(contrast(Neon.cyanInk, g), text, 'cyanInk on $gName ($where)');
        atLeast(contrast(Neon.warningInk, g), text,
            'warningInk on $gName ($where)');
        atLeast(
            contrast(Neon.errorInk, g), text, 'errorInk on $gName ($where)');
        atLeast(contrast(Neon.successInk, g), text,
            'successInk on $gName ($where)');
      }
    });
  });

  test('by day, with the app violet or Indigo, every tile keeps white', () {
    Neon.setDark(false);
    for (final seed in [
      AccentController.defaultSeed,
      const Color(0xFF8B9CFF)
    ]) {
      Neon.setAccent(seed);
      for (final c in [
        Neon.accentA,
        Neon.accentB,
        Neon.accentC,
        Neon.accentD,
        Neon.accentE,
        Neon.accentF,
        Neon.error,
        Neon.warning,
      ]) {
        expect(Neon.onTile(c), const Color(0xFFFFFFFF),
            reason: 'tile ${c.toARGB32().toRadixString(16)}, seed $seed');
      }
      expect(Neon.onBrand, const Color(0xFFFFFFFF), reason: 'the mic, $seed');
    }
  });

  test('the mic and send glyphs read on the brand gradient', () {
    everyTheme((where) {
      final ink = Neon.onBrand;
      atLeast(contrast(ink, Neon.violet), glyph, 'glyph on violet ($where)');
      atLeast(contrast(ink, Neon.pink), glyph, 'glyph on pink ($where)');
    });
  });

  test('the dark theme Indigo accent: the mic reads, as measured', () {
    Neon.setDark(true);
    Neon.setAccent(const Color(0xFF8B9CFF));
    // White was 2.53:1 and 2.38:1 on the two stops.
    expect(Neon.onBrand, isNot(Colors.white));
    atLeast(contrast(Neon.onBrand, Neon.violet), 7.0, 'mic glyph on #8B9CFF');
  });

  test('tile glyphs read on every tile colour, and stay white by day', () {
    Color mid(Color c) {
      final g = Neon.tile(c);
      return Color.lerp(g.colors.first, g.colors.last, 0.35)!;
    }

    everyTheme((where) {
      for (final c in [
        Neon.accentA,
        Neon.accentB,
        Neon.accentC,
        Neon.accentD,
        Neon.accentE,
        Neon.accentF,
        Neon.error,
        Neon.warning,
      ]) {
        atLeast(contrast(Neon.onTile(c), mid(c)), glyph,
            'glyph on the ${c.toARGB32().toRadixString(16)} tile ($where)');
        // White stays wherever it passes: dark ink only where white fell
        // under 3:1 (a yellow partner of the Amber accent, the pastels at
        // night).
        if (Neon.onTile(c) != const Color(0xFFFFFFFF)) {
          expect(contrast(Colors.white, mid(c)), lessThan(glyph),
              reason: 'white would have passed on ${c.toARGB32()} ($where)');
        }
      }
    });
  });

  test('calendar day numbers read on every busy shade', () {
    everyTheme((where) {
      final heat = MonthCalendar.heatColors;
      expect(heat, hasLength(3));
      for (var i = 0; i < heat.length; i++) {
        atLeast(contrast(Neon.textOn(heat[i]), heat[i]), text,
            'day number on busy step ${i + 1} ($where)');
      }
      // Empty days have no fill: the number sits on the card itself.
      atLeast(contrast(Neon.textLo, Neon.surface), text,
          'empty day number ($where)');
    });
  });

  // WORDS ON THE ACCENT (2026-09-29, UI pass): white on the light theme's
  // violet #A855F7 was 3.95:1 on every primary button, FAB and selected
  // chip, and on the dark theme's Indigo 3.78:1. Neon.accentFill is the
  // accent deepened just enough; Neon.onAccent stays as it was.
  group('words on the accent fill', () {
    tearDown(() => Neon.usePalette(null));

    void fillReads(String where) {
      final fill = Neon.accentFill;
      atLeast(contrast(Neon.onAccent, fill), text, 'onAccent on accentFill ($where)');
      if (fill != Neon.violet) {
        // Deepened only as far as needed: a little lighter fails again.
        final h = HSLColor.fromColor(fill);
        final lighter = h.withLightness(h.lightness + 0.02).toColor();
        expect(contrast(Neon.onAccent, lighter), lessThan(text),
            reason: 'deeper than the words need ($where)');
      }
    }

    test('every accent, in both themes', () => everyTheme(fillReads));

    test("the app's own violet, in both themes", () {
      for (final dark in [false, true]) {
        Neon.setDark(dark);
        Neon.setAccent(null);
        fillReads(dark ? 'dark, no accent' : 'light, no accent');
      }
    });

    test('every Theme colour palette', () {
      for (final p in palettes) {
        Neon.usePalette(p);
        fillReads('palette ${p.name}');
      }
    });

    test('the measured case: white on the light violet', () {
      Neon.setDark(false);
      Neon.setAccent(null);
      expect(contrast(Colors.white, Neon.violet), lessThan(text));
      atLeast(contrast(Colors.white, Neon.accentFill), text, 'white on the light fill');
    });

    test('unchanged where the words already read', () {
      // The dark theme's pastel violet takes near-black words (6:1+).
      Neon.setDark(true);
      Neon.setAccent(null);
      expect(Neon.accentFill, Neon.violet);
      // The default Indigo's deep day ink already carries white.
      Neon.setDark(false);
      Neon.setAccent(AccentController.defaultSeed);
      expect(Neon.accentFill, Neon.violet);
    });
  });

  test('the voice screen type bar hint reads on the night ground', () {
    everyTheme((where) {
      // Mirrors _sessionGround() in inline_voice.dart at the bottom, where
      // the text box sits, and the box's own 7% white fill.
      final h = HSLColor.fromColor(Neon.violet);
      final ground = h.withLightness(0.06).withSaturation(0.40).toColor();
      final field = over(Colors.white, 0.07, ground);
      atLeast(contrast(over(Colors.white, 0.52, field), field), text,
          'type bar hint ($where)');
    });
  });
}
