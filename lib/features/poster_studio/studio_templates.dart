import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import 'studio_fonts.dart';
import 'studio_layout.dart';
import 'studio_models.dart';
import 'studio_palettes.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  EVENT TEMPLATES (2026-09-30). Four looks, each with one clear order of
///  importance: the title biggest, then the subtitle, the date chip, the
///  place with its pin, the details, and the call to action as a pill.
///  Each has three arrangements ("Variation") and draws its own art when
///  no AI picture is available, so a poster still looks finished offline.
///
///  The greeting-card designs (lib/features/poster) are separate: those
///  frame a person's photo; these set an event over a picture.
/// ─────────────────────────────────────────────────────────────────────────

/// The resolved inks of one template in one palette.
class StudioLook {
  const StudioLook({
    required this.ground,
    required this.groundHigh,
    required this.title,
    required this.subtitle,
    required this.body,
    required this.icon,
    required this.chipFill,
    required this.chipRim,
    required this.chipInk,
    required this.ctaFill,
    required this.ctaInk,
    required this.panel,
    required this.rim,
    required this.accent,
    this.titleFoil,
    this.titleGlow,
    this.panelRim,
    this.ctaGlow = false,
  });

  final Color ground;
  final Color groundHigh;
  final Color title;
  final Color subtitle;
  final Color body;
  final Color icon;
  final Color chipFill;
  final List<Color> chipRim;
  final Color chipInk;
  final List<Color> ctaFill;
  final Color ctaInk;

  /// The scrim behind words over a busy or bright picture.
  final Color panel;
  final Color? panelRim;
  final List<Color> rim;
  final Color accent;

  /// Gold foil across the title (Festive): its stops.
  final List<Color>? titleFoil;

  /// A soft neon glow behind the title's letters.
  final Color? titleGlow;
  final bool ctaGlow;

  /// The ink a line is drawn in; for foil, its least legible stop.
  Color inkFor(StudioField f) => switch (f) {
        StudioField.title => titleFoil == null
            ? title
            : titleFoil!.reduce((a, b) => a.computeLuminance() < b.computeLuminance() ? a : b),
        StudioField.subtitle => subtitle,
        StudioField.date || StudioField.time => chipInk,
        StudioField.cta => ctaInk,
        _ => body,
      };
}

/// What a template paints with.
class StudioPaintContext {
  StudioPaintContext(this.size, this.look, this.palette, this.layout, this.seed, this.image);
  final Size size;
  final StudioLook look;
  final StudioPalette palette;
  final StudioLayout layout;
  final int seed;

  /// The AI picture or his photo; null: the template's own art.
  final ui.Image? image;

  double get u => size.width / 1080;
  math.Random rng([int salt = 0]) => math.Random(seed * 7919 + salt);
}

abstract class EventTemplate {
  const EventTemplate();
  String get id;
  String get name;
  String get blurb;

  /// The palette it opens in.
  String get palette;

  /// The server's style word for its background (neon, corporate,
  /// festive, elegant, minimal, bold), so the picture suits the look.
  String get style;
  StudioType get type;
  int get variants => 3;

  StudioLook look(StudioPalette p);
  StudioZones zones(Size size, int variant, {bool logo = false});

  /// The ground and the picture (or the art standing in for it), with the
  /// veil that keeps words readable over it.
  void paintBackdrop(Canvas c, StudioPaintContext x);

  /// Rims, rules and ornaments — never across a word.
  void paintDecor(Canvas c, StudioPaintContext x) {}
}

const studioTemplates = <EventTemplate>[
  NeonNightTemplate(),
  CorporateCleanTemplate(),
  FestiveTemplate(),
  BoldMinimalTemplate(),
];

EventTemplate studioTemplate(String id) =>
    studioTemplates.firstWhere((t) => t.id == id, orElse: () => studioTemplates.first);

/// The template the design's own `style` word points to.
EventTemplate templateForStyle(String style) {
  final s = style.toLowerCase();
  bool has(List<String> w) => w.any(s.contains);
  if (has(['corporate', 'business', 'clean', 'professional', 'conference', 'office', 'seminar', 'workshop'])) {
    return studioTemplate('corporate_clean');
  }
  if (has(['festive', 'festival', 'diwali', 'onam', 'wedding', 'gold', 'celebrat', 'christmas', 'eid', 'pooja', 'puja', 'traditional', 'elegant'])) {
    return studioTemplate('festive');
  }
  if (has(['minimal', 'bold', 'simple', 'modern', 'swiss'])) return studioTemplate('bold_minimal');
  return studioTemplate('neon_night');
}

// ─────────────────────────────── helpers ──────────────────────────────────

/// The part of [img] that fills [dst] edge to edge, centred.
Rect studioCoverSrc(ui.Image img, Rect dst) {
  final iw = img.width.toDouble(), ih = img.height.toDouble();
  final k = math.max(dst.width / iw, dst.height / ih);
  return Rect.fromCenter(
      center: Offset(iw / 2, ih / 2), width: math.min(iw, dst.width / k), height: math.min(ih, dst.height / k));
}

void paintCover(Canvas c, ui.Image img, Rect dst, {ui.ImageFilter? filter}) {
  c.save();
  c.clipRect(dst);
  c.drawImageRect(
      img,
      studioCoverSrc(img, dst),
      filter == null ? dst : dst.inflate(dst.shortestSide * 0.05),
      Paint()
        ..filterQuality = FilterQuality.high
        ..imageFilter = filter);
  c.restore();
}

void _vertical(Canvas c, Rect r, List<Color> colours, [List<double>? stops]) => c.drawRect(
    r, Paint()..shader = ui.Gradient.linear(r.topCenter, r.bottomCenter, colours, stops));

void _glowBlob(Canvas c, Offset at, double radius, Color colour, double alpha) => c.drawCircle(
    at,
    radius,
    Paint()
      ..shader = ui.Gradient.radial(
          at, radius, [colour.withValues(alpha: alpha), colour.withValues(alpha: 0)]));

/// A glowing rounded-rect rim: a blurred wide stroke under a crisp one.
void _neonRim(Canvas c, RRect r, List<Color> colours, double width, {double glow = 1}) {
  final stops = [for (var i = 0; i < colours.length; i++) i / math.max(1, colours.length - 1)];
  Shader shader(double alpha) => ui.Gradient.linear(r.outerRect.topLeft, r.outerRect.bottomRight,
      [for (final col in colours) col.withValues(alpha: col.a * alpha)], stops);
  if (glow > 0) {
    c.drawRRect(
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = width * 3
          ..shader = shader(0.6 * glow)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, width * 3.2));
  }
  c.drawRRect(
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..shader = shader(1));
}

/// A pill's fill and ink that always read: the better ink for the fill,
/// then each stop of the fill nudged (hue kept) until that ink reaches
/// 4.5:1 on it — a navy-to-coral gradient reads nowhere otherwise.
({List<Color> fill, Color ink}) _pill(List<Color> fill) {
  double worst(Color ink) => fill.map((f) => contrastRatio(ink, f)).reduce(math.min);
  final ink = worst(StudioInk.white) >= worst(StudioInk.dark) ? StudioInk.white : StudioInk.dark;
  return (fill: [for (final f in fill) ensureContrast(f, ink, 4.7)], ink: ink);
}

/// A square of side [s] for the logo, per corner of the safe area.
Rect _logoAt(Rect safe, double s, Alignment where) {
  final x = safe.left + (safe.width - s) * (where.x + 1) / 2;
  final y = safe.top + (safe.height - s) * (where.y + 1) / 2;
  return Rect.fromLTWH(x, y, s, s);
}

// ───────────────────────────── Neon Night ─────────────────────────────────

/// Dark navy night, a fluorescent rim, cyan and magenta light.
class NeonNightTemplate extends EventTemplate {
  const NeonNightTemplate();
  @override
  String get id => 'neon_night';
  @override
  String get style => 'neon';
  @override
  String get name => 'Neon Night';
  @override
  String get blurb => 'Dark, glowing, electric';
  @override
  String get palette => 'neon';
  @override
  StudioType get type => const StudioType(
        title: StudioFonts.grotesk,
        subtitle: StudioFonts.groteskMedium,
        body: StudioFonts.semi,
        strong: StudioFonts.heavy,
        titleMax: 136,
        titleSpacing: -0.02,
      );

  @override
  StudioLook look(StudioPalette p) {
    final cta = _pill([p.secondary, p.accent]);
    return StudioLook(
      ground: StudioInk.night,
      groundHigh: StudioInk.nightHigh,
      title: StudioInk.white,
      titleGlow: p.primary,
      subtitle: ensureContrast(studioShade(p.primary, 0.78), StudioInk.night, 7),
      body: StudioInk.white,
      icon: ensureContrast(p.primary, StudioInk.night, 4.5),
      chipFill: Color.alphaBlend(p.primary.withValues(alpha: 0.16), StudioInk.nightPanel),
      chipRim: [p.primary, p.secondary],
      chipInk: StudioInk.white,
      ctaFill: cta.fill,
      ctaInk: cta.ink,
      ctaGlow: true,
      panel: StudioInk.nightPanel,
      panelRim: p.primary.withValues(alpha: 0.45),
      rim: [p.primary, p.secondary, p.accent],
      accent: p.accent,
    );
  }

  @override
  StudioZones zones(Size size, int variant, {bool logo = false}) {
    final w = size.width, h = size.height, m = w * 0.074;
    final safe = Rect.fromLTRB(m, m, w - m, h - m);
    final s = w * 0.15;
    return switch (variant % 3) {
      1 => StudioZones(
          image: Offset.zero & size,
          safe: safe,
          text: logo ? Rect.fromLTRB(m, m + s + w * 0.04, w - m, h - m) : safe,
          anchor: 0.5,
          align: TextAlign.center,
          logo: logo ? _logoAt(safe, s, Alignment.topCenter) : null,
        ),
      2 => StudioZones(
          image: Offset.zero & size,
          safe: safe,
          text: Rect.fromLTRB(m, m, w - m, logo ? h - m - s - w * 0.04 : h * 0.64),
          anchor: 0,
          whenFirst: true,
          logo: logo ? _logoAt(safe, s, Alignment.bottomLeft) : null,
        ),
      _ => StudioZones(
          image: Offset.zero & size,
          safe: safe,
          text: Rect.fromLTRB(m, logo ? m + s + w * 0.04 : h * 0.38, w - m, h - m),
          anchor: 1,
          logo: logo ? _logoAt(safe, s, Alignment.topLeft) : null,
        ),
    };
  }

  @override
  void paintBackdrop(Canvas c, StudioPaintContext x) {
    final r = Offset.zero & x.size;
    final l = x.look;
    final img = x.image;
    if (img != null) {
      paintCover(c, img, r);
      // The veil deepens where the words stand, lighter elsewhere.
      final a = x.layout.zones.anchor;
      final night = l.ground;
      _vertical(
          c,
          r,
          a >= 0.75
              ? [night.withValues(alpha: 0.05), night.withValues(alpha: 0.18), night.withValues(alpha: 0.58)]
              : a <= 0.25
                  ? [night.withValues(alpha: 0.58), night.withValues(alpha: 0.18), night.withValues(alpha: 0.05)]
                  : [night.withValues(alpha: 0.3), night.withValues(alpha: 0.42), night.withValues(alpha: 0.3)],
          const [0, 0.45, 1]);
      // A whisper of the palette's light over the picture.
      c.drawRect(
          r,
          Paint()
            ..shader = ui.Gradient.linear(r.topLeft, r.bottomRight, [
              x.palette.primary.withValues(alpha: 0.10),
              x.palette.secondary.withValues(alpha: 0.10),
            ]));
      return;
    }
    // No picture: a night sky of soft neon light.
    _vertical(c, r, [l.groundHigh, l.ground, l.ground], const [0, 0.55, 1]);
    final rng = x.rng(1);
    final w = x.size.width, h = x.size.height;
    final lights = [x.palette.primary, x.palette.secondary, x.palette.accent];
    for (var i = 0; i < 3; i++) {
      _glowBlob(c, Offset(w * (0.1 + rng.nextDouble() * 0.8), h * (0.08 + rng.nextDouble() * 0.6)),
          w * (0.45 + rng.nextDouble() * 0.35), lights[i], 0.34);
    }
    // Two ribbons of light.
    for (var i = 0; i < 2; i++) {
      final y0 = h * (0.18 + rng.nextDouble() * 0.45);
      final p = Path()
        ..moveTo(-w * 0.1, y0)
        ..cubicTo(w * 0.3, y0 - h * (0.12 + rng.nextDouble() * 0.12), w * 0.62,
            y0 + h * (0.1 + rng.nextDouble() * 0.12), w * 1.1, y0 - h * 0.05);
      Shader shader(double a) => ui.Gradient.linear(Offset(0, y0), Offset(w, y0), [
            lights[i].withValues(alpha: 0),
            lights[i].withValues(alpha: a),
            lights[(i + 1) % 3].withValues(alpha: a),
            lights[(i + 1) % 3].withValues(alpha: 0),
          ], const [0, 0.3, 0.7, 1]);
      c.drawPath(
          p,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 26 * x.u
            ..shader = shader(0.5)
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, 30 * x.u));
      c.drawPath(
          p,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3 * x.u
            ..shader = shader(1));
    }
    // Star dust.
    final dot = Paint();
    for (var i = 0; i < 70; i++) {
      dot.color = StudioInk.white.withValues(alpha: 0.12 + rng.nextDouble() * 0.4);
      c.drawCircle(Offset(rng.nextDouble() * w, rng.nextDouble() * h), (0.8 + rng.nextDouble() * 1.8) * x.u, dot);
    }
  }

  @override
  void paintDecor(Canvas c, StudioPaintContext x) {
    final w = x.size.width;
    final r = RRect.fromRectAndRadius(
        (Offset.zero & x.size).deflate(w * 0.03), Radius.circular(w * 0.045));
    _neonRim(c, r, x.look.rim, 4 * x.u);
  }
}

// ─────────────────────────── Corporate Clean ──────────────────────────────

/// White paper, a navy grid, strong type; the picture in a band.
class CorporateCleanTemplate extends EventTemplate {
  const CorporateCleanTemplate();
  @override
  String get id => 'corporate_clean';
  @override
  String get style => 'corporate';
  @override
  String get name => 'Corporate Clean';
  @override
  String get blurb => 'White, navy, sharp';
  @override
  String get palette => 'royal';
  @override
  StudioType get type => const StudioType(
        title: StudioFonts.heavy,
        subtitle: StudioFonts.semi,
        body: StudioFonts.medium,
        strong: StudioFonts.bold,
        titleMax: 112,
        titleMin: 44,
        titleSpacing: -0.018,
        titleHeight: 1.04,
      );

  @override
  StudioLook look(StudioPalette p) {
    final deep = ensureContrast(p.primary, StudioInk.paper, 4.8);
    final cta = _pill([deep, studioShade(deep, (HSLColor.fromColor(deep).lightness - 0.08).clamp(0.08, 1))]);
    final chip = _pill([deep]);
    return StudioLook(
      ground: StudioInk.paper,
      groundHigh: StudioInk.navy,
      title: StudioInk.navy,
      subtitle: StudioInk.slate,
      body: StudioInk.slate,
      icon: deep,
      chipFill: chip.fill.first,
      chipRim: [deep, deep],
      chipInk: chip.ink,
      ctaFill: cta.fill,
      ctaInk: cta.ink,
      panel: StudioInk.paper,
      rim: [deep, p.secondary],
      accent: deep,
    );
  }

  double _band(Size s) => s.height / s.width > 1.5
      ? 0.4
      : s.height / s.width < 1.1
          ? 0.36
          : 0.41;

  @override
  StudioZones zones(Size size, int variant, {bool logo = false}) {
    final w = size.width, h = size.height, m = w * 0.074;
    final safe = Rect.fromLTRB(m, m, w - m, h - m);
    final s = w * 0.14;
    final band = h * _band(size);
    return switch (variant % 3) {
      1 => StudioZones(
          image: Rect.fromLTRB(0, h - band, w, h),
          safe: Rect.fromLTRB(m, m, w - m, h - m * 0.6),
          text: Rect.fromLTRB(m, logo ? m + s + w * 0.04 : m * 1.2, w - m, h - band - w * 0.06),
          anchor: 0.5,
          logo: logo ? _logoAt(safe, s, Alignment.topLeft) : null,
        ),
      2 => StudioZones(
          image: Rect.fromLTRB(0, 0, w, band),
          safe: safe,
          text: Rect.fromLTRB(m, band + w * 0.06 + (logo ? s / 2 : 0), w - m, h - m),
          anchor: 0.5,
          align: TextAlign.center,
          logo: logo ? Rect.fromLTWH((w - s) / 2, band - s / 2, s, s) : null,
        ),
      _ => StudioZones(
          image: Rect.fromLTRB(0, 0, w, band),
          safe: safe,
          text: Rect.fromLTRB(m, band + w * 0.07 + (logo ? s / 2 : 0), w - m, h - m),
          anchor: 0,
          logo: logo ? Rect.fromLTWH(m, band - s / 2, s, s) : null,
        ),
    };
  }

  @override
  void paintBackdrop(Canvas c, StudioPaintContext x) {
    final r = Offset.zero & x.size;
    final l = x.look;
    c.drawRect(r, Paint()..color = l.ground);
    // A faint engineering grid on the paper.
    final step = x.size.width / 15;
    final line = Paint()
      ..color = StudioInk.paperLine.withValues(alpha: 0.55)
      ..strokeWidth = 1.2 * x.u;
    for (var gx = step; gx < x.size.width; gx += step) {
      c.drawLine(Offset(gx, 0), Offset(gx, x.size.height), line);
    }
    for (var gy = step; gy < x.size.height; gy += step) {
      c.drawLine(Offset(0, gy), Offset(x.size.width, gy), line);
    }
    final band = x.layout.zones.image;
    final img = x.image;
    if (img != null) {
      paintCover(c, img, band);
    } else {
      // Navy with overlapping glass shapes in the palette.
      _vertical(c, band, [StudioInk.navy, StudioInk.navyHigh]);
      c.save();
      c.clipRect(band);
      final rng = x.rng(2);
      final cols = [x.palette.primary, x.palette.secondary, l.accent];
      for (var i = 0; i < 5; i++) {
        final col = cols[i % cols.length].withValues(alpha: 0.22 + rng.nextDouble() * 0.22);
        final at = Offset(band.left + rng.nextDouble() * band.width, band.top + rng.nextDouble() * band.height);
        final sz = band.width * (0.18 + rng.nextDouble() * 0.32);
        if (i.isEven) {
          c.drawCircle(at, sz, Paint()..color = col);
        } else {
          c.save();
          c.translate(at.dx, at.dy);
          c.rotate(math.pi / 4);
          c.drawRect(Rect.fromCenter(center: Offset.zero, width: sz * 1.4, height: sz * 1.4),
              Paint()..color = col);
          c.restore();
        }
      }
      final thin = Paint()
        ..color = StudioInk.white.withValues(alpha: 0.12)
        ..strokeWidth = 2 * x.u;
      for (var d = -band.height; d < band.width; d += 46 * x.u) {
        c.drawLine(Offset(band.left + d, band.bottom), Offset(band.left + d + band.height, band.top), thin);
      }
      c.restore();
    }
    // The band's edge: one accent rule.
    final edge = band.top <= 0.5 ? band.bottom : band.top;
    c.drawRect(Rect.fromLTWH(0, edge - 5 * x.u, x.size.width, 10 * x.u), Paint()..color = l.accent);
  }

  @override
  void paintDecor(Canvas c, StudioPaintContext x) {
    // An accent bar over the title, when it leads the stack.
    final t = x.layout.block(StudioField.title);
    if (t == null || x.layout.blocks.first != t) return;
    final u = x.u;
    final w = 120 * u, hgt = 10 * u;
    final left = x.layout.zones.align == TextAlign.center ? t.ink.center.dx - w / 2 : t.box.left;
    final bar = Rect.fromLTWH(left, t.box.top - 30 * u, w, hgt);
    if (bar.top < x.layout.zones.image.bottom + 8 * u && x.layout.zones.image.top <= 0.5) return;
    c.drawRRect(RRect.fromRectAndRadius(bar, Radius.circular(hgt / 2)), Paint()..color = x.look.accent);
  }
}

// ─────────────────────────────── Festive ──────────────────────────────────

/// Warm maroon, gold foil lettering, a double gold frame.
class FestiveTemplate extends EventTemplate {
  const FestiveTemplate();
  @override
  String get id => 'festive';
  @override
  String get style => 'festive';
  @override
  String get name => 'Festive';
  @override
  String get blurb => 'Warm gold, celebration';
  @override
  String get palette => 'gold';
  @override
  StudioType get type => const StudioType(
        title: StudioFonts.serif,
        subtitle: StudioFonts.serifItalic,
        body: StudioFonts.semi,
        strong: StudioFonts.bold,
        titleMax: 124,
        titleMin: 46,
        titleSpacing: 0,
        titleHeight: 1.06,
        subtitleSize: 46,
      );

  @override
  StudioLook look(StudioPalette p) {
    final gold = HSLColor.fromColor(p.primary).lightness < 0.5 ? studioShade(p.primary, 0.6) : p.primary;
    // Every stop reads on the maroon scrim, so a scrim can always rescue it.
    final foil = [
      for (final f in [studioShade(gold, 0.86), gold, studioShade(gold, 0.62)])
        ensureContrast(f, StudioInk.maroon, 6),
    ];
    final cta = _pill([studioShade(gold, 0.8), gold]);
    return StudioLook(
      ground: StudioInk.maroon,
      groundHigh: StudioInk.cocoa,
      title: gold,
      titleFoil: foil,
      subtitle: StudioInk.cream,
      body: StudioInk.cream,
      icon: studioShade(gold, 0.7),
      chipFill: Color.alphaBlend(gold.withValues(alpha: 0.16), StudioInk.maroon),
      chipRim: [studioShade(gold, 0.85), studioShade(gold, 0.5)],
      chipInk: StudioInk.cream,
      ctaFill: cta.fill,
      ctaInk: cta.ink,
      panel: StudioInk.maroon,
      panelRim: gold.withValues(alpha: 0.5),
      rim: foil,
      accent: gold,
    );
  }

  @override
  StudioZones zones(Size size, int variant, {bool logo = false}) {
    final w = size.width, h = size.height, m = w * 0.1;
    final safe = Rect.fromLTRB(m, m, w - m, h - m);
    final s = w * 0.14;
    final top = logo ? m + s + w * 0.035 : m;
    return switch (variant % 3) {
      1 => StudioZones(
          image: Offset.zero & size,
          safe: safe,
          text: Rect.fromLTRB(m, math.max(top, h * 0.4), w - m, h - m),
          anchor: 1,
          align: TextAlign.center,
          logo: logo ? _logoAt(safe, s, Alignment.topCenter) : null,
        ),
      2 => StudioZones(
          image: Offset.zero & size,
          safe: safe,
          text: Rect.fromLTRB(m, m, w - m, logo ? h - m - s - w * 0.035 : h * 0.62),
          anchor: 0,
          align: TextAlign.center,
          whenFirst: true,
          logo: logo ? _logoAt(safe, s, Alignment.bottomCenter) : null,
        ),
      _ => StudioZones(
          image: Offset.zero & size,
          safe: safe,
          text: Rect.fromLTRB(m, top, w - m, h - m),
          anchor: 0.5,
          align: TextAlign.center,
          logo: logo ? _logoAt(safe, s, Alignment.topCenter) : null,
        ),
    };
  }

  @override
  void paintBackdrop(Canvas c, StudioPaintContext x) {
    final r = Offset.zero & x.size;
    final l = x.look;
    final w = x.size.width, h = x.size.height;
    final img = x.image;
    if (img != null) {
      paintCover(c, img, r);
      c.drawRect(r, Paint()..color = l.ground.withValues(alpha: 0.26));
      c.drawRect(
          r,
          Paint()
            ..shader = ui.Gradient.radial(r.center, h * 0.75,
                [l.ground.withValues(alpha: 0.05), l.ground.withValues(alpha: 0.5)]));
      return;
    }
    c.drawRect(
        r, Paint()..shader = ui.Gradient.radial(Offset(w / 2, h * 0.3), h * 0.85, [l.groundHigh, l.ground]));
    // Light rays from the top.
    final ray = Paint()..color = l.accent.withValues(alpha: 0.05);
    for (var i = 0; i < 9; i++) {
      final a = math.pi / 2 + (i - 4) * 0.17;
      final top = Offset(w / 2, -h * 0.05);
      Offset reach(double t) => top + Offset(math.cos(t), math.sin(t)) * h * 1.3;
      final p = Path()
        ..moveTo(top.dx, top.dy)
        ..lineTo(reach(a - 0.04).dx, reach(a - 0.04).dy)
        ..lineTo(reach(a + 0.04).dx, reach(a + 0.04).dy)
        ..close();
      c.drawPath(p, ray);
    }
    // Bokeh.
    final rng = x.rng(3);
    final cols = [l.accent, studioShade(l.accent, 0.8), x.palette.secondary];
    for (var i = 0; i < 44; i++) {
      final rad = (8 + rng.nextDouble() * 56) * x.u;
      final paint = Paint()
        ..color = cols[i % cols.length].withValues(alpha: 0.08 + rng.nextDouble() * 0.26);
      if (rng.nextBool()) paint.maskFilter = MaskFilter.blur(BlurStyle.normal, rad * 0.35);
      c.drawCircle(Offset(rng.nextDouble() * w, rng.nextDouble() * h), rad, paint);
    }
  }

  @override
  void paintDecor(Canvas c, StudioPaintContext x) {
    final w = x.size.width;
    final outer = RRect.fromRectAndRadius((Offset.zero & x.size).deflate(w * 0.035), Radius.circular(w * 0.012));
    final inner = RRect.fromRectAndRadius((Offset.zero & x.size).deflate(w * 0.052), Radius.circular(w * 0.008));
    _neonRim(c, outer, x.look.rim, 3.2 * x.u, glow: 0.35);
    c.drawRRect(
        inner,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4 * x.u
          ..color = x.look.accent.withValues(alpha: 0.7));
    // A small diamond at each corner, between the two lines.
    final d = w * 0.0435;
    final gem = Paint()..color = x.look.accent;
    for (final at in [
      Offset(d, d),
      Offset(x.size.width - d, d),
      Offset(d, x.size.height - d),
      Offset(x.size.width - d, x.size.height - d),
    ]) {
      final s = 9 * x.u;
      c.drawPath(
          Path()
            ..moveTo(at.dx, at.dy - s)
            ..lineTo(at.dx + s, at.dy)
            ..lineTo(at.dx, at.dy + s)
            ..lineTo(at.dx - s, at.dy)
            ..close(),
          gem);
    }
  }
}

// ──────────────────────────── Bold Minimal ────────────────────────────────

/// A huge title, one accent, nothing else.
class BoldMinimalTemplate extends EventTemplate {
  const BoldMinimalTemplate();
  @override
  String get id => 'bold_minimal';
  @override
  String get style => 'bold';
  @override
  String get name => 'Bold Minimal';
  @override
  String get blurb => 'Huge title, one accent';
  @override
  String get palette => 'neon';
  @override
  StudioType get type => const StudioType(
        title: StudioFonts.heavy,
        subtitle: StudioFonts.semi,
        body: StudioFonts.medium,
        strong: StudioFonts.heavy,
        titleMax: 210,
        titleMin: 60,
        titleLines: 4,
        titleHeight: 0.98,
        titleSpacing: -0.035,
        subtitleSize: 42,
      );

  @override
  StudioLook look(StudioPalette p) {
    final accent = ensureContrast(p.primary, StudioInk.minimal, 4.5);
    final minimalCta = _pill([accent]);
    return StudioLook(
      ground: StudioInk.minimal,
      groundHigh: Color.alphaBlend(accent.withValues(alpha: 0.12), StudioInk.minimal),
      title: StudioInk.white,
      subtitle: ensureContrast(studioShade(accent, 0.86), StudioInk.minimal, 7),
      body: StudioInk.white,
      icon: accent,
      chipFill: StudioInk.minimal,
      chipRim: [accent, accent],
      chipInk: StudioInk.white,
      ctaFill: minimalCta.fill,
      ctaInk: minimalCta.ink,
      panel: StudioInk.minimal,
      rim: [accent, accent],
      accent: accent,
    );
  }

  @override
  StudioZones zones(Size size, int variant, {bool logo = false}) {
    final w = size.width, h = size.height, m = w * 0.074;
    final safe = Rect.fromLTRB(m, m, w - m, h - m);
    final s = w * 0.14;
    return switch (variant % 3) {
      1 => StudioZones(
          image: Rect.fromLTRB(m, h * 0.6, w - m, h - m),
          safe: safe,
          text: Rect.fromLTRB(m, m, logo ? w - m - s - w * 0.03 : w - m, h * 0.6 - w * 0.05),
          anchor: 0,
          whenFirst: true,
          logo: logo ? _logoAt(safe, s, Alignment.topRight) : null,
        ),
      2 => StudioZones(
          image: Offset.zero & size,
          safe: safe,
          text: Rect.fromLTRB(m, logo ? m + s + w * 0.04 : h * 0.3, w - m, h - m),
          anchor: 1,
          logo: logo ? _logoAt(safe, s, Alignment.topLeft) : null,
        ),
      _ => StudioZones(
          image: Rect.fromLTRB(m, m, w - m, h * 0.4),
          safe: safe,
          text: Rect.fromLTRB(m, h * 0.4 + w * 0.05 + (logo ? s / 2 : 0), w - m, h - m),
          anchor: 1,
          logo: logo ? Rect.fromLTWH(w - m - s - w * 0.03, h * 0.4 - s / 2, s, s) : null,
        ),
    };
  }

  @override
  void paintBackdrop(Canvas c, StudioPaintContext x) {
    final r = Offset.zero & x.size;
    final l = x.look;
    c.drawRect(r, Paint()..color = l.ground);
    final box = x.layout.zones.image;
    final full = box.width >= x.size.width - 0.5;
    final img = x.image;
    if (img != null) {
      paintCover(c, img, box);
      if (full) {
        _vertical(c, r, [
          l.ground.withValues(alpha: 0.2),
          l.ground.withValues(alpha: 0.35),
          l.ground.withValues(alpha: 0.72),
        ], const [0, 0.4, 1]);
      }
      return;
    }
    // One huge accent circle, partly off the picture.
    c.save();
    c.clipRect(box);
    _vertical(c, box, [l.groundHigh, l.ground]);
    final rng = x.rng(4);
    final at = Offset(box.left + box.width * (0.55 + rng.nextDouble() * 0.35),
        box.top + box.height * (0.2 + rng.nextDouble() * 0.5));
    c.drawCircle(at, box.shortestSide * 0.62, Paint()..color = l.accent.withValues(alpha: full ? 0.22 : 0.9));
    c.drawCircle(
        at,
        box.shortestSide * 0.8,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3 * x.u
          ..color = l.accent.withValues(alpha: 0.5));
    c.restore();
  }

  @override
  void paintDecor(Canvas c, StudioPaintContext x) {
    // The one accent in the words' column: a short thick rule over the
    // first line, where it has room.
    final first = x.layout.blocks.isEmpty ? null : x.layout.blocks.first;
    if (first == null) return;
    final u = x.u;
    final bar = Rect.fromLTWH(first.box.left, first.box.top - 40 * u, 150 * u, 14 * u);
    final img = x.layout.zones.image;
    final full = img.width >= x.size.width - 0.5;
    if (bar.top < x.layout.zones.safe.top || (!full && bar.overlaps(img.inflate(8 * u)))) return;
    c.drawRect(bar, Paint()..color = x.look.accent);
  }
}
