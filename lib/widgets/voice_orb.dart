import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../design/gpu_programs.dart';
import '../design/motion.dart';
import '../design/neon_tokens.dart';
import '../design/orb_rings.dart';
import '../services/assistant_identity.dart';

/// ─────────────────────────────────────────────────────────────────────
///  THE VOICE ORB — the client's reference, 2026-09-25.
///
///  The client (WhatsApp, through the owner) circled the flares round the
///  old orb: "Change outer rendering to other style". Then he sent a
///  picture: "Make it something like this, when it's on, only the speaker
///  should move forward and backwards". The owner: "the exact same
///  surrounding design around the orb as this, with animation while
///  speaking and listening, moving forward and backward".
///
///  So it is two pictures now, and only one of them moves:
///   * THE CENTRE ([VoiceOrb]) — a dark disc with a thin mint-white rim,
///     a white microphone with a little trail of dots above it, and the
///     assistant's name. It holds still: no ticker, painted once.
///   * THE SPEAKER ([VoiceOrbBackdrop]) — the rings round it, brighter
///     and thicker at the sides like speaker cones seen side-on, and the
///     light-wave ribbons running out to both edges. While he talks (his
///     mic level) or the assistant answers (her voice's level) the rings
///     push out and spring back in with the voice; thinking is a slow
///     breath; at rest it is still.
///
///  EVERY NUMBER WAS MEASURED OFF THE REFERENCE, not guessed: the disc's
///  colours and rim, the mic's parts, the dots and the ring table in
///  lib/design/orb_rings.dart. The caption under the orb still says the
///  state in words.
/// ─────────────────────────────────────────────────────────────────────

/// How the orb is behaving, in the only terms the painting cares about.
enum OrbMood { idle, listening, thinking, speaking }

/// The words in the disc for the assistant's [name]: "My Assistant" until
/// the owner has named it (the neutral default, the same rule the splash
/// uses), and the name he chose after that — the "Maya" on the You tab.
String orbLabelFor(String name) {
  final n = name.trim();
  return n.isEmpty || n == AssistantIdentity.fallback ? 'My Assistant' : n;
}

/// The disc's box is this much wider than the disc: room for the rim's
/// soft light.
const double _centreBox = 1.08;

/// The size the reference's label was measured at: the disc on the voice
/// screen (168 dp across). A smaller disc draws it proportionally smaller.
const double _labelDisc = 168;

class VoiceOrb extends StatefulWidget {
  const VoiceOrb({super.key, required this.size, this.label});

  /// The disc's diameter. The rings round it are [VoiceOrbBackdrop].
  final double size;

  /// The words under the mic (see [orbLabelFor]); none when null.
  final String? label;

  @override
  State<VoiceOrb> createState() => _VoiceOrbState();
}

class _VoiceOrbState extends State<VoiceOrb> {
  @override
  void initState() {
    super.initState();
    PaintingBinding.instance.systemFonts.addListener(_fontsChanged);
  }

  @override
  void dispose() {
    PaintingBinding.instance.systemFonts.removeListener(_fontsChanged);
    super.dispose();
  }

  /// A font finished loading (Manrope on a slow first launch): the name
  /// was laid out in the fallback font, so lay it out again, once.
  void _fontsChanged() {
    _Label.clear();
    final p = _painter;
    if (mounted && p != null && p.fonts != _Label.generation) {
      setState(() => _painter = null);
    }
  }

  /// ONE PAINTER FOR AS LONG AS WHAT IT DRAWS IS THE SAME (2026-09-24, GPU
  /// pass). The voice screen rebuilds the orb several times a second (the
  /// caption pacer runs five times a second); the painter, and everything
  /// it has already worked out, is kept until the size, the name or the
  /// colours change.
  _CentrePainter? _painter;

  @override
  Widget build(BuildContext context) {
    final d = widget.size;
    final palette = OrbPalette.current;
    var painter = _painter;
    if (painter == null ||
        painter.diameter != d ||
        painter.label != widget.label ||
        painter.palette.seed != palette.seed) {
      painter = _painter =
          _CentrePainter(diameter: d, label: widget.label, palette: palette);
    }
    // Its own layer, and a still one: the rings round it repaint every
    // frame of a session, this never does.
    return RepaintBoundary(
      child: SizedBox(
        width: d * _centreBox,
        height: d * _centreBox,
        child: CustomPaint(painter: painter),
      ),
    );
  }
}

/// The still centre: disc, rim, mic, dots, stars and name. Nothing in it
/// moves, nothing in it is blurred (a blur is an offscreen pass on every
/// frame the screen is composited, still or not).
class _CentrePainter extends CustomPainter {
  _CentrePainter({
    required this.diameter,
    required this.label,
    required this.palette,
  }) : fonts = _Label.generation;

  final double diameter;
  final String? label;
  final OrbPalette palette;

  /// Which set of loaded fonts the name was laid out with.
  final int fonts;

  _CentreKit? _kit;

  @override
  void paint(Canvas canvas, Size size) {
    var k = _kit;
    if (k == null || k.size != size) k = _kit = _CentreKit(size, diameter, palette);
    final c = k.centre;
    final r = k.r;

    // THE DISC, THE RIM AND ITS LIGHT — one radial gradient. The picture's
    // disc is a deep navy that lifts to teal just inside the rim; the rim
    // is a bright mint-white line with a soft band of light outside it.
    canvas.drawCircle(c, r * _centreBox, k.disc);

    // THE MICROPHONE, as shapes (the icon font's mic has no base bar, and
    // the picture's has one): its soft light first, then the white.
    for (final (paint, extra) in k.micGlow) {
      paint.strokeWidth = extra;
      canvas.drawRRect(k.capsule, paint);
      canvas.drawRRect(k.base, paint);
      canvas.drawRect(k.stem, paint);
      paint.strokeWidth = k.arcWidth + extra;
      canvas.drawArc(k.arcRect, 0, math.pi, false, paint);
    }
    canvas.drawRRect(k.capsule, k.white);
    canvas.drawRect(k.stem, k.white);
    canvas.drawRRect(k.base, k.white);
    canvas.drawArc(k.arcRect, 0, math.pi, false, k.arc);

    // THE TRAIL OF DOTS rising from the mic to the rim, and the sparkles.
    for (final dot in k.dots) {
      canvas.drawCircle(dot.$1, dot.$2 * 2.0, dot.$4);
      canvas.drawCircle(dot.$1, dot.$2, dot.$3);
    }
    canvas.drawPath(k.starHalo, k.starGlow);
    canvas.drawPath(k.star, k.starPaint);
    canvas.drawPath(k.tinyStar, k.starPaint);

    // THE NAME, laid out once (see [_Label]) at the voice screen's size
    // and drawn to this disc's scale.
    final text = label;
    if (text != null && text.isNotEmpty) {
      final l = _Label.of(text);
      canvas.save();
      canvas.translate(c.dx, c.dy);
      canvas.scale(diameter / _labelDisc);
      l.painter.paint(
          canvas, Offset(-l.painter.width / 2, _Label.baselineY - l.baseline));
      canvas.restore();
    }
  }

  // A still picture: a new painter only when what it draws changed.
  @override
  bool shouldRepaint(_CentrePainter old) =>
      old.diameter != diameter ||
      old.label != label ||
      old.palette.seed != palette.seed ||
      old.fonts != fonts;
}

/// What the centre paints with, worked out once for a box and a palette.
class _CentreKit {
  _CentreKit(this.size, double diameter, OrbPalette pal) {
    centre = size.center(Offset.zero);
    r = diameter / 2;
    final c = centre;

    // The disc's colours, measured every few hundredths of its radius
    // (OrbPalette.discStops), then the rim and its light outside.
    final stops = <double>[];
    final colors = <Color>[];
    void at(double rr, Color col) {
      stops.add(rr / _centreBox);
      colors.add(col);
    }

    for (var i = 0; i < OrbPalette.discStops.length; i++) {
      at(OrbPalette.discStops[i], pal.disc[i]);
    }
    final inner = pal.disc.last;
    at(0.984, Color.lerp(inner, pal.rim, 0.30)!);
    at(0.990, Color.lerp(inner, pal.rim, 0.78)!);
    at(0.995, pal.rim);
    at(1.001, pal.rim);
    at(1.007, Color.lerp(pal.rimHalo, pal.rim, 0.62)!);
    at(1.013, Color.lerp(pal.rimHalo, pal.rim, 0.25)!.withValues(alpha: 0.95));
    at(1.020, pal.rimHalo.withValues(alpha: 0.90));
    at(1.045, pal.rimHalo.withValues(alpha: 0.80));
    at(1.075, pal.rimHalo.withValues(alpha: 0));
    at(_centreBox, pal.rimHalo.withValues(alpha: 0));
    disc = Paint()
      ..shader = RadialGradient(colors: colors, stops: stops)
          .createShader(Rect.fromCircle(center: c, radius: r * _centreBox));

    // The mic, in the picture's proportions (R units, y down): a capsule
    // 0.26 wide from -0.51 to -0.06, a U of radius 0.25 drawn 0.06 thick
    // round -0.28, a stem to 0.13 and a rounded base bar 0.36 wide. (The
    // picture's strokes measure 0.055 but carry a glow; drawn crisp they
    // need the extra hair to read the same.)
    capsule = RRect.fromLTRBR(c.dx - 0.13 * r, c.dy - 0.51 * r,
        c.dx + 0.13 * r, c.dy - 0.06 * r, Radius.circular(0.13 * r));
    arcRect =
        Rect.fromCircle(center: c + Offset(0, -0.2775 * r), radius: 0.25 * r);
    arcWidth = 0.062 * r;
    stem = Rect.fromLTRB(
        c.dx - 0.029 * r, c.dy - 0.03 * r, c.dx + 0.029 * r, c.dy + 0.13 * r);
    base = RRect.fromLTRBR(c.dx - 0.185 * r, c.dy + 0.12 * r, c.dx + 0.185 * r,
        c.dy + 0.172 * r, Radius.circular(0.026 * r));
    arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = arcWidth
      ..color = Colors.white;
    // Its soft light: three widening strokes, each fainter — the
    // picture's mic glows a little, and a blur would cost a pass.
    micGlow = [
      for (final (width, alpha) in [(0.11, 0.03), (0.07, 0.04), (0.035, 0.06)])
        (
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round
            ..color = Colors.white.withValues(alpha: alpha),
          width * r
        ),
    ];

    // The trail: nine dots, measured, shrinking and dimming toward the rim.
    const trail = [
      (0.023, -0.573, 0.024),
      (0.056, -0.615, 0.023),
      (0.088, -0.658, 0.022),
      (0.117, -0.701, 0.0206),
      (0.142, -0.744, 0.0188),
      (0.165, -0.786, 0.0167),
      (0.182, -0.828, 0.0153),
      (0.196, -0.870, 0.0139),
      (0.204, -0.913, 0.0127),
    ];
    dots = [
      for (var i = 0; i < trail.length; i++)
        (
          c + Offset(trail[i].$1 * r, trail[i].$2 * r),
          trail[i].$3 * r,
          Paint()..color = Color.lerp(pal.dotNear, pal.dotFar, i / 8)!,
          Paint()
            ..color = Color.lerp(pal.dotNear, pal.dotFar, i / 8)!
                .withValues(alpha: 0.16),
        ),
    ];
    starAt = c + Offset(-0.056 * r, -0.744 * r);
    star = _starPath(starAt, 0.052 * r);
    starHalo = _starPath(starAt, 0.075 * r);
    tinyStar = _starPath(c + Offset(0.19 * r, -0.968 * r), 0.03 * r);
    starPaint = Paint()..color = Color.lerp(pal.rim, Colors.white, 0.3)!;
    starGlow = Paint()..color = pal.rim.withValues(alpha: 0.22);
  }

  final Size size;
  late final Offset centre, starAt;
  late final double r, arcWidth;
  late final Paint disc, arc, starPaint, starGlow;
  late final RRect capsule, base;
  late final Rect arcRect, stem;
  late final Path star, starHalo, tinyStar;
  late final List<(Paint, double)> micGlow;
  late final List<(Offset, double, Paint, Paint)> dots;
  final Paint white = Paint()..color = Colors.white;

  /// A four-point star with concave sides — the "sparkle" shape.
  static Path _starPath(Offset c, double r) {
    final p = Path();
    const inner = 0.28;
    for (var i = 0; i < 4; i++) {
      final a = -math.pi / 2 + i * math.pi / 2;
      final tip = c + Offset(math.cos(a) * r, math.sin(a) * r);
      final nb = a + math.pi / 4;
      final waist =
          c + Offset(math.cos(nb) * r * inner, math.sin(nb) * r * inner);
      if (i == 0) {
        p.moveTo(tip.dx, tip.dy);
      } else {
        p.lineTo(tip.dx, tip.dy);
      }
      p.lineTo(waist.dx, waist.dy);
    }
    return p..close();
  }
}

/// How many times the orb has laid out a name so far. The test that pins
/// "once per name, never per rebuild" reads it.
@visibleForTesting
int get debugOrbLabelLayouts => _Label._layouts;

/// THE NAME, LAID OUT ONCE (the same rule the old mic glyph had, 2026-09-24
/// GPU pass): the voice screen rebuilds the orb several times a second,
/// and a name is laid out once for the app's life, at the voice screen's
/// size — a smaller disc draws it smaller instead of laying it out again.
///
/// Manrope SemiBold at the headline size: the picture's label is a
/// geometric sans about as wide as the mic's U is tall. Not scaled with
/// the phone's text size — it is part of a fixed-size picture, and the
/// caption under the orb (which is) says the same thing in words.
class _Label {
  _Label(this.painter, this.baseline);

  final TextPainter painter;

  /// From the top of the laid-out line to its baseline.
  final double baseline;

  /// Where the baseline sits below the disc's middle, at the voice
  /// screen's size: the picture's letters span 0.474 to 0.676 of the
  /// radius, so the baseline is at 0.62 of it.
  static const double baselineY = 0.62 * _labelDisc / 2;

  static final Map<String, _Label> _made = {};
  static int _layouts = 0;

  /// Bumped when a font loads and every name must be laid out again.
  static int generation = 0;

  static _Label of(String text) => _made[text] ??= _make(text);

  static void clear() {
    if (_made.isEmpty) return;
    for (final l in _made.values) {
      l.painter.dispose();
    }
    _made.clear();
    generation++;
  }

  static _Label _make(String text) {
    // Only a name or two exist in a session; never keep more than a few.
    if (_made.length >= 4) _made.remove(_made.keys.first)?.painter.dispose();
    _layouts++;
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: NeonType.manrope(NeonType.headline, FontWeight.w600)
            .copyWith(color: Colors.white),
      ),
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: 1.45 * _labelDisc / 2);
    final lines = tp.computeLineMetrics();
    final baseline = lines.isEmpty ? tp.height * 0.8 : lines.first.baseline;
    return _Label(tp, baseline);
  }
}

/// THE SPEAKER — the rings round the disc and the ribbons at its sides.
///
/// Paint it full-width: the ribbons run out toward both screen edges; the
/// rings need a slot [reach] times the disc's size, so size the slot for
/// that and every ring is a whole circle.
class VoiceOrbBackdrop extends StatefulWidget {
  const VoiceOrbBackdrop({
    super.key,
    required this.orbSize,
    this.mood = OrbMood.idle,
    this.level = 0,
    this.levelListenable,
    this.speakerLevel,
    this.active = true,
  });

  /// The whole ring system's size as a multiple of the disc's diameter.
  static const double reach = OrbRings.reach;

  /// The disc's diameter (the rings are measured from it).
  final double orbSize;
  final OrbMood mood;

  /// 0..1 — the voice's loudness, when it is not read live.
  final double level;

  /// His mic's loudness as a live value, read on every frame instead of
  /// [level]: the rings then follow the voice without the screen around
  /// them rebuilding for every mic reading.
  final ValueListenable<double>? levelListenable;

  /// The assistant's voice's loudness right now, asked on every frame
  /// while she speaks (a function: it changes every 20 ms of her audio,
  /// and nothing should rebuild for that). Null: [levelListenable].
  final double Function()? speakerLevel;

  /// False while its screen is hidden: it holds still and costs nothing.
  /// Turning true again (a new session) blooms it in afresh.
  final bool active;

  /// The innermost rings' push on the last frame (0 at rest), for tests.
  @visibleForTesting
  static double debugPush = 0;

  @override
  State<VoiceOrbBackdrop> createState() => _VoiceOrbBackdropState();
}

/// Everything the backdrop's painter reads on every frame. A ticker
/// changes it and the painter repaints from it directly — no widget is
/// rebuilt and nothing is laid out for a frame of the rings.
class _BackdropScene extends ChangeNotifier {
  /// Scene time, integrated from the ticks (a pause carries on from the
  /// same picture instead of jumping).
  double sec = 0;

  /// 0..1 — the bloom-in (see [_VoiceOrbBackdropState._bloomDelay]).
  double appear = 0;

  /// Eased 0..1: thinking; the voice's loudness; a session running.
  double think = 0, glow = 0, alive = 0;

  /// Each moving tier's push (a share of its radius) and its speed.
  final Float64List x = Float64List(5), v = Float64List(5);

  /// How much wider tier [t] is drawn than at rest.
  double scaleOf(int t) => t >= OrbRings.frame ? 1.0 : 1.0 + x[t];

  /// The ribbons drift up and down a little while a session runs...
  double get sway => alive * 0.022 * math.sin(0.47 * sec);

  /// ...and swell with the voice.
  double get stretch => 1 + 0.10 * glow;

  /// The GPU program's shader (see [_BackdropPainter._paintGpu]): made on
  /// the first frame drawn with it and reused.
  ui.FragmentShader? shader;

  void reset() {
    x.fillRange(0, 5, 0);
    v.fillRange(0, 5, 0);
    think = 0;
    glow = 0;
    alive = 0;
  }

  void changed() => notifyListeners();

  @override
  void dispose() {
    shader?.dispose();
    super.dispose();
  }
}

class _VoiceOrbBackdropState extends State<VoiceOrbBackdrop>
    with SingleTickerProviderStateMixin {
  /// Drives the repaints — ONLY while something moves (see [_sync]): while
  /// the orb listens, thinks or speaks, and while the rings are still
  /// settling. Then it stops, and a resting session draws no frames at
  /// all. Each frame is paint-only: the ticker changes [_scene], the
  /// painter repaints its own layer from it, and no widget is rebuilt.
  late final Ticker _ticker = createTicker(_onTick);
  Duration _lastTick = Duration.zero;
  final _BackdropScene _scene = _BackdropScene();

  /// THE LIGHTER FIRST FRAME (2026-09-24: opening the voice screen cost
  /// one 67 ms frame). The rings draw nothing for their first [_bloomDelay]
  /// seconds and then fade in over [_bloomFade] — one more number the GPU
  /// program multiplies by — so the ground, the disc and the words arrive
  /// first and the rings bloom in after them.
  static const _bloomDelay = 0.12, _bloomFade = 0.35;
  double _shownFor = 0;
  double get _appear =>
      ((_shownFor - _bloomDelay) / _bloomFade).clamp(0.0, 1.0);

  /// "Remove animations" is on: the rings hold still (the bloom still
  /// fades in — the app's rule is "fade only").
  bool _still = false;

  bool get _moving =>
      widget.active && widget.mood != OrbMood.idle && !_still;

  /// Fully faded in and every ring at rest: nothing left to move.
  bool get _settled {
    final sc = _scene;
    if (_appear < 1 || sc.think >= 0.01 || sc.glow >= 0.01) return false;
    if (sc.alive >= 0.01) return false;
    for (var i = 0; i < 5; i++) {
      if (sc.x[i].abs() >= 1e-4 || sc.v[i].abs() >= 1e-3) return false;
    }
    return true;
  }

  @override
  void initState() {
    super.initState();
    // Load the GPU program now, while this sits built and hidden behind
    // Home, so the first session never draws with the fallback or waits.
    GpuProgram.voiceBackdrop.load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _still = Motion.reduced(context);
    if (_still) _scene.reset();
    _sync();
  }

  @override
  void didUpdateWidget(VoiceOrbBackdrop old) {
    super.didUpdateWidget(old);
    // A new session: bloom in again, from rest. The screen was fully
    // faded out while inactive, so starting from nothing is never seen.
    if (widget.active && !old.active) {
      _shownFor = 0;
      _scene
        ..appear = 0
        ..reset();
    }
    _sync();
  }

  void _sync() {
    final run = widget.active && (_moving || !_settled);
    if (run && !_ticker.isActive) {
      _lastTick = Duration.zero;
      _ticker.start();
    } else if (!run && _ticker.isActive) {
      _ticker.stop();
    }
  }

  /// What the rings hear right now: his mic while listening, her voice
  /// while she speaks.
  double _heard() {
    final w = widget;
    final double l = switch (w.mood) {
      OrbMood.speaking =>
        w.speakerLevel?.call() ?? w.levelListenable?.value ?? w.level,
      OrbMood.listening => w.levelListenable?.value ?? w.level,
      _ => 0.0,
    };
    return l.isFinite ? l.clamp(0.0, 1.0) : 0.0;
  }

  /// Eases [v] toward [to] at [rate] per second over [dt] (a plain
  /// function, not a closure made each frame).
  static double _ease(double v, double to, double rate, double dt) =>
      v + (to - v) * (1 - math.exp(-dt * rate));

  void _onTick(Duration elapsed) {
    final dt = ((elapsed - _lastTick).inMicroseconds / 1e6).clamp(0.0, 0.1);
    _lastTick = elapsed;
    final sc = _scene;
    final moving = _moving;

    // A whisper does not move a speaker: below 3% is silence, and the
    // curve lifts quiet speech so it still shows.
    final heard = moving ? _heard() : 0.0;
    final drive =
        heard <= 0.03 ? 0.0 : math.pow((heard - 0.03) / 0.97, 0.75).toDouble();
    sc.glow = _ease(sc.glow, drive, drive > sc.glow ? 30 : 8, dt);
    sc.think =
        _ease(sc.think, moving && widget.mood == OrbMood.thinking ? 1 : 0, 4, dt);
    sc.alive = _ease(sc.alive, moving ? 1 : 0, 3, dt);
    sc.sec += dt;
    _shownFor += dt;
    sc.appear = _appear;

    // THE SPEAKER. Each tier is a spring chasing the voice: pushed out as
    // far as OrbRings.push says at full voice, and — being under-damped —
    // it overshoots a little on the way back, the push-and-return of a
    // cone. Thinking replaces the voice with a slow breath that rolls
    // outward. Stepped in small pieces so a long frame stays stable.
    final steps = (dt * 240).ceil().clamp(1, 24);
    final h = dt / steps;
    for (var i = 0; i < 5; i++) {
      final breath = sc.think *
          0.018 *
          (0.5 - 0.5 * math.cos(2 * math.pi * (sc.sec - 0.12 * i) / 2.8));
      final target = _still ? 0.0 : drive * OrbRings.push[i] + breath;
      final hz = OrbRings.springHz * (1 - OrbRings.springFalloff * i);
      final k = (2 * math.pi * hz) * (2 * math.pi * hz);
      final c = 2 * OrbRings.damping * math.sqrt(k);
      var x = sc.x[i], v = sc.v[i];
      for (var s = 0; s < steps; s++) {
        v += (k * (target - x) - c * v) * h;
        x += v * h;
      }
      sc.x[i] = x;
      sc.v[i] = v;
    }
    if (_still) sc.reset();

    if (!moving && _settled) {
      // Come to rest exactly — the picture is the reference again — then
      // stop asking for frames.
      sc.reset();
      _ticker.stop();
    }
    VoiceOrbBackdrop.debugPush = sc.x[0];
    sc.changed();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _scene.dispose();
    super.dispose();
  }

  // Its own layer, so the rings' frames never re-record the screen round
  // them.
  @override
  Widget build(BuildContext context) => RepaintBoundary(
        child: CustomPaint(
          painter: _BackdropPainter(
            scene: _scene,
            orbRadius: widget.orbSize / 2,
            palette: OrbPalette.current,
            dpr: MediaQuery.maybeDevicePixelRatioOf(context) ?? 3.0,
          ),
          child: const SizedBox.expand(),
        ),
      );
}

class _BackdropPainter extends CustomPainter {
  _BackdropPainter({
    required this.scene,
    required this.orbRadius,
    required this.palette,
    required this.dpr,
  }) : super(repaint: scene);

  final _BackdropScene scene;

  /// The disc's radius, R: every number in OrbRings is a multiple of it.
  final double orbRadius;
  final OrbPalette palette;

  /// The screen's density (the GPU program's dither is per device pixel).
  final double dpr;

  final Paint _gpu = Paint();
  final Paint _mesh = Paint();
  double _meshAlpha = -1;
  Rect _box = Rect.zero;

  @override
  void paint(Canvas canvas, Size size) {
    // Not faded in yet: draw nothing at all.
    if (scene.appear <= 0) return;
    final program = GpuProgram.voiceBackdrop.program;
    if (program != null) {
      _paintGpu(canvas, size, program);
    } else {
      _paintCanvas(canvas, size);
    }
  }

  ui.FragmentShader? _shader;
  int _u = 0;

  /// One uniform. A method, not a closure made per frame: the GPU path
  /// allocates nothing on a frame.
  void _f(double v) => _shader!.setFloat(_u++, v);

  void _rgb(Color c) {
    _f(c.r);
    _f(c.g);
    _f(c.b);
    _f(1);
  }

  /// THE GPU PATH: the whole picture — rings, ribbons, sparkles — in ONE
  /// rectangle, drawn by shaders/voice_backdrop.frag. No offscreen layer,
  /// no paths, no blur, nothing on the Canvas beside it.
  void _paintGpu(Canvas canvas, Size size, ui.FragmentProgram program) {
    final sc = scene;
    final r = orbRadius;
    _shader = sc.shader ??= program.fragmentShader();
    _u = 0;
    // uGeom, uState
    _f(size.width);
    _f(size.height);
    _f(r);
    _f(1 / dpr);
    _f(sc.appear);
    _f(sc.sway * r);
    _f(sc.stretch);
    _f(0);
    // uPush0, uPush1
    _f(sc.scaleOf(0));
    _f(sc.scaleOf(1));
    _f(sc.scaleOf(2));
    _f(sc.scaleOf(3));
    _f(sc.scaleOf(4));
    _f(OrbRings.pushTopShare);
    _f(0);
    _f(0);
    // The palette, in the order the program declares it.
    final top = palette.elements, sides = palette.sides;
    for (var i = 0; i < top.length; i++) {
      _rgb(top[i]);
    }
    for (var i = 0; i < sides.length; i++) {
      if (!OrbRings.elements[i].lens) _rgb(sides[i]);
    }
    _rgb(palette.ribbonNear);
    _rgb(palette.ribbonFar);
    _rgb(palette.ribbonAccent);
    _rgb(palette.sparkle);
    if (_box.width != size.width || _box.height != size.height) {
      _box = Offset.zero & size;
    }
    canvas.drawRect(_box, _gpu..shader = _shader);
  }

  /// THE CANVAS PATH — the same table, for the frames before the GPU
  /// program has loaded and for any phone that cannot load it. Every
  /// element is a triangle mesh built ONCE round the origin at radius 1
  /// ([_OrbMeshes]); a frame only moves it into place and scales it by
  /// its push, so the keyboard shrinking the orb or the voice pushing a
  /// ring rebuilds nothing. Each mesh carries its colours in its corners,
  /// and the GPU program interpolates exactly the same way, so the two
  /// pictures match to a rounding step.
  void _paintCanvas(Canvas canvas, Size size) {
    final sc = scene;
    final meshes = _OrbMeshes.of(palette);
    final r = orbRadius;
    final cx = size.width / 2, cy = size.height / 2;
    if (sc.appear != _meshAlpha) {
      _meshAlpha = sc.appear;
      _mesh.color = Color.fromRGBO(255, 255, 255, sc.appear);
    }
    const top = OrbRings.pushTopShare;
    for (var i = 0; i < OrbRings.elements.length; i++) {
      final s = sc.scaleOf(OrbRings.elements[i].tier);
      canvas.save();
      canvas.translate(cx, cy);
      canvas.scale(r * s, r * (1 + top * (s - 1)));
      canvas.drawVertices(meshes.elements[i], BlendMode.dst, _mesh);
      canvas.restore();
    }
    canvas.save();
    canvas.translate(cx, cy + sc.sway * r);
    canvas.scale(r, r * sc.stretch);
    canvas.drawVertices(meshes.ribbons, BlendMode.dst, _mesh);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_BackdropPainter old) =>
      // Frames repaint through [scene]. A rebuild repaints only when what
      // it draws with changed.
      old.scene != scene ||
      old.orbRadius != orbRadius ||
      old.palette.seed != palette.seed ||
      old.dpr != dpr;
}

/// THE CANVAS PAINTER'S MESHES, built once per palette (and kept: the
/// palette only changes when the owner picks a new theme colour).
///
/// Across an element the mesh has six rows — the glow's outer edge, the
/// bright edge, the core's two sides, the bright edge and the glow's
/// outer edge again — with the profile's alpha in each row, so the
/// renderer's own interpolation between the rows draws exactly the
/// profile the GPU program works out per pixel.
class _OrbMeshes {
  _OrbMeshes._(OrbPalette p)
      : elements = [
          for (var i = 0; i < OrbRings.elements.length; i++)
            _element(OrbRings.elements[i], p.elements[i], p.sides[i]),
        ],
        ribbons = _ribbons(p);

  final List<ui.Vertices> elements;
  final ui.Vertices ribbons;

  static _OrbMeshes? _last;
  static Color? _lastSeed;

  static _OrbMeshes of(OrbPalette p) {
    final last = _last;
    if (last != null && _lastSeed == p.seed) return last;
    _lastSeed = p.seed;
    return _last = _OrbMeshes._(p);
  }

  /// A colour with its alpha, for a vertex.
  static int _argb(Color c, double a) =>
      (((a.clamp(0.0, 1.0) * 255).round()) << 24) |
      (((c.r * 255).round()) << 16) |
      (((c.g * 255).round()) << 8) |
      ((c.b * 255).round());

  static ui.Vertices _element(OrbElement el, Color top, Color side) {
    // Angles to sample: all the way round for a full ring; for a lens,
    // the two arcs where it exists (right and left), densely enough that
    // its pointed ends stay pointed.
    final angles = <double>[];
    final arcs = <int>[];
    if (el.lens) {
      const n = 128;
      for (final mid in [0.0, 180.0]) {
        arcs.add(n + 1);
        for (var k = 0; k <= n; k++) {
          angles.add(mid - el.tip + 2 * el.tip * k / n);
        }
      }
    } else {
      const n = 256;
      arcs.add(n + 1);
      for (var k = 0; k <= n; k++) {
        angles.add(360.0 * k / n);
      }
    }
    final pos = Float32List(angles.length * 6 * 2);
    final col = Int32List(angles.length * 6);
    var vi = 0;
    for (final deg in angles) {
      final th = deg * math.pi / 180;
      final cs = math.cos(th), sn = math.sin(th);
      // Degrees from the horizontal, 0..90, as the program measures it.
      final al = math.atan2(sn.abs(), cs.abs()) * 180 / math.pi;
      double h = el.h, rc = el.r0, m = 1;
      var c = top;
      if (el.lens) {
        final w = (1 - (al / el.tip) * (al / el.tip)).clamp(0.0, 1.0);
        h = el.h * w;
        rc = el.r0 + el.drift * (1 - w);
        m = OrbRings.smoothstep(el.fade0, el.fade1, w);
      } else {
        final ts = (1 - (al / el.side) * (al / el.side)).clamp(0.0, 1.0);
        c = Color.lerp(top, side, ts)!;
      }
      final offs = [
        -(h + el.e + el.g), -(h + el.e), -h, h, h + el.e, h + el.e + el.g
      ];
      final alphas = [0.0, el.a1, el.a0, el.a0, el.a1, 0.0];
      for (var row = 0; row < 6; row++) {
        final rr = rc + offs[row];
        pos[vi * 2] = cs * rr;
        pos[vi * 2 + 1] = sn * rr;
        col[vi] = _argb(c, alphas[row] * m);
        vi++;
      }
    }
    final idx = <int>[];
    var start = 0;
    for (final count in arcs) {
      for (var k = 0; k < count - 1; k++) {
        for (var row = 0; row < 5; row++) {
          final a = (start + k) * 6 + row, b = a + 1;
          final c = a + 6, d = c + 1;
          idx.addAll([a, b, c, b, d, c]);
        }
      }
      start += count;
    }
    return ui.Vertices.raw(ui.VertexMode.triangles, pos,
        colors: col, indices: Uint16List.fromList(idx));
  }

  /// Each side's sheet, its strands (three rows each: nothing, the line,
  /// nothing) and accent strands, then the sparkles as little soft discs —
  /// in the order the program paints them.
  static ui.Vertices _ribbons(OrbPalette p) {
    final pos = <double>[];
    final col = <int>[];
    final idx = <int>[];
    const n = OrbRings.ribbonSamples;

    /// A band along the ribbon: at each sample, [rows] heights (offsets
    /// from [y], in units of [unit]) with their share of [a].
    void strip(int side, double Function(double u) y, double Function(double u) unit,
        double Function(double u) a, Color Function(double u) colour,
        List<(double, double)> rows) {
      final base = pos.length ~/ 2;
      final m = rows.length;
      for (var k = 0; k <= n; k++) {
        final xAbs = OrbRings.ribbonFrom +
            (OrbRings.ribbonTo - OrbRings.ribbonFrom) * k / n;
        final u = OrbRings.ribbonU(xAbs);
        final yy = y(u), un = unit(u), al = a(u);
        final c = colour(u);
        for (final (dy, share) in rows) {
          pos
            ..add(side * xAbs)
            ..add(yy + dy * un);
          col.add(_argb(c, al * share));
        }
      }
      for (var k = 0; k < n; k++) {
        for (var row = 0; row < m - 1; row++) {
          final a0 = base + k * m + row, b0 = a0 + 1;
          final c0 = a0 + m, d0 = c0 + 1;
          idx.addAll([a0, b0, c0, b0, d0, c0]);
        }
      }
    }

    Color shade(double u) =>
        Color.lerp(p.ribbonNear, p.ribbonFar, OrbRings.ribbonShade(u))!;
    const line = [(-1.0, 0.0), (0.0, 1.0), (1.0, 0.0)];
    const sheet = [
      (-1.0, 0.0),
      (-OrbRings.sheetKnee, OrbRings.sheetKneeAlpha),
      (0.0, 1.0),
      (OrbRings.sheetKnee, OrbRings.sheetKneeAlpha),
      (1.0, 0.0),
    ];

    for (final side in [1, -1]) {
      strip(side, (u) => OrbRings.ribbonMid(u, side),
          (u) => OrbRings.ribbonHalf(u, side), OrbRings.sheetAlpha, shade, sheet);
      for (var j = 0; j < OrbRings.strands; j++) {
        strip(side, (u) => OrbRings.strandY(u, side, j), (_) => OrbRings.strandHalf,
            (u) => OrbRings.strandAlpha(u, side, j), shade, line);
      }
      for (var i = 0; i < OrbRings.accents; i++) {
        strip(side, (u) => OrbRings.accentY(u, side, i), (_) => OrbRings.accentHalf,
            OrbRings.accentAlpha, (_) => p.ribbonAccent, line);
      }
      for (final (x, dy, rad, a) in side > 0
          ? OrbRings.sparklesRight
          : OrbRings.sparklesLeft) {
        final cx = side * x;
        final cy = OrbRings.ribbonMid(OrbRings.ribbonU(x), side) + dy;
        final base = pos.length ~/ 2;
        const spokes = 24;
        pos
          ..add(cx)
          ..add(cy);
        col.add(_argb(p.sparkle, a));
        for (var s = 0; s < spokes; s++) {
          final t = 2 * math.pi * s / spokes;
          for (final (f, on) in [(0.45, 1.0), (1.0, 0.0)]) {
            pos
              ..add(cx + math.cos(t) * rad * f)
              ..add(cy + math.sin(t) * rad * f);
            col.add(_argb(p.sparkle, a * on));
          }
        }
        for (var s = 0; s < spokes; s++) {
          final i0 = base + 1 + s * 2, o0 = i0 + 1;
          final i1 = base + 1 + ((s + 1) % spokes) * 2, o1 = i1 + 1;
          idx.addAll([base, i0, i1, i0, o0, i1, o0, o1, i1]);
        }
      }
    }
    return ui.Vertices.raw(ui.VertexMode.triangles, Float32List.fromList(pos),
        colors: Int32List.fromList(col), indices: Uint16List.fromList(idx));
  }
}
