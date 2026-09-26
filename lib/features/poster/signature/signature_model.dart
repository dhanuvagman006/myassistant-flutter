import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';

/// HIS SIGNATURE, AS LINES — never as a picture.
///
/// The client (2026-09-26): "make a birthday card for my daughter… with my
/// signature". It is drawn once with a finger and kept as the pen's path
/// (points 0..1 inside its own box, with the time of each), so it is
/// redrawn sharp at any size and in the card's own ink. It lives only on
/// this phone (signature_store.dart); the server only knows on/off.
///
/// Stored as the contract's §6 JSON:
///   {v: 1, kind: 'drawn', aspect, strokes: [[[x, y, t], ...], ...]}
class SignaturePoint {
  final double x;
  final double y;

  /// Milliseconds since the stroke began — the pen's speed thins the line.
  final int t;
  const SignaturePoint(this.x, this.y, this.t);

  List<num> toJson() => [_r(x), _r(y), t];

  static double _r(double v) => (v * 10000).roundToDouble() / 10000;

  factory SignaturePoint.fromJson(List<dynamic> j) => SignaturePoint(
        (j[0] as num).toDouble(),
        (j[1] as num).toDouble(),
        j.length > 2 ? (j[2] as num).toInt() : 0,
      );

  @override
  bool operator ==(Object other) =>
      other is SignaturePoint && other.x == x && other.y == y && other.t == t;

  @override
  int get hashCode => Object.hash(x, y, t);
}

class SignatureData {
  final String kind;

  /// Width / height of the signature's own box.
  final double aspect;
  final List<List<SignaturePoint>> strokes;

  const SignatureData({this.kind = 'drawn', required this.aspect, required this.strokes});

  bool get isEmpty => strokes.every((s) => s.isEmpty);

  /// Raw strokes in pad pixels → normalised to their bounding box. A thin
  /// margin keeps the pen's width inside the box when redrawn.
  factory SignatureData.fromRaw(List<List<({Offset p, int t})>> raw) {
    final pts = [for (final s in raw) ...s.map((e) => e.p)];
    if (pts.isEmpty) return const SignatureData(aspect: 3, strokes: []);
    var minX = pts.first.dx, maxX = minX, minY = pts.first.dy, maxY = minY;
    for (final p in pts) {
      minX = math.min(minX, p.dx);
      maxX = math.max(maxX, p.dx);
      minY = math.min(minY, p.dy);
      maxY = math.max(maxY, p.dy);
    }
    final w = math.max(maxX - minX, 1.0), h = math.max(maxY - minY, 1.0);
    // A single dot or a flat line still gets a sensible box.
    final boxW = math.max(w, h * 0.5), boxH = math.max(h, w * 0.12);
    final ox = minX - (boxW - w) / 2, oy = minY - (boxH - h) / 2;
    return SignatureData(
      aspect: boxW / boxH,
      strokes: [
        for (final s in raw)
          [
            for (final e in s)
              SignaturePoint((e.p.dx - ox) / boxW, (e.p.dy - oy) / boxH, e.t),
          ],
      ],
    );
  }

  Map<String, dynamic> toJson() => {
        'v': 1,
        'kind': kind,
        'aspect': SignaturePoint._r(aspect),
        'strokes': [
          for (final s in strokes) [for (final p in s) p.toJson()],
        ],
      };

  String encode() => jsonEncode(toJson());

  factory SignatureData.fromJson(Map<String, dynamic> j) => SignatureData(
        kind: (j['kind'] ?? 'drawn').toString(),
        aspect: (j['aspect'] as num?)?.toDouble() ?? 3,
        strokes: [
          for (final s in (j['strokes'] as List? ?? const []))
            [for (final p in (s as List)) SignaturePoint.fromJson(p as List)],
        ],
      );

  static SignatureData? decode(String? s) {
    if (s == null || s.isEmpty) return null;
    try {
      final d = SignatureData.fromJson(jsonDecode(s) as Map<String, dynamic>);
      return d.isEmpty ? null : d;
    } catch (_) {
      return null;
    }
  }

  /// Draws the signature filling [box] (keeping its shape), in [ink].
  /// Curves run through the midpoints of the pen's samples, and the line
  /// thins where the pen moved fast — the way ink does.
  void paint(Canvas canvas, Rect box, Color ink) {
    if (isEmpty) return;
    final scale = math.min(box.width / aspect, box.height);
    final w = scale * aspect, h = scale;
    final ox = box.left + (box.width - w) / 2, oy = box.top + (box.height - h) / 2;
    Offset at(SignaturePoint p) => Offset(ox + p.x * w, oy + p.y * h);
    final base = math.max(1.2, h * 0.035);
    final paint = Paint()
      ..color = ink
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;
    for (final s in strokes) {
      if (s.isEmpty) continue;
      if (s.length == 1) {
        canvas.drawCircle(at(s.first), base * 0.6, Paint()..color = ink);
        continue;
      }
      var prevMid = at(s.first);
      for (var i = 1; i < s.length; i++) {
        final a = at(s[i - 1]), b = at(s[i]);
        final mid = Offset.lerp(a, b, 0.5)!;
        final dt = math.max(1, s[i].t - s[i - 1].t);
        // Normalised speed: box heights per second.
        final speed = (b - a).distance / h / (dt / 1000);
        final width = base * (1.35 - (speed / 6).clamp(0.0, 0.75));
        paint.strokeWidth = width;
        final path = Path()
          ..moveTo(prevMid.dx, prevMid.dy)
          ..quadraticBezierTo(a.dx, a.dy, mid.dx, mid.dy);
        canvas.drawPath(path, paint);
        prevMid = mid;
      }
      canvas.drawLine(prevMid, at(s.last), paint);
    }
  }
}
