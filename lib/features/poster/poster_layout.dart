import 'dart:math' as math;

import 'package:flutter/painting.dart';

import 'poster_fonts.dart';
import 'poster_models.dart';
import 'poster_palettes.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  WHERE EVERYTHING GOES ON THE CARD — and the rule that his words are
///  never cut.
///
///  Each line is set in its design's size, then SHRUNK (never truncated,
///  never ellipsised, never broken inside a word) until the card holds it.
///  Words first give up a little size, then the photo gives up room, then
///  the words shrink again to a floor. If they still do not fit, the layout
///  says which line needs shortening and the app ASKS him — the contract's
///  `need` (2026-09-26).
/// ─────────────────────────────────────────────────────────────────────────

enum FrameShape { arch, oval, jharokha, polaroid, rounded, circle }

/// How one kind of line is set in a design.
class RoleStyle {
  /// The Latin face; Malayalam/Devanagari fall back per [bold].
  final String family;
  final bool bold;

  /// Size in card pixels (the card is 1080 wide) at text size 1.0.
  final double size;

  /// 'ink' | 'body' | 'soft' | 'foil' | 'party'
  final String colour;
  final double letterSpacing;
  final double height;

  /// More lines than this and the line shrinks instead (a fit rule, not a
  /// cut: nothing is ever hidden).
  final int maxLines;

  /// Share of the text column this line may use.
  final double widthFactor;

  const RoleStyle({
    required this.family,
    this.bold = false,
    required this.size,
    this.colour = 'ink',
    this.letterSpacing = 0,
    this.height = 1.2,
    this.maxLines = 2,
    this.widthFactor = 1,
  });
}

/// One design's proportions for one card size.
class TemplateLayout {
  /// Nothing (words or photo) goes outside this.
  final EdgeInsets safe;

  /// "Happy Birthday" above the photo instead of below it.
  final bool headlineFirst;

  /// The photo's zone as shares of the card: its preferred and smallest
  /// height, and its widest.
  final double photoMaxH;
  final double photoMinH;
  final double photoMaxW;

  /// Room kept round the photo for its mat, ring or polaroid card.
  final EdgeInsets framePad;

  /// The frame follows the photo's own shape within these, so the whole
  /// photo shows by default (no face cut off).
  final double aspectMin;
  final double aspectMax;

  /// The text column, as a share of the card's width.
  final double textWidth;

  /// Space between lines, and between the photo and the words.
  final double gap;
  final double photoGap;

  /// Height of the ornament between the name and the wishes (0 = none).
  final double divider;

  /// Printed before the "from" line — typography, not words.
  final String fromPrefix;

  final Map<String, RoleStyle> roles;

  const TemplateLayout({
    required this.safe,
    this.headlineFirst = false,
    this.photoMaxH = 0.46,
    this.photoMinH = 0.26,
    this.photoMaxW = 0.62,
    this.framePad = const EdgeInsets.all(30),
    this.aspectMin = 0.7,
    this.aspectMax = 1.45,
    this.textWidth = 0.74,
    this.gap = 14,
    this.photoGap = 26,
    this.divider = 30,
    this.fromPrefix = '— ',
    required this.roles,
  });
}

/// A line placed on the card.
class TextBlock {
  final String field;

  /// Exactly his words (the painter may add [prefix] as typography).
  final String text;
  final String prefix;
  final RoleStyle role;
  final double fontSize;
  final Offset offset;
  final double width;
  final double height;

  /// Each drawn line's box, in card pixels — ornaments keep clear of them.
  final List<Rect> lines;

  const TextBlock({
    required this.field,
    required this.text,
    required this.prefix,
    required this.role,
    required this.fontSize,
    required this.offset,
    required this.width,
    required this.height,
    required this.lines,
  });

  Rect get rect => offset & Size(width, height);
}

/// The finished arrangement of one card.
class PosterLayout {
  final Size size;
  final double scale;
  final Rect? zone;
  final Rect? frame;
  final FrameShape shape;
  final bool emblem;
  final List<TextBlock> blocks;
  final Offset? divider;
  final double dividerWidth;
  final Rect? signature;
  final List<PosterNeed> needs;

  const PosterLayout({
    required this.size,
    required this.scale,
    required this.zone,
    required this.frame,
    required this.shape,
    required this.emblem,
    required this.blocks,
    required this.divider,
    required this.dividerWidth,
    required this.signature,
    required this.needs,
  });

  bool get fits => needs.isEmpty;

  /// Every line's box, grown by [pad] — where ornaments must not go.
  List<Rect> keepOut([double pad = 14]) => [
        for (final b in blocks)
          for (final l in b.lines) l.inflate(pad),
        if (signature != null) signature!.inflate(pad),
      ];

  TextBlock? block(String field) {
    for (final b in blocks) {
      if (b.field == field) return b;
    }
    return null;
  }
}

/// Builds the painter for one line. [paintStyle] swaps in the foil shader
/// or party colours when drawing; layout uses a plain colour.
TextPainter buildLinePainter(
  String text,
  RoleStyle role,
  double size,
  PosterPalette palette, {
  String prefix = '',
  Paint? foreground,
  List<Shadow>? shadows,
}) {
  final indic = scriptOf(text) != 'en';
  final base = TextStyle(
    fontFamily: role.family,
    fontFamilyFallback: role.bold ? PosterFonts.fallbackBold : PosterFonts.fallbackRegular,
    // Malayalam and Devanagari letters sit smaller than Latin ones at the
    // same size; a touch more keeps his words as readable as English.
    fontSize: indic ? size * 1.06 : size,
    // Indic scripts keep their own generous line metrics: a tight Latin
    // line height would let vowel signs collide between lines.
    height: indic ? null : role.height,
    letterSpacing: indic ? 0 : role.letterSpacing * size / 40,
    color: foreground == null ? colourFor(role.colour, palette) : null,
    foreground: foreground,
    shadows: shadows,
  );
  InlineSpan span;
  if (role.colour == 'party' && !indic && foreground == null) {
    // One colour per letter, like balloons on a string — inks deep enough
    // to read on a pale sky (the balloons' own pastels are not).
    final cols = palette.deep ? palette.party : _partyInk;
    var i = 0;
    span = TextSpan(style: base, children: [
      if (prefix.isNotEmpty) TextSpan(text: prefix),
      for (final ch in text.split(''))
        TextSpan(
            text: ch,
            style: ch.trim().isEmpty
                ? null
                : TextStyle(color: cols[(i++) % cols.length])),
    ]);
  } else {
    span = TextSpan(
      style: base,
      children: [
        if (prefix.isNotEmpty)
          TextSpan(
              text: prefix,
              style: foreground == null
                  ? TextStyle(color: colourFor('soft', palette))
                  : null),
        TextSpan(text: text),
      ],
    );
  }
  return TextPainter(
    text: span,
    textAlign: TextAlign.center,
    textDirection: TextDirection.ltr,
    textScaler: TextScaler.noScaling,
  );
}

const _partyInk = [
  Color(0xFFE03E52),
  Color(0xFFE8740C),
  Color(0xFF2B9348),
  Color(0xFF1C6FD1),
  Color(0xFF7248D6),
  Color(0xFFD1356E),
];

Color colourFor(String role, PosterPalette p) => switch (role) {
      'body' => p.body,
      'soft' => p.soft,
      'foil' => p.deep ? p.foil[1] : foilTextColours(p)[1],
      'party' => p.ink,
      _ => p.ink,
    };

/// Foil for WORDS: on a light card the metallic gradient is darkened until
/// it reads (gold on cream is 2:1 otherwise).
List<Color> foilTextColours(PosterPalette p) {
  if (p.deep) return p.foil;
  // A warm ink (rose, gold, ivory's brown-black) darkens the foil toward
  // itself, so rose-gold stays rosy. A cool ink (navy, violet, forest)
  // would cancel the gold into grey — "Happy 25th Birthday" in a muddy
  // khaki on the blue card (review, 2026-09-26) — so there the gold
  // deepens toward a warm antique brown and stays gold.
  final hue = HSLColor.fromColor(p.ink).hue;
  final warm = hue < 60 || hue > 300;
  final toward = warm ? p.ink : const Color(0xFF5A3A0A);
  return [
    for (final c in p.foil)
      Color.lerp(Color.lerp(c, toward, 0.5)!, const Color(0xFF000000), 0.08)!,
  ];
}

/// Sets one line in its column, centred, WITHOUT a lonely last word: a
/// wish that ends "…laughter and / light." reads like a mistake on a card.
/// First a hair smaller type is tried (it often pulls the word back up),
/// then narrower lines so the last one has company. Never a cut.
({TextPainter painter, double size, double width}) settleLines(
  String text,
  RoleStyle role,
  double size,
  double width,
  PosterPalette palette, {
  String prefix = '',
}) {
  TextPainter lay(double fs, double bw) =>
      buildLinePainter(text, role, fs, palette, prefix: prefix)
        // min = max: the paragraph IS the column, so centring is centring.
        ..layout(minWidth: bw, maxWidth: bw);
  final first = lay(size, width);
  if (!hasOrphan(first)) return (painter: first, size: size, width: width);
  final count = first.computeLineMetrics().length;
  for (var k = 0.98; k >= 0.9 - 1e-9; k -= 0.02) {
    final p = lay(size * k, width);
    if (p.computeLineMetrics().length < count && !hasOrphan(p)) {
      return (painter: p, size: size * k, width: width);
    }
  }
  for (var k = 0.96; k >= 0.66 - 1e-9; k -= 0.03) {
    final p = lay(size, width * k);
    if (p.minIntrinsicWidth > width * k + 0.5) break;
    if (p.computeLineMetrics().length > count) break;
    if (!hasOrphan(p)) return (painter: p, size: size, width: width * k);
  }
  return (painter: first, size: size, width: width);
}

/// True when a wrapped paragraph ends in a single word on its own line.
bool hasOrphan(TextPainter p) {
  final metrics = p.computeLineMetrics();
  if (metrics.length < 2) return false;
  final plain = p.plainText;
  final ranges = [
    for (final m in metrics)
      p.getLineBoundary(p.getPositionForOffset(Offset(m.left + m.width / 2, m.baseline))),
  ];
  bool endsParagraph(TextRange r) =>
      r.end >= plain.length ||
      plain.substring(r.start, r.end).endsWith('\n') ||
      plain[r.end] == '\n';
  for (var i = 1; i < ranges.length; i++) {
    if (!endsParagraph(ranges[i]) || endsParagraph(ranges[i - 1])) continue;
    final words = plain
        .substring(ranges[i].start, ranges[i].end)
        .trim()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty);
    if (words.length == 1) return true;
  }
  return false;
}

const _order = ['headline', 'age', 'name', 'message', 'from', 'date'];

/// Lays out [spec] in a design. [photoAspect] is width/height of his photo
/// (null: no photo, the design's emblem stands in). [signatureAspect] is
/// set when a signature will be drawn.
PosterLayout layoutPoster({
  required PosterSpec spec,
  required TemplateLayout t,
  required FrameShape Function(double aspect) shapeFor,
  required PosterPalette palette,
  double? photoAspect,
  double? signatureAspect,
}) {
  final px = posterPixels(spec.format);
  final size = Size(px.w.toDouble(), px.h.toDouble());
  final w = size.width, h = size.height;
  final colW = w * t.textWidth;
  final avail = h - t.safe.vertical;
  final hasPhoto = photoAspect != null && photoAspect > 0;
  final shape = hasPhoto ? shapeFor(photoAspect) : FrameShape.circle;

  final lines = <String, String>{
    'headline': spec.printedHeadline,
    'age': ageLine(spec) ?? '',
    'name': spec.name.trim(),
    'message': spec.message.trim(),
    'from': spec.from.trim(),
    'date': spec.date.trim(),
  };
  final fields = [
    for (final f in _order)
      if (lines[f]!.isNotEmpty) f,
  ];
  // Above the photo when the design leads with the heading.
  final above = t.headlineFirst
      ? [for (final f in fields) if (f == 'headline' || f == 'age') f]
      : const <String>[];
  final below = [for (final f in fields) if (!above.contains(f)) f];

  // ── each line's own ceiling: the largest size at which no word breaks
  //    and it keeps to its line count.
  final needs = <PosterNeed>[];
  final ceiling = <String, double>{};
  for (final f in fields) {
    final role = t.roles[f]!;
    final width = colW * role.widthFactor;
    var s = role.size * 1.7;
    while (true) {
      final p = buildLinePainter(lines[f]!, role, s, palette,
          prefix: f == 'from' ? t.fromPrefix : '')
        ..layout(maxWidth: width);
      final ok = p.minIntrinsicWidth <= width + 0.5 &&
          (f == 'message' || p.computeLineMetrics().length <= role.maxLines);
      if (ok) break;
      s *= 0.96;
      if (s < role.size * 0.42) {
        needs.add(PosterNeed(field: f, reason: 'no_room', max: posterLimits[f]));
        break;
      }
    }
    ceiling[f] = s;
  }

  double sigH(double s) => signatureAspect == null
      ? 0
      : math.min(h * 0.085 * s.clamp(0.8, 1.25), colW * 0.36 / signatureAspect);

  // ── the words' total height at text scale [s].
  ({
    double height,
    Map<String, TextPainter> painters,
    Map<String, double> sizes,
    Map<String, double> widths,
  }) measure(double s) {
    final painters = <String, TextPainter>{};
    final sizes = <String, double>{};
    final widths = <String, double>{};
    var total = 0.0;
    for (final f in fields) {
      final role = t.roles[f]!;
      final fs = math.min(role.size * s, ceiling[f]!);
      final bw = colW * role.widthFactor;
      final settled = settleLines(lines[f]!, role, fs, bw, palette,
          prefix: f == 'from' ? t.fromPrefix : '');
      painters[f] = settled.painter;
      sizes[f] = settled.size;
      widths[f] = settled.width;
      total += settled.painter.height;
    }
    final g = t.gap * s.clamp(0.7, 1.2);
    final between = math.max(0, above.length - 1) + math.max(0, below.length - 1);
    total += between * g;
    if (t.divider > 0 && fields.contains('message') && fields.contains('name')) {
      total += t.divider * s.clamp(0.7, 1.1);
    }
    final sh = sigH(s);
    if (sh > 0) total += sh + g * 0.5;
    return (height: total, painters: painters, sizes: sizes, widths: widths);
  }

  // ── the photo zone at its preferred size.
  final padH = t.framePad.vertical, padW = t.framePad.horizontal;
  final aspect = hasPhoto ? photoAspect.clamp(t.aspectMin, t.aspectMax) : 1.0;
  double zoneFor(double maxZoneH) {
    final maxFrameH = maxZoneH - padH;
    final maxFrameW = w * t.photoMaxW - padW;
    final fh = math.min(maxFrameH, maxFrameW / aspect);
    return fh + padH;
  }

  final emblemScale = hasPhoto ? 1.0 : 0.62;
  final prefZone = zoneFor(h * t.photoMaxH * emblemScale);
  final minZone = math.min(prefZone, h * t.photoMinH * (hasPhoto ? 1 : 0.8));
  final headGap = above.isNotEmpty ? t.photoGap : 0.0;
  final fixed = t.photoGap + headGap;

  final start = spec.textScale;
  double? scale;
  double zone = prefZone;
  // 1. The words give up a little size; the photo stays as it is.
  for (var s = start; s >= start * 0.84 - 1e-9 && s >= 0.6; s -= 0.02) {
    if (measure(s).height + prefZone + fixed <= avail) {
      scale = s;
      break;
    }
  }
  // 2. The photo gives up room, down to its smallest.
  if (scale == null) {
    final s = math.max(0.6, start * 0.84);
    final left = avail - fixed - measure(s).height;
    if (left >= minZone) {
      scale = s;
      zone = math.min(prefZone, left);
    }
  }
  // 3. The words shrink again, to the floor.
  if (scale == null) {
    for (var s = math.max(0.6, start * 0.84); s >= 0.6 - 1e-9; s -= 0.02) {
      final left = avail - fixed - measure(s).height;
      if (left >= minZone) {
        scale = s;
        zone = math.min(prefZone, left);
        break;
      }
    }
  }
  if (scale == null) {
    // Nothing fits: ask for the longest line to be shortened. The layout
    // is still produced (at the floor) so the screen can show it.
    scale = 0.6;
    zone = minZone;
    final longest = fields.contains('message')
        ? 'message'
        : (fields.contains('name') ? 'name' : 'headline');
    if (!needs.any((n) => n.field == longest)) {
      needs.add(PosterNeed(field: longest, reason: 'no_room', max: posterLimits[longest]));
    }
  }

  final m = measure(scale);
  final slack = math.max(0.0, avail - m.height - zone - fixed);
  final g = t.gap * scale.clamp(0.7, 1.2);
  // A little of any spare room separates the photo from the words; the
  // rest centres the whole arrangement.
  final extraPhotoGap = math.min(slack * 0.3, 44.0);
  var y = t.safe.top + (slack - extraPhotoGap) / 2;

  final blocks = <TextBlock>[];
  Offset? dividerAt;
  Rect? zoneRect, frameRect, sigRect;

  void place(String f) {
    final p = m.painters[f]!;
    final role = t.roles[f]!;
    final bw = m.widths[f]!;
    final x = (w - bw) / 2;
    final metrics = p.computeLineMetrics();
    blocks.add(TextBlock(
      field: f,
      text: lines[f]!,
      prefix: f == 'from' ? t.fromPrefix : '',
      role: role,
      fontSize: m.sizes[f]!,
      offset: Offset(x, y),
      width: bw,
      height: p.height,
      lines: [
        for (final lm in metrics)
          Rect.fromLTWH(x + lm.left, y + lm.baseline - lm.ascent, lm.width,
              lm.ascent + lm.descent),
      ],
    ));
    y += p.height;
  }

  void placeZone() {
    zoneRect = Rect.fromLTWH(0, y, w, zone);
    final fh = zone - padH;
    final fw = math.min(fh * aspect, w * t.photoMaxW - padW);
    final fhh = fw / aspect;
    frameRect = Rect.fromLTWH(
        (w - fw) / 2 + (t.framePad.left - t.framePad.right) / 2,
        y + t.framePad.top + (fh - fhh) / 2,
        fw,
        fhh);
    y += zone;
  }

  var first = true;
  if (above.isNotEmpty) {
    for (var i = 0; i < above.length; i++) {
      if (i > 0) y += g;
      place(above[i]);
    }
    y += t.photoGap;
    placeZone();
    y += t.photoGap + extraPhotoGap;
  } else {
    placeZone();
    y += t.photoGap + extraPhotoGap;
  }
  final sh = sigH(scale);
  void placeSignature() {
    if (sh <= 0 || sigRect != null) return;
    y += g * 0.5;
    final sw = sh * signatureAspect!;
    sigRect = Rect.fromLTWH((w - sw) / 2, y, sw, sh);
    y += sh;
  }

  for (final f in below) {
    // His signature sits under the "from" line, above the date.
    if (f == 'date') placeSignature();
    if (!first) y += g;
    first = false;
    if (f == 'message' && t.divider > 0 && fields.contains('name')) {
      final dh = t.divider * scale.clamp(0.7, 1.1);
      dividerAt = Offset(w / 2, y + dh / 2 - g / 2);
      y += dh;
    }
    place(f);
  }
  placeSignature();

  return PosterLayout(
    size: size,
    scale: scale,
    zone: zoneRect,
    frame: frameRect,
    shape: shape,
    emblem: !hasPhoto,
    blocks: blocks,
    divider: dividerAt,
    dividerWidth: math.min(colW * 0.42, 260),
    signature: sigRect,
    needs: needs,
  );
}
