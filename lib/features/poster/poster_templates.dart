import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import 'poster_decor.dart';
import 'poster_fonts.dart';
import 'poster_layout.dart';
import 'poster_palettes.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  THE GIFT-CARD DESIGNS.
///
///  Owner, 2026-09-26: "create it like a GIFT CARD, not just a photo — a
///  photo with some designs like flowers or something, with 'Happy
///  Birthday' and the caption or content the user gives."
///
///  Six designs, each a set of proportions (TemplateLayout) plus its own
///  painting: paper, border, the photo's frame, and the ornaments. The
///  words are set by poster_layout.dart and drawn by poster_painter.dart;
///  a design only decides WHERE and in WHICH face, never WHAT.
///
///  Ornaments keep clear of every line of text (PosterLayout.keepOut): a
///  bouquet that would touch a word is drawn smaller instead, measured by
///  where its art really paints (poster_decor.dart footprints), and left
///  out if even small it would touch one. poster_visual_loop_test proves it
///  pixel by pixel for every design.
/// ─────────────────────────────────────────────────────────────────────────

/// What a design needs while painting.
class PosterPaintContext {
  final Size size;
  final PosterPalette p;
  final PosterLayout l;
  final int seed;
  const PosterPaintContext(this.size, this.p, this.l, this.seed);

  double get w => size.width;
  double get h => size.height;
  Rect get card => Offset.zero & size;
  LinearGradient get foil => p.foilGradient();
  LinearGradient get foilText => LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: foilTextColours(p),
      );
  math.Random rnd(int salt) => math.Random(seed * 7919 + salt);
  List<Rect> get keepOut => l.keepOut();
}

abstract class PosterTemplate {
  const PosterTemplate();

  String get id;
  String get title;

  /// One line for the carousel.
  String get blurb;

  /// Whether a colour is drawn in its deep mood in this design.
  bool deepFor(String colour) => false;

  FrameShape shapeFor(double aspect);

  TemplateLayout layout(String format);

  void paintBackground(Canvas c, PosterPaintContext x);

  /// Draws the mat, rings and shadow round [frame], calling [content] to
  /// draw the photo (or the emblem) clipped to [clip].
  void paintFrame(Canvas c, PosterPaintContext x, Rect frame, FrameShape shape,
      void Function(Path clip) content);

  void paintOrnaments(Canvas c, PosterPaintContext x);

  void paintDivider(Canvas c, PosterPaintContext x, Offset at, double half) {
    paintDivider0(c, x, at, half);
  }

  /// A soft lift under words on deep grounds.
  List<Shadow>? textShadows(PosterPalette p) => p.deep
      ? const [Shadow(color: Color(0x66000000), blurRadius: 8, offset: Offset(0, 2))]
      : null;
}

const posterTemplateList = <PosterTemplate>[
  FloralTemplate(),
  GoldenTemplate(),
  BalloonsTemplate(),
  MandalaTemplate(),
  GardenTemplate(),
  IvoryTemplate(),
];

PosterTemplate posterTemplate(String id) =>
    posterTemplateList.firstWhere((t) => t.id == id, orElse: () => posterTemplateList.first);

// ───────────────────────────── shared helpers ───────────────────────────

Path framePath(FrameShape s, Rect r) {
  switch (s) {
    case FrameShape.arch:
      final ah = math.min(r.width / 2, r.height * 0.42);
      return Path()
        ..moveTo(r.left, r.bottom)
        ..lineTo(r.left, r.top + ah)
        ..arcTo(Rect.fromLTWH(r.left, r.top, r.width, ah * 2), math.pi, math.pi, false)
        ..lineTo(r.right, r.bottom)
        ..close();
    case FrameShape.oval:
    case FrameShape.circle:
      return Path()..addOval(r);
    case FrameShape.jharokha:
      final ah = math.min(r.width * 0.62, r.height * 0.44);
      final cx = r.center.dx;
      return Path()
        ..moveTo(r.left, r.bottom)
        ..lineTo(r.left, r.top + ah)
        ..cubicTo(r.left, r.top + ah * 0.4, cx - r.width * 0.3, r.top + ah * 0.18, cx, r.top)
        ..cubicTo(cx + r.width * 0.3, r.top + ah * 0.18, r.right, r.top + ah * 0.4, r.right,
            r.top + ah)
        ..lineTo(r.right, r.bottom)
        ..close();
    case FrameShape.polaroid:
      return Path()..addRect(r);
    case FrameShape.rounded:
      return Path()
        ..addRRect(RRect.fromRectAndRadius(r, Radius.circular(r.shortestSide * 0.035)));
  }
}

void dropShadow(Canvas c, Path p, {double blur = 18, double dy = 10, double a = 0.2}) {
  c.drawPath(
      p.shift(Offset(0, dy)),
      Paint()
        ..color = Color.fromRGBO(30, 20, 10, a)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, blur));
}

void paperGround(Canvas c, PosterPaintContext x, {double glowAt = 0.28, double grain = 0.03}) {
  final p = x.p;
  c.drawRect(
      x.card,
      Paint()
        ..shader = ui.Gradient.linear(
            Offset.zero, Offset(0, x.h), [p.bgTop, p.bgBottom]));
  c.drawRect(
      x.card,
      Paint()
        ..shader = ui.Gradient.radial(Offset(x.w / 2, x.h * glowAt), x.w * 0.85,
            [p.glow.withValues(alpha: p.deep ? 0.55 : 0.7), p.glow.withValues(alpha: 0)]));
  paintPaperGrain(c, x.size, p.deep ? const Color(0xFFFFFFFF) : p.ink, x.seed,
      opacity: p.deep ? grain * 0.8 : grain);
}

/// Scale (≤1) at which a circle of [r] round [o] clears every word.
double clearScale(Offset o, double r, List<Rect> keepOut, {double min = 0.45}) {
  bool hits(double s) => keepOut.any((k) {
        final dx = math.max(k.left - o.dx, math.max(0, o.dx - k.right));
        final dy = math.max(k.top - o.dy, math.max(0, o.dy - k.bottom));
        return dx * dx + dy * dy < (r * s) * (r * s);
      });
  var s = 1.0;
  while (s > min && hits(s)) {
    s -= 0.04;
  }
  return s;
}

void paintDivider0(Canvas c, PosterPaintContext x, Offset at, double half) {
  final bounds = Rect.fromCenter(center: at, width: half * 2, height: 20);
  paintDivider(c, at, half, foilStroke(x.foilText, bounds, 2), foilFill(x.foilText, bounds),
      gem: 8);
}

/// Mat + single foil line round any frame shape.
void matAndLine(Canvas c, PosterPaintContext x, Rect frame, FrameShape shape,
    {double mat = 14, double line = 3, double lineAt = 22, double shadow = 0.2}) {
  final matPath = framePath(shape, frame.inflate(mat));
  dropShadow(c, matPath, a: shadow);
  c.drawPath(matPath, Paint()..color = x.p.mat);
  final outer = frame.inflate(lineAt);
  c.drawPath(framePath(shape, outer), foilStroke(x.foil, outer, line));
}

// A standard 4:5 / 9:16 pair of role sets, tuned per design below.
Map<String, RoleStyle> _roles({
  required String headlineFamily,
  double headline = 60,
  String headlineColour = 'foil',
  double headlineSpacing = 0,
  double name = 118,
  String nameColour = 'ink',
  double message = 38,
  double from = 44,
  String fromColour = 'ink',
  double date = 27,
}) =>
    {
      'headline': RoleStyle(
        family: headlineFamily,
        bold: headlineFamily == PosterFonts.displayBold || headlineFamily == PosterFonts.round,
        size: headline,
        colour: headlineColour,
        letterSpacing: headlineSpacing,
        height: 1.12,
        maxLines: 2,
      ),
      'name': RoleStyle(
        family: PosterFonts.displayItalic,
        bold: true,
        size: name,
        colour: nameColour,
        height: 1.04,
        maxLines: 2,
      ),
      'message': RoleStyle(
        family: PosterFonts.display,
        size: message,
        colour: 'body',
        height: 1.38,
        maxLines: 99,
        widthFactor: 0.96,
      ),
      // A non-English heading's age, as a numeral (the fixture's words_ml).
      'age': RoleStyle(
        family: PosterFonts.displayBold,
        bold: true,
        size: headline * 1.2,
        colour: 'foil',
        height: 1.0,
        maxLines: 1,
      ),
      'from': RoleStyle(
        family: PosterFonts.displayItalic,
        size: from,
        colour: fromColour,
        height: 1.15,
        maxLines: 2,
      ),
      'date': RoleStyle(
        family: PosterFonts.display,
        size: date,
        colour: 'soft',
        letterSpacing: 2.4,
        height: 1.2,
        maxLines: 1,
      ),
    };

// ───────────────────────────── 1. Floral Blush ──────────────────────────

class FloralTemplate extends PosterTemplate {
  const FloralTemplate();
  @override
  String get id => 'floral_blush';
  @override
  String get title => 'Floral Blush';
  @override
  String get blurb => 'Roses and peonies in the corners';

  @override
  FrameShape shapeFor(double aspect) => FrameShape.arch;

  @override
  TemplateLayout layout(String format) {
    final story = format == 'story';
    return TemplateLayout(
      safe: story
          ? const EdgeInsets.fromLTRB(96, 190, 96, 190)
          : const EdgeInsets.fromLTRB(96, 96, 96, 92),
      photoMaxH: story ? 0.46 : 0.45,
      photoMinH: 0.25,
      photoMaxW: 0.6,
      framePad: const EdgeInsets.all(30),
      aspectMin: 0.68,
      aspectMax: 1.45,
      textWidth: 0.7,
      gap: 12,
      photoGap: 22,
      divider: 30,
      roles: _roles(headlineFamily: PosterFonts.displayItalic, headline: 62),
    );
  }

  @override
  void paintBackground(Canvas c, PosterPaintContext x) {
    paperGround(c, x, glowAt: 0.3);
    final r1 = Rect.fromLTRB(34, 34, x.w - 34, x.h - 34);
    c.drawRRect(RRect.fromRectAndRadius(r1, const Radius.circular(22)),
        foilStroke(x.foil, r1, 3));
    final r2 = r1.deflate(12);
    c.drawRRect(
        RRect.fromRectAndRadius(r2, const Radius.circular(14)),
        foilStroke(x.foil, r2, 1.2)
          ..color = const Color(0x99000000));
  }

  @override
  void paintFrame(Canvas c, PosterPaintContext x, Rect frame, FrameShape shape,
      void Function(Path clip) content) {
    matAndLine(c, x, frame, shape, mat: 14, lineAt: 22, line: 3);
    content(framePath(shape, frame));
    final inner = frame.inflate(5);
    c.drawPath(framePath(shape, inner),
        foilStroke(x.foil, inner, 1.2)..color = const Color(0x80000000));
  }

  static const _fillers = [
    Offset(318, 44), Offset(300, 104), Offset(338, 88), Offset(44, 318),
    Offset(104, 300), Offset(88, 338), Offset(170, 232),
  ];

  /// Where [_bouquet] paints — its sprigs reach ~440 px from the corner,
  /// further than the 360 px circle that used to guard the date.
  static final Footprint _bouquetPrint = [
    ...sprigFootprint(const Offset(215, 70), 1.75, 190, bend: 0.12),
    ...sprigFootprint(const Offset(70, 215), 2.95, 190, bend: -0.12),
    ...leafFootprint(const Offset(160, 150), 2.3, 150, 64),
    ...leafFootprint(const Offset(185, 95), 1.6, 130, 56),
    ...leafFootprint(const Offset(95, 185), 3.1, 130, 56),
    ...leafFootprint(const Offset(250, 150), 2.0, 96, 42),
    (const Offset(240, 48), 66 * 1.12),
    (const Offset(52, 238), 52 * 1.12),
    (const Offset(112, 108), 90 * 1.12),
    (const Offset(222, 178), 30 * 1.12),
    for (final f in _fillers) (f, 11.0),
  ];

  static Footprint _sprayPrint(double angle) => [
        ...sprigFootprint(Offset.zero, angle, 170, bend: 0.2),
        (Offset(math.sin(angle) * 150, -math.cos(angle) * 150), 11.0),
      ];

  static final Footprint _footPrint = [
    ...leafFootprint(Offset.zero, -1.1, 78, 34),
    ...leafFootprint(const Offset(4, 4), -0.2, 70, 30),
    ...leafFootprint(const Offset(6, 2), 1.9, 60, 26),
    (Offset.zero, 34 * 1.12),
    (const Offset(40, 14), 20 * 1.12),
    (const Offset(-30, 26), 9.0),
  ];

  void _bouquet(Canvas c, PosterPaintContext x) {
    final p = x.p;
    // Leaves and sprigs behind the blooms.
    paintSprig(c, const Offset(215, 70), 1.75, 190,
        light: p.leafLight, dark: p.leaf, leaves: 7, bend: 0.12);
    paintSprig(c, const Offset(70, 215), 2.95, 190,
        light: p.leafLight, dark: p.leaf, leaves: 7, bend: -0.12);
    paintLeaf(c, const Offset(160, 150), 2.3, 150, 64, light: p.leafLight, dark: p.leafDark);
    paintLeaf(c, const Offset(185, 95), 1.6, 130, 56, light: p.leafLight, dark: p.leafDark);
    paintLeaf(c, const Offset(95, 185), 3.1, 130, 56, light: p.leafLight, dark: p.leafDark);
    paintLeaf(c, const Offset(250, 150), 2.0, 96, 42, light: p.leafLight, dark: p.leaf);
    paintPeony(c, const Offset(240, 48), 66,
        light: p.petal2Light, mid: p.petal2, deep: p.petal2Deep, rot: 0.4);
    paintRose(c, const Offset(52, 238), 52,
        light: p.petalLight, mid: p.petal, deep: p.petalDeep, rot: 1.1);
    paintRose(c, const Offset(112, 108), 90,
        light: p.petalLight, mid: p.petal, deep: p.petalDeep, rot: 0.2);
    paintBlossom(c, const Offset(222, 178), 30,
        light: p.petal2Light, mid: p.petal2, centre: p.petal2Deep, rot: 0.3);
    for (final f in _fillers) {
      paintFiller(c, f, 9, const Color(0xFFFFFFFF), p.petalLight);
    }
  }

  @override
  void paintOrnaments(Canvas c, PosterPaintContext x) {
    final ko = x.keepOut;
    // Top-left and bottom-right bouquets, drawn smaller if a word is near.
    for (final corner in [Offset.zero, Offset(x.w, x.h)]) {
      final rot = corner == Offset.zero ? 0.0 : math.pi;
      final s = fitAt(_bouquetPrint, corner, ko, rot: rot, min: 0.4);
      if (s == null) continue;
      c.save();
      c.translate(corner.dx, corner.dy);
      c.rotate(rot);
      c.scale(s);
      _bouquet(c, x);
      c.restore();
    }
    // Light sprigs in the other two corners for balance.
    for (final (corner, angle) in [
      (Offset(x.w - 30, 30), -2.2),
      (Offset(30, x.h - 30), 0.95),
    ]) {
      final s = fitAt(_sprayPrint(angle), corner, ko, min: 0.4);
      if (s == null) continue;
      c.save();
      c.translate(corner.dx, corner.dy);
      c.scale(s);
      paintSprig(c, Offset.zero, angle, 170,
          light: x.p.leafLight, dark: x.p.leaf, leaves: 6, bend: 0.2);
      paintFiller(c, Offset(math.sin(angle) * 150, -math.cos(angle) * 150), 9,
          const Color(0xFFFFFFFF), x.p.petalLight);
      c.restore();
    }
    // A small spray at each foot of the arch.
    final f = x.l.frame;
    if (f != null && !x.l.emblem) {
      for (final side in [-1.0, 1.0]) {
        final o = Offset(side < 0 ? f.left - 6 : f.right + 6, f.bottom + 2);
        final s = fitAt(_footPrint, o, ko, mirror: side < 0, min: 0.5);
        if (s == null) continue;
        c.save();
        c.translate(o.dx, o.dy);
        c.scale(side * s, s);
        final p = x.p;
        paintLeaf(c, const Offset(0, 0), -1.1, 78, 34, light: p.leafLight, dark: p.leaf);
        paintLeaf(c, const Offset(4, 4), -0.2, 70, 30, light: p.leafLight, dark: p.leafDark);
        paintLeaf(c, const Offset(6, 2), 1.9, 60, 26, light: p.leafLight, dark: p.leaf);
        paintRose(c, const Offset(0, 0), 34,
            light: p.petalLight, mid: p.petal, deep: p.petalDeep, rot: 0.8);
        paintBlossom(c, const Offset(40, 14), 20,
            light: p.petal2Light, mid: p.petal2, centre: p.petal2Deep);
        paintFiller(c, const Offset(-30, 26), 7, const Color(0xFFFFFFFF), p.petalLight);
        c.restore();
      }
    }
  }

  @override
  void paintDivider(Canvas c, PosterPaintContext x, Offset at, double half) {
    final bounds = Rect.fromCenter(center: at, width: half * 2, height: 20);
    final line = foilStroke(x.foilText, bounds, 1.8)..strokeCap = StrokeCap.round;
    c.drawLine(at + Offset(-half * 0.8, 0), at + const Offset(-26, 0), line);
    c.drawLine(at + const Offset(26, 0), at + Offset(half * 0.8, 0), line);
    paintBlossom(c, at, 14,
        light: x.p.petalLight, mid: x.p.petal, centre: x.p.petalDeep, shadow: false);
  }
}

// ─────────────────────────── 2. Golden Celebration ──────────────────────

class GoldenTemplate extends PosterTemplate {
  const GoldenTemplate();
  @override
  String get id => 'golden_celebration';
  @override
  String get title => 'Golden Celebration';
  @override
  String get blurb => 'Gold frame, confetti and stars';

  @override
  bool deepFor(String colour) => colour != 'white';

  @override
  FrameShape shapeFor(double aspect) => FrameShape.oval;

  @override
  TemplateLayout layout(String format) {
    final story = format == 'story';
    return TemplateLayout(
      safe: story
          ? const EdgeInsets.fromLTRB(100, 200, 100, 180)
          : const EdgeInsets.fromLTRB(100, 100, 100, 92),
      headlineFirst: true,
      photoMaxH: story ? 0.44 : 0.42,
      photoMinH: 0.24,
      photoMaxW: 0.6,
      framePad: const EdgeInsets.all(36),
      aspectMin: 0.72,
      aspectMax: 1.4,
      textWidth: 0.74,
      gap: 12,
      photoGap: 18,
      divider: 28,
      roles: _roles(
        headlineFamily: PosterFonts.displayBold,
        headline: 64,
        headlineSpacing: 1.2,
        name: 116,
        fromColour: 'foil',
      ),
    );
  }

  @override
  void paintBackground(Canvas c, PosterPaintContext x) {
    paperGround(c, x, glowAt: 0.36, grain: 0.02);
    final p = x.p;
    final rnd = x.rnd(1);
    // Gold dust and soft bokeh.
    for (var i = 0; i < 26; i++) {
      final o = Offset(rnd.nextDouble() * x.w, rnd.nextDouble() * x.h);
      c.drawCircle(
          o,
          18 + rnd.nextDouble() * 40,
          Paint()
            ..color = p.foil[1].withValues(alpha: p.deep ? 0.06 : 0.08)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10));
    }
    final dust = <Offset>[
      for (var i = 0; i < 380; i++) Offset(rnd.nextDouble() * x.w, rnd.nextDouble() * x.h),
    ];
    c.drawPoints(
        ui.PointMode.points,
        dust,
        Paint()
          ..strokeWidth = 2.6
          ..strokeCap = StrokeCap.round
          ..color = p.foil[1].withValues(alpha: p.deep ? 0.32 : 0.35));
    // Art-deco double border with stepped corners.
    final r1 = Rect.fromLTRB(30, 30, x.w - 30, x.h - 30);
    c.drawRect(r1, foilStroke(x.foil, r1, 5));
    final r2 = r1.deflate(14);
    c.drawRect(r2, foilStroke(x.foil, r2, 1.6));
    final gem = foilFill(x.foil, x.card);
    for (final (corner, sx, sy) in [
      (r2.topLeft, 1.0, 1.0),
      (r2.topRight, -1.0, 1.0),
      (r2.bottomLeft, 1.0, -1.0),
      (r2.bottomRight, -1.0, -1.0),
    ]) {
      final line = foilStroke(x.foil, x.card, 1.6);
      c.drawLine(corner + Offset(sx * 14, sy * 14), corner + Offset(sx * 84, sy * 14), line);
      c.drawLine(corner + Offset(sx * 14, sy * 14), corner + Offset(sx * 14, sy * 84), line);
      c.drawPath(diamondPath(corner + Offset(sx * 14, sy * 14), 10), gem);
      c.drawCircle(corner + Offset(sx * 92, sy * 14), 3.2, gem);
      c.drawCircle(corner + Offset(sx * 14, sy * 92), 3.2, gem);
    }
    // Falling gold confetti, clear of words and photo.
    final avoid = [...x.keepOut, if (x.l.zone != null) x.l.frame!.inflate(40)];
    paintConfetti(c, Rect.fromLTRB(50, 50, x.w - 50, x.h - 50), x.foil.colors, x.rnd(2),
        count: 150, size: 17, avoid: avoid);
  }

  @override
  void paintFrame(Canvas c, PosterPaintContext x, Rect frame, FrameShape shape,
      void Function(Path clip) content) {
    final p = x.p;
    final glow = framePath(shape, frame.inflate(18));
    c.drawPath(
        glow,
        Paint()
          ..color = p.foil[1].withValues(alpha: p.deep ? 0.35 : 0.25)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 26));
    dropShadow(c, framePath(shape, frame.inflate(10)), a: 0.35, blur: 20);
    content(framePath(shape, frame));
    final ring = frame.inflate(6);
    c.drawPath(framePath(shape, ring), foilStroke(x.foil, ring, 11));
    final ring2 = frame.inflate(24);
    c.drawPath(framePath(shape, ring2), foilStroke(x.foil, ring2, 1.6));
    // Beads round the outer ring.
    final gem = foilFill(x.foil, ring2);
    for (final m in framePath(shape, frame.inflate(30)).computeMetrics()) {
      final n = (m.length / 26).floor();
      for (var i = 0; i < n; i++) {
        final t = m.getTangentForOffset(m.length * i / n);
        if (t != null) c.drawCircle(t.position, i.isEven ? 3.4 : 2.2, gem);
      }
    }
  }

  @override
  void paintOrnaments(Canvas c, PosterPaintContext x) {
    final ko = x.keepOut;
    final gem = foilFill(x.foil, x.card);
    final rnd = x.rnd(3);
    // Sparkles round the photo and in the top corners.
    final f = x.l.frame;
    final spots = <(Offset, double)>[
      (Offset(x.w * 0.15, x.h * 0.075), 30),
      (Offset(x.w * 0.85, x.h * 0.08), 34),
      (Offset(x.w * 0.09, x.h * 0.2), 18),
      (Offset(x.w * 0.91, x.h * 0.22), 20),
      if (f != null) ...[
        (Offset(f.right + 10, f.top + f.height * 0.12), 34),
        (Offset(f.left - 14, f.bottom - f.height * 0.1), 28),
        (Offset(f.right + 40, f.top + f.height * 0.32), 14),
        (Offset(f.left - 40, f.bottom - f.height * 0.34), 12),
      ],
      (Offset(x.w * 0.12, x.h * 0.9), 22),
      (Offset(x.w * 0.88, x.h * 0.92), 26),
    ];
    for (final (o, r) in spots) {
      final s = clearScale(o, r * 1.2, ko);
      if (s < 0.6) continue;
      paintSparkle(c, o, r * s, gem, glow: x.p.deep);
    }
    // A few stars.
    for (var i = 0; i < 9; i++) {
      final o = Offset(60 + rnd.nextDouble() * (x.w - 120), 60 + rnd.nextDouble() * (x.h - 120));
      if (clearScale(o, 22, [...ko, if (f != null) f.inflate(50)]) < 1) continue;
      c.drawPath(starPath(o, 9 + rnd.nextDouble() * 8, rot: rnd.nextDouble()), gem);
    }
  }
}

// ─────────────────────────── 3. Balloons & Confetti ─────────────────────

class BalloonsTemplate extends PosterTemplate {
  const BalloonsTemplate();
  @override
  String get id => 'balloons_confetti';
  @override
  String get title => 'Balloons & Confetti';
  @override
  String get blurb => 'Bright, playful party';

  @override
  FrameShape shapeFor(double aspect) => FrameShape.polaroid;

  @override
  TemplateLayout layout(String format) {
    final story = format == 'story';
    return TemplateLayout(
      // The words start below the bunting's lowest flag, with air: at 142
      // the flags hung among the heading's letters (review, 2026-09-26).
      safe: story
          ? const EdgeInsets.fromLTRB(70, 230, 70, 170)
          : const EdgeInsets.fromLTRB(70, 166, 70, 72),
      headlineFirst: true,
      photoMaxH: story ? 0.44 : 0.43,
      photoMinH: 0.24,
      photoMaxW: 0.56,
      framePad: const EdgeInsets.fromLTRB(40, 40, 40, 104),
      aspectMin: 0.72,
      aspectMax: 1.4,
      textWidth: 0.8,
      gap: 10,
      photoGap: 14,
      divider: 26,
      roles: _roles(
        headlineFamily: PosterFonts.round,
        headline: 76,
        headlineColour: 'party',
        name: 112,
        message: 37,
        from: 42,
      ),
    );
  }

  @override
  void paintBackground(Canvas c, PosterPaintContext x) {
    paperGround(c, x, glowAt: 0.45, grain: 0.02);
    // Clouds low on the card.
    for (final (o, w) in [
      (Offset(x.w * 0.18, x.h - 40), 380.0),
      (Offset(x.w * 0.62, x.h - 18), 460.0),
      (Offset(x.w * 0.95, x.h - 70), 300.0),
    ]) {
      paintCloud(c, o, w, opacity: x.p.deep ? 0.08 : 0.75);
    }
    final avoid = [...x.keepOut, if (x.l.frame != null) _card(x.l.frame!).inflate(26)];
    paintConfetti(c, Rect.fromLTRB(20, 120, x.w - 20, x.h - 20), x.p.party, x.rnd(4),
        count: 150, size: 20, avoid: avoid, opacity: 0.9);
  }

  Rect _card(Rect photo) => Rect.fromLTRB(photo.left - 24, photo.top - 24, photo.right + 24,
      photo.bottom + 88);

  @override
  void paintFrame(Canvas c, PosterPaintContext x, Rect frame, FrameShape shape,
      void Function(Path clip) content) {
    if (shape != FrameShape.polaroid) {
      // The emblem: a white disc with a candy ring.
      matAndLine(c, x, frame, shape, mat: 16, lineAt: 26, line: 6, shadow: 0.18);
      content(framePath(shape, frame));
      return;
    }
    c.save();
    c.translate(frame.center.dx, frame.center.dy);
    c.rotate(-0.045);
    c.translate(-frame.center.dx, -frame.center.dy);
    final card = _card(frame);
    dropShadow(c, Path()..addRect(card), blur: 16, dy: 12, a: 0.28);
    c.drawRect(card, Paint()..color = x.p.mat);
    c.drawRect(
        card,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = const Color(0x14000000));
    content(Path()..addRect(frame));
    c.drawRect(
        frame,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = const Color(0x22000000));
    // Washi tape holding it up.
    c.save();
    c.translate(card.center.dx, card.top + 4);
    c.rotate(0.07);
    final tape = Path();
    const tw = 170.0, th = 46.0;
    tape.moveTo(-tw / 2, -th / 2);
    for (var i = 0; i <= 4; i++) {
      tape.lineTo(-tw / 2 + (i.isEven ? 0 : 6), -th / 2 + th * i / 4);
    }
    tape.lineTo(tw / 2, th / 2);
    for (var i = 4; i >= 0; i--) {
      tape.lineTo(tw / 2 - (i.isEven ? 0 : 6), -th / 2 + th * i / 4);
    }
    tape.close();
    c.drawPath(tape, Paint()..color = x.p.party[1 % x.p.party.length].withValues(alpha: 0.72));
    for (var i = -3; i <= 3; i++) {
      c.drawLine(Offset(i * 22.0 - 8, -th / 2), Offset(i * 22.0 + 8, th / 2),
          Paint()
            ..strokeWidth = 5
            ..color = const Color(0x33FFFFFF));
    }
    c.restore();
    c.restore();
  }

  @override
  void paintOrnaments(Canvas c, PosterPaintContext x) {
    // Bunting across the top; its lowest flags end ~34 px above the words.
    paintBunting(c, const Offset(-30, 16), Offset(x.w + 30, 16), 46, x.p.party, flag: 62);
    final f = x.l.frame;
    final z = x.l.zone;
    if (f == null || z == null) return;
    final ko = x.keepOut;
    final cols = x.p.party;
    final card = _card(f);
    // A bunch either side of the photo, tied to its lower corners.
    final balloons = <({Offset o, double r, Color colour, double tilt, Offset tie})>[];
    final polaroid = x.l.shape == FrameShape.polaroid;
    final body = polaroid ? card : f;
    for (final side in [-1.0, 1.0]) {
      final edge = side < 0 ? body.left : body.right;
      final room = side < 0 ? edge - 20 : x.w - edge - 20;
      // As big as the room beside the photo allows — and no taller than
      // the photo's own zone, so a small photo gets a smaller bunch.
      final r = math.min((room * 0.42).clamp(40.0, 84.0), z.height / 4.7);
      final cx = side < 0 ? edge - room * 0.52 : edge + room * 0.52;
      final tie = polaroid
          ? Offset(side < 0 ? card.left + 6 : card.right - 6, card.bottom - 40)
          : Offset(side < 0 ? f.left + f.width * 0.18 : f.right - f.width * 0.18,
              f.bottom + 6);
      final top = z.top + math.max(0.0, (z.height - r * 4.9) / 2);
      final bunch = [
        (Offset(cx - side * r * 0.1, top + r * 1.1), r, 0),
        (Offset(cx + side * r * 0.45, top + r * 2.75), r * 0.9, 1),
        (Offset(cx - side * r * 0.35, top + r * 4.1), r * 0.82, 2),
      ];
      for (final (o, rr, k) in bunch.reversed) {
        final s = clearScale(o, rr * 1.15, ko, min: 0.55);
        balloons.add((
          o: o,
          r: rr * s,
          colour: cols[(k + (side < 0 ? 0 : 3)) % cols.length],
          tilt: side * 0.12 * (k - 1),
          tie: tie,
        ));
      }
    }
    // Every string first, then the balloons over them: a string drawn with
    // its own balloon cut across the ones below like a wire.
    for (final b in balloons) {
      paintBalloonString(c, b.o, b.r, b.tie, tilt: b.tilt, string: x.p.soft);
    }
    for (final b in balloons) {
      paintBalloon(c, b.o, b.r, b.colour, tilt: b.tilt);
    }
  }

  @override
  void paintDivider(Canvas c, PosterPaintContext x, Offset at, double half) {
    final cols = x.p.party;
    for (var i = -2; i <= 2; i++) {
      c.drawCircle(at + Offset(i * 22.0, 0), i == 0 ? 7 : 5,
          Paint()..color = cols[(i + 2) % cols.length]);
    }
  }
}

// ───────────────────────────── 4. Royal Mandala ─────────────────────────

class MandalaTemplate extends PosterTemplate {
  const MandalaTemplate();
  @override
  String get id => 'royal_mandala';
  @override
  String get title => 'Royal Mandala';
  @override
  String get blurb => 'Rangoli, marigolds and a palace arch';

  /// Royal by default: jewel grounds (purple, maroon, navy, emerald) with
  /// gold; gold and white keep the festive cream paper.
  @override
  bool deepFor(String colour) => colour != 'gold' && colour != 'white';

  @override
  FrameShape shapeFor(double aspect) => FrameShape.jharokha;

  @override
  TemplateLayout layout(String format) {
    final story = format == 'story';
    return TemplateLayout(
      safe: story
          ? const EdgeInsets.fromLTRB(112, 300, 112, 220)
          : const EdgeInsets.fromLTRB(112, 196, 112, 104),
      photoMaxH: story ? 0.42 : 0.4,
      photoMinH: 0.22,
      photoMaxW: 0.54,
      framePad: const EdgeInsets.fromLTRB(42, 44, 42, 40),
      aspectMin: 0.66,
      aspectMax: 1.3,
      textWidth: 0.7,
      gap: 12,
      photoGap: 18,
      divider: 32,
      roles: _roles(
        headlineFamily: PosterFonts.displayBold,
        headline: 56,
        headlineSpacing: 0.8,
        name: 112,
        message: 36,
        from: 42,
        date: 26,
      ),
    );
  }

  @override
  void paintBackground(Canvas c, PosterPaintContext x) {
    paperGround(c, x, glowAt: 0.4);
    final p = x.p;
    // A faint mandala behind the photo.
    final f = x.l.frame;
    final centre = f?.center ?? Offset(x.w / 2, x.h * 0.4);
    c.saveLayer(x.card, Paint()..color = const Color(0x14000000));
    paintMandala(c, centre, x.w * 0.56,
        foil: x.foil, fill: p.petal, fill2: p.petalLight, accent: p.petal2, line: 3);
    c.restore();
  }

  @override
  void paintFrame(Canvas c, PosterPaintContext x, Rect frame, FrameShape shape,
      void Function(Path clip) content) {
    final p = x.p;
    final matPath = framePath(shape, frame.inflate(14));
    dropShadow(c, matPath, a: 0.22);
    c.drawPath(matPath, Paint()..color = p.mat);
    content(framePath(shape, frame));
    final band = frame.inflate(21);
    c.drawPath(framePath(shape, band),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 10
          ..color = p.petal2.withValues(alpha: 0.9));
    c.drawPath(framePath(shape, frame.inflate(15)), foilStroke(x.foil, band, 2.4));
    c.drawPath(framePath(shape, frame.inflate(27)), foilStroke(x.foil, band, 2.4));
    final gem = foilFill(x.foil, band.inflate(20));
    for (final m in framePath(shape, frame.inflate(36)).computeMetrics()) {
      final n = (m.length / 24).floor();
      for (var i = 0; i < n; i++) {
        final t = m.getTangentForOffset(m.length * i / n);
        if (t != null) c.drawCircle(t.position, 3.4, gem);
      }
    }
    if (shape == FrameShape.jharokha) {
      // A finial on the arch's point.
      final tip = Offset(frame.center.dx, frame.top - 36);
      c.drawPath(diamondPath(tip + const Offset(0, -12), 14), gem);
      c.drawCircle(tip + const Offset(0, -34), 6, gem);
    }
  }

  @override
  void paintOrnaments(Canvas c, PosterPaintContext x) {
    final p = x.p;
    // Rangoli in the four corners, smaller (or left out) near a word.
    for (final corner in [Offset.zero, Offset(x.w, 0), Offset(0, x.h), Offset(x.w, x.h)]) {
      final top = corner.dy == 0;
      final r = top ? 170.0 : 230.0;
      final s = fitScale([(Offset.zero, r)], (q, k) => corner + q * k, x.keepOut, min: 0.5);
      if (s == null) continue;
      paintMandala(c, corner, r * s,
          foil: x.foil, fill: p.petal, fill2: p.petalLight, accent: p.petal2);
    }
    const m = _marigold;
    paintToran(c, -12, x.w + 12, 22, 34,
        light: m.light,
        mid: m.mid,
        deep: m.deep,
        alt: m.alt,
        altLight: m.altLight,
        leafLight: m.leafLight,
        leafDark: m.leafDark,
        flower: 23,
        drops: 7,
        seed: x.seed);
    final f = x.l.frame;
    if (f == null || x.l.emblem) return;
    final ko = x.keepOut;
    for (final side in [-1.0, 1.0]) {
      final o = Offset(side < 0 ? f.left - 20 : f.right + 20, f.bottom + 10);
      final s = clearScale(o, 64, ko, min: 0.5);
      c.save();
      c.translate(o.dx, o.dy);
      c.scale(side * s, s);
      paintLeaf(c, const Offset(0, 0), -1.25, 88, 30, light: m.leafLight, dark: m.leafDark);
      paintLeaf(c, const Offset(0, 0), -0.5, 74, 26, light: m.leafLight, dark: m.leafDark);
      paintMarigold(c, const Offset(8, -34), 20,
          light: m.altLight, mid: m.alt, deep: shade(m.alt, -0.35), seed: 5);
      paintMarigold(c, const Offset(0, 0), 28,
          light: m.light, mid: m.mid, deep: m.deep, seed: 3);
      paintMarigold(c, const Offset(36, 18), 18,
          light: m.light, mid: m.mid, deep: m.deep, seed: 9);
      c.restore();
    }
  }

  @override
  void paintDivider(Canvas c, PosterPaintContext x, Offset at, double half) {
    final bounds = Rect.fromCenter(center: at, width: half * 2, height: 30);
    final line = foilStroke(x.foilText, bounds, 1.8)..strokeCap = StrokeCap.round;
    c.drawLine(at + Offset(-half * 0.85, 0), at + const Offset(-34, 0), line);
    c.drawLine(at + const Offset(34, 0), at + Offset(half * 0.85, 0), line);
    final fill = Paint()..color = x.p.petal;
    for (final a in [-0.9, 0.0, 0.9]) {
      c.save();
      c.translate(at.dx, at.dy + 10);
      c.rotate(a);
      c.drawPath(lotusPath(26, 14), fill);
      c.drawPath(lotusPath(26, 14), foilStroke(x.foilText, bounds, 1.2));
      c.restore();
    }
  }
}

/// Real marigold colours: a garland is orange and saffron on every card.
const _marigold = (
  light: Color(0xFFFFD36E),
  mid: Color(0xFFF6A531),
  deep: Color(0xFFDD6A12),
  alt: Color(0xFFE2463F),
  altLight: Color(0xFFF7897A),
  leafLight: Color(0xFF8DBA6A),
  leafDark: Color(0xFF3F6B30),
);

// ───────────────────────────── 5. Garden Green ──────────────────────────

class GardenTemplate extends PosterTemplate {
  const GardenTemplate();
  @override
  String get id => 'garden_green';
  @override
  String get title => 'Garden Green';
  @override
  String get blurb => 'A leafy wreath with little white flowers';

  @override
  FrameShape shapeFor(double aspect) => FrameShape.circle;

  @override
  TemplateLayout layout(String format) {
    final story = format == 'story';
    return TemplateLayout(
      safe: story
          ? const EdgeInsets.fromLTRB(100, 190, 100, 180)
          : const EdgeInsets.fromLTRB(100, 90, 100, 88),
      photoMaxH: story ? 0.46 : 0.46,
      photoMinH: 0.27,
      photoMaxW: 0.66,
      // The foot of the wreath carries a small bouquet: room below it.
      framePad: const EdgeInsets.fromLTRB(62, 62, 62, 96),
      aspectMin: 0.8,
      aspectMax: 1.25,
      textWidth: 0.72,
      gap: 12,
      photoGap: 10,
      divider: 28,
      roles: _roles(headlineFamily: PosterFonts.displayItalic, headline: 62),
    );
  }

  @override
  void paintBackground(Canvas c, PosterPaintContext x) {
    paperGround(c, x, glowAt: 0.32);
  }

  /// The wreath's outer edge (leaves, blossoms) and the posy at its foot.
  static List<Rect> _wreath(Rect frame) {
    final ring = frame.inflate(40);
    return [
      frame.inflate(100),
      Rect.fromCenter(center: Offset(ring.center.dx, ring.bottom + 10), width: 250, height: 140),
    ];
  }

  @override
  void paintFrame(Canvas c, PosterPaintContext x, Rect frame, FrameShape shape,
      void Function(Path clip) content) {
    final p = x.p;
    final mat = framePath(shape, frame.inflate(12));
    dropShadow(c, mat, a: 0.2);
    c.drawPath(mat, Paint()..color = p.mat);
    content(framePath(shape, frame));
    final line = frame.inflate(18);
    c.drawPath(framePath(shape, line), foilStroke(x.foil, line, 2));
    // The wreath: leaves laid along an ellipse just outside the mat.
    final ring = frame.inflate(40);
    final rnd = x.rnd(5);
    for (final m in (Path()..addOval(ring)).computeMetrics()) {
      final n = (m.length / 30).floor();
      for (var pass = 0; pass < 2; pass++) {
        for (var i = 0; i < n; i++) {
          final t = m.getTangentForOffset(m.length * (i + pass * 0.5) / n);
          if (t == null) continue;
          final a = math.atan2(t.vector.dy, t.vector.dx) + math.pi / 2;
          final out = i.isEven ? 1.0 : -1.0;
          final len = (pass == 0 ? 52.0 : 40.0) * (0.85 + rnd.nextDouble() * 0.3);
          final col = [p.leaf, p.leafDark, p.leafLight][(i + pass) % 3];
          paintLeaf(c, t.position, a + out * 0.62 - math.pi / 2 + math.pi, len, len * 0.42,
              light: pass == 0 ? col : p.leafLight, dark: shade(col, -0.15), curl: out * 0.2);
        }
      }
      // Little white flowers and berries through the wreath.
      final k = (m.length / 58).floor();
      for (var i = 0; i < k; i++) {
        final t = m.getTangentForOffset(m.length * (i + 0.25) / k);
        if (t == null) continue;
        if (i % 3 == 2) {
          for (var b = 0; b < 3; b++) {
            c.drawCircle(t.position + Offset(b * 8.0 - 8, (b % 2) * 7.0 - 3), 6.5,
                Paint()..color = p.petal2Deep);
          }
        } else {
          paintBlossom(c, t.position, 15,
              light: p.petalLight, mid: p.petal, centre: const Color(0xFFE2B54A),
              rot: rnd.nextDouble());
        }
      }
    }
    // A cluster at the foot of the wreath, like a bow.
    final foot = Offset(ring.center.dx, ring.bottom + 4);
    paintLeaf(c, foot, -1.9, 80, 34, light: p.leafLight, dark: p.leafDark);
    paintLeaf(c, foot, 1.9, 80, 34, light: p.leafLight, dark: p.leafDark);
    paintPeony(c, foot, 42, light: p.petal2Light, mid: p.petal2, deep: p.petal2Deep);
    paintBlossom(c, foot + const Offset(-50, -8), 26,
        light: p.petalLight, mid: p.petal, centre: const Color(0xFFE2B54A));
    paintBlossom(c, foot + const Offset(50, -8), 26,
        light: p.petalLight, mid: p.petal, centre: const Color(0xFFE2B54A), rot: 0.5);
    final top = Offset(ring.left + ring.width * 0.16, ring.top + ring.height * 0.14);
    paintBlossom(c, top, 22,
        light: p.petal2Light, mid: p.petal2, centre: p.petal2Deep, rot: 0.2);
    paintFiller(c, top + const Offset(26, -18), 8, const Color(0xFFFFFFFF), p.petal2Light);
  }

  @override
  void paintOrnaments(Canvas c, PosterPaintContext x) {
    final p = x.p;
    final ko = x.keepOut;
    final f = x.l.frame;
    // The sprigs keep off the words AND the wreath: two garlands piled on
    // each other read as a tangle, not a frame (review, 2026-09-26).
    final wreath = f == null ? const <Rect>[] : _wreath(f);
    void sprig(Offset corner, double angle, double len, bool round) {
      final print = sprigFootprint(Offset.zero, angle, len, bend: 0.18, round: round);
      final s = fitAt(print, corner, ko, ovals: wreath, min: 0.4);
      if (s == null) return;
      c.save();
      c.translate(corner.dx, corner.dy);
      c.scale(s);
      paintSprig(c, Offset.zero, angle, len,
          light: p.leafLight, dark: round ? p.leaf : p.leafDark, leaves: round ? 9 : 8,
          round: round, bend: 0.18);
      c.restore();
    }

    sprig(const Offset(-10, 170), 1.05, 300, true);
    sprig(const Offset(150, -10), 2.35, 250, false);
    sprig(Offset(x.w + 10, x.h - 170), 1.05 + math.pi, 300, true);
    sprig(Offset(x.w - 150, x.h + 10), 2.35 + math.pi, 250, false);
    sprig(Offset(x.w + 10, 120), -1.3, 190, false);
    sprig(Offset(-10, x.h - 120), 1.85, 190, false);
  }

  @override
  void paintDivider(Canvas c, PosterPaintContext x, Offset at, double half) {
    final p = x.p;
    final line = Paint()
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..color = p.leafDark.withValues(alpha: 0.7);
    c.drawLine(at + Offset(-half * 0.75, 0), at + const Offset(-20, 0), line);
    c.drawLine(at + const Offset(20, 0), at + Offset(half * 0.75, 0), line);
    paintLeaf(c, at + const Offset(-4, 0), -1.9, 26, 12, light: p.leafLight, dark: p.leaf);
    paintLeaf(c, at + const Offset(4, 0), 1.9, 26, 12, light: p.leafLight, dark: p.leaf);
    c.drawCircle(at, 4.5, Paint()..color = p.petal2Deep);
  }
}

// ───────────────────────────── 6. Classic Ivory ─────────────────────────

class IvoryTemplate extends PosterTemplate {
  const IvoryTemplate();
  @override
  String get id => 'classic_ivory';
  @override
  String get title => 'Classic Ivory';
  @override
  String get blurb => 'Quiet and elegant, gold lines';

  @override
  FrameShape shapeFor(double aspect) => FrameShape.rounded;

  @override
  TemplateLayout layout(String format) {
    final story = format == 'story';
    return TemplateLayout(
      safe: story
          ? const EdgeInsets.fromLTRB(124, 210, 124, 200)
          : const EdgeInsets.fromLTRB(124, 126, 124, 112),
      photoMaxH: story ? 0.46 : 0.45,
      photoMinH: 0.25,
      photoMaxW: 0.6,
      framePad: const EdgeInsets.all(24),
      aspectMin: 0.7,
      aspectMax: 1.5,
      textWidth: 0.68,
      gap: 12,
      photoGap: 28,
      divider: 30,
      roles: _roles(
        headlineFamily: PosterFonts.display,
        headline: 44,
        headlineSpacing: 4.5,
        name: 122,
        message: 36,
        from: 42,
        date: 25,
      ),
    );
  }

  @override
  void paintBackground(Canvas c, PosterPaintContext x) {
    paperGround(c, x, glowAt: 0.3, grain: 0.022);
    final r1 = Rect.fromLTRB(46, 46, x.w - 46, x.h - 46);
    c.drawRect(r1, foilStroke(x.foil, r1, 2.6));
    final r2 = r1.deflate(12);
    c.drawRect(r2, foilStroke(x.foil, r2, 1));
    final stroke = foilStroke(x.foil, x.card, 2)..strokeCap = StrokeCap.round;
    final gem = foilFill(x.foil, x.card);
    for (final (corner, rot) in [
      (r2.topLeft, 0.0),
      (r2.topRight, math.pi / 2),
      (r2.bottomRight, math.pi),
      (r2.bottomLeft, -math.pi / 2),
    ]) {
      c.save();
      c.translate(corner.dx, corner.dy);
      c.rotate(rot);
      paintCornerScroll(c, const Offset(10, 10), 74, stroke, gem);
      c.restore();
    }
    // A small crest on the top and bottom rules.
    for (final y in [r1.top, r1.bottom]) {
      final o = Offset(x.w / 2, y);
      c.drawRect(Rect.fromCenter(center: o, width: 70, height: 30),
          Paint()..color = Color.lerp(x.p.bgTop, x.p.bgBottom, y / x.h)!);
      c.drawPath(diamondPath(o, 11), gem);
      c.drawCircle(o + const Offset(-22, 0), 3.2, gem);
      c.drawCircle(o + const Offset(22, 0), 3.2, gem);
    }
  }

  @override
  void paintFrame(Canvas c, PosterPaintContext x, Rect frame, FrameShape shape,
      void Function(Path clip) content) {
    matAndLine(c, x, frame, shape, mat: 10, lineAt: 17, line: 2, shadow: 0.16);
    content(framePath(shape, frame));
  }

  @override
  void paintOrnaments(Canvas c, PosterPaintContext x) {
    final f = x.l.frame;
    if (f == null || x.l.emblem) return;
    // A single ivory rose with two leaves at the photo's lower corner.
    final p = x.p;
    final o = Offset(f.right + 4, f.bottom + 2);
    final s = clearScale(o, 60, x.keepOut, min: 0.5);
    c.save();
    c.translate(o.dx, o.dy);
    c.scale(s);
    paintLeaf(c, Offset.zero, -2.3, 70, 30, light: p.leafLight, dark: p.leaf);
    paintLeaf(c, Offset.zero, 0.5, 62, 26, light: p.leafLight, dark: p.leafDark);
    paintRose(c, Offset.zero, 32, light: p.petalLight, mid: p.petal, deep: p.petalDeep);
    paintFiller(c, const Offset(-34, 20), 7, const Color(0xFFFFFFFF), p.petalDeep);
    c.restore();
  }
}
