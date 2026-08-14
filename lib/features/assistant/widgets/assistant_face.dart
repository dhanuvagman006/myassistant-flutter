import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../design/neon_tokens.dart';
import '../state/assistant_state.dart';
import 'assistant_persona.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  ASSISTANT FACE — the assistant's visual presence inside the existing
///  hero ring. Replaces the microphone icon; the ring, sizing, gyro tilt
///  and every surrounding control are untouched.
///
///  THREE LAYERS, best available wins:
///
///   1. LIVE AVATAR   — a video frame pushed by the existing Tavus session
///      (see AvatarScreen / backend src/avatar/tavus.js). When the unified
///      session has a live avatar, [liveFrame] renders here. This is the
///      production path and reuses the existing provider; no second video
///      agent is created.
///
///   2. PORTRAIT      — assets/avatar/assistant_female.jpg / _male.jpg.
///      Drop-in photoreal portraits, chosen by [persona]. Absent by
///      default: this repository ships no face imagery, because a
///      photorealistic human face must be a licensed asset, not something
///      invented in code. Add the files and this layer activates with no
///      code change.
///
///   3. PRESENCE      — an animated, non-photographic presence: a soft
///      lit form that breathes, blinks and reacts to the assistant's
///      state. Deliberately NOT a cartoon face — an abstract presence is
///      honest about being a placeholder, where a crude drawn face would
///      look broken. Never falls back to the old microphone icon (§12).
///
///  The widget is presentation only. It holds no business logic, reads no
///  services and makes no network calls — it renders whatever the one
///  agent session tells it (§3, §20 "avatar contains no business logic").
/// ─────────────────────────────────────────────────────────────────────────
class AssistantFace extends StatefulWidget {
  /// Diameter of the inner face area.
  final double size;

  /// Current agent state — drives expression, not behaviour.
  final AssistantPhase phase;

  /// 0..1 speaking energy, for lip/／glow movement while talking.
  final double speakingLevel;

  /// Which persona (gender/appearance) to present.
  final AssistantPersona persona;

  /// A live avatar video frame, when the session has one. When null the
  /// widget falls through to portrait, then presence.
  final Widget? liveFrame;

  /// True while the avatar provider is still connecting, so we can show a
  /// polished loading treatment instead of snapping between layers.
  final bool connecting;

  const AssistantFace({
    super.key,
    required this.size,
    required this.phase,
    required this.persona,
    this.speakingLevel = 0,
    this.liveFrame,
    this.connecting = false,
  });

  @override
  State<AssistantFace> createState() => _AssistantFaceState();
}

class _AssistantFaceState extends State<AssistantFace>
    with TickerProviderStateMixin {
  late final AnimationController _breath;
  late final AnimationController _blink;
  Timer? _blinkTimer;
  final _rand = math.Random();

  /// Whether the portrait asset exists. Resolved once; a missing asset is
  /// expected, not an error.
  Future<bool>? _portraitProbe;

  @override
  void initState() {
    super.initState();
    // Idle life: a slow breath and occasional blink. Deliberately subtle —
    // the brief asks for realism, not motion for its own sake (§9).
    _breath = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3800),
    )..repeat(reverse: true);
    _blink = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 160),
    );
    _scheduleBlink();
    _portraitProbe = _hasAsset(widget.persona.portraitAsset);
  }

  @override
  void didUpdateWidget(covariant AssistantFace old) {
    super.didUpdateWidget(old);
    if (old.persona.portraitAsset != widget.persona.portraitAsset) {
      _portraitProbe = _hasAsset(widget.persona.portraitAsset);
    }
  }

  Future<bool> _hasAsset(String path) async {
    try {
      await rootBundle.load(path);
      return true;
    } catch (_) {
      return false;
    }
  }

  void _scheduleBlink() {
    _blinkTimer?.cancel();
    _blinkTimer = Timer(Duration(milliseconds: 2600 + _rand.nextInt(3800)), () {
      if (!mounted) return;
      _blink.forward().then((_) => _blink.reverse());
      _scheduleBlink();
    });
  }

  @override
  void dispose() {
    _blinkTimer?.cancel();
    _breath.dispose();
    _blink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: ClipOval(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 420),
          child: _layer(),
        ),
      ),
    );
  }

  Widget _layer() {
    // 1. Live avatar from the unified session.
    if (widget.liveFrame != null) {
      return SizedBox.expand(
        key: const ValueKey('live'),
        child: FittedBox(fit: BoxFit.cover, child: widget.liveFrame),
      );
    }
    // 2. Licensed portrait asset, if the app ships one.
    return FutureBuilder<bool>(
      key: const ValueKey('static'),
      future: _portraitProbe,
      builder: (context, snap) {
        if (snap.data == true) {
          return _animate(
            Image.asset(
              widget.persona.portraitAsset,
              fit: BoxFit.cover,
              width: widget.size,
              height: widget.size,
              // A decode failure must not blank the assistant.
              errorBuilder: (_, __, ___) => _presence(),
            ),
          );
        }
        // 3. Presence placeholder (also used while probing).
        return _animate(_presence());
      },
    );
  }

  /// Shared life: breathing scale, blink dim, and a speaking pulse. Applied
  /// to whichever layer is showing so the assistant feels equally alive.
  Widget _animate(Widget child) {
    return AnimatedBuilder(
      animation: Listenable.merge([_breath, _blink]),
      builder: (context, _) {
        final breath = 1.0 + 0.012 * math.sin(_breath.value * math.pi * 2);
        final speak = widget.phase == AssistantPhase.speaking
            ? 1.0 + 0.02 * widget.speakingLevel.clamp(0.0, 1.0)
            : 1.0;
        return Transform.scale(
          scale: breath * speak,
          child: ColorFiltered(
            // A blink reads as a brief dim on a portrait/presence; on a
            // live video frame the provider does its own blinking, so keep
            // this very light.
            colorFilter: ColorFilter.mode(
              Colors.black.withValues(alpha: 0.30 * _blink.value),
              BlendMode.darken,
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                child,
                _stateWash(),
                if (widget.connecting) _connecting(),
              ],
            ),
          ),
        );
      },
    );
  }

  /// A soft coloured wash conveying agent state WITHOUT covering the face
  /// or reverting to an icon (§9, §12).
  Widget _stateWash() {
    final (Color c, double a) = switch (widget.phase) {
      AssistantPhase.listening => (Neon.cyan, 0.16),
      AssistantPhase.speaking => (Neon.violet, 0.12),
      AssistantPhase.thinking ||
      AssistantPhase.searching ||
      AssistantPhase.transcribing ||
      AssistantPhase.generatingVoice ||
      AssistantPhase.findingContact ||
      AssistantPhase.preparingMessage =>
        (Neon.violet, 0.20),
      AssistantPhase.error => (Colors.redAccent, 0.18),
      _ => (Colors.transparent, 0.0),
    };
    if (a == 0) return const SizedBox.shrink();
    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            colors: [Colors.transparent, c.withValues(alpha: a)],
            stops: const [0.45, 1.0],
          ),
        ),
      ),
    );
  }

  Widget _connecting() => IgnorePointer(
        child: Container(
          color: Colors.black.withValues(alpha: 0.25),
          alignment: Alignment.bottomCenter,
          padding: const EdgeInsets.only(bottom: 18),
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Colors.white.withValues(alpha: 0.85),
            ),
          ),
        ),
      );

  /// Non-photographic presence: warm lit form, soft rim light, gentle
  /// gradient. Reads as "someone is here" without pretending to be a photo.
  Widget _presence() {
    final p = widget.persona;
    return Semantics(
      label: '${p.displayName}, your assistant',
      image: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: const Alignment(-0.25, -0.4),
            radius: 1.1,
            colors: [
              p.tint.withValues(alpha: 0.55),
              p.tint.withValues(alpha: 0.22),
              Neon.bg.withValues(alpha: 0.94),
            ],
            stops: const [0.0, 0.45, 1.0],
          ),
        ),
        child: Center(
          child: Text(
            p.initial,
            style: TextStyle(
              fontSize: widget.size * 0.34,
              fontWeight: FontWeight.w300,
              letterSpacing: 1,
              color: Colors.white.withValues(alpha: 0.92),
              shadows: [
                Shadow(color: p.tint.withValues(alpha: 0.8), blurRadius: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
