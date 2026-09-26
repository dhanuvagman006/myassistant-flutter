import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  THE CARD'S ORNAMENTS — every flower, leaf, balloon and garland is drawn
///  here from plain curves. No clip-art, no downloaded images, nothing an
///  AI made (owner, 2026-09-26: "a photo with some designs like flowers or
///  something… we can do it without an image generation model").
///
///  All sizes are in card pixels (the card is 1080 wide), so the same call
///  draws the preview and the shared PNG identically. Anything random is
///  seeded, so a card looks the same every time it is drawn.
/// ─────────────────────────────────────────────────────────────────────────

const _tau = math.pi * 2;

Color _mix(Color a, Color b, double t) => Color.lerp(a, b, t)!;
Color _alpha(Color c, double a) => c.withValues(alpha: a);

/// Lighter or darker by [t] (-1..1), keeping the hue.
Color shade(Color c, double t) =>
    t >= 0 ? _mix(c, const Color(0xFFFFFFFF), t) : _mix(c, const Color(0xFF000000), -t);

// ─────────────────────────────── petals ────────────────────────────────

/// A petal with its base at the origin, pointing up (−y). [notch] dents
/// the tip (0 = round, 0.1 = a heart-shaped petal).
Path petalPath(double len, double wid, {double notch = 0, double lean = 0}) {
  final w = wid / 2;
  final p = Path()..moveTo(0, 0);
  p.cubicTo(-w * 1.1 + lean * w, -len * 0.12, -w * 1.25 + lean * w, -len * 0.78,
      -w * 0.52 + lean * w, -len * 0.96);
  if (notch > 0) {
    p.quadraticBezierTo(-w * 0.22 + lean * w, -len * 1.03, lean * w, -len * (1 - notch));
    p.quadraticBezierTo(w * 0.22 + lean * w, -len * 1.03, w * 0.52 + lean * w, -len * 0.96);
  } else {
    p.quadraticBezierTo(lean * w, -len * 1.07, w * 0.52 + lean * w, -len * 0.96);
  }
  p.cubicTo(w * 1.25 + lean * w, -len * 0.78, w * 1.1 + lean * w, -len * 0.12, 0, 0);
  p.close();
  return p;
}

Path _ring(Offset o, int n, double len, double wid, double rot,
    {double notch = 0, double base = 0}) {
  final path = Path();
  for (var i = 0; i < n; i++) {
    final a = rot + i * _tau / n;
    final m = Matrix4Lite.rotateAround(o, a, base: base);
    path.addPath(petalPath(len, wid, notch: notch), Offset.zero, matrix4: m);
  }
  return path;
}

/// A tiny 2D transform helper for placing petals: rotate by [angle] about
/// [o], after moving [base] out along the petal's own axis.
abstract final class Matrix4Lite {
  static Float64List rotateAround(Offset o, double angle, {double base = 0}) {
    final c = math.cos(angle), s = math.sin(angle);
    // Column-major 4x4: rotate, then translate to o + rotated (0, -base).
    final tx = o.dx + s * base;
    final ty = o.dy - c * base;
    return Float64List.fromList([
      c, s, 0, 0, //
      -s, c, 0, 0, //
      0, 0, 1, 0, //
      tx, ty, 0, 1,
    ]);
  }
}

void _softShadow(Canvas c, Path p, double blur, {double a = 0.16, Offset d = Offset.zero}) {
  c.drawPath(
    p.shift(d),
    Paint()
      ..color = _alpha(const Color(0xFF3A1F18), a)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, blur),
  );
}

/// A rose seen from above: rings of cupped petals, lighter at the edge,
/// deepening to a curled heart.
void paintRose(Canvas c, Offset o, double r,
    {required Color light, required Color mid, required Color deep, double rot = 0}) {
  // A soft shadow under the whole bloom lifts it off the paper.
  _softShadow(c, Path()..addOval(Rect.fromCircle(center: o, radius: r * 0.95)), r * 0.12,
      a: 0.18, d: Offset(r * 0.04, r * 0.08));
  const layers = [
    (n: 5, len: 1.0, wid: 1.02, rot: 0.0),
    (n: 5, len: 0.76, wid: 0.84, rot: 0.63),
    (n: 5, len: 0.54, wid: 0.66, rot: 0.2),
    (n: 4, len: 0.36, wid: 0.5, rot: 0.9),
  ];
  for (var i = 0; i < layers.length; i++) {
    final l = layers[i];
    final len = r * l.len;
    final path = _ring(o, l.n, len, r * l.wid, rot + l.rot);
    if (i > 0) _softShadow(c, path, r * 0.05, a: 0.22, d: Offset(0, r * 0.025));
    final t = i / (layers.length - 1);
    c.drawPath(
      path,
      Paint()
        ..shader = ui.Gradient.radial(o, len, [
          _mix(deep, mid, 0.15 + 0.2 * (1 - t)),
          _mix(mid, light, 0.25),
          _mix(light, const Color(0xFFFFFFFF), 0.25 * (1 - t)),
        ], [0.1, 0.62, 1.0]),
    );
    c.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(0.8, r * 0.016)
        ..color = _alpha(deep, 0.28),
    );
  }
  // The curled heart: a few tightening arcs.
  final heart = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeWidth = math.max(1, r * 0.035)
    ..color = _alpha(deep, 0.75);
  for (var k = 0; k < 3; k++) {
    final rr = r * (0.16 - k * 0.045);
    c.drawArc(Rect.fromCircle(center: o.translate(r * 0.01 * k, 0), radius: rr),
        rot + k * 1.7, math.pi * 1.25, false, heart);
  }
  c.drawCircle(o, r * 0.045, Paint()..color = _alpha(deep, 0.9));
}

/// A soft peony / garden rose: more, frillier petals and a glimpse of
/// golden stamens.
void paintPeony(Canvas c, Offset o, double r,
    {required Color light, required Color mid, required Color deep, double rot = 0}) {
  _softShadow(c, Path()..addOval(Rect.fromCircle(center: o, radius: r * 0.95)), r * 0.12,
      a: 0.16, d: Offset(r * 0.04, r * 0.08));
  const layers = [
    (n: 7, len: 1.0, wid: 0.95, rot: 0.0),
    (n: 6, len: 0.78, wid: 0.84, rot: 0.4),
    (n: 5, len: 0.56, wid: 0.72, rot: 0.1),
  ];
  for (var i = 0; i < layers.length; i++) {
    final l = layers[i];
    final len = r * l.len;
    final path = _ring(o, l.n, len, r * l.wid, rot + l.rot, notch: 0.08);
    if (i > 0) _softShadow(c, path, r * 0.05, a: 0.2, d: Offset(0, r * 0.02));
    c.drawPath(
      path,
      Paint()
        ..shader = ui.Gradient.radial(o, len, [
          _mix(deep, mid, 0.55),
          mid,
          _mix(light, const Color(0xFFFFFFFF), 0.3),
        ], [0.0, 0.55, 1.0]),
    );
    c.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(0.8, r * 0.014)
        ..color = _alpha(deep, 0.22),
    );
  }
  // Stamens.
  final rnd = math.Random((o.dx * 7 + o.dy * 13).round());
  for (var i = 0; i < 14; i++) {
    final a = rnd.nextDouble() * _tau;
    final d = r * (0.05 + rnd.nextDouble() * 0.16);
    c.drawCircle(o + Offset(math.cos(a) * d, math.sin(a) * d), r * 0.035,
        Paint()..color = const Color(0xFFE9B949));
  }
  c.drawCircle(o, r * 0.08, Paint()..color = _alpha(deep, 0.85));
}

/// A five-petal blossom (cherry, anemone, wild rose) with a stamen crown.
void paintBlossom(Canvas c, Offset o, double r,
    {required Color light,
    required Color mid,
    required Color centre,
    int petals = 5,
    double rot = 0,
    bool shadow = true}) {
  final path = _ring(o, petals, r, r * 1.05, rot, notch: 0.1);
  if (shadow) _softShadow(c, path, r * 0.1, a: 0.14, d: Offset(0, r * 0.06));
  c.drawPath(
    path,
    Paint()
      ..shader = ui.Gradient.radial(o, r, [_mix(mid, centre, 0.25), mid, light], [0, 0.45, 1]),
  );
  c.drawPath(
    path,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(0.7, r * 0.03)
      ..color = _alpha(_mix(mid, centre, 0.5), 0.35),
  );
  for (var i = 0; i < 8; i++) {
    final a = rot + i * _tau / 8;
    final p2 = o + Offset(math.cos(a), math.sin(a)) * (r * 0.26);
    c.drawLine(o, p2,
        Paint()
          ..strokeWidth = math.max(0.6, r * 0.03)
          ..color = _alpha(centre, 0.7));
    c.drawCircle(p2, r * 0.05, Paint()..color = const Color(0xFFE8B54A));
  }
  c.drawCircle(o, r * 0.12, Paint()..color = centre);
}

/// Baby's breath: a tiny five-dot flower.
void paintFiller(Canvas c, Offset o, double r, Color petal, Color heart) {
  final p = Paint()..color = petal;
  for (var i = 0; i < 5; i++) {
    final a = i * _tau / 5 - math.pi / 2;
    c.drawCircle(o + Offset(math.cos(a), math.sin(a)) * (r * 0.55), r * 0.5, p);
  }
  c.drawCircle(o, r * 0.32, Paint()..color = heart);
}

// ──────────────────────────────── leaves ───────────────────────────────

/// A pointed leaf from [base] along [angle] (radians, 0 = up), shaded as
/// if folded along its midrib.
void paintLeaf(Canvas c, Offset base, double angle, double len, double wid,
    {required Color light, required Color dark, bool vein = true, double curl = 0}) {
  final w = wid / 2;
  final left = Path()
    ..moveTo(0, 0)
    ..cubicTo(-w * 1.15, -len * 0.18, -w * 1.05 + curl * w, -len * 0.72, curl * w, -len)
    ..quadraticBezierTo(curl * w * 0.4, -len * 0.5, 0, 0)
    ..close();
  final right = Path()
    ..moveTo(0, 0)
    ..cubicTo(w * 1.15, -len * 0.18, w * 1.05 + curl * w, -len * 0.72, curl * w, -len)
    ..quadraticBezierTo(curl * w * 0.4, -len * 0.5, 0, 0)
    ..close();
  c.save();
  c.translate(base.dx, base.dy);
  c.rotate(angle);
  c.drawPath(Path()..addPath(left, Offset.zero)..addPath(right, Offset.zero),
      Paint()
        ..color = _alpha(const Color(0xFF1E2A1C), 0.12)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, math.max(1, wid * 0.12)));
  c.drawPath(left, Paint()..color = dark);
  c.drawPath(
      right,
      Paint()
        ..shader = ui.Gradient.linear(
            Offset.zero, Offset(0, -len), [light, _mix(light, dark, 0.35)]));
  if (vein) {
    c.drawPath(
      Path()
        ..moveTo(0, 0)
        ..quadraticBezierTo(curl * w * 0.4, -len * 0.5, curl * w, -len * 0.92),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(0.6, wid * 0.045)
        ..color = _alpha(shade(light, 0.35), 0.8),
    );
  }
  c.restore();
}

/// A round eucalyptus-style leaf.
void paintRoundLeaf(Canvas c, Offset o, double r, double angle, Color light, Color dark) {
  c.save();
  c.translate(o.dx, o.dy);
  c.rotate(angle);
  final rect = Rect.fromCenter(center: Offset.zero, width: r * 1.7, height: r * 2);
  c.drawOval(rect.shift(Offset(r * 0.05, r * 0.12)),
      Paint()
        ..color = _alpha(const Color(0xFF1E2A1C), 0.12)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.2));
  c.drawOval(
      rect,
      Paint()
        ..shader = ui.Gradient.linear(rect.topLeft, rect.bottomRight, [light, dark]));
  c.drawLine(Offset(0, r * 0.9), Offset(0, -r * 0.6),
      Paint()
        ..strokeWidth = math.max(0.6, r * 0.06)
        ..color = _alpha(shade(light, 0.4), 0.6));
  c.restore();
}

/// A curving stem with leaves along it, tapering to a bud.
void paintSprig(Canvas c, Offset start, double angle, double len,
    {required Color light,
    required Color dark,
    int leaves = 7,
    bool round = false,
    double bend = 0.25,
    double leafScale = 1,
    Color? bud}) {
  final dir = Offset(math.sin(angle), -math.cos(angle));
  final normal = Offset(-dir.dy, dir.dx);
  final end = start + dir * len;
  final ctrl = start + dir * (len * 0.5) + normal * (len * bend);
  Offset at(double t) {
    final a = start * ((1 - t) * (1 - t)) + ctrl * (2 * (1 - t) * t) + end * (t * t);
    return a;
  }

  Offset tangent(double t) {
    final d = (ctrl - start) * (2 * (1 - t)) + (end - ctrl) * (2 * t);
    return d / d.distance;
  }

  c.drawPath(
    Path()
      ..moveTo(start.dx, start.dy)
      ..quadraticBezierTo(ctrl.dx, ctrl.dy, end.dx, end.dy),
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = math.max(1.2, len * 0.012)
      ..color = dark,
  );
  for (var i = 0; i < leaves; i++) {
    final t = 0.14 + 0.8 * i / math.max(1, leaves - 1);
    final p = at(t);
    final tg = tangent(t);
    final side = i.isEven ? 1.0 : -1.0;
    final a = math.atan2(tg.dx, -tg.dy) + side * 0.75;
    final size = len * 0.2 * (1.1 - t * 0.55) * leafScale;
    if (round) {
      final o = p + Offset(math.sin(a), -math.cos(a)) * size * 0.55;
      paintRoundLeaf(c, o, size * 0.42, a, light, dark);
    } else {
      paintLeaf(c, p, a, size, size * 0.46, light: light, dark: dark, curl: side * 0.2);
    }
  }
  final ta = math.atan2(tangent(1).dx, -tangent(1).dy);
  if (bud != null) {
    c.drawOval(
        Rect.fromCenter(center: end + dir * (len * 0.02), width: len * 0.05, height: len * 0.07),
        Paint()..color = bud);
  } else if (!round) {
    paintLeaf(c, end, ta, len * 0.13 * leafScale, len * 0.06 * leafScale,
        light: light, dark: dark);
  }
}

// ───────────────────────────── footprints ──────────────────────────────
//
// Where an ornament really paints, as discs (centre, radius) in its own
// coordinates — so it can be kept off every word, measured from the art
// itself. A single "reach" circle round a corner was not enough: the
// Floral bouquet's sprig reached ~440 px while the check stopped at 360,
// and its leaf lay across the date (review, 2026-09-26).

typedef Footprint = List<(Offset, double)>;

/// The discs a [paintSprig] with the same arguments covers: its stem with
/// the leaves either side, and the tip leaf.
Footprint sprigFootprint(Offset start, double angle, double len,
    {double bend = 0.25, bool round = false, double leafScale = 1}) {
  final dir = Offset(math.sin(angle), -math.cos(angle));
  final normal = Offset(-dir.dy, dir.dx);
  final end = start + dir * len;
  final ctrl = start + dir * (len * 0.5) + normal * (len * bend);
  Offset at(double t) => start * ((1 - t) * (1 - t)) + ctrl * (2 * (1 - t) * t) + end * (t * t);
  return [
    for (var i = 0; i <= 12; i++)
      // A leaf reaches its own length from the stem.
      (at(i / 12), len * 0.2 * (1.1 - (i / 12) * 0.55) * leafScale + 3),
    if (!round) (end, len * 0.13 * leafScale + 3),
  ];
}

/// The discs a [paintLeaf] with the same arguments covers.
Footprint leafFootprint(Offset base, double angle, double len, double wid) {
  final dir = Offset(math.sin(angle), -math.cos(angle));
  return [
    for (final t in const [0.12, 0.35, 0.6, 0.85, 1.0])
      (base + dir * (len * t), math.max(wid * 0.6, len * 0.12) + 2),
  ];
}

/// The largest scale (1 down to [min]) at which [print], placed by
/// [place] (its local point and the scale → card point), keeps clear of
/// every rectangle in [keepOut] and every oval in [ovals]. Null when even
/// [min] would touch one — the ornament is then left out rather than laid
/// over a word.
double? fitScale(Footprint print, Offset Function(Offset p, double s) place,
    List<Rect> keepOut, {double min = 0.45, List<Rect> ovals = const []}) {
  bool hits(double s) {
    for (final (p, r0) in print) {
      final o = place(p, s);
      final r = r0 * s;
      for (final k in keepOut) {
        final dx = math.max(k.left - o.dx, math.max(0.0, o.dx - k.right));
        final dy = math.max(k.top - o.dy, math.max(0.0, o.dy - k.bottom));
        if (dx * dx + dy * dy < r * r) return true;
      }
      for (final e in ovals) {
        final a = e.width / 2 + r, b = e.height / 2 + r;
        final x = (o.dx - e.center.dx) / a, y = (o.dy - e.center.dy) / b;
        if (x * x + y * y < 1) return true;
      }
    }
    return false;
  }

  for (var s = 1.0; s >= min - 1e-9; s -= 0.04) {
    if (!hits(s)) return s;
  }
  return null;
}

/// [fitScale] for an ornament drawn at [origin], rotated by [rot] and
/// scaled (mirrored when [mirror]).
double? fitAt(Footprint print, Offset origin, List<Rect> keepOut,
    {double rot = 0, bool mirror = false, double min = 0.45, List<Rect> ovals = const []}) {
  final c = math.cos(rot), sn = math.sin(rot);
  return fitScale(print, (p, s) {
    final x = (mirror ? -p.dx : p.dx) * s, y = p.dy * s;
    return origin + Offset(x * c - y * sn, x * sn + y * c);
  }, keepOut, min: min, ovals: ovals);
}

// ─────────────────────────────── marigolds ─────────────────────────────

/// A marigold from above: a dense pom-pom of ruffled petals.
void paintMarigold(Canvas c, Offset o, double r,
    {required Color light, required Color mid, required Color deep, int seed = 0}) {
  final rnd = math.Random(seed + (o.dx * 3 + o.dy * 5).round());
  c.drawCircle(o.translate(r * 0.06, r * 0.1), r * 1.02,
      Paint()
        ..color = _alpha(const Color(0xFF40210A), 0.22)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.14));
  c.drawCircle(o, r, Paint()..color = _mix(deep, mid, 0.3));
  const rings = [
    (rad: 0.86, n: 20, s: 0.3),
    (rad: 0.66, n: 16, s: 0.3),
    (rad: 0.46, n: 12, s: 0.28),
    (rad: 0.26, n: 8, s: 0.25),
  ];
  for (var k = 0; k < rings.length; k++) {
    final ring = rings[k];
    final off = rnd.nextDouble() * _tau;
    final t = k / (rings.length - 1);
    for (var i = 0; i < ring.n; i++) {
      final a = off + i * _tau / ring.n;
      final p = o + Offset(math.cos(a), math.sin(a)) * (r * ring.rad);
      final pr = r * ring.s;
      final rect = Rect.fromCenter(center: p, width: pr * 1.5, height: pr * 1.15);
      c.save();
      c.translate(p.dx, p.dy);
      c.rotate(a);
      c.translate(-p.dx, -p.dy);
      c.drawOval(
          rect,
          Paint()
            ..shader = ui.Gradient.radial(p.translate(-pr * 0.2, -pr * 0.2), pr * 0.9,
                [_mix(light, mid, 0.2 + 0.4 * (1 - t)), _mix(mid, deep, 0.35)]));
      c.drawArc(rect.deflate(pr * 0.1), -0.6, 1.2, false,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = math.max(0.6, r * 0.03)
            ..color = _alpha(deep, 0.45));
      c.restore();
    }
  }
  c.drawCircle(o, r * 0.12, Paint()..color = _mix(mid, light, 0.4));
}

/// A marigold-and-mango-leaf garland (toran) across the top of the card,
/// with strings of flowers hanging from it.
void paintToran(Canvas c, double left, double right, double y, double sag,
    {required Color light,
    required Color mid,
    required Color deep,
    required Color alt,
    required Color altLight,
    required Color leafLight,
    required Color leafDark,
    double flower = 26,
    int drops = 7,
    int seed = 1}) {
  Offset at(double t) {
    final x = left + (right - left) * t;
    return Offset(x, y + sag * 4 * t * (1 - t));
  }

  // Mango leaves hang behind the rope.
  final n = ((right - left) / (flower * 1.55)).floor();
  for (var i = 0; i <= n; i += 2) {
    final p = at(i / n);
    paintLeaf(c, p, math.pi + (i.isEven ? 0.18 : -0.18), flower * 2.6, flower * 0.95,
        light: leafLight, dark: leafDark);
  }
  // Hanging strings.
  for (var d = 0; d < drops; d++) {
    final t = (d + 0.5) / drops;
    final top = at(t);
    final count = 3 + ((d - (drops - 1) / 2).abs() < 1.2 ? 1 : 0);
    c.drawLine(top, top + Offset(0, flower * 1.6 * count),
        Paint()
          ..strokeWidth = 2
          ..color = _alpha(deep, 0.5));
    for (var k = 1; k <= count; k++) {
      final p = top + Offset(0, flower * 1.55 * k);
      final isAlt = (k + d).isEven;
      paintMarigold(c, p, flower * 0.66,
          light: isAlt ? altLight : light,
          mid: isAlt ? alt : mid,
          deep: isAlt ? shade(alt, -0.35) : deep,
          seed: seed + d * 7 + k);
    }
    final tip = top + Offset(0, flower * 1.55 * count + flower * 0.6);
    paintLeaf(c, tip, math.pi, flower * 1.3, flower * 0.55, light: leafLight, dark: leafDark);
  }
  // The rope of flowers.
  for (var i = 0; i <= n; i++) {
    final p = at(i / n);
    final isAlt = i % 3 == 1;
    paintMarigold(c, p, flower,
        light: isAlt ? altLight : light,
        mid: isAlt ? alt : mid,
        deep: isAlt ? shade(alt, -0.35) : deep,
        seed: seed + i);
  }
}

// ─────────────────────────────── mandala ───────────────────────────────

/// A lotus petal (pointed), base at origin, pointing up.
Path lotusPath(double len, double wid) {
  final w = wid / 2;
  return Path()
    ..moveTo(0, 0)
    ..cubicTo(-w * 1.3, -len * 0.25, -w * 0.9, -len * 0.7, 0, -len)
    ..cubicTo(w * 0.9, -len * 0.7, w * 1.3, -len * 0.25, 0, 0)
    ..close();
}

/// A rangoli-style mandala in foil lines over soft fills.
void paintMandala(Canvas c, Offset o, double r,
    {required LinearGradient foil,
    required Color fill,
    required Color fill2,
    required Color accent,
    double opacity = 1,
    double line = 2.2}) {
  final bounds = Rect.fromCircle(center: o, radius: r);
  final stroke = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = line
    ..shader = foil.createShader(bounds);
  Paint fillOf(Color col, double a) => Paint()..color = _alpha(col, a * opacity);

  void petals(int n, double base, double len, double wid, double rot, Paint f,
      {bool lotus = true}) {
    final path = Path();
    for (var i = 0; i < n; i++) {
      final m = Matrix4Lite.rotateAround(o, rot + i * _tau / n, base: base);
      path.addPath(lotus ? lotusPath(len, wid) : petalPath(len, wid), Offset.zero, matrix4: m);
    }
    c.drawPath(path, f);
    c.drawPath(path, stroke);
  }

  // Outer lotus crown.
  petals(16, r * 0.7, r * 0.3, r * 0.2, 0, fillOf(fill, 0.85));
  petals(16, r * 0.7, r * 0.18, r * 0.09, 0, fillOf(accent, 0.9));
  // Dotted ring.
  final dots = Paint()..shader = foil.createShader(bounds);
  for (var i = 0; i < 32; i++) {
    final a = i * _tau / 32 + _tau / 64;
    c.drawCircle(o + Offset(math.cos(a), math.sin(a)) * (r * 0.66), r * 0.018, dots);
  }
  c.drawCircle(o, r * 0.62, stroke);
  // Scallops.
  for (var i = 0; i < 24; i++) {
    final a = i * _tau / 24;
    final p = o + Offset(math.cos(a), math.sin(a)) * (r * 0.62);
    c.drawArc(Rect.fromCircle(center: p, radius: r * 0.08), a - math.pi / 2, math.pi, false,
        stroke);
  }
  c.drawCircle(o, r * 0.5, fillOf(fill2, 0.55));
  c.drawCircle(o, r * 0.5, stroke);
  petals(12, r * 0.2, r * 0.28, r * 0.17, _tau / 24, fillOf(fill, 0.9), lotus: false);
  petals(8, r * 0.1, r * 0.17, r * 0.12, 0, fillOf(accent, 0.95));
  c.drawCircle(o, r * 0.1, fillOf(fill2, 1));
  c.drawCircle(o, r * 0.1, stroke);
  c.drawCircle(o, r * 0.035, Paint()..shader = foil.createShader(bounds));
}

// ─────────────────────────── balloons & party ──────────────────────────

Path balloonPath(double r) => Path()
  ..moveTo(0, -1.12 * r)
  ..cubicTo(0.64 * r, -1.12 * r, 1.0 * r, -0.62 * r, 1.0 * r, -0.1 * r)
  ..cubicTo(1.0 * r, 0.46 * r, 0.52 * r, 0.98 * r, 0, 1.12 * r)
  ..cubicTo(-0.52 * r, 0.98 * r, -1.0 * r, 0.46 * r, -1.0 * r, -0.1 * r)
  ..cubicTo(-1.0 * r, -0.62 * r, -0.64 * r, -1.12 * r, 0, -1.12 * r)
  ..close();

/// A balloon's curling string, from its knot to [tail]. A bunch draws every
/// string first and the balloons over them — strings drawn with each
/// balloon cut across the ones below like wires (review, 2026-09-26).
void paintBalloonString(Canvas c, Offset o, double r, Offset tail,
    {double tilt = 0, Color string = const Color(0xFF9AA3AE)}) {
  final knot = o + Offset(math.sin(-tilt), math.cos(tilt)) * (1.12 * r);
  final mid = Offset.lerp(knot, tail, 0.5)!;
  final wig = (tail - knot).distance * 0.12;
  c.drawPath(
    Path()
      ..moveTo(knot.dx, knot.dy + r * 0.14)
      ..cubicTo(mid.dx - wig, knot.dy + (tail.dy - knot.dy) * 0.3, mid.dx + wig,
          knot.dy + (tail.dy - knot.dy) * 0.65, tail.dx, tail.dy),
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.2, r * 0.025)
      ..color = _alpha(string, 0.8),
  );
}

/// A glossy party balloon with its knot (and its string to [tail], when
/// given).
void paintBalloon(Canvas c, Offset o, double r, Color colour,
    {double tilt = 0, Offset? tail, Color string = const Color(0xFF9AA3AE)}) {
  if (tail != null) paintBalloonString(c, o, r, tail, tilt: tilt, string: string);
  c.save();
  c.translate(o.dx, o.dy);
  c.rotate(tilt);
  final body = balloonPath(r);
  c.drawPath(body.shift(Offset(r * 0.08, r * 0.12)),
      Paint()
        ..color = _alpha(const Color(0xFF203040), 0.16)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.14));
  c.drawPath(
    body,
    Paint()
      ..shader = ui.Gradient.radial(Offset(-r * 0.35, -r * 0.45), r * 1.75,
          [shade(colour, 0.45), colour, shade(colour, -0.22)], [0, 0.42, 1]),
  );
  // Knot.
  c.drawPath(
    Path()
      ..moveTo(0, 1.08 * r)
      ..lineTo(-0.13 * r, 1.26 * r)
      ..lineTo(0.13 * r, 1.26 * r)
      ..close(),
    Paint()..color = shade(colour, -0.25),
  );
  // Shine.
  c.save();
  c.translate(-0.45 * r, -0.5 * r);
  c.rotate(-0.5);
  c.drawOval(Rect.fromCenter(center: Offset.zero, width: 0.26 * r, height: 0.5 * r),
      Paint()
        ..color = _alpha(const Color(0xFFFFFFFF), 0.55)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.04));
  c.restore();
  c.drawCircle(Offset(-0.18 * r, -0.86 * r), r * 0.05,
      Paint()..color = _alpha(const Color(0xFFFFFFFF), 0.5));
  c.restore();
}

/// Triangular flags on a sagging string.
void paintBunting(Canvas c, Offset a, Offset b, double sag, List<Color> colours,
    {double flag = 60}) {
  Offset at(double t) =>
      Offset.lerp(a, b, t)! + Offset(0, sag * 4 * t * (1 - t));
  c.drawPath(
    Path()
      ..moveTo(a.dx, a.dy)
      ..quadraticBezierTo((a.dx + b.dx) / 2, (a.dy + b.dy) / 2 + sag * 2, b.dx, b.dy),
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..color = const Color(0xFF8B95A3),
  );
  final n = ((b.dx - a.dx) / (flag * 1.08)).floor();
  for (var i = 0; i < n; i++) {
    final t0 = (i + 0.08) / n, t1 = (i + 0.92) / n;
    final p0 = at(t0), p1 = at(t1);
    final mid = Offset.lerp(p0, p1, 0.5)!;
    final down = Offset(0, flag * 1.1);
    final tip = mid + down;
    final col = colours[i % colours.length];
    final path = Path()
      ..moveTo(p0.dx, p0.dy)
      ..lineTo(p1.dx, p1.dy)
      ..lineTo(tip.dx, tip.dy)
      ..close();
    c.drawPath(path.shift(const Offset(3, 5)),
        Paint()
          ..color = _alpha(const Color(0xFF203040), 0.14)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4));
    c.drawPath(
        path,
        Paint()
          ..shader = ui.Gradient.linear(p0, tip, [shade(col, 0.15), shade(col, -0.12)]));
    // A folded edge along the string.
    c.drawLine(p0, p1,
        Paint()
          ..strokeWidth = flag * 0.12
          ..color = shade(col, -0.2));
  }
}

/// Paper confetti: ribbons, dots and tiny triangles. Pieces that would
/// land inside [avoid] (words, the photo) are skipped.
void paintConfetti(Canvas c, Rect area, List<Color> colours, math.Random rnd,
    {int count = 60, double size = 16, List<Rect> avoid = const [], double opacity = 1}) {
  for (var i = 0; i < count; i++) {
    final p = Offset(area.left + rnd.nextDouble() * area.width,
        area.top + rnd.nextDouble() * area.height);
    final col = colours[rnd.nextInt(colours.length)];
    final kind = rnd.nextDouble();
    final s = size * (0.6 + rnd.nextDouble() * 0.7);
    final rot = rnd.nextDouble() * math.pi;
    if (avoid.any((r) => r.inflate(s).contains(p))) continue;
    final paint = Paint()..color = _alpha(col, opacity);
    c.save();
    c.translate(p.dx, p.dy);
    c.rotate(rot);
    if (kind < 0.42) {
      c.drawRRect(
          RRect.fromRectAndRadius(
              Rect.fromCenter(center: Offset.zero, width: s, height: s * 0.42),
              Radius.circular(s * 0.08)),
          paint);
    } else if (kind < 0.7) {
      c.drawCircle(Offset.zero, s * 0.3, paint);
    } else if (kind < 0.85) {
      c.drawPath(
          Path()
            ..moveTo(0, -s * 0.4)
            ..lineTo(s * 0.36, s * 0.3)
            ..lineTo(-s * 0.36, s * 0.3)
            ..close(),
          paint);
    } else {
      final w = Path()..moveTo(-s * 0.7, 0);
      for (var k = 0; k < 3; k++) {
        final x0 = -s * 0.7 + k * s * 0.47;
        w.quadraticBezierTo(x0 + s * 0.12, (k.isEven ? -1 : 1) * s * 0.3, x0 + s * 0.47, 0);
      }
      c.drawPath(
          w,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = s * 0.16
            ..strokeCap = StrokeCap.round
            ..color = _alpha(col, opacity));
    }
    c.restore();
  }
}

/// A five-point star.
Path starPath(Offset o, double r, {int points = 5, double inner = 0.45, double rot = 0}) {
  final p = Path();
  for (var i = 0; i < points * 2; i++) {
    final rr = i.isEven ? r : r * inner;
    final a = rot - math.pi / 2 + i * math.pi / points;
    final q = o + Offset(math.cos(a), math.sin(a)) * rr;
    i == 0 ? p.moveTo(q.dx, q.dy) : p.lineTo(q.dx, q.dy);
  }
  return p..close();
}

/// A four-point twinkle with concave sides.
Path sparklePath(Offset o, double r) => Path()
  ..moveTo(o.dx, o.dy - r)
  ..quadraticBezierTo(o.dx + r * 0.14, o.dy - r * 0.14, o.dx + r, o.dy)
  ..quadraticBezierTo(o.dx + r * 0.14, o.dy + r * 0.14, o.dx, o.dy + r)
  ..quadraticBezierTo(o.dx - r * 0.14, o.dy + r * 0.14, o.dx - r, o.dy)
  ..quadraticBezierTo(o.dx - r * 0.14, o.dy - r * 0.14, o.dx, o.dy - r)
  ..close();

void paintSparkle(Canvas c, Offset o, double r, Paint p, {bool glow = false}) {
  if (glow) {
    c.drawCircle(o, r * 0.9,
        Paint()
          ..color = _alpha(const Color(0xFFFFF4CC), 0.35)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.5));
  }
  c.drawPath(sparklePath(o, r), p);
}

/// A soft cloud.
void paintCloud(Canvas c, Offset o, double w, {double opacity = 0.9}) {
  final path = Path()
    ..addOval(Rect.fromCenter(center: o, width: w, height: w * 0.36))
    ..addOval(Rect.fromCircle(center: o + Offset(-w * 0.18, -w * 0.12), radius: w * 0.2))
    ..addOval(Rect.fromCircle(center: o + Offset(w * 0.08, -w * 0.2), radius: w * 0.25))
    ..addOval(Rect.fromCircle(center: o + Offset(w * 0.3, -w * 0.06), radius: w * 0.15));
  c.drawPath(path,
      Paint()
        ..color = _alpha(const Color(0xFFFFFFFF), opacity)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, w * 0.012));
}

// ─────────────────────────────── foil lines ────────────────────────────

Paint foilStroke(LinearGradient foil, Rect bounds, double width) => Paint()
  ..style = PaintingStyle.stroke
  ..strokeWidth = width
  ..shader = foil.createShader(bounds);

Paint foilFill(LinearGradient foil, Rect bounds) =>
    Paint()..shader = foil.createShader(bounds);

/// A small diamond.
Path diamondPath(Offset o, double r) => Path()
  ..moveTo(o.dx, o.dy - r)
  ..lineTo(o.dx + r * 0.7, o.dy)
  ..lineTo(o.dx, o.dy + r)
  ..lineTo(o.dx - r * 0.7, o.dy)
  ..close();

/// line · diamond · line, the divider between the name and the wishes.
void paintDivider(Canvas c, Offset o, double halfWidth, Paint line, Paint fill,
    {double gem = 9}) {
  final l = Paint()
    ..shader = line.shader
    ..color = line.color
    ..strokeWidth = line.strokeWidth
    ..strokeCap = StrokeCap.round;
  c.drawLine(o + Offset(-halfWidth, 0), o + Offset(-gem * 2.2, 0), l);
  c.drawLine(o + Offset(gem * 2.2, 0), o + Offset(halfWidth, 0), l);
  c.drawPath(diamondPath(o, gem), fill);
  c.drawCircle(o + Offset(-gem * 1.45, 0), gem * 0.26, fill);
  c.drawCircle(o + Offset(gem * 1.45, 0), gem * 0.26, fill);
}

/// A scroll flourish for a frame's corner, drawn for the TOP-LEFT corner
/// at [o]; rotate the canvas for the others.
void paintCornerScroll(Canvas c, Offset o, double s, Paint stroke, Paint fill) {
  final p = Path()
    ..moveTo(o.dx, o.dy + s)
    ..cubicTo(o.dx, o.dy + s * 0.45, o.dx + s * 0.1, o.dy + s * 0.1, o.dx + s * 0.45, o.dy + s * 0.05)
    ..moveTo(o.dx + s, o.dy)
    ..cubicTo(o.dx + s * 0.45, o.dy, o.dx + s * 0.1, o.dy + s * 0.1, o.dx + s * 0.05, o.dy + s * 0.45);
  c.drawPath(p, stroke);
  // Curls at both ends.
  c.drawArc(Rect.fromCircle(center: o + Offset(s * 0.08, s * 1.0), radius: s * 0.08),
      -math.pi / 2, math.pi * 1.4, false, stroke);
  c.drawArc(Rect.fromCircle(center: o + Offset(s * 1.0, s * 0.08), radius: s * 0.08),
      math.pi, math.pi * 1.4, false, stroke);
  c.drawPath(diamondPath(o + Offset(s * 0.2, s * 0.2), s * 0.09), fill);
}

/// Fine paper grain: a few thousand faint specks.
void paintPaperGrain(Canvas c, Size size, Color ink, int seed, {double opacity = 0.035}) {
  final rnd = math.Random(seed);
  final pts = <Offset>[
    for (var i = 0; i < 2600; i++)
      Offset(rnd.nextDouble() * size.width, rnd.nextDouble() * size.height),
  ];
  c.drawPoints(
      ui.PointMode.points,
      pts,
      Paint()
        ..strokeWidth = 1.6
        ..strokeCap = StrokeCap.round
        ..color = _alpha(ink, opacity));
}

/// A heart, for a card with neither a photo, an age nor a name yet.
Path heartPath(Offset o, double r) => Path()
  ..moveTo(o.dx, o.dy + r * 0.85)
  ..cubicTo(o.dx - r * 1.35, o.dy - r * 0.1, o.dx - r * 0.75, o.dy - r * 1.1, o.dx, o.dy - r * 0.45)
  ..cubicTo(o.dx + r * 0.75, o.dy - r * 1.1, o.dx + r * 1.35, o.dy - r * 0.1, o.dx, o.dy + r * 0.85)
  ..close();
