import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/assistant_identity.dart';

/// THE SPLASH (2026-10-06, the owner: "something new and modern"). The new
/// logo comes alive: the microphone draws itself on, its capsule fills with
/// the logo's cyan-to-magenta light, the sound waves open out on both
/// sides, and the name rises in the same gradient. While the session
/// restores the waves keep rippling as if she were speaking, under a slow
/// aurora. With "Remove animations" on, the finished logo stands still.
///
/// Brand colours, not the theme's accent: this is the logo's moment, and
/// the native launch screen before it is the same night
/// (android/app/src/main/res/values/splash_colors.xml).
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  static const night = Color(0xFF05060D);

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

/// The logo's light, measured off assets/icon/icon.png.
class _Brand {
  static const cyan = Color(0xFF22E6FF);
  static const sky = Color(0xFF3FA9FF);
  static const blue = Color(0xFF3550FF);
  static const violet = Color(0xFF8B3DFF);
  static const magenta = Color(0xFFFF3DDB);
  static const pink = Color(0xFFFF5FA8);
  static const ice = Color(0xFFE6F7FF);
}

class _SplashScreenState extends State<SplashScreen> with TickerProviderStateMixin {
  /// The entrance: draw-on, fill, waves, name, tagline (1.3 s, once).
  late final AnimationController _in =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1300));

  /// The living loop after it: ripples, shimmer, aurora.
  late final AnimationController _loop =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 3200));

  /// What the assistant does, one truth at a time.
  static const _lines = [
    'Just say it — it handles it.',
    'Understands your calls.',
    'Remembers your promises.',
    'Plans your day.',
  ];
  int _line = 0;
  Timer? _cycle;
  bool _still = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (still == _still && (_in.isAnimating || _in.isCompleted)) return;
    _still = still;
    if (_still) {
      _in.value = 1;
      _loop.stop();
      _cycle?.cancel();
      _cycle = null;
    } else {
      if (!_in.isCompleted) _in.forward();
      _loop.repeat();
      _cycle ??= Timer.periodic(const Duration(milliseconds: 1800), (_) {
        if (mounted) setState(() => _line = (_line + 1) % _lines.length);
      });
    }
  }

  @override
  void dispose() {
    _cycle?.cancel();
    _in.dispose();
    _loop.dispose();
    super.dispose();
  }

  Animation<double> _beat(double from, double to, [Curve curve = Curves.easeOutCubic]) =>
      CurvedAnimation(parent: _in, curve: Interval(from, to, curve: curve));

  late final _nameIn = _beat(0.50, 0.90);
  late final _restIn = _beat(0.70, 1.0);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: SplashScreen.night,
      body: Stack(
        fit: StackFit.expand,
        children: [
          RepaintBoundary(child: CustomPaint(painter: _Aurora(_loop))),
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                RepaintBoundary(
                  child: SizedBox.square(
                    dimension: 220,
                    child: CustomPaint(painter: _LivingLogo(_in, _loop)),
                  ),
                ),
                const SizedBox(height: 28),
                AnimatedBuilder(
                  animation: Listenable.merge([_nameIn, _loop]),
                  builder: (_, child) => Opacity(
                    opacity: _nameIn.value,
                    child: Transform.translate(
                      offset: Offset(0, 18 * (1 - _nameIn.value)),
                      child: ShaderMask(
                        blendMode: BlendMode.srcIn,
                        shaderCallback: (r) => _gradientText(r, _loop.value),
                        child: child,
                      ),
                    ),
                  ),
                  // The name the USER chose; the product's before sign-in.
                  child: ValueListenableBuilder<String>(
                    valueListenable: AssistantIdentity.notifier,
                    builder: (_, name, __) => Text(
                      name == AssistantIdentity.fallback ? 'My Assistant' : name,
                      style: GoogleFonts.spaceGrotesk(
                        color: Colors.white,
                        fontSize: 32,
                        letterSpacing: -0.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                FadeTransition(
                  opacity: _restIn,
                  child: Column(
                    children: [
                      SizedBox(
                        height: 20,
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 420),
                          transitionBuilder: (child, a) => FadeTransition(
                            opacity: a,
                            child: SlideTransition(
                              position: Tween(begin: const Offset(0, 0.4), end: Offset.zero)
                                  .animate(a),
                              child: child,
                            ),
                          ),
                          child: Text(
                            _lines[_line],
                            key: ValueKey(_line),
                            style: TextStyle(
                              color: _Brand.ice.withValues(alpha: 0.62),
                              fontSize: 14,
                              letterSpacing: 0.2,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 36),
                      RepaintBoundary(
                        child: SizedBox(
                          width: 132,
                          height: 3,
                          child: CustomPaint(painter: _Shimmer(_loop)),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The name's gradient, drifting slowly across it.
  static Shader _gradientText(Rect r, double t) {
    final shift = math.sin(t * 2 * math.pi) * 0.25;
    return LinearGradient(
      begin: Alignment(-1 + shift, 0),
      end: Alignment(1 + shift, 0),
      colors: const [_Brand.cyan, _Brand.sky, _Brand.ice, _Brand.magenta, _Brand.pink],
      stops: const [0.0, 0.28, 0.5, 0.78, 1.0],
    ).createShader(r);
  }
}

/// The microphone and its sound waves, drawn (not a picture), so every
/// part can move: [entrance] 0..1 once, then [loop] 0..1 round and round.
class _LivingLogo extends CustomPainter {
  _LivingLogo(this.entrance, this.loop) : super(repaint: Listenable.merge([entrance, loop]));

  final Animation<double> entrance;
  final Animation<double> loop;

  static double _seg(double t, double a, double b) =>
      Curves.easeOutCubic.transform(((t - a) / (b - a)).clamp(0.0, 1.0));

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final o = Offset((size.width - s) / 2, (size.height - s) / 2);
    Offset p(double x, double y) => o + Offset(x * s, y * s);
    final e = entrance.value;
    final t = loop.value;
    final w = 0.046 * s; // stroke width, as the logo's

    // 1. THE CAPSULE: grows in, filled with the logo's light, its gradient
    //    turning slowly, with a soft halo behind it.
    final grow = Curves.easeOutBack.transform(_seg(e, 0.10, 0.55));
    if (grow > 0) {
      final rect = Rect.fromCenter(
        center: p(0.5, 0.36),
        width: 0.25 * s * grow.clamp(0.0, 1.2),
        height: 0.50 * s * grow.clamp(0.0, 1.2),
      );
      final capsule = RRect.fromRectAndRadius(rect, Radius.circular(rect.width / 2));
      final a = t * 2 * math.pi;
      final fill = ui.Gradient.linear(
        rect.topCenter + Offset(math.sin(a) * rect.width * 0.3, 0),
        rect.bottomCenter - Offset(math.sin(a) * rect.width * 0.3, 0),
        const [_Brand.ice, _Brand.sky, _Brand.blue, _Brand.violet, _Brand.magenta],
        const [0.0, 0.25, 0.55, 0.8, 1.0],
      );
      final halo = 0.55 + 0.15 * math.sin(a * 2);
      canvas.drawRRect(
        capsule.inflate(0.035 * s),
        Paint()
          ..shader = fill
          ..color = Colors.white.withValues(alpha: halo)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, 0.06 * s),
      );
      canvas.drawRRect(capsule, Paint()..shader = fill);
      // A glint near the top, as on glass.
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(rect.left + rect.width * 0.22, rect.top + rect.height * 0.08,
              rect.width * 0.18, rect.height * 0.30),
          Radius.circular(rect.width),
        ),
        Paint()..color = Colors.white.withValues(alpha: 0.35 * grow.clamp(0.0, 1.0)),
      );
    }

    // 2. THE CRADLE, STEM AND BASE: drawn on like a pen stroke.
    final cradle = Path()
      ..moveTo(p(0.29, 0.40).dx, p(0.29, 0.40).dy)
      ..lineTo(p(0.29, 0.47).dx, p(0.29, 0.47).dy)
      ..arcTo(Rect.fromCircle(center: p(0.5, 0.47), radius: 0.21 * s), math.pi, -math.pi, false)
      ..lineTo(p(0.71, 0.40).dx, p(0.71, 0.40).dy);
    final stand = Path()
      ..moveTo(p(0.5, 0.68).dx, p(0.5, 0.68).dy)
      ..lineTo(p(0.5, 0.78).dx, p(0.5, 0.78).dy)
      ..moveTo(p(0.39, 0.80).dx, p(0.39, 0.80).dy)
      ..lineTo(p(0.61, 0.80).dx, p(0.61, 0.80).dy);
    final draw = _seg(e, 0.0, 0.50);
    final cradleShader = ui.Gradient.linear(
        p(0.5, 0.30), p(0.5, 0.80), const [_Brand.ice, Color(0xFFBFEFFF), _Brand.cyan],
        const [0.0, 0.5, 1.0]);
    _glowStroke(canvas, _trim(cradle, draw), cradleShader, w, s);
    _glowStroke(canvas, _trim(stand, _seg(e, 0.30, 0.65)),
        ui.Gradient.linear(p(0.4, 0.7), p(0.6, 0.8), const [_Brand.cyan, _Brand.cyan]), w * 1.1, s);

    // 3. THE SOUND WAVES: they open out, inner then outer, and then
    //    ripple outward like a voice, cyan on the left, magenta on the right.
    const c = Offset(0.5, 0.44);
    for (var i = 0; i < 2; i++) {
      final open = _seg(e, 0.35 + 0.15 * i, 0.80 + 0.1 * i);
      if (open <= 0) continue;
      // The ripple: each wave brightens and steps out in turn.
      final phase = (t * 2 - i * 0.35) % 1.0;
      final pulse = math.sin(math.pi * phase.clamp(0.0, 1.0));
      final radius = (0.33 + 0.12 * i + 0.012 * pulse) * s;
      final sweep = (0.62 + 0.06 * i) * open;
      final bright = 0.78 + 0.22 * pulse;
      final centre = o + Offset(c.dx * s, c.dy * s);
      final box = Rect.fromCircle(center: centre, radius: radius);
      final left = Path()..addArc(box, math.pi - sweep / 2, sweep);
      final right = Path()..addArc(box, -sweep / 2, sweep);
      final lc = i == 0 ? _Brand.sky : _Brand.cyan;
      final rc = i == 0 ? _Brand.magenta : _Brand.pink;
      _glowStroke(canvas, left, ui.Gradient.linear(box.topLeft, box.bottomLeft,
          [lc.withValues(alpha: bright), lc.withValues(alpha: bright)]), w, s);
      _glowStroke(canvas, right, ui.Gradient.linear(box.topRight, box.bottomRight,
          [rc.withValues(alpha: bright), rc.withValues(alpha: bright)]), w, s);
    }

    // 4. ECHOES: faint rings carrying the sound out past the waves.
    if (e >= 1) {
      for (final k in const [0.0, 0.5]) {
        final q = (t + k) % 1.0;
        final r = (0.48 + 0.22 * q) * s;
        final alpha = (1 - q) * 0.16;
        canvas.drawCircle(
          o + Offset(c.dx * s, c.dy * s),
          r,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.4
            ..shader = ui.Gradient.linear(
              o + Offset(0, c.dy * s),
              o + Offset(s, c.dy * s),
              [_Brand.cyan.withValues(alpha: alpha), _Brand.magenta.withValues(alpha: alpha)],
            ),
        );
      }
    }
  }

  /// The first [f] of [path], for the draw-on.
  static Path _trim(Path path, double f) {
    if (f >= 1) return path;
    final out = Path();
    if (f <= 0) return out;
    final metrics = path.computeMetrics().toList();
    final total = metrics.fold<double>(0, (a, m) => a + m.length);
    var left = total * f;
    for (final m in metrics) {
      if (left <= 0) break;
      out.addPath(m.extractPath(0, math.min(left, m.length)), Offset.zero);
      left -= m.length;
    }
    return out;
  }

  /// A neon stroke: a soft wide glow under a crisp line.
  static void _glowStroke(Canvas canvas, Path path, Shader shader, double w, double s) {
    final base = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..shader = shader;
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = w * 2.2
        ..shader = shader
        ..color = Colors.white.withValues(alpha: 0.5)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 0.03 * s),
    );
    canvas.drawPath(path, base..strokeWidth = w);
  }

  @override
  bool shouldRepaint(_LivingLogo old) => old.entrance != entrance || old.loop != loop;
}

/// Two soft lights drifting in the night: cyan high on the left, magenta
/// low on the right, as in the logo.
class _Aurora extends CustomPainter {
  _Aurora(this.t) : super(repaint: t);
  final Animation<double> t;

  @override
  void paint(Canvas canvas, Size size) {
    final a = t.value * 2 * math.pi;
    final d = size.shortestSide;
    void light(Offset at, Color c, double r) {
      canvas.drawCircle(
        at,
        r,
        Paint()
          ..shader = ui.Gradient.radial(at, r, [c.withValues(alpha: 0.22), c.withValues(alpha: 0)]),
      );
    }

    light(Offset(size.width * (0.22 + 0.05 * math.sin(a)), size.height * (0.30 + 0.03 * math.cos(a))),
        _Brand.cyan, d * 0.75);
    light(Offset(size.width * (0.80 - 0.05 * math.sin(a)), size.height * (0.70 - 0.03 * math.cos(a))),
        _Brand.magenta, d * 0.8);
    light(Offset(size.width * 0.5, size.height * (0.42 + 0.02 * math.sin(a * 2))), _Brand.blue, d * 0.5);
  }

  @override
  bool shouldRepaint(_Aurora old) => old.t != t;
}

/// The loading line: a slim track with a gradient light sweeping along it.
class _Shimmer extends CustomPainter {
  _Shimmer(this.t) : super(repaint: t);
  final Animation<double> t;

  @override
  void paint(Canvas canvas, Size size) {
    final track = RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(size.height));
    canvas.drawRRect(track, Paint()..color = Colors.white.withValues(alpha: 0.08));
    final x = Curves.easeInOutSine.transform((t.value * 2) % 1.0);
    final len = size.width * 0.42;
    final left = -len + (size.width + len) * x;
    canvas.save();
    canvas.clipRRect(track);
    canvas.drawRect(
      Rect.fromLTWH(left, 0, len, size.height),
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(left, 0),
          Offset(left + len, 0),
          [
            _Brand.cyan.withValues(alpha: 0),
            _Brand.cyan,
            _Brand.magenta,
            _Brand.magenta.withValues(alpha: 0),
          ],
          const [0.0, 0.35, 0.65, 1.0],
        ),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_Shimmer old) => old.t != t;
}
