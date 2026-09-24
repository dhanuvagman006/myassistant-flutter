import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../design/gpu_programs.dart';
import '../design/neon_tokens.dart';

/// ─────────────────────────────────────────────────────────────────────
///  THE LISTENING ORB — built from the reference design on his phone.
///
///  A glossy mint sphere with a white microphone in it, floating in a
///  tunnel of concentric rings that runs off both edges of the screen —
///  teal on the left, magenta on the right — with thin waveform lines
///  crossing behind it.
///
///  EVERY NUMBER HERE WAS MEASURED OFF THE REFERENCE, not guessed:
///  the sphere is 35% of the screen's width; the light falls from the
///  upper left (#64EED6 where it lands, #078778 at the shaded bottom);
///  the rings sit at 1.02, 1.39, 1.56, 1.91 and 2.2 times the sphere's
///  radius. Copying a design by eye is how you end up with something
///  that is nearly it and reads as wrong.
///
///  WHAT IT STILL HAS TO DO. The old orb showed the session's state in
///  colour — cyan listening, violet thinking, pink speaking — and that
///  was worth keeping when the picture itself is now one fixed mint. So
///  the SPHERE is the design and never changes, and the state lives in
///  the movement around it: a liquid ring ripples with the voice and
///  pulses roll outward while it listens or speaks, and comets circle it
///  while it thinks. The caption under the orb still says the word.
/// ─────────────────────────────────────────────────────────────────────

/// How the orb is behaving, in the only terms the painting cares about.
enum OrbMood { idle, listening, thinking, speaking }

class VoiceOrb extends StatefulWidget {
  const VoiceOrb({
    super.key,
    required this.size,
    this.mood = OrbMood.idle,
    this.level = 0,
    this.levelListenable,
    this.active = true,
  });

  /// The sphere's diameter. The backdrop is drawn by [VoiceOrbBackdrop].
  final double size;
  final OrbMood mood;

  /// 0..1 — mic loudness while listening, voice loudness while speaking.
  final double level;

  /// The same loudness as a live value, read on every frame instead of
  /// [level]: the orb then follows the voice without the screen around it
  /// rebuilding for every mic reading.
  final ValueListenable<double>? levelListenable;

  /// False while the screen the orb lives on is hidden. The voice
  /// session's overlay stays built between sessions (so opening it is one
  /// cheap frame, not a whole screen built from nothing), and a hidden orb
  /// must not tick.
  final bool active;

  @override
  State<VoiceOrb> createState() => _VoiceOrbState();
}

/// What the sphere's painter reads on every frame. A ticker changes it
/// and the painter repaints from it directly — no widget is rebuilt and
/// nothing is laid out for a frame of the orb.
class _SphereMotion extends ChangeNotifier {
  /// 0..1 round one slow six-second breath (and the inner light's orbit).
  double phase = 0;

  /// The voice, chased (see [_VoiceOrbState._onTick]).
  double glow = 0;

  /// The extra swell the voice gives the sphere; 0 at rest.
  double swell = 0;

  void changed() => notifyListeners();
}

class _VoiceOrbState extends State<VoiceOrb>
    with SingleTickerProviderStateMixin {
  /// One slow breath — ONLY while something is happening.
  ///
  /// It used to run forever. The voice overlay is built (invisible) behind
  /// Home the whole time, so this one animation kept the idle Home drawing
  /// 60 frames a second — measured on his phone, 2026-09-24. It now moves
  /// while the orb listens, thinks or speaks, lets the glow settle when it
  /// stops, and holds still at rest (hidden, connecting, or paused while
  /// he types). Paused, not reset: it resumes from the same breath.
  ///
  /// PAINT-ONLY FRAMES. It used to rebuild its widgets every frame, and
  /// on the voice screen that re-ran the screen's layout up to the page —
  /// every frame of the session. The ticker now updates [_motion] and only
  /// the sphere's own layer is repainted.
  late final Ticker _ticker = createTicker(_onTick);
  Duration _lastTick = Duration.zero;
  final _SphereMotion _motion = _SphereMotion();

  bool get _moving => widget.active && widget.mood != OrbMood.idle;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(VoiceOrb old) {
    super.didUpdateWidget(old);
    _sync();
  }

  /// Runs while it moves, or while the glow is still settling.
  void _sync() {
    if (!widget.active) {
      // Hidden: hold still where it is (its screen is fading away) and
      // start the next session from rest.
      if (_ticker.isActive) _ticker.stop();
      _motion
        ..glow = 0
        ..swell = 0;
      return;
    }
    final run = _moving || _motion.glow > 0 || _motion.swell > 0;
    if (run && !_ticker.isActive) {
      _lastTick = Duration.zero;
      _ticker.start();
    } else if (!run && _ticker.isActive) {
      _ticker.stop();
    }
  }

  void _onTick(Duration elapsed) {
    final dt = ((elapsed - _lastTick).inMicroseconds / 1e6).clamp(0.0, 0.1);
    _lastTick = elapsed;
    final m = _motion;
    final moving = _moving;
    // The level jumps frame to frame; following it directly makes the orb
    // judder. Chase it instead — fast to swell, slow to settle, the way a
    // physical thing with mass would move. At rest it settles to nothing.
    final heard = widget.levelListenable?.value ?? widget.level;
    final target = moving ? heard.clamp(0.0, 1.0) : 0.0;
    // The rates were tuned per mic reading, about 30 a second; now they
    // are applied per frame, scaled to the same pace.
    final rate = target > m.glow ? 0.35 : 0.08;
    m.glow += (target - m.glow) * (1 - math.pow(1 - rate, dt * 30));
    if (target == 0 && m.glow < 0.002) m.glow = 0;
    // Up to 7% more size when a voice is behind it.
    m.swell = widget.mood == OrbMood.idle ? 0.0 : m.glow * 0.07;
    if (moving) m.phase = (m.phase + dt / 6) % 1.0;
    m.changed();
    if (!moving && m.glow == 0 && m.swell == 0) _ticker.stop();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _motion.dispose();
    super.dispose();
  }

  /// ONE PAINTER FOR AS LONG AS WHAT IT DRAWS IS THE SAME (2026-09-24,
  /// GPU pass). The voice screen rebuilds the orb several times a second
  /// (the caption pacer runs five times a second); each rebuild used to
  /// hand it a brand-new painter, which then built its gradients and laid
  /// out the mic glyph all over again. The painter, and everything it has
  /// already worked out, is now kept until the size or the colours change.
  _SpherePainter? _painter;

  @override
  Widget build(BuildContext context) {
    final d = widget.size;
    var painter = _painter;
    if (painter == null ||
        painter.diameter != d ||
        painter.violet != Neon.violet ||
        painter.pink != Neon.pink) {
      painter = _painter = _SpherePainter(
        motion: _motion,
        diameter: d,
        violet: Neon.violet,
        pink: Neon.pink,
      );
    }
    // Its own layer: the sphere repaints every frame while it moves, and
    // without a boundary each of those frames re-recorded the whole voice
    // screen around it — captions, text box and all.
    return RepaintBoundary(
      child: SizedBox(
        width: d * 1.6, // room for the glow
        height: d * 1.6,
        child: CustomPaint(painter: painter),
      ),
    );
  }
}

/// The sphere: lit from the upper left, shaded at the bottom, with a
/// specular highlight, a soft teal glow around it, the small sparkle the
/// reference puts at its upper right — and the microphone in it.
class _SpherePainter extends CustomPainter {
  _SpherePainter({
    required this.motion,
    required this.diameter,
    required this.violet,
    required this.pink,
  }) : super(repaint: motion);

  final _SphereMotion motion;
  final double diameter;

  /// The accent pair, carried so a still orb repaints when it changes —
  /// it no longer repaints every frame and would otherwise keep the old
  /// colour.
  final Color violet, pink;

  /// THE REFERENCE'S LIGHTING, THE APP'S COLOUR.
  ///
  /// His correction: "the exact same design and background but in current
  /// app's theme". So the SHAPE of the light is copied precisely — the
  /// reference runs from L=0.85 where the light lands to L=0.26 in the
  /// shade, over one hue — and that same ramp is rebuilt on the app's
  /// accent instead of the mint it was drawn in.
  ///
  /// Read from the tokens, never hardcoded: the accent is the user's own
  /// choice (Settings → theme colour), and a fixed violet here would be
  /// the one thing on screen that ignored it.
  static Color _ramp(Color base, double lightness, [Color? toward, double mix = 0]) {
    final c = toward == null ? base : Color.lerp(base, toward, mix)!;
    final h = HSLColor.fromColor(c);
    return h
        .withLightness(lightness.clamp(0.0, 1.0))
        .withSaturation((h.saturation * 1.05).clamp(0.35, 1.0))
        .toColor();
  }

  /// NOTHING BUILT PER FRAME (2026-09-24, GPU pass). The gradients, blurs,
  /// clip and sparkle depend only on the box and the colours, yet every
  /// frame of a session used to create them all again. They are made on
  /// the first frame and kept for this painter's life (and the painter is
  /// kept across rebuilds, see [_VoiceOrbState._painter]).
  _SphereKit? _kit;

  _SphereKit _kitFor(Size size) {
    final k = _kit;
    if (k != null && k.size == size) return k;
    return _kit = _SphereKit(size, diameter, violet, pink);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final k = _kitFor(size);
    final c = k.centre;
    final r = k.r;
    final t = motion.phase;
    final glow = motion.glow;

    // A 2% breath while it moves; up to 7% more when a voice is behind
    // it. Round the centre, glyph included.
    final scale = 1 + 0.02 * math.sin(t * 2 * math.pi) + motion.swell;
    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.scale(scale);
    canvas.translate(-c.dx, -c.dy);

    // The light it throws, in the accent's own hue.
    canvas.drawCircle(c, r * 0.96,
        k.light..color = violet.withValues(alpha: 0.22 + glow * 0.16));

    // THE BODY. The focal point is up and to the left, which is where the
    // reference puts its light; everything else follows from that.
    canvas.drawCircle(c, r, k.body);

    // The shaded underside, so it reads as a ball and not a disc.
    canvas.drawCircle(c, r, k.shade);

    // LIGHT INSIDE IT — a soft glow drifting round within the ball, a
    // touch brighter with the voice, so the sphere itself looks alive.
    // The gradient is made once round the origin and moved into place;
    // its strength rides on the paint's alpha, which gives the same
    // colour, stop for stop, as a gradient rebuilt with that alpha.
    final orbit = t * 2 * math.pi;
    final inner = c +
        Offset(math.cos(orbit) * r * 0.38, math.sin(orbit) * r * 0.30 + r * 0.18);
    canvas.save();
    canvas.clipPath(k.clip);
    canvas.translate(inner.dx, inner.dy);
    canvas.drawCircle(Offset.zero, r * 0.75,
        k.inner..color = Color.fromRGBO(0, 0, 0, 0.28 + glow * 0.30));
    canvas.restore();

    // THE HIGHLIGHT — a soft oval where the light lands, not a hard dot.
    canvas.drawOval(k.highlightRect, k.highlight);

    // THE SPARKLE at the upper right: a four-point star and two dots,
    // exactly where the reference has them.
    canvas.drawPath(k.star, k.starPaint);
    canvas.drawCircle(c + Offset(r * 0.68, -r * 0.40), r * 0.035, k.dotBright);
    canvas.drawCircle(c + Offset(r * 0.30, -r * 0.26), r * 0.022, k.dotSoft);

    // THE MICROPHONE, on top of it all.
    final glyph = _Glyph.of(diameter);
    glyph.paint(canvas, c - Offset(glyph.width / 2, glyph.height / 2));
    canvas.restore();
  }

  // Frames repaint through [motion]; a new painter only when what it
  // draws with changed.
  @override
  bool shouldRepaint(_SpherePainter old) =>
      old.motion != motion ||
      old.diameter != diameter ||
      old.violet != violet ||
      old.pink != pink;
}

/// What the sphere paints with, worked out once for a box and colours.
class _SphereKit {
  _SphereKit(this.size, double diameter, Color violet, Color pink) {
    centre = size.center(Offset.zero);
    // The sphere is [diameter] across — less only when the box it was
    // given is smaller still.
    r = math.min(diameter, size.shortestSide) / 2;
    final ball = Rect.fromCircle(center: centre, radius: r);
    light = Paint()..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.16);
    body = Paint()
      ..shader = RadialGradient(
        center: const Alignment(-0.38, -0.42),
        radius: 0.95,
        colors: [
          // The same four stops the reference has, re-hued: lit, body,
          // and a shaded underside pulled toward the gradient partner
          // so the ball carries the brand's violet-into-magenta.
          _SpherePainter._ramp(violet, 0.86),
          _SpherePainter._ramp(violet, 0.70),
          _SpherePainter._ramp(violet, 0.54, pink, 0.25),
          _SpherePainter._ramp(violet, 0.33, pink, 0.40),
        ],
        stops: const [0.0, 0.34, 0.72, 1.0],
      ).createShader(ball);
    final under = _SpherePainter._ramp(violet, 0.20, pink, 0.3);
    shade = Paint()
      ..shader = RadialGradient(
        center: const Alignment(0.25, 0.85),
        radius: 0.8,
        colors: [
          under.withValues(alpha: 0.55),
          under.withValues(alpha: 0.0),
        ],
        stops: const [0.0, 1.0],
      ).createShader(ball);
    inner = Paint()
      ..shader = RadialGradient(colors: [
        Color.lerp(pink, Colors.white, 0.25)!,
        pink.withValues(alpha: 0),
      ]).createShader(Rect.fromCircle(center: Offset.zero, radius: r * 0.75));
    clip = Path()..addOval(ball);
    highlightRect = Rect.fromCenter(
      center: centre + Offset(-r * 0.32, -r * 0.46),
      width: r * 0.76,
      height: r * 0.50,
    );
    highlight = Paint()
      ..color = Colors.white.withValues(alpha: 0.42)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.16);
    star = _starPath(centre + Offset(r * 0.44, -r * 0.50), r * 0.17);
  }

  final Size size;
  late final Offset centre;
  late final double r;
  late final Paint light, body, shade, inner, highlight;
  late final Path clip, star;
  late final Rect highlightRect;
  final Paint starPaint = Paint()..color = Colors.white.withValues(alpha: 0.95);
  final Paint dotBright = Paint()..color = Colors.white.withValues(alpha: 0.85);
  final Paint dotSoft = Paint()..color = Colors.white.withValues(alpha: 0.60);

  /// A four-point star with concave sides — the "sparkle" shape.
  static Path _starPath(Offset c, double r) {
    final p = Path();
    const inner = 0.30;
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

/// How many times the orb has laid out its mic glyph so far. The test
/// that pins "once per size, never per rebuild" reads it.
@visibleForTesting
int get debugOrbGlyphLayouts => _Glyph._layouts;

/// THE MIC GLYPH, LAID OUT ONCE PER SIZE (2026-09-24, GPU pass).
///
/// It is text in the icon font, exactly as the Icon widget draws it, so it
/// stays as crisp at every density — painted in the sphere so it breathes
/// with it. It used to be laid out afresh by every new painter, and the
/// voice screen made a new painter several times a second; now each size
/// is laid out once for the app's life.
///
/// Still text, on purpose. Drawing it from a picture instead (so the
/// renderer would not rasterise it at each new breathing scale) softened
/// its edges by about half a pixel, and the glyph cache that saves is
/// small and fills within the first seconds of a session.
class _Glyph {
  static final Map<double, TextPainter> _made = {};
  static int _layouts = 0;

  static TextPainter of(double diameter) =>
      _made[diameter] ??= _make(diameter);

  static TextPainter _make(double diameter) {
    // Only a handful of orb sizes exist; never keep more than a few.
    if (_made.length >= 4) _made.remove(_made.keys.first)?.dispose();
    _layouts++;
    return TextPainter(
      text: TextSpan(
        text: String.fromCharCode(Icons.mic_rounded.codePoint),
        style: TextStyle(
          inherit: false,
          color: Colors.white,
          fontSize: diameter * 0.36,
          fontFamily: Icons.mic_rounded.fontFamily,
          package: Icons.mic_rounded.fontPackage,
          height: 1.0,
          leadingDistribution: TextLeadingDistribution.even,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
  }
}

/// The space behind the orb. Same two brand hues as before, rebuilt to
/// feel alive rather than busy:
///
///  * an AURORA — two soft clouds of the accent (left) and its partner
///    (right) drifting slowly, brightening with the voice;
///  * DUST — faint motes floating outward from the orb, the way sound
///    carries;
///  * the reference's ring TUNNEL, kept for depth but pulled right back;
///  * and the part that says "I hear you": a LIQUID RING hugging the orb
///    that ripples with the voice, and pulses that roll outward faster the
///    louder it gets. Thinking swaps both for comets circling the orb.
///
/// Paint it full-width — it reaches both screen edges.
class VoiceOrbBackdrop extends StatefulWidget {
  const VoiceOrbBackdrop({
    super.key,
    required this.orbSize,
    this.mood = OrbMood.idle,
    this.level = 0,
    this.levelListenable,
    this.active = true,
  });

  final double orbSize;
  final OrbMood mood;
  final double level;

  /// The loudness as a live value, read on every frame instead of [level]
  /// (see [VoiceOrb.levelListenable]).
  final ValueListenable<double>? levelListenable;

  /// False while its screen is hidden: it holds still and costs nothing.
  /// Turning true again (a new session) blooms it in afresh.
  final bool active;

  @override
  State<VoiceOrbBackdrop> createState() => _VoiceOrbBackdropState();
}

/// Everything the backdrop's painter reads on every frame — changed by
/// the ticker, repainted from directly (see [_SphereMotion]).
class _BackdropScene extends ChangeNotifier {
  /// Scene time. Integrated from the ticks rather than read off the
  /// ticker, so a pause and a restart carry on from the same picture
  /// instead of jumping back to zero.
  double sec = 0;

  /// Integrated, not derived from the clock: the pulses speed up with the
  /// voice, and a speed change must never make them jump backwards.
  double pulse = 0;

  // Everything the mood changes is eased in and out, never switched.
  double level = 0, pulseAmt = 0, think = 0;

  /// 0..1 — the bloom-in (see [_VoiceOrbBackdropState._bloomDelay]).
  double appear = 0;

  /// The GPU program's shader (see [_BackdropPainter._paintGpu]): made on
  /// the first frame drawn with it and reused — each frame's numbers are
  /// copied into that frame's picture, so one object serves them all.
  ui.FragmentShader? shader;

  void changed() => notifyListeners();

  @override
  void dispose() {
    shader?.dispose();
    super.dispose();
  }
}

class _VoiceOrbBackdropState extends State<VoiceOrbBackdrop>
    with SingleTickerProviderStateMixin {
  /// Drives the repaints — ONLY while something moves (see [_sync]).
  ///
  /// It used to be a controller repeating forever. It now runs while the
  /// orb listens, thinks or speaks, and while the scene is still easing
  /// (the bloom-in, or the pulses fading out as it comes to rest); then
  /// it stops, and a resting session draws no frames at all. Each frame
  /// is paint-only: the ticker changes [_scene], the painter repaints from
  /// it, and no widget is rebuilt (see [_VoiceOrbState._ticker]).
  late final Ticker _ticker = createTicker(_onTick);
  Duration _lastTick = Duration.zero;
  final _BackdropScene _scene = _BackdropScene();

  /// THE LIGHTER FIRST FRAME (2026-09-24: opening the voice screen cost
  /// one 67 ms frame). This is the most expensive thing on that screen —
  /// an offscreen layer, forty-odd motes and two liquid rings — and it
  /// used to be built and drawn in full on the very frame the screen
  /// appeared. It now draws nothing for its first [_bloomDelay] seconds
  /// and then fades in over [_bloomFade] — one more number the GPU
  /// program multiplies by (or, drawing with the Canvas, the alpha of the
  /// layer it already paints into), so the fade itself costs nothing
  /// extra: the ground, the orb and the words arrive first, the aurora
  /// blooms in after them.
  static const _bloomDelay = 0.12, _bloomFade = 0.35;
  double _shownFor = 0;
  double get _appear =>
      ((_shownFor - _bloomDelay) / _bloomFade).clamp(0.0, 1.0);

  bool get _moving => widget.active && widget.mood != OrbMood.idle;

  /// At rest and fully faded in: nothing left to move.
  bool get _settled =>
      _appear >= 1 &&
      _scene.pulseAmt < 0.01 &&
      _scene.think < 0.01 &&
      _scene.level < 0.01;

  @override
  void initState() {
    super.initState();
    // Load the GPU program now, while this sits built and hidden behind
    // Home, so the first session never draws with the fallback or waits.
    GpuProgram.voiceBackdrop.load();
    _sync();
  }

  @override
  void didUpdateWidget(VoiceOrbBackdrop old) {
    super.didUpdateWidget(old);
    // A new session: bloom in again. The screen was fully faded out while
    // inactive, so starting from nothing is never seen as a blink.
    if (widget.active && !old.active) {
      _shownFor = 0;
      _scene.appear = 0;
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

  void _onTick(Duration elapsed) {
    final dt = ((elapsed - _lastTick).inMicroseconds / 1e6).clamp(0.0, 0.1);
    _lastTick = elapsed;
    double ease(double v, double to, double rate) =>
        v + (to - v) * (1 - math.exp(-dt * rate));

    final sc = _scene;
    final moving = _moving;
    // At rest the scene settles: no pulses, no voice in the ring — the
    // way the orb itself rests while he types.
    final heard = widget.levelListenable?.value ?? widget.level;
    final target = moving ? heard.clamp(0.0, 1.0) : 0.0;
    sc.level = ease(sc.level, target, target > sc.level ? 18 : 4);
    sc.pulseAmt = ease(
        sc.pulseAmt,
        moving && widget.mood != OrbMood.thinking ? 1.0 : 0.0,
        3);
    sc.think = ease(sc.think, widget.mood == OrbMood.thinking ? 1 : 0, 4);
    sc.sec += dt;
    _shownFor += dt;
    sc.appear = _appear;
    // Pulses per second: a slow heartbeat when quiet, quicker as the
    // voice gets louder.
    sc.pulse += dt * (0.30 + sc.level * 0.55);

    if (!moving && _settled) {
      // Come to rest exactly, then stop asking for frames.
      sc
        ..level = 0
        ..pulseAmt = 0
        ..think = 0;
      _ticker.stop();
    }
    sc.changed();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _scene.dispose();
    super.dispose();
  }

  // Its own layer, so the scene's frames never re-record the screen
  // around it.
  @override
  Widget build(BuildContext context) => RepaintBoundary(
        child: CustomPaint(
          painter: _BackdropPainter(
            scene: _scene,
            orbRadius: widget.orbSize / 2,
            violet: Neon.violet,
            pink: Neon.pink,
            dpr: MediaQuery.maybeDevicePixelRatioOf(context) ?? 3.0,
          ),
          child: const SizedBox.expand(),
        ),
      );
}

/// One mote of dust: where it starts, how fast it drifts, how it twinkles.
class _Mote {
  const _Mote(this.angle, this.offset, this.speed, this.size, this.twinkle);
  final double angle, offset, speed, size, twinkle;
}

final List<_Mote> _motes = () {
  final rnd = math.Random(7); // fixed: the same sky every time
  return List.generate(
      42,
      (_) => _Mote(
            rnd.nextDouble() * 2 * math.pi,
            rnd.nextDouble(),
            0.035 + rnd.nextDouble() * 0.05,
            0.7 + rnd.nextDouble() * 1.3,
            1.5 + rnd.nextDouble() * 2.5,
          ));
}();

class _BackdropPainter extends CustomPainter {
  _BackdropPainter({
    required this.scene,
    required this.orbRadius,
    required this.violet,
    required this.pink,
    required this.dpr,
  }) : super(repaint: scene);

  final _BackdropScene scene;
  final double orbRadius;

  /// The accent pair (see [_SpherePainter.violet]).
  final Color violet, pink;

  /// The screen's density: the GPU program anti-aliases over one device
  /// pixel.
  final double dpr;

  /// Where the reference's rings sit, as multiples of the sphere's radius
  /// — fewer than before; they are depth now, not the subject.
  /// (shaders/voice_backdrop.frag has the same five.)
  static const _rings = [1.39, 1.91, 2.42, 2.9, 3.4];

  static const _tau = 2 * math.pi;

  /// The tunnel's left-to-right colours: accent, ink, partner. Worked out
  /// once per painter, not per frame.
  late final List<Color> _sweepColors = [
    HSLColor.fromColor(violet).withLightness(0.46).toColor(),
    HSLColor.fromColor(violet).withSaturation(0.35).withLightness(0.18).toColor(),
    HSLColor.fromColor(pink).withLightness(0.44).toColor(),
  ];

  // The motes' colour runs from these two across the width (the accent
  // and its partner, each 55% of the way to white).
  late final Color _moteLeft = Color.lerp(violet, Colors.white, 0.55)!;
  late final Color _moteRight = Color.lerp(pink, Colors.white, 0.55)!;
  final Paint _mote = Paint();
  final Paint _gpu = Paint();

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

  /// THE GPU PATH (2026-09-24, GPU pass): the whole scene but the dust in
  /// ONE rectangle, drawn by shaders/voice_backdrop.frag — no offscreen
  /// layer, no paths, no second pass for the fade. Everything that moves
  /// is worked out here once per frame (the positions of the clouds, the
  /// angles of the ripples) and handed over as numbers, each angle wrapped
  /// to one turn so the GPU never sees a clock that grows all session.
  void _paintGpu(Canvas canvas, Size size, ui.FragmentProgram program) {
    final sc = scene;
    final sec = sc.sec, level = sc.level, think = sc.think;
    final r = orbRadius;
    final c = size.center(Offset.zero);
    final shader = sc.shader ??= program.fragmentShader();
    var i = 0;
    void f(double v) => shader.setFloat(i++, v);
    void rgb(Color col) {
      f(col.r);
      f(col.g);
      f(col.b);
      f(1);
    }

    // uGeom, uState
    f(size.width);
    f(size.height);
    f(r);
    f(1 / dpr);
    f(sc.appear);
    f(level);
    f(sc.pulseAmt);
    f(think);
    // uClouds: the two drifting clouds' centres (the third sits on the orb).
    f(c.dx - r * 0.95 + math.cos(sec * 0.21) * r * 0.3);
    f(c.dy + math.sin(sec * 0.17) * r * 0.18);
    f(c.dx + r * 0.95 + math.cos(sec * 0.19 + 2.1) * r * 0.3);
    f(c.dy + math.sin(sec * 0.23 + 1.3) * r * 0.18);
    // uCloudA: their strengths, and the tunnel's breath.
    f(0.34 + level * 0.16);
    f(0.27 + level * 0.14);
    f(0.16 + level * 0.20);
    f(1 + 0.025 * math.sin(sec * 0.7) + level * 0.04);
    // uPhase: the round-the-orb colour's turn, the pulse clock, the comets.
    f((sec * 0.35) % _tau);
    f(sc.pulse % 1.0);
    f((sec * _tau * 0.55) % _tau);
    f(0);
    // uLiquid0/1: each strand's three ripple phases, and its amplitude.
    final amp = r * (0.018 + level * 0.12) * (1 - think * 0.7);
    for (var j = 0; j < 2; j++) {
      final phase = sec * 2.1 + j * 1.9;
      f((phase * 1.3) % _tau);
      f((phase * 1.7) % _tau);
      f((phase * 2.3) % _tau);
      f(amp * (1 - j * 0.4));
    }
    rgb(violet);
    rgb(pink);
    for (final col in _sweepColors) {
      rgb(col);
    }
    canvas.drawRect(Offset.zero & size, _gpu..shader = shader);
    // The dust stays on the Canvas, faded the same way the program fades
    // everything else.
    _paintMotes(canvas, size, fadeHere: true);
  }

  /// 2. DUST drifting outward. Drawn last on the GPU path (a mote passing
  /// over a hairline ring instead of under it is not something an eye can
  /// catch), in the offscreen layer on the Canvas path.
  void _paintMotes(Canvas canvas, Size size, {required bool fadeHere}) {
    final sec = scene.sec;
    final c = size.center(Offset.zero);
    final r = orbRadius;
    final maxD = size.width * 0.56;
    final appear = scene.appear;
    for (final m in _motes) {
      final life = (m.offset + sec * m.speed) % 1.0;
      final dist = r * 1.3 + life * (maxD - r * 1.3);
      final a = m.angle + sec * 0.025;
      final pos = c + Offset(math.cos(a) * dist, math.sin(a) * dist * 0.7);
      final fade = math.sin(life * math.pi);
      final tw = 0.55 + 0.45 * math.sin(sec * m.twinkle + m.offset * 6.3);
      var alpha = 0.5 * fade * tw;
      // Outside the layer, the top/bottom melt and the bloom-in are this
      // mote's own to apply.
      if (fadeHere) alpha *= _edgeFade(pos.dy / size.height) * appear;
      if (alpha <= 0) continue;
      _mote.color = Color.lerp(
              _moteLeft, _moteRight, (pos.dx / size.width).clamp(0.0, 1.0))!
          .withValues(alpha: alpha);
      canvas.drawCircle(pos, m.size, _mote);
    }
  }

  /// The top and bottom melt: 0 at the edges, 1 from 22% in.
  static double _edgeFade(double v) {
    if (v <= 0 || v >= 1) return 0;
    if (v < 0.22) return v / 0.22;
    if (v > 0.78) return (1 - v) / 0.22;
    return 1;
  }

  // Worked out once per box, not once per frame (the Canvas path only).
  Shader? _sweep;
  Size? _sweepSize;

  /// THE CANVAS PATH — the picture as it was drawn before the GPU program,
  /// kept for the frames before the program has loaded and for any phone
  /// that cannot load it.
  void _paintCanvas(Canvas canvas, Size size) {
    final sec = scene.sec, pulse = scene.pulse, level = scene.level;
    final pulseAmt = scene.pulseAmt, think = scene.think;
    // The bloom-in, applied through the one offscreen layer this already
    // paints into, so fading costs nothing.
    final appear = scene.appear;
    final c = size.center(Offset.zero);
    final r = orbRadius;
    final bounds = Offset.zero & size;

    // Left-to-right sweep for the tunnel: accent, ink, partner.
    if (_sweep == null || _sweepSize != size) {
      _sweepSize = size;
      _sweep = LinearGradient(colors: _sweepColors).createShader(bounds);
    }
    final sweep = _sweep!;
    // Round-the-orb sweep for the rings that hug it, turning slowly.
    final around = SweepGradient(
      colors: [violet, pink, Color.lerp(violet, pink, 0.4)!, violet],
      stops: const [0.0, 0.4, 0.75, 1.0],
      transform: GradientRotation(sec * 0.35),
    ).createShader(Rect.fromCircle(center: c, radius: r * 3));

    // Everything but the vignette fades out toward the top and bottom, so
    // it melts into the overlay instead of ending at the box's edge. ONE
    // offscreen layer per frame — per-element layers are how a pretty orb
    // becomes a stuttering one on a mid-range phone.
    canvas.saveLayer(
        bounds, Paint()..color = Colors.black.withValues(alpha: appear));

    // 1. AURORA — squashed into ovals so it stays inside the box.
    void cloud(Offset at, double radius, Color col, double a) {
      canvas.save();
      canvas.translate(at.dx, at.dy);
      canvas.scale(1, 0.62);
      canvas.drawCircle(
        Offset.zero,
        radius,
        Paint()
          ..shader = RadialGradient(
            colors: [
              col.withValues(alpha: a),
              col.withValues(alpha: a * 0.35),
              col.withValues(alpha: 0),
            ],
            stops: const [0.0, 0.45, 1.0],
          ).createShader(Rect.fromCircle(center: Offset.zero, radius: radius)),
      );
      canvas.restore();
    }

    cloud(
        c +
            Offset(-r * 0.95 + math.cos(sec * 0.21) * r * 0.3,
                math.sin(sec * 0.17) * r * 0.18),
        r * 2.7,
        violet,
        0.34 + level * 0.16);
    cloud(
        c +
            Offset(r * 0.95 + math.cos(sec * 0.19 + 2.1) * r * 0.3,
                math.sin(sec * 0.23 + 1.3) * r * 0.18),
        r * 2.5,
        pink,
        0.27 + level * 0.14);
    cloud(c, r * 1.8, Color.lerp(violet, pink, 0.45)!, 0.16 + level * 0.20);

    // 2. DUST drifting outward.
    _paintMotes(canvas, size, fadeHere: false);

    // 3. The TUNNEL, breathing very slightly.
    final breathe = 1 + 0.025 * math.sin(sec * 0.7) + level * 0.04;
    for (var i = 0; i < _rings.length; i++) {
      final rx = r * _rings[i] * breathe;
      final ry = r * (1.3 + i * 0.16) * breathe;
      canvas.drawOval(
        Rect.fromCenter(center: c, width: rx * 2, height: ry * 2),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..shader = sweep
          ..color = Colors.white.withValues(alpha: 0.30 * (1 - i / 5)),
      );
    }

    // 4. PULSES rolling out from the orb.
    if (pulseAmt > 0.01) {
      for (var i = 0; i < 3; i++) {
        final ph = (pulse + i / 3) % 1.0;
        final fade = (1 - ph) * (1 - ph);
        canvas.drawCircle(
          c,
          r * (1.08 + ph * 0.95),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 0.6 + 2.2 * (1 - ph)
            ..shader = around
            ..color = Colors.white
                .withValues(alpha: fade * pulseAmt * (0.35 + level * 0.55)),
        );
      }
    }

    // 5. The LIQUID RING — hugs the orb and ripples with the voice. Two
    // strands out of step read as liquid; one reads as a wobbly circle.
    final calm = 1 - think * 0.7;
    final amp = r * (0.018 + level * 0.12) * calm;
    for (var j = 0; j < 2; j++) {
      final path = _liquid(
          c, r * (1.12 + j * 0.035), amp * (1 - j * 0.4), sec * 2.1 + j * 1.9);
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 8
          ..shader = around
          ..color = Colors.white.withValues(alpha: 0.10 + level * 0.10),
      );
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = j == 0 ? 2.0 : 1.2
          ..shader = around
          ..color = Colors.white.withValues(alpha: j == 0 ? 0.9 : 0.5),
      );
    }

    // 6. THINKING — two comets chasing round the orb.
    if (think > 0.01) {
      final rect = Rect.fromCircle(center: c, radius: r * 1.26);
      for (var k = 0; k < 2; k++) {
        final start = sec * 2 * math.pi * 0.55 + k * math.pi;
        final shader = SweepGradient(
          colors: [
            violet.withValues(alpha: 0),
            violet,
            Color.lerp(pink, Colors.white, 0.3)!,
          ],
          stops: const [0.0, 0.3, 0.42],
          transform: GradientRotation(start),
        ).createShader(rect);
        canvas.drawArc(
          rect,
          start,
          math.pi * 0.84,
          false,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.6
            ..strokeCap = StrokeCap.round
            ..shader = shader
            ..color = Colors.white.withValues(alpha: think * (1 - k * 0.45)),
        );
      }
    }

    canvas.drawRect(
      bounds,
      Paint()
        ..blendMode = BlendMode.dstIn
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.transparent,
            Colors.white,
            Colors.white,
            Colors.transparent,
          ],
          stops: [0.0, 0.22, 0.78, 1.0],
        ).createShader(bounds),
    );
    // No vignette. It was a black rectangle's worth of shading, and over
    // the session's tinted ground its edges drew a box round the orb; the
    // fade above already lets everything melt away top and bottom.
    canvas.restore();
  }

  /// A closed ring whose radius wanders with three harmonics moving at
  /// different speeds, so the ripple never visibly repeats.
  Path _liquid(Offset c, double base, double amp, double phase) {
    final p = Path();
    const n = 120;
    for (var k = 0; k <= n; k++) {
      final th = k / n * 2 * math.pi;
      final d = base +
          amp *
              (0.55 * math.sin(3 * th + phase * 1.3) +
                  0.30 * math.sin(5 * th - phase * 1.7) +
                  0.15 * math.sin(8 * th + phase * 2.3));
      final pt = c + Offset(math.cos(th) * d, math.sin(th) * d);
      if (k == 0) {
        p.moveTo(pt.dx, pt.dy);
      } else {
        p.lineTo(pt.dx, pt.dy);
      }
    }
    return p..close();
  }

  @override
  bool shouldRepaint(_BackdropPainter old) =>
      // Frames repaint through [scene]. A rebuild repaints only when what
      // it draws with changed — it used to be always, which is right for
      // a scene that never stops; this one holds still at rest.
      old.scene != scene ||
      old.orbRadius != orbRadius ||
      old.violet != violet ||
      old.pink != pink ||
      old.dpr != dpr;
}
