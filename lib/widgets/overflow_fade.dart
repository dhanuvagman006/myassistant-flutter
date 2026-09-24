import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// A SOFT TOP EDGE, ONLY WHEN THERE IS SOMETHING TO SOFTEN (2026-09-24,
/// GPU pass).
///
/// The voice screen's captions fade out at the top when a reply is taller
/// than its space, so the oldest words melt away instead of being sliced.
/// That fade was a ShaderMask round the whole caption area — an offscreen
/// layer about 930 x 790 pixels, a mask pass and a composite — and the
/// phone's renderer draws every layer on screen again on every frame, so
/// it was paid on every frame of the orb for the whole session, even with
/// one short line that nothing had to fade.
///
/// Now the mask is laid on only while the scroll view inside really
/// overflows (it says so with a [ScrollMetricsNotification]); otherwise
/// the words are painted straight onto the screen. What shows is the same
/// either way — a fade over text that fits covers nothing. The tree never
/// changes shape when the mask comes and goes, so the captions inside keep
/// their state and their running animations.
class TopFadeWhenOverflowing extends StatefulWidget {
  const TopFadeWhenOverflowing({
    super.key,
    this.height = 14,
    required this.child,
  });

  /// How far down from the top the fade runs, from clear to solid.
  final double height;

  /// Holds the scroll view whose overflow switches the fade on.
  final Widget child;

  @override
  State<TopFadeWhenOverflowing> createState() => _TopFadeWhenOverflowingState();
}

class _TopFadeWhenOverflowingState extends State<TopFadeWhenOverflowing> {
  bool _overflowing = false;

  bool _onMetrics(ScrollMetricsNotification n) {
    if (n.depth == 0) {
      final over = n.metrics.maxScrollExtent > n.metrics.minScrollExtent;
      if (over != _overflowing) setState(() => _overflowing = over);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) =>
      NotificationListener<ScrollMetricsNotification>(
        onNotification: _onMetrics,
        child: _TopFade(
          enabled: _overflowing,
          height: widget.height,
          child: widget.child,
        ),
      );
}

class _TopFade extends SingleChildRenderObjectWidget {
  const _TopFade({required this.enabled, required this.height, super.child});

  final bool enabled;
  final double height;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderTopFade(enabled, height);

  @override
  void updateRenderObject(BuildContext context, _RenderTopFade renderObject) {
    renderObject
      ..enabled = enabled
      ..height = height;
  }
}

/// A [RenderShaderMask] that can stand aside: with [enabled] off it paints
/// its child directly and pushes no layer at all.
class _RenderTopFade extends RenderProxyBox {
  _RenderTopFade(this._enabled, this._height);

  bool _enabled;
  set enabled(bool value) {
    if (value == _enabled) return;
    _enabled = value;
    markNeedsCompositingBitsUpdate();
    markNeedsPaint();
  }

  double _height;
  set height(double value) {
    if (value == _height) return;
    _height = value;
    _shader = null;
    markNeedsPaint();
  }

  // The fade, made once per width, not once per frame.
  Shader? _shader;
  double? _shaderWidth;

  @override
  bool get alwaysNeedsCompositing => child != null && _enabled;

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) {
      layer = null;
      return;
    }
    if (!_enabled) {
      layer = null;
      context.paintChild(child, offset);
      return;
    }
    if (_shader == null || _shaderWidth != size.width) {
      _shaderWidth = size.width;
      _shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Colors.transparent, Colors.black],
        stops: [0.0, 1.0],
      ).createShader(Rect.fromLTWH(0, 0, size.width, _height));
    }
    final mask = (layer as ShaderMaskLayer?) ?? ShaderMaskLayer();
    mask
      ..shader = _shader
      ..maskRect = offset & size
      ..blendMode = BlendMode.dstIn;
    context.pushLayer(mask, super.paint, offset);
    layer = mask;
  }
}
