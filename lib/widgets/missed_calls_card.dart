import 'package:flutter/material.dart';

import '../design/neon_tokens.dart';
import '../features/assistant/state/assistant_engine.dart';
import '../services/call_history.dart';
import '../services/missed_calls_service.dart';

/// MISSED CALLS, ON HOME.
///
/// Owner, 2026-09-24: "it should report when we have any missed calls".
/// A small card under the header while there are calls he has not dealt
/// with: who, when, how many times, and a Call back button that dials
/// straight away (his tap is the go-ahead). ✕ puts it away; calling the
/// person back from anywhere clears them by itself (MissedCallsService).
///
/// Renders nothing at all when there is nothing missed, and grows in
/// rather than jumping the feed down.
class MissedCallsCard extends StatelessWidget {
  const MissedCallsCard({super.key, this.onCallBack, this.now});

  /// Test seam; the engine's call-back flow otherwise.
  final void Function(CallEntry entry)? onCallBack;

  /// Test seam for the "3:10 pm" / "yesterday" labels.
  final DateTime Function()? now;

  /// At most this many callers on the card; the rest are counted.
  static const maxRows = 3;

  @override
  Widget build(BuildContext context) {
    final svc = MissedCallsService.instance;
    return ValueListenableBuilder<List<CallEntry>>(
      valueListenable: svc.pending,
      builder: (context, calls, _) => AnimatedSize(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        alignment: Alignment.topCenter,
        child: calls.isEmpty
            ? const SizedBox(width: double.infinity)
            : _card(context, calls),
      ),
    );
  }

  Widget _card(BuildContext context, List<CallEntry> calls) {
    final groups = CallHistory.group(calls);
    final t = (now ?? DateTime.now)();
    final red = Neon.error;
    final shown = groups.take(maxRows).toList();
    final more = groups.length - shown.length;
    return Padding(
      key: const ValueKey('missed-calls-card'),
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
        decoration: BoxDecoration(
          color: Neon.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: red.withValues(alpha: 0.28)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.phone_missed_rounded, size: 18, color: red),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Missed calls',
                    style: NeonType.sectionTitle.copyWith(color: Neon.textHi),
                  ),
                ),
                IconButton(
                  tooltip: 'Dismiss missed calls',
                  constraints:
                      const BoxConstraints(minWidth: 48, minHeight: 48),
                  padding: EdgeInsets.zero,
                  onPressed: MissedCallsService.instance.dismiss,
                  icon: Icon(Icons.close_rounded,
                      size: 18, color: Neon.textLo),
                ),
              ],
            ),
            for (final g in shown) _row(g, t),
            if (more > 0)
              Padding(
                padding: const EdgeInsets.only(top: 2, bottom: 4),
                child: Text(
                  '+$more more',
                  style: TextStyle(color: Neon.textLo, fontSize: 13),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _row(CallGroup g, DateTime t) {
    final c = g.latest;
    final when = CallHistory.when(c.at, t).replaceFirst(RegExp(r'^at '), '');
    final times = g.count > 1 ? ' · ${g.count} calls' : '';
    final canDial = c.dialable.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  c.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: NeonType.manrope(NeonType.callout, FontWeight.w600)
                      .copyWith(color: Neon.textHi),
                ),
                Text(
                  '$when$times',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Neon.textLo, fontSize: 13),
                ),
              ],
            ),
          ),
          if (canDial)
            TextButton.icon(
              style: TextButton.styleFrom(
                foregroundColor: Neon.violet,
                minimumSize: const Size(48, 48),
              ),
              onPressed: () => (onCallBack ??
                  AssistantEngine.instance.callBackMissed)(c),
              icon: const Icon(Icons.call_rounded, size: 18),
              label: const Text('Call back'),
            ),
        ],
      ),
    );
  }
}
