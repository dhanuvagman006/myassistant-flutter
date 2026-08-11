import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../design/neon_tokens.dart';
import '../state/assistant_state.dart';

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
  const AssistantHeroWidget({
    super.key,
    required this.phase,
    this.micLevel = 0,
    this.onTap,
  });

  @override
  State<AssistantHeroWidget> createState() => _AssistantHeroWidgetState();
}

class _AssistantHeroWidgetState extends State<AssistantHeroWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: const Duration(seconds: 3))
      ..repeat();
  }

  @override
  void dispose() {
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
          return SizedBox(
            width: 210,
            height: 210,
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
                              center: const Alignment(-0.35, -0.45),
                              colors: [
                                Colors.white.withValues(alpha: 0.16),
                                Neon.bg.withValues(alpha: 0.86),
                              ],
                            ),
                          ),
                          child: Center(
                            child: AnimatedSwitcher(
                              duration: const Duration(milliseconds: 250),
                              child: Icon(
                                _icon,
                                key: ValueKey(_icon),
                                size: 44,
                                color: Colors.white.withValues(alpha: 0.94),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  IconData get _icon => switch (widget.phase) {
        AssistantPhase.listening => Icons.graphic_eq_rounded,
        AssistantPhase.transcribing => Icons.short_text_rounded,
        AssistantPhase.thinking => Icons.auto_awesome_rounded,
        AssistantPhase.searching => Icons.travel_explore_rounded,
        AssistantPhase.findingContact => Icons.person_search_rounded,
        AssistantPhase.preparingMessage => Icons.edit_note_rounded,
        AssistantPhase.generatingVoice => Icons.record_voice_over_rounded,
        AssistantPhase.waitingForConfirmation => Icons.help_outline_rounded,
        AssistantPhase.dialing ||
        AssistantPhase.ringing ||
        AssistantPhase.inCall =>
          Icons.phone_in_talk_rounded,
        AssistantPhase.speaking => Icons.volume_up_rounded,
        AssistantPhase.error => Icons.error_outline_rounded,
        _ => Icons.mic_none_rounded,
      };
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
        color: Colors.white.withValues(alpha: 0.07),
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
              color: Colors.white,
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (phase.cancellable && onCancel != null) ...[
            const SizedBox(width: 8),
            GestureDetector(
              onTap: onCancel,
              child: Icon(Icons.close_rounded,
                  size: 16, color: Colors.white.withValues(alpha: 0.7)),
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
          color: isUser ? null : Colors.white.withValues(alpha: 0.07),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(18),
            topRight: const Radius.circular(18),
            bottomLeft: Radius.circular(isUser ? 18 : 4),
            bottomRight: Radius.circular(isUser ? 4 : 18),
          ),
          border: isUser
              ? null
              : Border.all(color: Colors.white.withValues(alpha: 0.08)),
        ),
        child: Text(
          entry.text,
          style: TextStyle(
            color: Colors.white.withValues(alpha: isUser ? 1 : 0.92),
            fontSize: 14.5,
            height: 1.35,
          ),
        ),
      ),
    );
  }
}
