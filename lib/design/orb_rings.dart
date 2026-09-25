import 'dart:math' as math;
import 'dart:ui' show Color;

import 'accent_controller.dart';

/// ─────────────────────────────────────────────────────────────────────
///  THE VOICE SCREEN'S RINGS — the client's reference, as numbers
///  (2026-09-25).
///
///  The client, on WhatsApp through the owner, about the voice screen:
///  "Change outer rendering to other style" (he circled the flares round
///  the orb), then a picture and "Make it something like this, when it's
///  on, only the speaker should move forward and backwards". The owner:
///  "the exact same surrounding design around the orb as this, with
///  animation while speaking and listening, moving forward and backward".
///
///  EVERY NUMBER HERE WAS MEASURED OFF THAT PICTURE, not guessed (the
///  same rule the old orb was built by). Distances are in multiples of the
///  centre disc's radius R, angles in degrees from the horizontal:
///   * five thin FULL RINGS — mint 1.10, teal 1.28, blue 1.46, violet
///     1.64 and a faint mauve 1.82 (the last one is the speaker's frame:
///     it never moves);
///   * four bright LENSES, only at the left and right — mint 1.21, cyan
///     1.34, blue 1.48, violet 1.61 — thickest at the horizontal and
///     tapering to a point 37-49° up and down, like speaker cones seen
///     from the side;
///   * a soft HAZE between them at the sides (the picture's gaps there
///     are lit, not black);
///   * the light-wave RIBBONS running out of both sides: a twisted bundle
///     of fine strands (a lattice of little diamonds), lavender near the
///     disc, washing the lenses bluer where it crosses them, and gone by
///     about 2 R, with a violet strand through them and a few sparkles;
///   * and the GROUND round it all: the picture's night is a dark teal,
///     not our navy, so the gaps between its rings read as lit haze.
///  Unwrapped into angle and radius, the reference and these numbers were
///  compared ray by ray until they matched.
///
///  ONE TABLE, TWO PAINTERS. lib/widgets/voice_orb.dart draws this table
///  on the Canvas (as triangle meshes, built once) and
///  shaders/voice_backdrop.frag draws the same table on the GPU. The
///  shader cannot import Dart, so it carries a copy of every number;
///  test/orb_rings_test.dart reads the shader and fails if the two ever
///  differ, and test/gpu_pass_test.dart compares their pixels.
/// ─────────────────────────────────────────────────────────────────────

/// One element of the ring system, in units of the disc's radius.
///
/// A FULL RING ([lens] false) goes all the way round at radius [r0]. A
/// LENS exists only near the horizontal: at an angle a from it, it is
/// w = 1 - (a / [tip])² as thick as at the horizontal (so it ends in a
/// point at [tip] degrees), its middle slides [drift] outward as it thins,
/// and it fades by smoothstep([fade0], [fade1], w).
///
/// Across its width every element has the same profile: [a0] over the
/// core (half-width [h]), falling to [a1] over the next [e] (the bright
/// edge), then to nothing over [g] (the glow). Colours come from
/// [OrbPalette.elements], index for index.
class OrbElement {
  const OrbElement(
    this.name, {
    required this.lens,
    required this.tier,
    required this.r0,
    this.drift = 0,
    required this.h,
    required this.e,
    required this.g,
    required this.a0,
    required this.a1,
    this.tip = 0,
    this.fade0 = 0,
    this.fade1 = 1,
    this.side = 0,
  });

  final String name;
  final bool lens;

  /// Which spring moves it: 0 (innermost) .. 4, or [OrbRings.frame] for
  /// the one that holds still.
  final int tier;
  final double r0, drift, h, e, g, a0, a1;

  /// Lenses: where the lens ends, in degrees from the horizontal.
  final double tip;
  final double fade0, fade1;

  /// Full rings: over this many degrees from the horizontal the ring's
  /// colour turns from its top colour to its side colour (the picture's
  /// rings are brighter where the lenses light them).
  final double side;

  /// How far out it reaches, glow and all.
  double get reach => r0 + drift + h + e + g;
}

abstract final class OrbRings {
  /// The tier that never moves (the faint outer ring).
  static const int frame = 5;

  /// In the order they are painted: the haze, then the lenses, then the
  /// full rings on top (the picture's rings stay visible as thin bright
  /// lines inside the lenses).
  static const List<OrbElement> elements = [
    // THE HAZE at the sides, between the lenses.
    OrbElement('haze-mint', lens: true, tier: 0, r0: 1.140, h: 0.040,
        e: 0.012, g: 0.020, a0: 0.95, a1: 0.95, tip: 60),
    OrbElement('haze-teal', lens: true, tier: 2, r0: 1.278, h: 0.024,
        e: 0.010, g: 0.015, a0: 0.95, a1: 0.95, tip: 48),
    OrbElement('haze-steel', lens: true, tier: 2, r0: 1.405, h: 0.030,
        e: 0.012, g: 0.020, a0: 1.00, a1: 1.00, tip: 40),
    OrbElement('haze-blue', lens: true, tier: 3, r0: 1.537, h: 0.022,
        e: 0.012, g: 0.020, a0: 0.95, a1: 0.95, tip: 38),
    OrbElement('haze-violet', lens: true, tier: 4, r0: 1.655, h: 0.012,
        e: 0.010, g: 0.080, a0: 0.60, a1: 0.50, tip: 36),
    // THE LENSES — the speaker cones.
    OrbElement('lens-mint', lens: true, tier: 1, r0: 1.207, drift: 0.006,
        h: 0.043, e: 0.008, g: 0.020, a0: 1, a1: 0.45, tip: 49,
        fade0: 0, fade1: 0.15),
    OrbElement('lens-cyan', lens: true, tier: 2, r0: 1.340, h: 0.036,
        e: 0.008, g: 0.018, a0: 1, a1: 0.45, tip: 38, fade0: 0, fade1: 0.4),
    OrbElement('lens-blue', lens: true, tier: 3, r0: 1.478, drift: 0.004,
        h: 0.035, e: 0.008, g: 0.018, a0: 1, a1: 0.45, tip: 37,
        fade0: 0.05, fade1: 0.4),
    OrbElement('lens-violet', lens: true, tier: 4, r0: 1.608, drift: 0.008,
        h: 0.040, e: 0.006, g: 0.016, a0: 1, a1: 0.40, tip: 38,
        fade0: 0, fade1: 0.2),
    // THE FULL RINGS.
    OrbElement('ring-mint', lens: false, tier: 0, r0: 1.099, h: 0.009,
        e: 0.008, g: 0.022, a0: 1, a1: 0.45, side: 50),
    OrbElement('ring-teal', lens: false, tier: 2, r0: 1.279, h: 0.007,
        e: 0.007, g: 0.028, a0: 1, a1: 0.35, side: 50),
    OrbElement('ring-blue', lens: false, tier: 3, r0: 1.460, h: 0.005,
        e: 0.007, g: 0.025, a0: 1, a1: 0.30, side: 36),
    OrbElement('ring-violet', lens: false, tier: 4, r0: 1.637, h: 0.005,
        e: 0.007, g: 0.020, a0: 1, a1: 0.30, side: 38),
    OrbElement('ring-frame', lens: false, tier: frame, r0: 1.815, h: 0.003,
        e: 0.007, g: 0.015, a0: 1, a1: 0.25, side: 40),
  ];

  /// How far the whole system reaches as a multiple of the disc's
  /// DIAMETER (the outer ring and its glow), so a slot can be sized to
  /// hold all of it: the rings are whole circles now, never cut off.
  static const double reach = 1.85;

  // ── The speaker's push ────────────────────────────────────────────────
  /// How far each tier pushes out at full voice, as a share of its own
  /// radius: the inner rings most, the outer ones less, the frame not at
  /// all — a cone moves most at its middle and not at its rim, and the
  /// eye reads a push travelling outward.
  ///
  /// BIGGER, 2026-09-25 (review). The client asked for a speaker moving
  /// "forward and backwards"; at 0.070 an ordinary voice moved the inner
  /// ring 2-3 dp, which at arm's length reads as a shimmer, and a quiet
  /// word looked the same as the thinking breath. At 0.105 (with the
  /// livelier curve in _onTick) ordinary speech pushes it about 5-6 dp at
  /// the sides. The frame still holds: the violet lens at its peak,
  /// overshoot and all (1.608 × (1 + 0.060 × 1.23) + 0.062 ≈ 1.79 R),
  /// stays inside the frame ring at 1.815 R (orb_rings_test checks every
  /// tier).
  static const List<double> push = [0.105, 0.096, 0.084, 0.072, 0.060];

  /// The curve from the voice's loudness to the push: ((l - 0.03) / 0.97)
  /// to this power. Below 1 lifts ordinary speech (the mic reads it at
  /// about 0.2-0.4) toward a full push; it was 0.75.
  static const double driveCurve = 0.6;

  /// A cone seen from the side moves along the axis it faces: the rings
  /// push further at the left and right than at the top and bottom.
  static const double pushTopShare = 0.6;

  /// Each tier's spring: 5 Hz at the middle, a little slower outward so
  /// the outer rings follow a beat behind, like moving air. Under-damped,
  /// so a syllable is a quick push and a small bounce back.
  static const double springHz = 5.0, springFalloff = 0.08, damping = 0.42;

  // ── The light-wave ribbons at the sides ───────────────────────────────
  /// Strands per side, and the brighter accent strands per side. Twenty
  /// strands twisting 1.4 times make the picture's fine lattice (its
  /// diamonds are about 0.04 R across).
  static const int strands = 20, accents = 2;

  /// Where the ribbons run, from under the disc's edge outward, to where
  /// they are gone (2.05 R, see [ribbonEnvelope]; nothing is drawn past
  /// it — it ran to 2.30 R before the review of 2026-09-25).
  static const double ribbonFrom = 0.97, ribbonTo = 2.05;

  /// Half-width of a strand and of an accent strand (vertical, R units).
  static const double strandHalf = 0.009, accentHalf = 0.022;

  /// Samples along each strand in the Canvas painter's mesh.
  static const int ribbonSamples = 100;

  /// How far along a ribbon [x] is: 0 at the disc's edge, 0.84 where the
  /// ribbon is gone (the shapes below were measured on this scale).
  static double ribbonU(double x) => (x - 1.0) / 1.25;

  /// The ribbon's middle line and half-height at [u], for the right (+1)
  /// and left (-1) side, measured off the picture: on the right it leaves
  /// the disc just above level and its lower edge flares downward; on the
  /// left it rises over the rings, then comes down and flares.
  static double ribbonMid(double u, int side) => side > 0
      ? -0.045 + 0.13 * u + 0.40 * u * u
      : -0.084 - 0.58 * u + 1.05 * u * u;
  static double ribbonHalf(double u, int side) =>
      side > 0 ? 0.095 + 0.29 * u * u : 0.16 - 0.12 * u + 0.33 * u * u;

  /// The twist: turns of the helix along the ribbon, and each side's start.
  static const double twist = 1.4, accentTwist = 0.8;
  static double ribbonPhase(int side) => side > 0 ? 0.4 : 2.1;
  static double accentPhase(int side, int i) =>
      side > 0 ? (i == 0 ? 0.9 : 2.6) : (i == 0 ? 3.3 : 5.0);

  /// Full strength as it leaves the disc, fading from [fadeOut0] and
  /// gone by [fadeOut1] (x = 2.05 R).
  ///
  /// SHORTER, 2026-09-25 (review). Faded over 0.55-1.0 the ribbons ran on
  /// to about 2.25 R and past the outer ring were twice as bright as the
  /// picture's, drooping there into crisp magenta lattices; the picture's
  /// ends are a faint grey-lavender, gone by about 2 R. The review's
  /// 0.42-0.80 went too far the other way once drawn (under half the
  /// picture's light at 1.86-1.95 R, and too dark from 1.75 R); 0.52-0.84
  /// is about half the old light there, which is about the picture's.
  static const double fadeIn0 = -0.05, fadeIn1 = 0.04;
  static const double fadeOut0 = 0.52, fadeOut1 = 0.84;
  static double ribbonEnvelope(double u) =>
      smoothstep(fadeIn0, fadeIn1, u) * (1 - smoothstep(fadeOut0, fadeOut1, u));

  /// The strands' and the accent strands' strength. The accent was 0.70
  /// and pink (2026-09-25, review: in the picture it is a faint violet
  /// thread, not a magenta one).
  static const double strandStrength = 0.60, accentStrength = 0.38;

  /// Strand [j] of [side] at [u]: its height and its brightness (strands
  /// on the near side of the twist are brighter, which is what makes a
  /// flat bundle of lines read as a twisted ribbon of light).
  static double strandY(double u, int side, int j) =>
      ribbonMid(u, side) +
      ribbonHalf(u, side) *
          math.sin(2 * math.pi * twist * u + ribbonPhase(side) + 2 * math.pi * j / strands);
  static double strandAlpha(double u, int side, int j) {
    final depth = math.cos(
        2 * math.pi * twist * u + ribbonPhase(side) + 2 * math.pi * j / strands);
    return strandStrength * ribbonEnvelope(u) * (0.35 + 0.65 * (0.5 + 0.5 * depth));
  }

  static double accentY(double u, int side, int i) =>
      ribbonMid(u, side) +
      0.35 *
          ribbonHalf(u, side) *
          math.sin(2 * math.pi * accentTwist * u + accentPhase(side, i));
  static double accentAlpha(double u) => accentStrength * ribbonEnvelope(u);

  /// THE SHEET under the strands: near the disc the picture's lattice is
  /// so dense it reads as a band of lavender light laid over the rings;
  /// further out it thins to lines. Its strength across the band, from
  /// the middle (0) to the edge (1): full, 0.85 at 0.6, nothing at 1.
  ///
  /// OVER THE LENSES TOO, 2026-09-25 (review). It used to thin out by
  /// u = 0.55 (about 1.4 R), so the violet lens showed through almost
  /// unchanged and the band read as separate thin lines; in the picture a
  /// soft blue-lavender band still washes the violet and blue lenses at
  /// 1.6 R. It now thins over [sheetThin0]-[sheetThin1] (0.34 at 1.62 R,
  /// was 0.135), and the far colour it turns to is bluer.
  static const double sheetKnee = 0.6, sheetKneeAlpha = 0.85;
  static const double sheetFloor = 0.12, sheetNear = 0.55;
  static const double sheetThin0 = 0.10, sheetThin1 = 0.80;
  static double sheetAlpha(double u) =>
      ribbonEnvelope(u) *
      (sheetFloor + sheetNear * (1 - smoothstep(sheetThin0, sheetThin1, u)));

  /// Near-to-far colour share along a ribbon.
  static double ribbonShade(double u) => smoothstep(0.0, 0.9, u);

  /// The sparkles on the ribbons: (x, height above or below the ribbon's
  /// middle, radius, alpha), right side; the left side mirrors x and
  /// uses the second list.
  static const List<(double, double, double, double)> sparklesRight = [
    (1.08, -0.06, 0.012, 0.85),
    (1.22, 0.05, 0.014, 0.75),
    (1.34, -0.08, 0.010, 0.80),
    (1.47, 0.03, 0.015, 0.90),
    (1.58, 0.12, 0.011, 0.65),
    (1.68, -0.04, 0.013, 0.80),
    (1.80, 0.14, 0.016, 0.70),
    (1.40, 0.16, 0.010, 0.55),
  ];
  static const List<(double, double, double, double)> sparklesLeft = [
    (1.06, 0.03, 0.013, 0.85),
    (1.18, -0.08, 0.011, 0.75),
    (1.30, 0.07, 0.015, 0.85),
    (1.43, -0.05, 0.010, 0.70),
    (1.55, 0.10, 0.013, 0.65),
    (1.66, -0.09, 0.011, 0.80),
    (1.78, 0.04, 0.015, 0.70),
    (1.50, 0.19, 0.010, 0.55),
  ];

  // ── The ground under the rings ────────────────────────────────────────
  /// THE WASH, 2026-09-25 (review). The picture's night round the orb is
  /// a dark teal (#081718-#0A1D1F), ours a navy (#06070F): its gaps
  /// between the rings read as lit haze, ours as black, and next to it
  /// ours looked colder and harder-edged. The screen's ground stays as it
  /// is (the words' contrast is measured on it); the speaker lays the
  /// picture's teal ([OrbPalette.wash]) under its own rings instead: full
  /// out to [washFull], gone by [washGone].
  ///
  /// AN ELLIPSE AS HIGH AS ITS BOX. The rings fill their slot: it reaches
  /// only about 1.85-1.96 R above and below the middle, and a wash cut
  /// off there would end in a hard line across the screen. So the wash
  /// is squashed to end exactly at the box's top and bottom ([washSquash])
  /// and runs its full width to the sides, where the ribbons are. It
  /// never reaches past the slot, over the words or the Sound button.
  static const double washFull = 1.9, washGone = 2.7;

  /// The wash's height as a share of its width in a box reaching
  /// [halfHeight] (in R) above and below the middle.
  static double washSquash(double halfHeight) =>
      (halfHeight / washGone).clamp(0.5, 1.0);

  /// Its strength [d] (in R, the ellipse's own measure) from the middle.
  static double washAlpha(double d) => 1 - smoothstep(washFull, washGone, d);

  static double smoothstep(double e0, double e1, double x) {
    final t = ((x - e0) / (e1 - e0)).clamp(0.0, 1.0);
    return t * t * (3 - 2 * t);
  }
}

/// ─────────────────────────────────────────────────────────────────────
///  THE COLOURS. For the default theme colour (Indigo) these are exactly
///  the reference's, sampled off the picture. For any other theme colour
///  every hue is moved toward the chosen one, so the owner's choice still
///  shows: each colour keeps its distance from Indigo's hue (231°) but
///  squeezed to 55%, and is re-centred on the new colour — Teal gives
///  green, teal and sky rings, Rose gives magenta, rose and red. The
///  lightness is kept (so the picture's light stays the same) and a grey
///  choice (Slate) gives greyer rings.
///
///  Keyed on AccentController.seed, never Neon.violet: in the light app
///  theme Neon.violet is the dark "ink" version, and the voice screen is
///  always night.
/// ─────────────────────────────────────────────────────────────────────
class OrbPalette {
  OrbPalette._(this.seed, Color Function(Color) f)
      : elements = [for (final c in _elements) f(c)],
        sides = [for (final c in _sides) f(c)],
        ribbonNear = f(_ribbonNear),
        ribbonFar = f(_ribbonFar),
        ribbonAccent = f(_ribbonAccent),
        sparkle = f(_sparkle),
        wash = f(_wash),
        disc = [for (final c in _disc) f(c)],
        rim = f(_rim),
        rimHalo = f(_rimHalo),
        dotNear = f(_dotNear),
        dotFar = f(_dotFar);

  final Color seed;

  /// One colour per [OrbRings.elements] entry (a full ring's top colour).
  final List<Color> elements;

  /// A full ring's side colour, per element (lenses repeat their colour).
  final List<Color> sides;
  final Color ribbonNear, ribbonFar, ribbonAccent, sparkle;

  /// The teal night laid under the rings (see [OrbRings.washFull]).
  final Color wash;

  /// The disc's fill, at [discStops] of its radius.
  final List<Color> disc;
  final Color rim, rimHalo, dotNear, dotFar;

  static const List<double> discStops = [
    0.0, 0.5, 0.8, 0.86, 0.88, 0.90, 0.92, 0.94, 0.96, 0.975,
  ];

  static const _elements = <Color>[
    Color(0xFF02987E), // haze-mint
    Color(0xFF24D6CC), // haze-teal
    Color(0xFF3586AC), // haze-steel
    Color(0xFF3C54A2), // haze-blue
    Color(0xFF3E2A96), // haze-violet
    Color(0xFF10FCD1), // lens-mint
    Color(0xFF44D4E6), // lens-cyan
    Color(0xFF6498F4), // lens-blue
    Color(0xFF5A3BD4), // lens-violet
    Color(0xFF16DEBA), // ring-mint
    Color(0xFF37A0B1), // ring-teal
    Color(0xFF3C5793), // ring-blue
    Color(0xFF3B326D), // ring-violet
    Color(0xFF402C48), // ring-frame
  ];
  static const _sides = <Color>[
    Color(0xFF02987E),
    Color(0xFF24D6CC),
    Color(0xFF3586AC),
    Color(0xFF3C54A2),
    Color(0xFF3E2A96),
    Color(0xFF10FCD1),
    Color(0xFF44D4E6),
    Color(0xFF6498F4),
    Color(0xFF5A3BD4),
    Color(0xFF12E0BC), // ring-mint at the sides
    Color(0xFF28DED4), // ring-teal
    Color(0xFF689CF6), // ring-blue
    Color(0xFF6844E4), // ring-violet
    Color(0xFF40304C), // ring-frame
  ];
  static const _ribbonNear = Color(0xFFB0B2FF);
  // 2026-09-25 (review): the far colour was a violet #8C7FE4; the
  // picture's band turns the violet lens bluer where it crosses it, so it
  // is a periwinkle now. The accent strand was a pink #CF7EF0; in the
  // picture it is a violet-lavender.
  static const _ribbonFar = Color(0xFF8C8CF0);
  static const _ribbonAccent = Color(0xFFA884F2);
  static const _sparkle = Color(0xFFEDEBFF);
  static const _wash = Color(0xFF0B1E20);
  static const _disc = <Color>[
    Color(0xFF0B0C28),
    Color(0xFF090B20),
    Color(0xFF06091A),
    Color(0xFF050818),
    Color(0xFF0F131F),
    Color(0xFF151D28),
    Color(0xFF202D36),
    Color(0xFF2D3D45),
    Color(0xFF354A50),
    Color(0xFF355256),
  ];
  static const _rim = Color(0xFFD5FFFD);
  static const _rimHalo = Color(0xFF38686A);
  static const _dotNear = Color(0xFFD2FFFD);
  static const _dotFar = Color(0xFF9CBDBF);

  /// Indigo's hue: the reference was drawn round it.
  static const double _homeHue = 231.2;

  static OrbPalette? _last;

  /// The palette for [seed]. Worked out once per theme colour (the last
  /// one is kept), not per frame or per rebuild.
  static OrbPalette of(Color seed) {
    final last = _last;
    if (last != null && last.seed == seed) return last;
    return _last = OrbPalette._(seed, _shiftFor(seed));
  }

  /// The palette of the theme colour chosen right now.
  static OrbPalette get current => of(AccentController.seed.value);

  static Color Function(Color) _shiftFor(Color seed) {
    if (seed.toARGB32() == AccentController.defaultSeed.toARGB32()) {
      return (c) => c;
    }
    final s = _Hsl.of(seed);
    final satScale = s.s.clamp(0.35, 1.0);
    return (c) {
      final h = _Hsl.of(c);
      var d = h.h - _homeHue;
      if (d > 180) d -= 360;
      if (d < -180) d += 360;
      final hue = (s.h + d * 0.55) % 360;
      return _Hsl(hue < 0 ? hue + 360 : hue, h.s * satScale, h.l)
          .toColor(c.a);
    };
  }
}

/// HSL without Flutter's painting library, so this file stays plain Dart
/// (the same maths as HSLColor).
class _Hsl {
  const _Hsl(this.h, this.s, this.l);
  final double h, s, l;

  static _Hsl of(Color c) {
    final r = c.r, g = c.g, b = c.b;
    final mx = math.max(r, math.max(g, b)), mn = math.min(r, math.min(g, b));
    final d = mx - mn;
    final l = (mx + mn) / 2;
    double h = 0;
    if (d > 0) {
      if (mx == r) {
        h = 60 * (((g - b) / d) % 6);
      } else if (mx == g) {
        h = 60 * ((b - r) / d + 2);
      } else {
        h = 60 * ((r - g) / d + 4);
      }
    }
    if (h < 0) h += 360;
    final s = (l == 0 || l == 1) ? 0.0 : d / (1 - (2 * l - 1).abs());
    return _Hsl(h, s.clamp(0.0, 1.0), l);
  }

  Color toColor(double alpha) {
    final c = (1 - (2 * l - 1).abs()) * s;
    final hp = h / 60;
    final x = c * (1 - (hp % 2 - 1).abs());
    double r = 0, g = 0, b = 0;
    if (hp < 1) {
      r = c;
      g = x;
    } else if (hp < 2) {
      r = x;
      g = c;
    } else if (hp < 3) {
      g = c;
      b = x;
    } else if (hp < 4) {
      g = x;
      b = c;
    } else if (hp < 5) {
      r = x;
      b = c;
    } else {
      r = c;
      b = x;
    }
    final m = l - c / 2;
    return Color.from(
        alpha: alpha,
        red: (r + m).clamp(0.0, 1.0),
        green: (g + m).clamp(0.0, 1.0),
        blue: (b + m).clamp(0.0, 1.0));
  }
}
