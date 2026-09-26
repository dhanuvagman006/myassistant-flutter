import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// SYNTHETIC PHOTOS for the card tests — drawn in code, so no real
/// person's picture is ever in the repository. They are made to look like
/// a faded family print (warm cast, soft light, grain), with faces placed
/// where a real portrait has them, so a design that crops a head shows it.

void _figure(Canvas c, Offset head, double r, Color dress, Color hair, Color skin, int seed) {
  final rnd = math.Random(seed);
  // Shoulders and body.
  final body = Path()
    ..moveTo(head.dx - r * 2.3, head.dy + r * 4.6)
    ..cubicTo(head.dx - r * 2.2, head.dy + r * 2.0, head.dx - r * 1.2, head.dy + r * 1.55,
        head.dx, head.dy + r * 1.5)
    ..cubicTo(head.dx + r * 1.2, head.dy + r * 1.55, head.dx + r * 2.2, head.dy + r * 2.0,
        head.dx + r * 2.3, head.dy + r * 4.6)
    ..close();
  c.drawPath(
      body,
      Paint()
        ..shader = ui.Gradient.linear(head + Offset(-r * 2, r * 1.5), head + Offset(r * 2, r * 4.5),
            [Color.lerp(dress, const Color(0xFFFFFFFF), 0.25)!, dress]));
  // Neck.
  c.drawRect(Rect.fromCenter(center: head + Offset(0, r * 1.15), width: r * 0.7, height: r * 0.8),
      Paint()..color = Color.lerp(skin, const Color(0xFF000000), 0.12)!);
  // Hair behind the head.
  c.drawOval(Rect.fromCenter(center: head + Offset(0, r * 0.25), width: r * 2.5, height: r * 2.9),
      Paint()..color = hair);
  // Face.
  final face = Rect.fromCenter(center: head, width: r * 1.8, height: r * 2.2);
  c.drawOval(
      face,
      Paint()
        ..shader = ui.Gradient.radial(head + Offset(-r * 0.3, -r * 0.4), r * 1.6,
            [Color.lerp(skin, const Color(0xFFFFFFFF), 0.25)!, skin,
             Color.lerp(skin, const Color(0xFF000000), 0.2)!], [0, 0.6, 1]));
  // Fringe.
  c.drawPath(
      Path()
        ..moveTo(head.dx - r * 0.95, head.dy - r * 0.2)
        ..quadraticBezierTo(head.dx - r * 0.5, head.dy - r * 1.5, head.dx + r * 0.95, head.dy - r * 0.35)
        ..quadraticBezierTo(head.dx + r * 0.3, head.dy - r * 1.0, head.dx - r * 0.95, head.dy - r * 0.2),
      Paint()..color = hair);
  // Eyes, brows, smile, cheeks.
  for (final s in [-1.0, 1.0]) {
    c.drawOval(Rect.fromCenter(center: head + Offset(s * r * 0.38, r * 0.05), width: r * 0.28, height: r * 0.16),
        Paint()..color = const Color(0xFF2B1D16));
    c.drawCircle(head + Offset(s * r * 0.38 - r * 0.04, r * 0.02), r * 0.035,
        Paint()..color = const Color(0xCCFFFFFF));
    c.drawLine(head + Offset(s * r * 0.24, -r * 0.2), head + Offset(s * r * 0.55, -r * 0.16),
        Paint()
          ..strokeWidth = r * 0.07
          ..strokeCap = StrokeCap.round
          ..color = Color.lerp(hair, skin, 0.2)!);
    c.drawCircle(head + Offset(s * r * 0.5, r * 0.45), r * 0.18,
        Paint()
          ..color = const Color(0x33E0707A)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.08));
  }
  c.drawArc(Rect.fromCenter(center: head + Offset(0, r * 0.52), width: r * 0.62, height: r * 0.34),
      0.2, math.pi - 0.4, false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * 0.07
        ..strokeCap = StrokeCap.round
        ..color = const Color(0xFF9A4A4A));
  // A little random texture on the dress.
  for (var i = 0; i < 40; i++) {
    c.drawCircle(
        head + Offset((rnd.nextDouble() - 0.5) * r * 3.6, r * 2 + rnd.nextDouble() * r * 2.4),
        r * 0.05,
        Paint()..color = const Color(0x33FFFFFF));
  }
}

void _oldPrintFinish(Canvas c, Size s, int seed) {
  final rnd = math.Random(seed);
  // Warm fade and a vignette, like an old print.
  c.drawRect(Offset.zero & s, Paint()..color = const Color(0x22D9B98A));
  c.drawRect(
      Offset.zero & s,
      Paint()
        ..shader = ui.Gradient.radial(s.center(Offset.zero), s.longestSide * 0.7,
            [const Color(0x00000000), const Color(0x55301E10)], [0.55, 1]));
  final pts = [
    for (var i = 0; i < 9000; i++) Offset(rnd.nextDouble() * s.width, rnd.nextDouble() * s.height),
  ];
  c.drawPoints(ui.PointMode.points, pts,
      Paint()
        ..strokeWidth = 1.5
        ..color = const Color(0x16000000));
}

/// A head-and-shoulders portrait, 3:4, the face in the upper middle.
Future<ui.Image> syntheticPortrait({int w = 900, int h = 1200}) async {
  final rec = ui.PictureRecorder();
  final size = Size(w.toDouble(), h.toDouble());
  final c = Canvas(rec, Offset.zero & size);
  c.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = ui.Gradient.linear(Offset.zero, Offset(0, size.height),
            [const Color(0xFF9DB7C9), const Color(0xFFC9B99A), const Color(0xFF7E8B63)],
            [0, 0.55, 1]));
  final rnd = math.Random(3);
  for (var i = 0; i < 22; i++) {
    c.drawCircle(Offset(rnd.nextDouble() * size.width, rnd.nextDouble() * size.height * 0.6),
        20 + rnd.nextDouble() * 60,
        Paint()
          ..color = const Color(0x22FFF6DC)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18));
  }
  _figure(c, Offset(size.width * 0.5, size.height * 0.36), size.width * 0.14,
      const Color(0xFFB2455E), const Color(0xFF2A1B14), const Color(0xFFD7A07A), 1);
  _oldPrintFinish(c, size, 7);
  return rec.endRecording().toImage(w, h);
}

/// The faces' centres in [syntheticWideGroup], as shares of its width.
const wideGroupFaces = [0.08, 0.30, 0.50, 0.70, 0.92];

/// An ordinary 16:9 phone photo of a family standing in a row, the people
/// at the ends near the edges (8 % and 92 %) — the photo that showed the
/// designs cropping the end faces (review, 2026-09-26).
Future<ui.Image> syntheticWideGroup({int w = 1920, int h = 1080}) async {
  final rec = ui.PictureRecorder();
  final size = Size(w.toDouble(), h.toDouble());
  final c = Canvas(rec, Offset.zero & size);
  c.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = ui.Gradient.linear(Offset.zero, Offset(0, size.height),
            [const Color(0xFFA9C4D8), const Color(0xFFE1D3B4), const Color(0xFF7F8F62)],
            [0, 0.58, 1]));
  const dresses = [
    Color(0xFF3F6D8E), Color(0xFFB2455E), Color(0xFFE0A33A), Color(0xFF6F8F4E), Color(0xFF7A4E9A),
  ];
  const skins = [
    Color(0xFFC99470), Color(0xFFD7A07A), Color(0xFFB98563), Color(0xFFCF9A74), Color(0xFFC08A66),
  ];
  for (var i = 0; i < wideGroupFaces.length; i++) {
    _figure(c, Offset(size.width * wideGroupFaces[i], size.height * (0.36 + (i % 2) * 0.04)),
        size.width * 0.034, dresses[i], const Color(0xFF2A1B14), skins[i], 10 + i);
  }
  _oldPrintFinish(c, size, 11);
  return rec.endRecording().toImage(w, h);
}

/// A family group, 3:2 landscape, three faces spread across the width.
Future<ui.Image> syntheticGroup({int w = 1500, int h = 1000}) async {
  final rec = ui.PictureRecorder();
  final size = Size(w.toDouble(), h.toDouble());
  final c = Canvas(rec, Offset.zero & size);
  c.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = ui.Gradient.linear(Offset.zero, Offset(0, size.height),
            [const Color(0xFFB9C7B0), const Color(0xFFD8C8A8), const Color(0xFF8D7B5E)],
            [0, 0.6, 1]));
  _figure(c, Offset(size.width * 0.2, size.height * 0.4), size.width * 0.075,
      const Color(0xFF3F6D8E), const Color(0xFF3A2A20), const Color(0xFFC99470), 2);
  _figure(c, Offset(size.width * 0.5, size.height * 0.33), size.width * 0.08,
      const Color(0xFFB2455E), const Color(0xFF2A1B14), const Color(0xFFD7A07A), 3);
  _figure(c, Offset(size.width * 0.8, size.height * 0.42), size.width * 0.07,
      const Color(0xFF6F8F4E), const Color(0xFF1E1510), const Color(0xFFB98563), 4);
  _oldPrintFinish(c, size, 9);
  return rec.endRecording().toImage(w, h);
}
