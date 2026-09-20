import 'dart:async';

import 'package:flutter/widgets.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  MOTION — the app's two micro-animations (Sept 2026).
///
///  Restrained on purpose: content settles in once, buttons acknowledge a
///  finger. Nothing loops on screens (battery), nothing bounces. The
///  assistant orb keeps its own presence animations in inline_voice.
/// ─────────────────────────────────────────────────────────────────────────

/// One-shot entrance: fade in while drifting up 14 px. Plays when the
/// widget first mounts (optionally after [delayMs], for a stagger) and
/// never replays on rebuilds — a refresh must not make the page twitch.
class Reveal extends StatefulWidget {
  final Widget child;
  final int delayMs;
  const Reveal({super.key, required this.child, this.delayMs = 0});

  @override
  State<Reveal> createState() => _RevealState();
}

class _RevealState extends State<Reveal> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 380));
  late final Animation<double> _a =
      CurvedAnimation(parent: _c, curve: Curves.easeOutCubic);
  Timer? _t;

  @override
  void initState() {
    super.initState();
    if (widget.delayMs <= 0) {
      _c.forward();
    } else {
      _t = Timer(Duration(milliseconds: widget.delayMs), () {
        if (mounted) _c.forward();
      });
    }
  }

  @override
  void dispose() {
    _t?.cancel();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _a,
      builder: (_, child) => Opacity(
        opacity: _a.value,
        // Drift up with a whisper of scale — the page feels light, like
        // it settles rather than loads.
        child: Transform.translate(
          offset: Offset(0, 14 * (1 - _a.value)),
          child: Transform.scale(
              scale: 0.985 + 0.015 * _a.value, child: child),
        ),
      ),
      child: widget.child,
    );
  }
}

/// Press feedback: the child dips to 96% while a finger is down. Uses a
/// [Listener] so the child's own GestureDetector/InkWell still receives
/// the tap — this only watches the pointer, it never claims it.
class PressScale extends StatefulWidget {
  final Widget child;
  const PressScale({super.key, required this.child});

  @override
  State<PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<PressScale> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => setState(() => _down = true),
      onPointerUp: (_) => setState(() => _down = false),
      onPointerCancel: (_) => setState(() => _down = false),
      child: AnimatedScale(
        scale: _down ? 0.96 : 1.0,
        duration: const Duration(milliseconds: 110),
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}
