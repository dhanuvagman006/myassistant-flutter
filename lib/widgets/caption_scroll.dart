import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../design/motion.dart';

/// THE WHOLE REPLY, STILL STREAMING (2026-09-26).
///
/// The owner: "if we have long output it's getting hidden… we need
/// streaming like response, but the full response should be visible." The
/// captions sat in a bottom-anchored view that nobody could scroll. Once a
/// reply outgrew its space its beginning left over the top, and it was
/// simply gone. Now:
///   - as the words stream in, the view follows the newest line, gliding
///     down to each one as it appears (this used to be CaptionGlide);
///   - a drag reads back through the whole reply, and while the owner is up
///     there nothing moves under them;
///   - a "Latest" pill takes them back to the end, and following resumes;
///     scrolling down to the end does the same;
///   - an edge fades only where there is more to see beyond it. The mask is
///     a full-size layer, so it is laid on only then (the GPU pass,
///     2026-09-24); short words are painted straight onto the screen.
class CaptionScroll extends StatefulWidget {
  const CaptionScroll({
    super.key,
    required this.child,
    this.onOverflow,
    this.fade = 48,
    this.glide = const Duration(milliseconds: 220),
  });

  final Widget child;

  /// Called once, the first time the words outgrow their space.
  final VoidCallback? onOverflow;

  /// How deep each edge's fade runs.
  final double fade;

  /// How long following takes to reach a new line.
  final Duration glide;

  @override
  State<CaptionScroll> createState() => _CaptionScrollState();
}

class _CaptionScrollState extends State<CaptionScroll> {
  final _c = ScrollController();

  /// Keeping the newest line in view. Off while the owner reads back.
  bool _following = true;

  /// More words below the view than the owner has read (the pill shows).
  bool _unread = false;

  bool _above = false;
  bool _below = false;
  bool _told = false;
  double _lastMax = 0;

  /// Within this of the end counts as at the end.
  static const _atEndSlack = 24.0;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  bool _atEnd(ScrollMetrics m) => m.pixels >= m.maxScrollExtent - _atEndSlack;

  void _edges(ScrollMetrics m) {
    final above = m.pixels > m.minScrollExtent + 0.5;
    final below = m.pixels < m.maxScrollExtent - 0.5;
    if (above != _above || below != _below) {
      setState(() {
        _above = above;
        _below = below;
      });
    }
  }

  bool _onMetrics(ScrollMetricsNotification n) {
    if (n.depth != 0) return false;
    final m = n.metrics;
    if (!_told && m.maxScrollExtent > m.minScrollExtent) {
      _told = true;
      widget.onOverflow?.call();
    }
    final grew = m.maxScrollExtent > _lastMax + 0.5;
    _lastMax = m.maxScrollExtent;
    if (grew) {
      if (_following) {
        _toEnd();
      } else if (!_unread) {
        setState(() => _unread = true);
      }
    }
    _edges(m);
    return false;
  }

  bool _onScroll(ScrollNotification n) {
    if (n.depth != 0) return false;
    final m = n.metrics;
    // Only the owner's own drag changes what is followed: the glide below
    // scrolls too, and must not switch following off on its way down.
    final byHand = (n is ScrollUpdateNotification && n.dragDetails != null) ||
        n is UserScrollNotification;
    if (byHand) {
      final atEnd = _atEnd(m);
      if (atEnd != _following || (atEnd && _unread)) {
        setState(() {
          _following = atEnd;
          if (atEnd) _unread = false;
        });
      }
    }
    _edges(m);
    return false;
  }

  /// Glides to the newest line. Called from the metrics notification, which
  /// Flutter sends in a microtask after the frame's layout, so the scroll
  /// can start at once rather than a frame later.
  void _toEnd() {
    if (!mounted || !_c.hasClients) return;
    final max = _c.position.maxScrollExtent;
    if (_c.offset >= max) return;
    if (Motion.reduced(context)) {
      _c.jumpTo(max);
    } else {
      _c.animateTo(max, duration: widget.glide, curve: Motion.easeMove);
    }
  }

  void _backToLatest() {
    setState(() {
      _following = true;
      _unread = false;
    });
    _toEnd();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, area) => Stack(
        children: [
          Positioned.fill(
            child: NotificationListener<ScrollMetricsNotification>(
              onNotification: _onMetrics,
              child: NotificationListener<ScrollNotification>(
                onNotification: _onScroll,
                child: _EdgeFade(
                  top: _above,
                  bottom: _below,
                  height: widget.fade,
                  child: ClipRect(
                    child: SingleChildScrollView(
                      controller: _c,
                      physics: const ClampingScrollPhysics(),
                      child: ConstrainedBox(
                        // Short words still sit right under the orb.
                        constraints: BoxConstraints(minHeight: area.maxHeight),
                        child: Align(
                          alignment: Alignment.topLeft,
                          child: widget.child,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (_unread)
            Positioned(
              right: 0,
              bottom: 4,
              child: _LatestPill(onTap: _backToLatest),
            ),
        ],
      ),
    );
  }
}

/// "Latest ↓" — new words arrived below while the owner read back.
class _LatestPill extends StatelessWidget {
  const _LatestPill({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Jump to the latest words',
      child: Material(
        color: Colors.white.withValues(alpha: 0.16),
        shape: const StadiumBorder(),
        child: InkWell(
          key: const ValueKey('caption-latest'),
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 7, 10, 7),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Latest',
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.92),
                        fontSize: 13,
                        fontWeight: FontWeight.w600)),
                const SizedBox(width: 4),
                Icon(Icons.arrow_downward_rounded,
                    size: 16, color: Colors.white.withValues(alpha: 0.92)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EdgeFade extends SingleChildRenderObjectWidget {
  const _EdgeFade({
    required this.top,
    required this.bottom,
    required this.height,
    super.child,
  });

  final bool top;
  final bool bottom;
  final double height;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderEdgeFade(top, bottom, height);

  @override
  void updateRenderObject(BuildContext context, _RenderEdgeFade r) {
    r
      ..top = top
      ..bottom = bottom
      ..height = height;
  }
}

/// A shader mask that stands aside when neither edge has anything beyond
/// it: then it paints its child directly and pushes no layer at all.
class _RenderEdgeFade extends RenderProxyBox {
  _RenderEdgeFade(this._top, this._bottom, this._height);

  bool _top;
  set top(bool v) {
    if (v == _top) return;
    final was = _on;
    _top = v;
    _shader = null;
    if (was != _on) markNeedsCompositingBitsUpdate();
    markNeedsPaint();
  }

  bool _bottom;
  set bottom(bool v) {
    if (v == _bottom) return;
    final was = _on;
    _bottom = v;
    _shader = null;
    if (was != _on) markNeedsCompositingBitsUpdate();
    markNeedsPaint();
  }

  double _height;
  set height(double v) {
    if (v == _height) return;
    _height = v;
    _shader = null;
    markNeedsPaint();
  }

  bool get _on => _top || _bottom;

  Shader? _shader;
  Size? _shaderSize;

  @override
  bool get alwaysNeedsCompositing => child != null && _on;

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) {
      layer = null;
      return;
    }
    if (!_on || size.height <= 0) {
      layer = null;
      context.paintChild(child, offset);
      return;
    }
    if (_shader == null || _shaderSize != size) {
      _shaderSize = size;
      final f = (_height / size.height).clamp(0.0, 0.45);
      _shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          _top ? Colors.transparent : Colors.black,
          Colors.black,
          Colors.black,
          _bottom ? Colors.transparent : Colors.black,
        ],
        stops: [0.0, f, 1.0 - f, 1.0],
      ).createShader(Offset.zero & size);
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
