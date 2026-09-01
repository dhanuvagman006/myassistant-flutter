import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../design/gyro_motion.dart';
import '../../../design/neon_tokens.dart';
import '../state/assistant_state.dart';
import 'assistant_face.dart';
import 'assistant_persona.dart';

/// The central animated assistant visual — a breathing gradient orb with a
/// state-driven halo:
///   idle       slow calm breathing
///   listening  pulses with the LIVE mic level (you can see it hear you)
///   thinking / searching / finding / preparing  orbiting sparks
///   speaking   rhythmic ripple
///   in call    steady green ring
///   error      red flash ring
class AssistantHeroWidget extends StatefulWidget {
  final AssistantPhase phase;
  final double micLevel;
  final VoidCallback? onTap;

  /// Who the assistant appears to be (opposite gender to the user).
  /// Defaults to neutral so every existing call site keeps compiling.
  final AssistantPersona persona;

  /// Live avatar video frame from the SAME agent session, when available.
  final Widget? liveFrame;

  /// True while the avatar provider is connecting.
  final bool avatarConnecting;

  const AssistantHeroWidget({
    super.key,
    required this.phase,
    this.micLevel = 0,
    this.onTap,
    this.persona = AssistantPersona.neutral,
    this.liveFrame,
    this.avatarConnecting = false,
  });

  @override
  State<AssistantHeroWidget> createState() => _AssistantHeroWidgetState();
}

class _AssistantHeroWidgetState extends State<AssistantHeroWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  // Shared, battery-aware device-tilt signal (one stream for the whole
  // app — see GyroMotion). Read inside the existing AnimatedBuilder, so
  // the orb's 3D parallax costs no extra ticker and no extra rebuilds.
  final _gyro = GyroMotion.instance;

  @override
  void initState() {
    super.initState();
    _gyro.retain();
    _c = AnimationController(vsync: this, duration: const Duration(seconds: 3))
      ..repeat();
  }

  @override
  void dispose() {
    _gyro.release();
    _c.dispose();
    super.dispose();
  }

  Color get _accent => switch (widget.phase) {
        AssistantPhase.listening => Neon.cyan,
        AssistantPhase.error => Neon.error,
        AssistantPhase.inCall ||
        AssistantPhase.dialing ||
        AssistantPhase.ringing =>
          Neon.success,
        _ => Neon.violet,
      };

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final t = _c.value;
          final breathe = 1 + 0.03 * math.sin(t * 2 * math.pi);
          final level = widget.phase == AssistantPhase.listening
              ? (0.15 + widget.micLevel * 0.85)
              : 0.0;
          // Device tilt → gentle 3D parallax. Read from the shared signal
          // (−1.2..1.2, self-centering); scaled down so the orb feels like
          // it has depth without wobbling. Degrades to 0 with no gyroscope.
          final gx = _gyro.x, gy = _gyro.y;
          return SizedBox(
            width: 210,
            height: 210,
            child: Transform(
              alignment: Alignment.center,
              transform: Matrix4.identity()
                ..setEntry(3, 2, 0.0014) // perspective
                ..rotateX(gx * 0.12)
                ..rotateY(gy * 0.12),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Live-level halo (listening) / activity ripple (speaking)
                  if (widget.phase == AssistantPhase.listening ||
                      widget.phase == AssistantPhase.speaking)
                    Container(
                      width: 150 + 55 * (level > 0 ? level : (0.5 + 0.5 * math.sin(t * 6 * math.pi))),
                      height: 150 + 55 * (level > 0 ? level : (0.5 + 0.5 * math.sin(t * 6 * math.pi))),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _accent.withValues(alpha: 0.14),
                      ),
                    ),
                  // Busy: orbiting sparks
                  if (widget.phase.busy &&
                      widget.phase != AssistantPhase.listening &&
                      widget.phase != AssistantPhase.speaking)
                    ...List.generate(3, (i) {
                      final a = t * 2 * math.pi + i * (2 * math.pi / 3);
                      return Transform.translate(
                        offset: Offset(math.cos(a) * 92, math.sin(a) * 92),
                        child: Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _accent.withValues(alpha: 0.9),
                            boxShadow: [
                              BoxShadow(
                                color: _accent.withValues(alpha: 0.6),
                                blurRadius: 10,
                              ),
                            ],
                          ),
                        ),
                      );
                    }),
                  // State ring
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    width: 172,
                    height: 172,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: _accent.withValues(
                            alpha: widget.phase == AssistantPhase.idle ? 0.25 : 0.7),
                        width: 2.5,
                      ),
                    ),
                  ),
                  // The orb itself — slowly rotating tri-color neon sweep
                  Transform.scale(
                    scale: breathe + level * 0.08,
                    child: Transform.rotate(
                      angle: t * 2 * math.pi,
                      child: Container(
                        width: 148,
                        height: 148,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: Neon.gOrb,
                          boxShadow: [
                            BoxShadow(
                              color: _accent.withValues(alpha: 0.40),
                              blurRadius: 44,
                              spreadRadius: 4,
                            ),
                            BoxShadow(
                              color: Neon.pink.withValues(alpha: 0.18),
                              blurRadius: 70,
                              spreadRadius: 10,
                            ),
                          ],
                        ),
                        child: Transform.rotate(
                          angle: -t * 2 * math.pi, // keep the face upright
                          child: Container(
                            margin: const EdgeInsets.all(7),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: RadialGradient(
                                // Highlight drifts with the tilt — the glass
                                // catches light from where the phone leans.
                                center: Alignment(
                                    (-0.35 + gy * 0.5).clamp(-1.0, 1.0),
                                    (-0.45 + gx * 0.5).clamp(-1.0, 1.0)),
                                colors: [
                                  Colors.white.withValues(alpha: 0.16),
                                  Neon.bg.withValues(alpha: 0.86),
                                ],
                              ),
                            ),
                            // THE ASSISTANT'S FACE replaces the old mic
                            // icon here. The ring, sizing, gyro tilt and
                            // every surrounding control are unchanged —
                            // only the centre content differs.
                            child: ClipOval(
                              child: AssistantFace(
                                // The inner glass circle is 150 wide with a
                                // 7px margin on each side.
                                size: 136,
                                phase: widget.phase,
                                persona: widget.persona,
                                speakingLevel: level,
                                liveFrame: widget.liveFrame,
                                connecting: widget.avatarConnecting,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // The per-phase mic/status ICON that used to sit in the centre is gone:
  // AssistantFace now conveys state through expression and a colour wash,
  // so the assistant never reverts to an icon (§12). The status pill below
  // still shows the phase in words.
}

/// Live status pill — always tells the user what the assistant is doing.
class AssistantStatusPill extends StatelessWidget {
  final AssistantPhase phase;
  final bool connected;
  final VoidCallback? onCancel;
  const AssistantStatusPill({
    super.key,
    required this.phase,
    required this.connected,
    this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final accent = switch (phase) {
      AssistantPhase.listening => Neon.cyan,
      AssistantPhase.error => Neon.error,
      AssistantPhase.inCall => Neon.success,
      _ => Neon.violet,
    };
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
      decoration: BoxDecoration(
        color: Neon.surfaceHigh,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: accent.withValues(alpha: 0.45)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (phase.busy)
            SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 2, color: accent),
            )
          else
            Container(
              width: 9,
              height: 9,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: connected ? accent : Colors.grey,
              ),
            ),
          const SizedBox(width: 9),
          Text(
            connected ? phase.label : 'Reconnecting…',
            style: const TextStyle(
              color: Neon.textHi,
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (phase.cancellable && onCancel != null) ...[
            const SizedBox(width: 8),
            GestureDetector(
              onTap: onCancel,
              child: const Icon(Icons.close_rounded,
                  size: 16, color: Neon.textLo),
            ),
          ],
        ],
      ),
    );
  }
}

/// One line of the live transcript (user right, assistant left).
class TranscriptBubble extends StatelessWidget {
  final TranscriptEntry entry;
  const TranscriptBubble({super.key, required this.entry});

  @override
  Widget build(BuildContext context) {
    final isUser = entry.role == TranscriptRole.user;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        constraints: const BoxConstraints(maxWidth: 300),
        decoration: BoxDecoration(
          gradient: isUser ? Neon.gVioletPink : null,
          color: isUser ? null : Neon.surfaceHigh,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(18),
            topRight: const Radius.circular(18),
            bottomLeft: Radius.circular(isUser ? 18 : 4),
            bottomRight: Radius.circular(isUser ? 4 : 18),
          ),
          border: isUser
              ? null
              : Border.all(color: Neon.line),
        ),
        child: Text(
          entry.text,
          style: TextStyle(
            color: isUser ? Colors.white : Neon.textHi,
            fontSize: 14.5,
            height: 1.35,
          ),
        ),
      ),
    );
  }
}
