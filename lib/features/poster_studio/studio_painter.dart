import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import 'studio_contrast.dart';
import 'studio_fonts.dart';
import 'studio_layout.dart';
import 'studio_models.dart';
import 'studio_palettes.dart';
import 'studio_templates.dart';

/// Everything one event poster is drawn from.
class StudioScene {
  const StudioScene({
    required this.design,
    required this.template,
    required this.palette,
    this.image,
    this.logo,
    this.variant = 0,
    this.seed = 1,
  });

  final EventDesign design;
  final EventTemplate template;
  final StudioPalette palette;

  /// The AI picture (or his photo); null: the template draws its own art.
  final ui.Image? image;

  /// His logo or a small photo, in the template's logo corner.
  final ui.Image? logo;

  /// The arrangement ("Variation").
  final int variant;

  /// Seeds the drawn art, so a poster never reshuffles itself.
  final int seed;
}

/// A scrim behind some words.
class StudioPanel {
  const StudioPanel(this.rect, this.alpha, this.blur, this.fields);
  final Rect rect;
  final double alpha;
  final bool blur;
  final Set<StudioField> fields;
}

/// A laid-out poster with its scrims, ready to paint.
class PreparedStudio {
  const PreparedStudio(this.scene, this.look, this.layout, this.panels, this.contrast);
  final StudioScene scene;
  final StudioLook look;
  final StudioLayout layout;
  final List<StudioPanel> panels;

  /// Each line's contrast against what is finally under it.
  final Map<StudioField, double> contrast;

  Size get size => layout.size;
  List<StudioField> get needs => layout.needs;
}

/// Words drawn straight on the backdrop (the pills carry their own fill).
const _onBackdrop = {StudioField.title, StudioField.subtitle, StudioField.location, StudioField.details};

StudioPaintContext _context(StudioScene s, StudioLook look, StudioLayout l) =>
    StudioPaintContext(l.size, look, s.palette, l, s.seed, s.image);

StudioLayout _layout(StudioScene s) => layoutStudio(
      design: s.design,
      template: s.template,
      variant: s.variant,
      logo: s.logo != null,
    );

Map<StudioField, double> _pillContrast(StudioLook look, StudioLayout l) => {
      if (l.block(StudioField.date) != null) StudioField.date: contrastRatio(look.chipInk, look.chipFill),
      if (l.block(StudioField.cta) != null)
        StudioField.cta: look.ctaFill.map((f) => contrastRatio(look.ctaInk, f)).reduce(math.min),
    };

/// Laid out without measuring the picture (thumbnails): no scrims.
PreparedStudio prepareStudioSync(StudioScene s) {
  final look = s.template.look(s.palette);
  final l = _layout(s);
  return PreparedStudio(s, look, l, const [], _pillContrast(look, l));
}

/// Laid out, then measured: every line of words gets the scrim its
/// backdrop needs to reach 4.5:1.
Future<PreparedStudio> prepareStudio(StudioScene s) async {
  final look = s.template.look(s.palette);
  final l = _layout(s);
  final x = _context(s, look, l);
  final grid = await LuminanceGrid.capture(l.size, (c) {
    s.template.paintBackdrop(c, x);
    s.template.paintDecor(c, x);
  });
  return prepareWithGrid(s, look, l, grid);
}

/// The measuring half of [prepareStudio], for a grid already captured.
PreparedStudio prepareWithGrid(StudioScene s, StudioLook look, StudioLayout l, LuminanceGrid grid) {
  final u = l.unit;
  final contrast = _pillContrast(look, l);
  final wants = <({StudioBlock block, ScrimPlan plan, Rect rect})>[];
  for (final b in l.blocks) {
    if (!_onBackdrop.contains(b.field)) continue;
    final ink = look.inkFor(b.field);
    final plan = planScrim(ink, grid.tone(b.ink.inflate(b.fontSize * 0.12)), look.panel);
    contrast[b.field] = plan.after;
    if (!plan.needed) continue;
    final padX = (b.fontSize * 0.5).clamp(18 * u, 40 * u), padY = (b.fontSize * 0.3).clamp(12 * u, 28 * u);
    wants.add((block: b, plan: plan, rect: Rect.fromLTRB(b.ink.left - padX, b.ink.top - padY, b.ink.right + padX, b.ink.bottom + padY)));
  }
  // One glass panel behind the whole run of words that needs it (the
  // pills between included): a card, not a patchwork of boxes.
  final panels = <StudioPanel>[];
  if (wants.isNotEmpty) {
    final first = l.blocks.indexOf(wants.first.block), last = l.blocks.indexOf(wants.last.block);
    var rect = wants.first.rect;
    for (final w in wants) {
      rect = rect.expandToInclude(w.rect);
    }
    for (var i = first; i <= last; i++) {
      rect = rect.expandToInclude(l.blocks[i].box.inflate(12 * u));
    }
    panels.add(StudioPanel(
      rect.intersect((Offset.zero & l.size).deflate(4 * u)),
      wants.map((w) => w.plan.alpha).reduce(math.max),
      wants.any((w) => w.plan.blur),
      {for (var i = first; i <= last; i++) if (_onBackdrop.contains(l.blocks[i].field)) l.blocks[i].field},
    ));
  }
  // The shared panel is as strong as its neediest line: re-measure.
  for (final p in panels) {
    for (final f in p.fields) {
      final b = l.block(f)!;
      contrast[f] = contrastOver(look.inkFor(f), grid.tone(b.ink.inflate(b.fontSize * 0.12)), look.panel, p.alpha);
    }
  }
  return PreparedStudio(s, look, l, panels, contrast);
}

// ───────────────────────────── painting ───────────────────────────────────

void paintStudio(Canvas c, PreparedStudio r, {bool words = true}) {
  final s = r.scene;
  final l = r.layout;
  final look = r.look;
  final x = _context(s, look, l);
  final u = l.unit;
  c.save();
  c.clipRect(Offset.zero & l.size);
  s.template.paintBackdrop(c, x);
  s.template.paintDecor(c, x);

  for (final p in r.panels) {
    final rr = RRect.fromRectAndRadius(p.rect, Radius.circular(28 * u));
    if (p.blur && s.image != null) {
      // Frosted glass: the backdrop again (veil and all, so it is never
      // lighter than what was measured), softly blurred, inside the panel.
      c.save();
      c.clipRRect(rr);
      c.saveLayer(
          rr.outerRect,
          Paint()
            ..imageFilter =
                ui.ImageFilter.blur(sigmaX: 22 * u, sigmaY: 22 * u, tileMode: TileMode.clamp));
      s.template.paintBackdrop(c, x);
      c.restore();
      c.restore();
    }
    c.drawRRect(rr, Paint()..color = look.panel.withValues(alpha: p.alpha));
    if (look.panelRim != null) {
      c.drawRRect(
          rr,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2 * u
            ..color = look.panelRim!);
    }
  }

  final logo = s.logo;
  final lr = l.zones.logo;
  if (logo != null && lr != null) _paintLogo(c, logo, lr, look, u);

  if (words) {
    for (final b in l.blocks) {
      switch (b.field) {
        case StudioField.date:
          _paintChip(c, b, look, u);
        case StudioField.cta:
          _paintCta(c, b, look, u);
        case StudioField.location:
          _paintPin(c, b.icon!, look.icon);
          _paintText(c, b, look.body);
        case StudioField.title:
          _paintTitle(c, b, look);
        case StudioField.subtitle:
          _paintText(c, b, look.subtitle);
        default:
          _paintText(c, b, look.body);
      }
    }
  }
  c.restore();
}

void _paintText(Canvas c, StudioBlock b, Color colour, {List<Shadow>? shadows, Paint? foreground}) {
  final style = b.style.copyWith(
    color: foreground == null ? colour : null,
    foreground: foreground,
    shadows: shadows,
  );
  studioPainter(b.text, style, b.align)
    ..layout(minWidth: b.layoutWidth, maxWidth: b.layoutWidth)
    ..paint(c, b.textAt);
}

void _paintTitle(Canvas c, StudioBlock b, StudioLook look) {
  final glow = look.titleGlow;
  final shadows = glow == null
      ? [Shadow(color: StudioInk.black.withValues(alpha: 0.35), blurRadius: b.fontSize * 0.12, offset: Offset(0, b.fontSize * 0.03))]
      : [
          Shadow(color: glow.withValues(alpha: 0.55), blurRadius: b.fontSize * 0.34),
          Shadow(color: glow.withValues(alpha: 0.35), blurRadius: b.fontSize * 0.1),
        ];
  final foil = look.titleFoil;
  if (foil == null) {
    _paintText(c, b, look.title, shadows: shadows);
    return;
  }
  // Gold foil across the letters themselves.
  final local = b.ink.shift(-b.textAt);
  final paint = Paint()
    ..shader = ui.Gradient.linear(local.topLeft, local.bottomRight, foil,
        [for (var i = 0; i < foil.length; i++) i / (foil.length - 1)]);
  c.save();
  c.translate(b.textAt.dx, b.textAt.dy);
  final style = b.style.copyWith(foreground: paint, shadows: shadows);
  studioPainter(b.text, style, b.align)
    ..layout(minWidth: b.layoutWidth, maxWidth: b.layoutWidth)
    ..paint(c, Offset.zero);
  c.restore();
}

void _paintChip(Canvas c, StudioBlock b, StudioLook look, double u) {
  final rr = RRect.fromRectAndRadius(b.box, Radius.circular(b.box.height / 2));
  c.drawRRect(rr, Paint()..color = look.chipFill);
  c.drawRRect(
      rr,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.6 * u
        ..shader = _across(b.box, look.chipRim));
  if (b.icon != null) _paintCalendar(c, b.icon!, look.chipInk);
  _paintText(c, b, look.chipInk);
}

/// A left-to-right gradient of any number of colours (one: flat).
Shader _across(Rect r, List<Color> colours) {
  final cs = colours.length == 1 ? [colours.first, colours.first] : colours;
  return ui.Gradient.linear(
      r.centerLeft, r.centerRight, cs, [for (var i = 0; i < cs.length; i++) i / (cs.length - 1)]);
}

void _paintCta(Canvas c, StudioBlock b, StudioLook look, double u) {
  final rr = RRect.fromRectAndRadius(b.box, Radius.circular(b.box.height / 2));
  if (look.ctaGlow) {
    c.drawRRect(
        rr.inflate(4 * u),
        Paint()
          ..shader = _across(b.box, [for (final f in look.ctaFill) f.withValues(alpha: 0.55)])
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, 22 * u));
  }
  c.drawRRect(rr, Paint()..shader = _across(b.box, look.ctaFill));
  _paintText(c, b, look.ctaInk);
}

/// A map pin: a round head with a hole, tapering to a point.
void _paintPin(Canvas c, Rect r, Color colour) {
  final cx = r.center.dx;
  final rad = r.width * 0.34;
  final head = Offset(cx, r.top + rad + r.height * 0.06);
  final tip = Offset(cx, r.bottom - r.height * 0.04);
  final body = Path()
    ..addOval(Rect.fromCircle(center: head, radius: rad))
    ..moveTo(cx - rad * 0.86, head.dy + rad * 0.5)
    ..quadraticBezierTo(cx - rad * 0.4, head.dy + rad * 1.3, tip.dx, tip.dy)
    ..quadraticBezierTo(cx + rad * 0.4, head.dy + rad * 1.3, cx + rad * 0.86, head.dy + rad * 0.5)
    ..close();
  final hole = Path()..addOval(Rect.fromCircle(center: head, radius: rad * 0.4));
  c.drawPath(Path.combine(PathOperation.difference, body, hole), Paint()..color = colour);
}

/// A small calendar page.
void _paintCalendar(Canvas c, Rect r, Color colour) {
  final s = r.width;
  final page = Rect.fromLTWH(r.left + s * 0.08, r.top + s * 0.16, s * 0.84, s * 0.76);
  final stroke = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = s * 0.09
    ..color = colour;
  c.drawRRect(RRect.fromRectAndRadius(page, Radius.circular(s * 0.12)), stroke);
  c.drawRect(Rect.fromLTWH(page.left, page.top, page.width, s * 0.2), Paint()..color = colour);
  final ring = Paint()
    ..strokeWidth = s * 0.1
    ..strokeCap = StrokeCap.round
    ..color = colour;
  c.drawLine(Offset(page.left + s * 0.22, r.top + s * 0.06), Offset(page.left + s * 0.22, r.top + s * 0.24), ring);
  c.drawLine(Offset(page.right - s * 0.22, r.top + s * 0.06), Offset(page.right - s * 0.22, r.top + s * 0.24), ring);
  final dot = Paint()..color = colour;
  for (var i = 0; i < 3; i++) {
    c.drawCircle(Offset(page.left + page.width * (0.27 + i * 0.23), page.top + page.height * 0.62), s * 0.055, dot);
  }
}

void _paintLogo(Canvas c, ui.Image img, Rect r, StudioLook look, double u) {
  final rr = RRect.fromRectAndRadius(r, Radius.circular(r.width * 0.22));
  c.drawRRect(rr.inflate(5 * u), Paint()..color = look.panel);
  c.save();
  c.clipRRect(rr);
  paintCover(c, img, r);
  c.restore();
  c.drawRRect(
      rr.inflate(5 * u),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3 * u
        ..shader = _across(r, look.rim));
}

/// Records the poster once; the preview replays it at any size.
ui.Picture recordStudio(PreparedStudio r) {
  final rec = ui.PictureRecorder();
  paintStudio(Canvas(rec, Offset.zero & r.size), r);
  return rec.endRecording();
}

/// The poster as the PNG he shares, at full size (1080 wide).
Future<Uint8List> renderStudioPng(PreparedStudio r) async {
  await StudioFonts.ensureLoaded();
  final pic = recordStudio(r);
  final img = await pic.toImage(r.size.width.round(), r.size.height.round());
  pic.dispose();
  final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return bytes!.buffer.asUint8List();
}

/// What a screen reader says for the poster.
String describeStudio(EventDesign d) => [
      if (d.title.isNotEmpty) d.title,
      if (d.subtitle.isNotEmpty) d.subtitle,
      if (d.when.isNotEmpty) d.when.replaceAll('  ·  ', ', '),
      if (d.location.isNotEmpty) 'at ${d.location}',
      ...d.details,
      if (d.cta.isNotEmpty) d.cta,
    ].join('. ');
