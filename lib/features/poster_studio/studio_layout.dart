import 'dart:math' as math;

import 'package:flutter/painting.dart';

import '../poster/poster_models.dart' show scriptOf;
import 'studio_fonts.dart';
import 'studio_models.dart';
import 'studio_templates.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  THE POSTER'S WORDS ARE NEVER CUT (2026-09-30). Every line is laid out
///  whole: the title is the largest thing on the poster and takes the
///  biggest size at which it fits its lines without breaking a word; then
///  the title, the other lines and the gaps give way in that order; then
///  the column grows into the rest of the poster. No ellipsis, no maxLines
///  on a painter, no clipping. Only when even that cannot fit does the
///  layout name the line to shorten ([StudioLayout.needs]).
///
///  Sizes are written for a 1080-px-wide poster and scale with it.
/// ─────────────────────────────────────────────────────────────────────────

/// A template's lettering.
class StudioType {
  const StudioType({
    required this.title,
    required this.subtitle,
    required this.body,
    required this.strong,
    this.titleMax = 132,
    this.titleMin = 46,
    this.titleLines = 3,
    this.titleHeight = 1.02,
    this.titleSpacing = -0.012,
    this.subtitleSize = 44,
    this.subtitleHeight = 1.22,
    this.bodySize = 36,
    this.chipSize = 35,
    this.detailSize = 31,
    this.ctaSize = 37,
  });

  final String title;
  final String subtitle;
  final String body;

  /// Chips and the call to action.
  final String strong;
  final double titleMax;
  final double titleMin;
  final int titleLines;
  final double titleHeight;

  /// Letter spacing as a share of the size (negative: tighter).
  final double titleSpacing;
  final double subtitleSize;
  final double subtitleHeight;
  final double bodySize;
  final double chipSize;
  final double detailSize;
  final double ctaSize;
}

/// Where things go on a poster of one shape, in one of a template's
/// arrangements.
class StudioZones {
  const StudioZones({
    required this.image,
    required this.text,
    required this.safe,
    this.anchor = 1,
    this.align = TextAlign.left,
    this.logo,
    this.whenFirst = false,
  });

  /// The picture (or the drawn art standing in for it).
  final Rect image;

  /// The column the words stand in.
  final Rect text;

  /// Nothing is drawn outside it; the column may grow to it.
  final Rect safe;

  /// Where the words sit in their column: 0 top, 0.5 centre, 1 bottom.
  final double anchor;
  final TextAlign align;

  /// The logo's square, when he added one.
  final Rect? logo;

  /// The date chip above the title, as an eyebrow.
  final bool whenFirst;
}

/// One laid-out line group of the poster.
class StudioBlock {
  const StudioBlock({
    required this.field,
    required this.text,
    required this.box,
    required this.ink,
    required this.textAt,
    required this.layoutWidth,
    required this.fontSize,
    required this.style,
    required this.align,
    required this.lines,
    this.icon,
  });

  /// title, subtitle, date (the date + time chip), location, details, cta.
  final StudioField field;

  /// Exactly the words drawn.
  final String text;

  /// The whole block: a chip's pill, the pin and its words.
  final Rect box;

  /// The words' own bounds (what a scrim must cover).
  final Rect ink;

  /// Where the paragraph is painted, and the width it is laid out at.
  final Offset textAt;
  final double layoutWidth;
  final double fontSize;

  /// Its style, without colour.
  final TextStyle style;
  final TextAlign align;
  final int lines;

  /// The pin (location) or the calendar (date chip).
  final Rect? icon;

  bool get pill => field == StudioField.date || field == StudioField.cta;
}

class StudioLayout {
  const StudioLayout({
    required this.size,
    required this.zones,
    required this.column,
    required this.blocks,
    this.needs = const [],
  });

  final Size size;
  final StudioZones zones;

  /// The column the words finally took (the zone, or grown from it).
  final Rect column;
  final List<StudioBlock> blocks;

  /// Lines too long for this poster even at the smallest sizes.
  final List<StudioField> needs;

  StudioBlock? block(StudioField f) {
    for (final b in blocks) {
      if (b.field == f) return b;
    }
    return null;
  }

  double get unit => size.width / 1080;
}

bool _indic(String text) => scriptOf(text) != 'en';

/// A style for [text] in [family] at [size]. Indic scripts keep their own
/// generous line height and no tracking, so vowel signs never collide.
TextStyle studioStyle(String text, String family, double size,
    {double height = 1.2, double spacing = 0, bool strong = false}) {
  final indic = _indic(text);
  return TextStyle(
    fontFamily: family,
    fontFamilyFallback: StudioFonts.fallback(strong),
    fontSize: indic ? size * 1.06 : size,
    height: indic ? null : height,
    letterSpacing: indic ? 0 : spacing * size,
  );
}

final _joinedHyphen = RegExp(r'(?<=[\p{L}\p{N}])-(?=[\p{L}\p{N}])', unicode: true);

/// A line never breaks after the hyphen inside a word ("Get-Together"):
/// an invisible word joiner follows it. Nothing visible changes.
String studioUnbreakable(String text) => text.replaceAll(_joinedHyphen, '-⁠');

/// The painter for one block: never a maxLines, never an ellipsis.
TextPainter studioPainter(String text, TextStyle style, TextAlign align) => TextPainter(
      text: TextSpan(text: studioUnbreakable(text), style: style),
      textAlign: align,
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
    );

class _Measure {
  _Measure(this.painter, this.width, this.height, this.lines, this.left);
  final TextPainter painter;
  final double width;
  final double height;
  final int lines;

  /// The first pixel of the widest line, from the paragraph's left.
  final double left;
}

_Measure _measure(String text, TextStyle style, double maxW, TextAlign align) {
  final p = studioPainter(text, style, align)..layout(minWidth: maxW, maxWidth: maxW);
  final m = p.computeLineMetrics();
  var w = 0.0, left = maxW;
  for (final l in m) {
    w = math.max(w, l.width);
    left = math.min(left, l.left);
  }
  return _Measure(p, w, p.height, m.length, m.isEmpty ? 0 : left);
}

/// True when no single word of [text] is wider than [maxW] — a word that
/// is would be broken across lines.
bool studioWordsFit(String text, TextStyle style, double maxW) {
  for (final w in text.split(RegExp(r'\s+'))) {
    if (w.isEmpty) continue;
    final p = studioPainter(w, style, TextAlign.left)..layout();
    if (p.width > maxW + 0.5) return false;
  }
  return true;
}

class _Draft {
  _Draft(this.field, this.text, this.w, this.h, this.build);
  final StudioField field;
  final String text;
  final double w;
  final double h;

  /// Places it with its box's top-left at the given point.
  final StudioBlock Function(Offset at) build;
}

/// Lays out [design] on [template] in one of its arrangements ([variant]).
StudioLayout layoutStudio({
  required EventDesign design,
  required EventTemplate template,
  StudioFormat? format,
  int variant = 0,
  bool logo = false,
}) {
  final size = (format ?? design.format).size;
  final u = size.width / 1080;
  final z = template.zones(size, variant, logo: logo);
  final ty = template.type;
  final align = z.align;
  final when = design.when;
  final fields = <StudioField>[
    if (z.whenFirst && when.isNotEmpty) StudioField.date,
    if (design.title.isNotEmpty) StudioField.title,
    if (design.subtitle.isNotEmpty) StudioField.subtitle,
    if (!z.whenFirst && when.isNotEmpty) StudioField.date,
    if (design.location.isNotEmpty) StudioField.location,
    if (design.details.isNotEmpty) StudioField.details,
    if (design.cta.isNotEmpty) StudioField.cta,
  ];

  TextStyle titleStyle(double s) => studioStyle(design.title, ty.title, s,
      height: ty.titleHeight, spacing: ty.titleSpacing, strong: true);

  _Draft draft(StudioField f, double width, double ts, double k) {
    double x0(double w) => align == TextAlign.center ? (width - w) / 2 : 0;
    // Nothing outranks the title, however far it had to shrink.
    double sized(double base) => math.min(base * u * k, ts * 0.8);
    switch (f) {
      case StudioField.title:
      case StudioField.subtitle:
      case StudioField.details:
        final text = switch (f) {
          StudioField.title => design.title,
          StudioField.subtitle => design.subtitle,
          _ => design.details.map((d) => '•  $d').join('\n'),
        };
        final style = switch (f) {
          StudioField.title => titleStyle(ts),
          StudioField.subtitle => studioStyle(text, ty.subtitle, sized(ty.subtitleSize),
              height: ty.subtitleHeight),
          _ => studioStyle(text, ty.body, sized(ty.detailSize), height: 1.3),
        };
        final m = _measure(text, style, width, align);
        return _Draft(f, text, m.width, m.height, (at) {
          final origin = Offset(at.dx - x0(m.width), at.dy);
          return StudioBlock(
            field: f,
            text: text,
            box: Rect.fromLTWH(at.dx, at.dy, m.width, m.height),
            ink: Rect.fromLTWH(origin.dx + m.left, at.dy, m.width, m.height),
            textAt: origin,
            layoutWidth: width,
            fontSize: style.fontSize!,
            style: style,
            align: align,
            lines: m.lines,
          );
        });
      case StudioField.location:
        final fs = sized(ty.bodySize);
        final icon = fs * 1.05, gap = fs * 0.42;
        final style = studioStyle(design.location, ty.body, fs, height: 1.24);
        final m = _measure(design.location, style, width - icon - gap, TextAlign.left);
        final lw = m.width.ceilToDouble() + 1;
        final w = icon + gap + lw;
        final h = math.max(m.height, icon);
        return _Draft(f, design.location, w, h, (at) {
          final firstLine = m.lines == 0 ? h : m.height / m.lines;
          return StudioBlock(
            field: f,
            text: design.location,
            box: Rect.fromLTWH(at.dx, at.dy, w, h),
            ink: Rect.fromLTWH(at.dx, at.dy, w, h),
            textAt: Offset(at.dx + icon + gap, at.dy),
            layoutWidth: lw,
            fontSize: fs,
            style: style,
            align: TextAlign.left,
            lines: m.lines,
            icon: Rect.fromLTWH(at.dx, at.dy + math.max(0, (firstLine - icon) / 2), icon, icon),
          );
        });
      case StudioField.date:
      case StudioField.cta:
        final isCta = f == StudioField.cta;
        final text = isCta ? design.cta : when;
        final fs = sized(isCta ? ty.ctaSize : ty.chipSize);
        final padH = fs * (isCta ? 1.15 : 0.72), padV = fs * (isCta ? 0.62 : 0.46);
        final icon = isCta ? 0.0 : fs * 0.95, gap = isCta ? 0.0 : fs * 0.45;
        final style = studioStyle(text, ty.strong, fs, height: 1.18, spacing: 0.01, strong: true);
        final m = _measure(text, style, math.max(fs, width - 2 * padH - icon - gap),
            isCta ? TextAlign.center : TextAlign.left);
        final lw = m.width.ceilToDouble() + 1;
        final w = 2 * padH + icon + gap + lw;
        final h = math.max(m.height, icon) + 2 * padV;
        return _Draft(f, text, w, h, (at) => StudioBlock(
              field: f,
              text: text,
              box: Rect.fromLTWH(at.dx, at.dy, w, h),
              ink: Rect.fromLTWH(at.dx, at.dy, w, h),
              textAt: Offset(at.dx + padH + icon + gap, at.dy + (h - m.height) / 2),
              layoutWidth: lw,
              fontSize: fs,
              style: style,
              align: isCta ? TextAlign.center : TextAlign.left,
              lines: m.lines,
              icon: isCta ? null : Rect.fromLTWH(at.dx + padH, at.dy + (h - icon) / 2, icon, icon),
            ));
      case StudioField.time:
        throw StateError('time is drawn inside the date chip');
    }
  }

  double gapAfter(StudioField f, double g) => switch (f) {
        StudioField.title => 34 * u * g,
        StudioField.date when z.whenFirst => 28 * u * g,
        _ => 22 * u * g,
      };

  List<_Draft> drafts(double width, double ts, double k) =>
      [for (final f in fields) draft(f, width, ts, k)];

  double total(List<_Draft> ds, double g) {
    var t = 0.0;
    for (var i = 0; i < ds.length; i++) {
      t += ds[i].h;
      if (i < ds.length - 1) {
        t += ds[i + 1].field == StudioField.cta ? 40 * u * g : gapAfter(ds[i].field, g);
      }
    }
    return t;
  }

  var column = z.text;
  final width = column.width;

  // 1. The title: the biggest size at which it keeps to its lines and no
  //    word breaks; below the floor only if one word is wider than the
  //    column at it.
  var ts = ty.titleMax * u;
  final tMin = ty.titleMin * u;
  if (design.title.isNotEmpty) {
    bool fits(double s) {
      final st = titleStyle(s);
      return _measure(design.title, st, width, align).lines <= ty.titleLines &&
          studioWordsFit(design.title, st, width);
    }

    while (ts * 0.95 >= tMin && !fits(ts)) {
      ts *= 0.95;
    }
    while (ts > 18 * u && !studioWordsFit(design.title, titleStyle(ts), width)) {
      ts *= 0.95;
    }
  }

  // 2. The stack fits its column. The title gives up to a quarter of its
  //    size first, then the other lines a little, then the title down to
  //    its floor, then the rest, then the gaps — so it stays the biggest,
  //    boldest thing however much there is to say.
  var k = 1.0, g = 1.0;
  var ds = drafts(width, ts, k);
  bool over() => total(ds, g) > column.height;
  final tFit = ts;
  while (over() && ts * 0.95 >= math.max(tMin, tFit * 0.74)) {
    ts *= 0.95;
    ds = drafts(width, ts, k);
  }
  while (over() && k > 0.86) {
    k -= 0.04;
    ds = drafts(width, ts, k);
  }
  while (over() && ts * 0.95 >= tMin) {
    ts *= 0.95;
    ds = drafts(width, ts, k);
  }
  while (over() && k > 0.74) {
    k -= 0.04;
    ds = drafts(width, ts, k);
  }
  while (over() && g > 0.5) {
    g -= 0.1;
  }

  // 3. Still too tall: the column grows into the rest of the safe area,
  //    from its anchored edge; past that, the title (and only then) goes
  //    below its floor. Whatever still overflows is named, never cut.
  var h = total(ds, g);
  // It never grows over the logo.
  var growTop = z.safe.top, growBottom = z.safe.bottom;
  final lg = z.logo;
  if (lg != null) {
    if (lg.bottom <= z.text.top + 1) growTop = math.max(growTop, lg.bottom + 16 * u);
    if (lg.top >= z.text.bottom - 1) growBottom = math.min(growBottom, lg.top - 16 * u);
  }
  if (h > column.height) {
    column = switch (z.anchor) {
      >= 0.75 => Rect.fromLTRB(column.left, math.max(growTop, column.bottom - h), column.right, column.bottom),
      <= 0.25 => Rect.fromLTRB(column.left, column.top, column.right, math.min(growBottom, column.top + h)),
      _ => Rect.fromLTRB(column.left, growTop, column.right, growBottom),
    };
    if (h > column.height) column = Rect.fromLTRB(column.left, growTop, column.right, growBottom);
  }
  while (h > column.height && ts > 24 * u && design.title.isNotEmpty) {
    ts *= 0.95;
    ds = drafts(width, ts, k);
    h = total(ds, g);
  }
  final needs = <StudioField>[];
  if (h > column.height + 0.5) {
    final others = ds.where((d) => d.field != StudioField.title).toList()
      ..sort((a, b) => b.h.compareTo(a.h));
    needs.add(others.isEmpty ? StudioField.title : others.first.field);
  }

  // 4. Place the stack.
  final top = h <= column.height
      ? column.top + (column.height - h) * z.anchor
      : math.max(growTop, column.top);
  final blocks = <StudioBlock>[];
  var y = top;
  for (var i = 0; i < ds.length; i++) {
    final d = ds[i];
    final x = align == TextAlign.center ? column.left + (width - d.w) / 2 : column.left;
    blocks.add(d.build(Offset(x, y)));
    y += d.h;
    if (i < ds.length - 1) {
      y += ds[i + 1].field == StudioField.cta ? 40 * u * g : gapAfter(d.field, g);
    }
  }
  return StudioLayout(size: size, zones: z, column: column, blocks: blocks, needs: needs);
}
