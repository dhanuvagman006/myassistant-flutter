import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../design/apple_kit.dart';
import '../../../design/neon_tokens.dart';
import '../../../services/app_feedback.dart';
import 'signature_model.dart';
import 'signature_store.dart';

/// SIGN ONCE WITH A FINGER (client, 2026-09-26: "with my signature").
///
/// A plain white page with a line to sign on. Touches are read with a
/// Listener, not a drag recogniser: a drag only starts after the finger
/// has moved ~18 px, and the first stroke of a shaky hand would lose its
/// beginning. Saved as lines (signature_model.dart), only on this phone.
class SignaturePadScreen extends StatefulWidget {
  const SignaturePadScreen({super.key, this.store});

  /// Defaults to [SignatureStore.instance].
  final SignatureStore? store;

  /// Opens the pad over everything; returns the saved signature, or null
  /// when he closes it.
  static Future<SignatureData?> open(BuildContext context, {SignatureStore? store}) =>
      Navigator.of(context, rootNavigator: true).push<SignatureData>(MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => SignaturePadScreen(store: store),
      ));

  @override
  State<SignaturePadScreen> createState() => SignaturePadState();
}

@visibleForTesting
class SignaturePadState extends State<SignaturePadScreen> {
  final List<List<({Offset p, int t})>> strokes = [];
  final _clock = Stopwatch()..start();
  int _repaint = 0;
  bool _saving = false;

  /// Ink that is really a signature: two strokes, or one spanning 40 px
  /// (a shaky single line still counts).
  bool get canSave {
    if (strokes.length >= 2) return true;
    final pts = [for (final s in strokes) ...s.map((e) => e.p)];
    if (pts.length < 2) return false;
    var minX = pts.first.dx, maxX = minX, minY = pts.first.dy, maxY = minY;
    for (final p in pts) {
      minX = math.min(minX, p.dx);
      maxX = math.max(maxX, p.dx);
      minY = math.min(minY, p.dy);
      maxY = math.max(maxY, p.dy);
    }
    return math.max(maxX - minX, maxY - minY) >= 40;
  }

  /// The one finger that is signing. A palm resting on the pad, or a
  /// second finger, is ignored: its moves used to join the stroke and zig-zag
  /// between the two contacts (review, 2026-09-26).
  int? _pen;

  void _down(PointerDownEvent e) {
    if (_pen != null) return;
    _pen = e.pointer;
    setState(() {
      strokes.add([(p: e.localPosition, t: _clock.elapsedMilliseconds)]);
      _repaint++;
    });
  }

  void _up(PointerEvent e) {
    if (e.pointer == _pen) _pen = null;
  }

  void _move(PointerMoveEvent e) {
    if (strokes.isEmpty || e.pointer != _pen) return;
    final s = strokes.last;
    // Points closer than 1.5 px add nothing but noise.
    if ((e.localPosition - s.last.p).distance < 1.5) return;
    setState(() {
      s.add((p: e.localPosition, t: _clock.elapsedMilliseconds));
      _repaint++;
    });
  }

  void clear() => setState(() {
        strokes.clear();
        _pen = null;
        _repaint++;
      });

  Future<void> save() async {
    if (!canSave || _saving) return;
    setState(() => _saving = true);
    final data = SignatureData.fromRaw(strokes);
    final ok = await (widget.store ?? SignatureStore.instance).save(data);
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) {
      HapticFeedback.mediumImpact();
      Navigator.of(context).pop(data);
    } else {
      AppFeedback.show("Couldn't keep the signature on this phone. Try again.", context: context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final big = NeonType.manrope(NeonType.rowTitle + 2, FontWeight.w700);
    return Scaffold(
      backgroundColor: Neon.bg,
      appBar: appleAppBar(context, 'Your signature'),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                "Sign the way you sign a greeting card. The card gets shared, "
                "so please don't use your bank signature. It stays only on this phone.",
                style: TextStyle(color: Neon.textLo, fontSize: NeonType.callout, height: 1.35),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(18),
                  child: Container(
                    color: Colors.white,
                    child: Listener(
                      key: const Key('signature-pad'),
                      behavior: HitTestBehavior.opaque,
                      onPointerDown: _down,
                      onPointerMove: _move,
                      onPointerUp: _up,
                      onPointerCancel: _up,
                      child: CustomPaint(
                        painter: _PadPainter(strokes, _repaint),
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 72,
                      child: OutlinedButton(
                        onPressed: strokes.isEmpty ? null : clear,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Neon.textHi,
                          side: BorderSide(color: Neon.lineBright),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        ),
                        child: Text('Clear', style: big),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: SizedBox(
                      height: 72,
                      child: FilledButton(
                        onPressed: canSave && !_saving ? save : null,
                        style: FilledButton.styleFrom(
                          backgroundColor: Neon.accentFill,
                          foregroundColor: Neon.onAccent,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        ),
                        child: Text('Save my signature', style: big, textAlign: TextAlign.center),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PadPainter extends CustomPainter {
  _PadPainter(this.strokes, this.version);
  final List<List<({Offset p, int t})>> strokes;
  final int version;

  @override
  void paint(Canvas canvas, Size size) {
    // The line to sign on, and the invitation while it is empty.
    final base = size.height * 0.68;
    canvas.drawLine(Offset(size.width * 0.08, base), Offset(size.width * 0.92, base),
        Paint()
          ..color = const Color(0xFFB9BEC7)
          ..strokeWidth = 2);
    if (strokes.isEmpty) {
      final tp = TextPainter(
        text: const TextSpan(
            text: 'Sign here with your finger',
            style: TextStyle(color: Color(0xFF8A909A), fontSize: 22)),
        textDirection: TextDirection.ltr,
        textScaler: TextScaler.noScaling,
      )..layout(maxWidth: size.width - 32);
      tp.paint(canvas, Offset((size.width - tp.width) / 2, base - tp.height - 18));
    }
    final ink = Paint()
      ..color = const Color(0xFF1E2A44)
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = 4.5;
    for (final s in strokes) {
      if (s.length == 1) {
        canvas.drawCircle(s.first.p, 2.6, Paint()..color = ink.color);
        continue;
      }
      final path = Path()..moveTo(s.first.p.dx, s.first.p.dy);
      for (var i = 1; i < s.length; i++) {
        final a = s[i - 1].p, b = s[i].p;
        final mid = Offset.lerp(a, b, 0.5)!;
        path.quadraticBezierTo(a.dx, a.dy, mid.dx, mid.dy);
      }
      path.lineTo(s.last.p.dx, s.last.p.dy);
      canvas.drawPath(path, ink);
    }
  }

  @override
  bool shouldRepaint(_PadPainter old) => old.version != version;
}
