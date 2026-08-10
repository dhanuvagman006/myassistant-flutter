import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../design/gyro_tilt.dart';
import '../../../design/neon_tokens.dart';
import '../../../theme/app_theme.dart';
import '../state/assistant_state.dart';

/// Shared glass card chrome for the dark assistant screen.
class _Glass extends StatelessWidget {
  final Widget child;
  final Color? borderTint;
  const _Glass({required this.child, this.borderTint});

  @override
  Widget build(BuildContext context) {
    return Padding(
      // Margin stays OUTSIDE the tilt so the layout box never moves —
      // only the painted card floats with the device.
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: GyroTilt(
        radius: 18,
        shadowColor: borderTint ?? Neon.violet,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: (borderTint ?? Colors.white).withValues(alpha: 0.14),
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Small "what I'm doing" chip — one per tool run.
class ToolCard extends StatelessWidget {
  final ToolActivity activity;
  const ToolCard({super.key, required this.activity});

  @override
  Widget build(BuildContext context) {
    return _Glass(
      child: Row(
        children: [
          activity.completed
              ? const Icon(Icons.check_circle_rounded,
                  size: 18, color: Color(0xFF35C48D))
              : const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: AppColors.peacockLight),
                ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              activity.label,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.85),
                fontSize: 13.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One web search hit — tappable to open the source.
class SearchResultCard extends StatelessWidget {
  final SearchResult result;
  const SearchResultCard({super.key, required this.result});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: () {
        final u = Uri.tryParse(result.url);
        if (u != null) launchUrl(u, mode: LaunchMode.externalApplication);
      },
      child: _Glass(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.public_rounded,
                    size: 14, color: AppColors.peacockLight),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    result.source,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.55),
                      fontSize: 12,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Icon(Icons.open_in_new_rounded,
                    size: 14, color: Colors.white.withValues(alpha: 0.4)),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              result.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (result.snippet.isNotEmpty) ...[
              const SizedBox(height: 5),
              Text(
                result.snippet,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.7),
                  fontSize: 13,
                  height: 1.35,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A resolved (or candidate) contact.
class ContactCard extends StatelessWidget {
  final ContactMatch contact;
  final VoidCallback? onTap; // set when the user must choose among several
  final bool selected;
  const ContactCard({
    super.key,
    required this.contact,
    this.onTap,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    final initial =
        contact.name.isNotEmpty ? contact.name[0].toUpperCase() : '?';
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      child: _Glass(
        borderTint: selected ? AppColors.peacockLight : null,
        child: Row(
          children: [
            CircleAvatar(
              radius: 20,
              backgroundColor: AppColors.peacock.withValues(alpha: 0.6),
              child: Text(initial,
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w700)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(contact.name,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w600)),
                  Text(contact.phone,
                      style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.6),
                          fontSize: 13)),
                ],
              ),
            ),
            if (onTap != null)
              Icon(Icons.chevron_right_rounded,
                  color: Colors.white.withValues(alpha: 0.5)),
          ],
        ),
      ),
    );
  }
}

/// Live call status — timeline dots for dialing → ringing → in call → done.
class CallStatusCard extends StatelessWidget {
  final CallStatusInfo status;
  const CallStatusCard({super.key, required this.status});

  static const _steps = ['dialing', 'ringing', 'in_call', 'completed'];

  @override
  Widget build(BuildContext context) {
    final failed = status.status == 'failed' || status.status == 'no_answer';
    final idx = _steps.indexOf(status.status);
    return _Glass(
      borderTint: failed ? AppColors.danger : const Color(0xFF35C48D),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                failed ? Icons.phone_missed_rounded : Icons.phone_in_talk_rounded,
                size: 18,
                color: failed ? AppColors.danger : const Color(0xFF35C48D),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${status.label} — ${status.contactName}',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          if (!failed) ...[
            const SizedBox(height: 12),
            Row(
              children: List.generate(_steps.length * 2 - 1, (i) {
                if (i.isOdd) {
                  final done = i ~/ 2 < idx;
                  return Expanded(
                    child: Container(
                      height: 2,
                      color: done
                          ? const Color(0xFF35C48D)
                          : Colors.white.withValues(alpha: 0.15),
                    ),
                  );
                }
                final step = i ~/ 2;
                final done = step <= idx;
                final current = step == idx && status.status != 'completed';
                return Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: done
                        ? const Color(0xFF35C48D)
                        : Colors.white.withValues(alpha: 0.2),
                    boxShadow: current
                        ? [
                            BoxShadow(
                                color: const Color(0xFF35C48D)
                                    .withValues(alpha: 0.6),
                                blurRadius: 8)
                          ]
                        : null,
                  ),
                );
              }),
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: const [
                _StepLabel('Dialing'),
                _StepLabel('Ringing'),
                _StepLabel('In call'),
                _StepLabel('Done'),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _StepLabel extends StatelessWidget {
  final String text;
  const _StepLabel(this.text);
  @override
  Widget build(BuildContext context) => Text(
        text,
        style:
            TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 10.5),
      );
}

/// "Should I place this call?" — always shown before dialing.
class ConfirmationCard extends StatelessWidget {
  final PendingConfirmation pending;
  final void Function(bool approved) onDecision;
  const ConfirmationCard({
    super.key,
    required this.pending,
    required this.onDecision,
  });

  @override
  Widget build(BuildContext context) {
    final isCall = pending.action == 'place_call';
    return _Glass(
      borderTint: AppColors.marigold,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.verified_user_outlined,
                  size: 18, color: AppColors.marigold),
              const SizedBox(width: 8),
              Text(
                isCall ? 'Confirm this call' : 'Confirm',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (isCall && pending.contact != null) ...[
            Text(
              'Call ${pending.contact!.name} (${pending.contact!.phone}) and say:',
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.75), fontSize: 13.5),
            ),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '“${pending.spokenPreview ?? pending.message ?? ''}”',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontStyle: FontStyle.italic,
                    height: 1.4),
              ),
            ),
          ] else
            Text(
              pending.question ?? 'Shall I go ahead?',
              style: const TextStyle(color: Colors.white, fontSize: 14.5),
            ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white70,
                    side: BorderSide(
                        color: Colors.white.withValues(alpha: 0.25)),
                  ),
                  onPressed: () => onDecision(false),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                      backgroundColor: AppColors.peacock),
                  onPressed: () => onDecision(true),
                  icon: Icon(isCall ? Icons.call_rounded : Icons.check_rounded,
                      size: 18),
                  label: Text(isCall ? 'Place call' : 'Confirm'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
