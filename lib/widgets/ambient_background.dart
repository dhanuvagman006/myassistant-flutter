import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../design/gpu_programs.dart';
import '../design/neon_tokens.dart';

/// THE ROOM THE APP SITS IN.
///
/// A flat page reads as "nothing rendered yet" — screens float on a void
/// with no depth. This paints the ground the whole app stands on: the
/// theme's own colour, bled through the page.
///
/// Three layers, in order:
///   1. a vertical wash, so the page is never one flat value top to
///      bottom — this is what stops it reading as black;
///   2. two large pools of light, top-left and bottom-right, giving the
///      page a direction;
///   3. a wide, very faint pool through the middle, because the first
///      two leave the centre of a tall phone screen dead.
///
/// Deliberately restrained: no visible edges, no second hue competing
/// with content. You should feel the colour without being able to point
/// at where it begins.
///
/// It never moves, and it is drawn as ONE picture on its own layer
/// (2026-09-24, smoothness pass): anything changing on the page above it
/// used to re-record these gradients too.
///
/// ONE OPAQUE FILL (2026-09-24, GPU pass). Recording it once was not the
/// whole cost: the phone's renderer draws every picture on screen again on
/// each frame that anything moves — a scroll, a spinner, a page sliding
/// in — so the wash and the three pools, about two screens of blended
/// gradient, were paid on every one of those frames on every tab. When
/// the GPU program (shaders/ambient.frag) has loaded, the same light is
/// drawn as a single opaque rectangle that works out all four layers per
/// pixel, with a half-step of dither so the dark theme's near-flat
/// gradient does not band. Until then, or if it cannot load, the layers
/// below are drawn exactly as before.
class AmbientBackground extends StatelessWidget {
  final Widget child;

  /// True while something opaque covers the whole page — the voice
  /// session. The light is not drawn then: nobody can see it, and it cost
  /// four full-screen gradients on every frame of the orb.
  final bool covered;

  const AmbientBackground(
      {super.key, required this.child, this.covered = false});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: Visibility.maintain(
            visible: !covered,
            child: const IgnorePointer(
              child: RepaintBoundary(child: _Light()),
            ),
          ),
        ),
        child,
      ],
    );
  }
}

/// The three layers themselves (see [AmbientBackground]).
class _Light extends StatelessWidget {
  const _Light();

  @override
  Widget build(BuildContext context) {
    // Rebuilt once, when the GPU program arrives.
    return ListenableBuilder(
      listenable: GpuProgram.ambient,
      builder: (context, _) {
        final program = GpuProgram.ambient.program;
        return program == null ? _layers(context) : _gpu(context, program);
      },
    );
  }

  /// The wash and the pools' numbers, shared by both ways of drawing them.
  static ({Color top, Color middle, double tintA, double partnerA, double middleA})
      _numbers() {
    final dark = Neon.isDark;
    final tint = Neon.violet;
    return (
      top: Color.alphaBlend(tint.withValues(alpha: dark ? 0.13 : 0.07), Neon.bg),
      middle: Color.alphaBlend(tint.withValues(alpha: dark ? 0.05 : 0.03), Neon.bg),
      tintA: dark ? 0.26 : 0.13,
      partnerA: dark ? 0.20 : 0.10,
      middleA: dark ? 0.10 : 0.05,
    );
  }

  Widget _gpu(BuildContext context, ui.FragmentProgram program) {
    final n = _numbers();
    return CustomPaint(
      painter: _AmbientPainter(
        program: program,
        screen: MediaQuery.sizeOf(context),
        dpr: MediaQuery.devicePixelRatioOf(context),
        top: n.top,
        middle: n.middle,
        ground: Neon.bg,
        tint: Neon.violet,
        partner: Neon.pink,
        tintA: n.tintA,
        partnerA: n.partnerA,
        middleA: n.middleA,
      ),
      child: const SizedBox.expand(),
    );
  }

  /// The Canvas way: the wash and three pools as separate gradients.
  Widget _layers(BuildContext context) {
    final n = _numbers();
    final tint = Neon.violet;
    final partner = Neon.pink;
    final size = MediaQuery.sizeOf(context);
    final w = size.width;
    final h = size.height;

    return Stack(
      children: [
        // 1 — the wash. Lifted at the top where the greeting sits,
        // settling to the page ground by the dock.
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [n.top, n.middle, Neon.bg],
                stops: const [0.0, 0.42, 1.0],
              ),
            ),
          ),
        ),
        // 2 — the two pools, sized to the screen so a tall phone and a
        // small one get the same picture rather than the same pixels.
        Positioned(
          left: -w * 0.35,
          top: -h * 0.12,
          child: _pool(tint, n.tintA, w * 1.25),
        ),
        Positioned(
          right: -w * 0.42,
          bottom: -h * 0.10,
          child: _pool(partner, n.partnerA, w * 1.30),
        ),
        // 3 — the middle, which the corner pools never reach.
        Positioned(
          left: w * 0.10,
          top: h * 0.34,
          child: _pool(partner, n.middleA, w * 1.05),
        ),
      ],
    );
  }

  /// One soft circle of light. A RadialGradient fading to fully
  /// transparent costs nothing to paint — a real blur filter over the
  /// whole page would cost a frame on a mid-range phone, every frame.
  static Widget _pool(Color c, double alpha, double size) => IgnorePointer(
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: [
                c.withValues(alpha: alpha),
                c.withValues(alpha: alpha * 0.55),
                c.withValues(alpha: alpha * 0.18),
                c.withValues(alpha: 0),
              ],
              stops: const [0.0, 0.34, 0.62, 1.0],
            ),
          ),
        ),
      );
}

/// The same light as [_Light._layers], by shaders/ambient.frag: one
/// opaque rectangle, one pass.
class _AmbientPainter extends CustomPainter {
  _AmbientPainter({
    required this.program,
    required this.screen,
    required this.dpr,
    required this.top,
    required this.middle,
    required this.ground,
    required this.tint,
    required this.partner,
    required this.tintA,
    required this.partnerA,
    required this.middleA,
  });

  final ui.FragmentProgram program;

  /// The pools are sized and placed by the SCREEN, as the layers are.
  final Size screen;
  final double dpr;
  final Color top, middle, ground, tint, partner;
  final double tintA, partnerA, middleA;

  @override
  void paint(Canvas canvas, Size size) {
    // A shader per painter: this repaints only when the theme or the
    // screen changes, never on a frame of its own.
    final shader = program.fragmentShader();
    var i = 0;
    void f(double v) => shader.setFloat(i++, v);
    void rgb(Color c, double a) {
      f(c.r);
      f(c.g);
      f(c.b);
      f(a);
    }

    f(size.width);
    f(size.height);
    f(screen.width);
    f(screen.height);
    f(1 / dpr);
    f(0);
    f(0);
    f(0);
    rgb(top, 1);
    rgb(middle, 1);
    rgb(ground, 1);
    rgb(tint, tintA);
    rgb(partner, partnerA);
    f(middleA);
    f(0);
    f(0);
    f(0);
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
    shader.dispose();
  }

  @override
  bool shouldRepaint(_AmbientPainter old) =>
      old.program != program ||
      old.screen != screen ||
      old.dpr != dpr ||
      old.top != top ||
      old.middle != middle ||
      old.ground != ground ||
      old.tint != tint ||
      old.partner != partner ||
      old.tintA != tintA ||
      old.partnerA != partnerA ||
      old.middleA != middleA;
}
