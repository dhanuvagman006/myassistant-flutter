
import 'package:flutter/material.dart';

import '../design/neon_tokens.dart';
import '../features/assistant/state/assistant_engine.dart';
import '../features/assistant/state/assistant_state.dart';
import '../features/assistant/widgets/siri_orb.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  INLINE VOICE — talk to the assistant from Home, no second screen.
///
///  The dock orb becomes the assistant itself: tap and the presence orb
///  wakes in place with a soft expanding halo; captions float above the
///  dock while either side is speaking and slip away when the exchange
///  ends. Hold the orb for the live face agent.
/// ─────────────────────────────────────────────────────────────────────────

/// The dock button: a calm mic circle when idle, the live presence orb
/// with a pulsing halo while a conversation is running.
class AssistantOrbButton extends StatefulWidget {
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  const AssistantOrbButton(
      {super.key, required this.onTap, required this.onLongPress});

  @override
  State<AssistantOrbButton> createState() => _AssistantOrbButtonState();
}

class _AssistantOrbButtonState extends State<AssistantOrbButton>
    with SingleTickerProviderStateMixin {
  final engine = AssistantEngine.instance;
  late final AnimationController _halo =
      AnimationController(vsync: this, duration: const Duration(seconds: 2));

  bool get _active =>
      engine.liveActive ||
      (engine.phase != AssistantPhase.idle &&
          engine.phase != AssistantPhase.completed);

  @override
  void initState() {
    super.initState();
    engine.addListener(_sync);
    _sync();
  }

  void _sync() {
    if (!mounted) return;
    if (_active && !_halo.isAnimating) _halo.repeat();
    if (!_active && _halo.isAnimating) {
      _halo.stop();
      _halo.reset();
    }
    setState(() {});
  }

  @override
  void dispose() {
    engine.removeListener(_sync);
    _halo.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final active = _active;
    return GestureDetector(
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: SizedBox(
        width: 76,
        height: 76,
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (active)
              AnimatedBuilder(
                animation: _halo,
                builder: (_, __) =>
                    CustomPaint(size: const Size(76, 76), painter: _HaloPainter(_halo.value)),
              ),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: active
                  ? ValueListenableBuilder<double>(
                      key: const ValueKey('live'),
                      valueListenable: engine.micLevelListenable,
                      builder: (_, level, __) => SiriOrb(
                        size: 64,
                        phase: engine.phase,
                        level: level,
                        connected: true,
                      ),
                    )
                  : Container(
                      key: const ValueKey('idle'),
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Neon.textHi,
                        boxShadow: [
                          BoxShadow(
                            color: Neon.textHi.withValues(alpha: 0.28),
                            blurRadius: 18,
                            offset: const Offset(0, 6),
                          ),
                        ],
                      ),
                      child:
                          Icon(Icons.mic_rounded, color: Neon.onInk, size: 30),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Two staggered rings breathing outward from the orb.
class _HaloPainter extends CustomPainter {
  final double t;
  _HaloPainter(this.t);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    for (final phase in const [0.0, 0.5]) {
      final p = (t + phase) % 1.0;
      final radius = 30 + p * 26;
      final alpha = (1 - p) * 0.35;
      canvas.drawCircle(
        c,
        radius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.2 - p * 1.4
          ..color = Neon.violet.withValues(alpha: alpha),
      );
    }
  }

  @override
  bool shouldRepaint(_HaloPainter old) => old.t != t;
}

/// Center-screen live captions, lyrics-style: while the inline
/// conversation runs the page behind dims, and what is being said appears
/// large in the middle of the screen — the assistant's words bright, the
/// user's own words softer. Everything fades away when the session ends.
class InlineCaptionOverlay extends StatefulWidget {
  const InlineCaptionOverlay({super.key});

  @override
  State<InlineCaptionOverlay> createState() => _InlineCaptionOverlayState();
}

class _InlineCaptionOverlayState extends State<InlineCaptionOverlay> {
  final engine = AssistantEngine.instance;
  String _text = '';
  bool _fromUser = false;

  bool get _active =>
      engine.inlineVoice &&
      (engine.liveActive ||
          (engine.phase != AssistantPhase.idle &&
              engine.phase != AssistantPhase.completed));

  @override
  void initState() {
    super.initState();
    engine.caption.addListener(_onCaption);
    engine.addListener(_onEngine);
  }

  @override
  void dispose() {
    engine.caption.removeListener(_onCaption);
    engine.removeListener(_onEngine);
    super.dispose();
  }

  void _onCaption() {
    if (!mounted) return;
    final c = engine.caption.value;
    if (c == null || c.text.trim().isEmpty) return;
    setState(() {
      _text = c.text.trim();
      _fromUser = c.speaker == 'you';
    });
  }

  void _onEngine() {
    if (!mounted) return;
    // Session over → the words leave with it.
    if (!_active && _text.isNotEmpty) _text = '';
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final show = _active;
    return IgnorePointer(
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOut,
        opacity: show ? 1 : 0,
        child: Container(
          // The page behind fades — the conversation takes the stage.
          color: Colors.black.withValues(alpha: 0.55),
          alignment: Alignment.center,
          padding: const EdgeInsets.fromLTRB(28, 80, 28, 160),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            switchInCurve: Curves.easeOut,
            child: Text(
              _text,
              key: ValueKey('$_fromUser|$_text'),
              textAlign: TextAlign.center,
              maxLines: 8,
              overflow: TextOverflow.fade,
              style: TextStyle(
                color: _fromUser
                    ? Colors.white.withValues(alpha: 0.65)
                    : Colors.white,
                fontSize: _fromUser ? 20 : 26,
                height: 1.4,
                fontWeight: _fromUser ? FontWeight.w500 : FontWeight.w600,
                letterSpacing: -0.3,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
