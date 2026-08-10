// The AI ORB that used to live here was REMOVED per client request —
// the assistant's visual is now the gendered avatar FACE in
// assistant_avatar.dart. This file keeps the shared status pill and
// transcript bubble widgets.


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
