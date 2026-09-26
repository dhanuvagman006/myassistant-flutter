import 'package:flutter/painting.dart';

/// THE SIX COLOURS OF A CARD, each in two moods.
///
/// "Pink", "gold", "blue"… are what he says; each resolves to a whole
/// palette tuned for print-like softness (paper grounds, rose-gold and
/// gold foil, petal and leaf shades). Most designs use the LIGHT mood; the
/// Golden Celebration design uses the DEEP one (black and gold, navy and
/// gold…), which is where foil looks richest.
///
/// Every pair a word sits on is held to WCAG contrast in
/// test/poster_palette_test.dart — a card that is shared must be readable
/// on a small phone in sunlight.
class PosterPalette {
  final String colour;
  final bool deep;

  /// Paper: a vertical gradient with a soft glow near the top.
  final Color bgTop;
  final Color bgBottom;
  final Color glow;

  /// Headline and name.
  final Color ink;

  /// The wishes.
  final Color body;

  /// Date and quiet details.
  final Color soft;

  /// Metallic foil, light → dark → light, laid diagonally.
  final List<Color> foil;

  /// Flowers: the main bloom, and a second one for mixed bunches.
  final Color petal;
  final Color petalLight;
  final Color petalDeep;
  final Color petal2;
  final Color petal2Light;
  final Color petal2Deep;

  final Color leaf;
  final Color leafDark;
  final Color leafLight;

  /// The photo's mat and a polaroid's card.
  final Color mat;

  /// Balloons, confetti and bunting.
  final List<Color> party;

  const PosterPalette({
    required this.colour,
    required this.deep,
    required this.bgTop,
    required this.bgBottom,
    required this.glow,
    required this.ink,
    required this.body,
    required this.soft,
    required this.foil,
    required this.petal,
    required this.petalLight,
    required this.petalDeep,
    required this.petal2,
    required this.petal2Light,
    required this.petal2Deep,
    required this.leaf,
    required this.leafDark,
    required this.leafLight,
    required this.mat,
    required this.party,
  });

  /// The signature is written in the name's ink.
  Color get signatureInk => ink;

  /// The foil's middle tone, for thin lines where a gradient would vanish.
  Color get foilMid => foil[foil.length ~/ 2];

  /// A swatch for the colour chip: what the card's paper looks like.
  Color get swatch => deep ? bgTop : Color.lerp(bgBottom, petal, 0.55)!;

  LinearGradient foilGradient() => LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: foil,
      );
}

const _gold = [
  Color(0xFFF6E3A6),
  Color(0xFFD9A93F),
  Color(0xFFA9761F),
  Color(0xFFD4A443),
  Color(0xFFF3DC9A),
];

const _roseGold = [
  Color(0xFFF1D2B6),
  Color(0xFFCF9A76),
  Color(0xFFA56A4B),
  Color(0xFFC9906B),
  Color(0xFFEBC6A8),
];

// Deep grounds need a brighter foil to glow rather than sink.
const _goldBright = [
  Color(0xFFFFF0BF),
  Color(0xFFF0C95A),
  Color(0xFFC8962F),
  Color(0xFFEBC158),
  Color(0xFFFFEDB5),
];

const _partyBright = [
  Color(0xFFF2667B),
  Color(0xFFFFC34D),
  Color(0xFF4C9EE3),
  Color(0xFF5CC9A7),
  Color(0xFFA78BFA),
  Color(0xFFFF8A4C),
];

const Map<String, PosterPalette> _light = {
  'pink': PosterPalette(
    colour: 'pink',
    deep: false,
    bgTop: Color(0xFFFFF7F5),
    bgBottom: Color(0xFFFBE2E4),
    glow: Color(0xFFFFFFFF),
    ink: Color(0xFF7D2946),
    body: Color(0xFF5B3942),
    soft: Color(0xFF8E5B69),
    foil: _roseGold,
    petal: Color(0xFFEE9DB2),
    petalLight: Color(0xFFFCD9E1),
    petalDeep: Color(0xFFC24D72),
    petal2: Color(0xFFF6B99C),
    petal2Light: Color(0xFFFDE4D5),
    petal2Deep: Color(0xFFD97C5A),
    leaf: Color(0xFF8DB397),
    leafDark: Color(0xFF55836A),
    leafLight: Color(0xFFC3DCC7),
    mat: Color(0xFFFFFFFF),
    party: [Color(0xFFEE9DB2), Color(0xFFF6B99C), Color(0xFFD9A93F), Color(0xFFC24D72)],
  ),
  'gold': PosterPalette(
    colour: 'gold',
    deep: false,
    bgTop: Color(0xFFFFFBF0),
    bgBottom: Color(0xFFF5E6C6),
    glow: Color(0xFFFFFFFF),
    ink: Color(0xFF7A2E12),
    body: Color(0xFF4F3A24),
    soft: Color(0xFF86623C),
    foil: _gold,
    petal: Color(0xFFF6A531),
    petalLight: Color(0xFFFFD36E),
    petalDeep: Color(0xFFDD6A12),
    petal2: Color(0xFFE2463F),
    petal2Light: Color(0xFFF7897A),
    petal2Deep: Color(0xFFA8202A),
    leaf: Color(0xFF6E9A4E),
    leafDark: Color(0xFF3F6B30),
    leafLight: Color(0xFFA9C98A),
    mat: Color(0xFFFFFDF6),
    party: [Color(0xFFF6A531), Color(0xFFE2463F), Color(0xFFD9A93F), Color(0xFF6E9A4E)],
  ),
  'blue': PosterPalette(
    colour: 'blue',
    deep: false,
    bgTop: Color(0xFFF3F9FF),
    bgBottom: Color(0xFFD4E8FA),
    glow: Color(0xFFFFFFFF),
    ink: Color(0xFF1C3D70),
    body: Color(0xFF2B3D55),
    soft: Color(0xFF52708F),
    foil: _gold,
    petal: Color(0xFF8FC1EE),
    petalLight: Color(0xFFD2E7FA),
    petalDeep: Color(0xFF3F7FC0),
    petal2: Color(0xFFF4B3C6),
    petal2Light: Color(0xFFFCDFE8),
    petal2Deep: Color(0xFFD06A8D),
    leaf: Color(0xFF86B59A),
    leafDark: Color(0xFF4E8467),
    leafLight: Color(0xFFC0DCCB),
    mat: Color(0xFFFFFFFF),
    party: _partyBright,
  ),
  'green': PosterPalette(
    colour: 'green',
    deep: false,
    bgTop: Color(0xFFF7FBF3),
    bgBottom: Color(0xFFDFECD6),
    glow: Color(0xFFFFFFFF),
    ink: Color(0xFF2B4D31),
    body: Color(0xFF33443A),
    soft: Color(0xFF5E7A64),
    foil: _gold,
    petal: Color(0xFFFFFFFF),
    petalLight: Color(0xFFFFFFFF),
    petalDeep: Color(0xFFDCE6D5),
    petal2: Color(0xFFF2C3B0),
    petal2Light: Color(0xFFFBE5DB),
    petal2Deep: Color(0xFFD98C74),
    leaf: Color(0xFF6C9B69),
    leafDark: Color(0xFF3B6843),
    leafLight: Color(0xFFA9CB9F),
    mat: Color(0xFFFFFFFF),
    party: [Color(0xFF6C9B69), Color(0xFFF2C3B0), Color(0xFFD9A93F), Color(0xFFFFFFFF)],
  ),
  'white': PosterPalette(
    colour: 'white',
    deep: false,
    bgTop: Color(0xFFFFFEFA),
    bgBottom: Color(0xFFF3EEE4),
    glow: Color(0xFFFFFFFF),
    ink: Color(0xFF2E2A26),
    body: Color(0xFF3B3732),
    soft: Color(0xFF766E62),
    foil: _gold,
    petal: Color(0xFFF4ECE0),
    petalLight: Color(0xFFFFFFFF),
    petalDeep: Color(0xFFD8C6AC),
    petal2: Color(0xFFEBD5CF),
    petal2Light: Color(0xFFF8ECE8),
    petal2Deep: Color(0xFFC9A49B),
    leaf: Color(0xFFA2AF95),
    leafDark: Color(0xFF6F8063),
    leafLight: Color(0xFFD0D9C5),
    mat: Color(0xFFFFFFFF),
    party: [Color(0xFFD9A93F), Color(0xFFEBD5CF), Color(0xFFA2AF95), Color(0xFFD8C6AC)],
  ),
  'purple': PosterPalette(
    colour: 'purple',
    deep: false,
    bgTop: Color(0xFFFAF6FF),
    bgBottom: Color(0xFFE6DBF7),
    glow: Color(0xFFFFFFFF),
    ink: Color(0xFF4A2A7C),
    body: Color(0xFF3D3351),
    soft: Color(0xFF6F6090),
    foil: _gold,
    petal: Color(0xFFC6A4EC),
    petalLight: Color(0xFFEADCF9),
    petalDeep: Color(0xFF8656C4),
    petal2: Color(0xFFF3B2CB),
    petal2Light: Color(0xFFFCDFEA),
    petal2Deep: Color(0xFFCF6892),
    leaf: Color(0xFF8AAE95),
    leafDark: Color(0xFF557F64),
    leafLight: Color(0xFFC4DACB),
    mat: Color(0xFFFFFFFF),
    party: [Color(0xFFC6A4EC), Color(0xFFF3B2CB), Color(0xFFD9A93F), Color(0xFF8656C4)],
  ),
};

const Map<String, PosterPalette> _deep = {
  'gold': PosterPalette(
    colour: 'gold',
    deep: true,
    bgTop: Color(0xFF2E241A),
    bgBottom: Color(0xFF110C07),
    glow: Color(0xFF4A3A26),
    ink: Color(0xFFF7DC93),
    body: Color(0xFFF4ECDD),
    soft: Color(0xFFD9C29A),
    foil: _goldBright,
    petal: Color(0xFFF2C14E),
    petalLight: Color(0xFFFBE3A0),
    petalDeep: Color(0xFFC78A22),
    petal2: Color(0xFFF1E6D2),
    petal2Light: Color(0xFFFFFFFF),
    petal2Deep: Color(0xFFCDBB9C),
    leaf: Color(0xFFB08D4A),
    leafDark: Color(0xFF7D6230),
    leafLight: Color(0xFFD8BD80),
    mat: Color(0xFFFFF9EC),
    party: _goldBright,
  ),
  'pink': PosterPalette(
    colour: 'pink',
    deep: true,
    bgTop: Color(0xFF6E1B3E),
    bgBottom: Color(0xFF3A0A20),
    glow: Color(0xFF8E2C55),
    ink: Color(0xFFFADDA6),
    body: Color(0xFFFCEBF1),
    soft: Color(0xFFEBBFD0),
    foil: _goldBright,
    petal: Color(0xFFF48FB1),
    petalLight: Color(0xFFFAC6D8),
    petalDeep: Color(0xFFD1467A),
    petal2: Color(0xFFFFD6C2),
    petal2Light: Color(0xFFFFEDE3),
    petal2Deep: Color(0xFFE8906E),
    leaf: Color(0xFF7FB08F),
    leafDark: Color(0xFF4B7D5E),
    leafLight: Color(0xFFB7D6C0),
    mat: Color(0xFFFFF6F0),
    party: [Color(0xFFF7D07A), Color(0xFFF48FB1), Color(0xFFFFD6C2), Color(0xFFFFFFFF)],
  ),
  'blue': PosterPalette(
    colour: 'blue',
    deep: true,
    bgTop: Color(0xFF17325F),
    bgBottom: Color(0xFF09152F),
    glow: Color(0xFF2A4C85),
    ink: Color(0xFFF6DA92),
    body: Color(0xFFEDF2FB),
    soft: Color(0xFFB9C9E3),
    foil: _goldBright,
    petal: Color(0xFF9CC5F5),
    petalLight: Color(0xFFD6E8FC),
    petalDeep: Color(0xFF4F8AD6),
    petal2: Color(0xFFFFFFFF),
    petal2Light: Color(0xFFFFFFFF),
    petal2Deep: Color(0xFFD5DDEA),
    leaf: Color(0xFF7FA9A0),
    leafDark: Color(0xFF4B7A70),
    leafLight: Color(0xFFB5D2CC),
    mat: Color(0xFFFFFCF3),
    party: [Color(0xFFF6DA92), Color(0xFF9CC5F5), Color(0xFFFFFFFF), Color(0xFFF0C95A)],
  ),
  'green': PosterPalette(
    colour: 'green',
    deep: true,
    bgTop: Color(0xFF0F4A3A),
    bgBottom: Color(0xFF062519),
    glow: Color(0xFF1E6650),
    ink: Color(0xFFF4D98E),
    body: Color(0xFFEAF5EE),
    soft: Color(0xFFB2D2C2),
    foil: _goldBright,
    petal: Color(0xFFFFFFFF),
    petalLight: Color(0xFFFFFFFF),
    petalDeep: Color(0xFFD9E6DD),
    petal2: Color(0xFFF7C9B5),
    petal2Light: Color(0xFFFDE8DE),
    petal2Deep: Color(0xFFE0957A),
    leaf: Color(0xFF6FAE85),
    leafDark: Color(0xFF3F7D57),
    leafLight: Color(0xFFA8D4B5),
    mat: Color(0xFFFFFCF3),
    party: [Color(0xFFF4D98E), Color(0xFFFFFFFF), Color(0xFFF7C9B5), Color(0xFF6FAE85)],
  ),
  'white': PosterPalette(
    colour: 'white',
    deep: true,
    bgTop: Color(0xFF3A3F4B),
    bgBottom: Color(0xFF1B1E25),
    glow: Color(0xFF555C6B),
    ink: Color(0xFFF5DE9E),
    body: Color(0xFFF3F2EE),
    soft: Color(0xFFC3C2BC),
    foil: _goldBright,
    petal: Color(0xFFFFFFFF),
    petalLight: Color(0xFFFFFFFF),
    petalDeep: Color(0xFFDAD8D2),
    petal2: Color(0xFFEFE3D0),
    petal2Light: Color(0xFFFFF8EE),
    petal2Deep: Color(0xFFCDBB9C),
    leaf: Color(0xFF9FB0A6),
    leafDark: Color(0xFF6C7D73),
    leafLight: Color(0xFFCAD6CF),
    mat: Color(0xFFFFFFFF),
    party: [Color(0xFFF5DE9E), Color(0xFFFFFFFF), Color(0xFFEFE3D0), Color(0xFFF0C95A)],
  ),
  'purple': PosterPalette(
    colour: 'purple',
    deep: true,
    bgTop: Color(0xFF2C1B5E),
    bgBottom: Color(0xFF110A2E),
    glow: Color(0xFF45308A),
    ink: Color(0xFFF7DC93),
    body: Color(0xFFEFE9FF),
    soft: Color(0xFFC2B5E8),
    foil: _goldBright,
    petal: Color(0xFFD1B3F5),
    petalLight: Color(0xFFEEE2FC),
    petalDeep: Color(0xFF9A6BDB),
    petal2: Color(0xFFF7C1D6),
    petal2Light: Color(0xFFFDE4EE),
    petal2Deep: Color(0xFFDC7FA5),
    leaf: Color(0xFF8FB3A2),
    leafDark: Color(0xFF5A8270),
    leafLight: Color(0xFFC3DAD0),
    mat: Color(0xFFFFFCF3),
    party: [Color(0xFFF7DC93), Color(0xFFD1B3F5), Color(0xFFF7C1D6), Color(0xFFFFFFFF)],
  ),
};

PosterPalette posterPalette(String colour, {bool deep = false}) =>
    (deep ? _deep[colour] : _light[colour]) ?? _light['pink']!;

/// Every palette, for the contrast test and the chips.
Iterable<PosterPalette> get allPosterPalettes => [..._light.values, ..._deep.values];
