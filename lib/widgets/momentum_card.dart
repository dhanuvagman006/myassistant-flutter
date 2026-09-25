import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design/motion.dart';
import '../design/neon_tokens.dart';
import '../models/momentum.dart';
import '../screens/focus_screen.dart';
import '../screens/momentum_screen.dart';
import '../services/focus_service.dart';
import '../services/momentum_service.dart';
import 'momentum_parts.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  MOMENTUM ON HOME (2026-09-25) — the streak, Today's 3, habit chips and
///  a Focus button, near the top of the feed.
///
///  Owner: "plan and add some features that make much better and keeps
///  user motivated and productive". Deciding what matters today is the
///  first step, so it sits right under the day's line, where it is seen
///  before anything else is read. Tapping ticks, long-pressing edits, and
///  it all works without a word spoken — the voice path ("my top three
///  today are…") lands in the same list.
///
///  At rest it asks for nothing: the ring moves only when the count
///  changes, and the celebration is a single 1.2 s burst.
/// ─────────────────────────────────────────────────────────────────────────
class MomentumCard extends StatelessWidget {
  const MomentumCard({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: MomentumService.instance,
      builder: (context, _) {
        final s = MomentumService.instance.summary;
        // Nothing yet (first launch offline): say nothing rather than a
        // streak of zero that may not be true.
        if (s == null) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(bottom: 18),
          child: MomentumCelebrationHost(
            origin: const Alignment(0.8, -0.2),
            builder: (context, line) => _Card(summary: s, line: line),
          ),
        );
      },
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.summary, this.line});
  final MomentumSummary summary;
  final String? line;

  @override
  Widget build(BuildContext context) {
    final s = summary;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
      decoration: BoxDecoration(
        color: Neon.surfaceHigh,
        borderRadius: BorderRadius.circular(Neon.rLg),
        border: Border.all(color: Neon.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Header(summary: s),
          if (line != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(line!,
                  key: const ValueKey('momentum-line'),
                  style: NeonType.manrope(NeonType.footnote, FontWeight.w700).copyWith(color: Neon.violet)),
            ),
          if (s.priorities.isEmpty) const _EmptyToday() else _Today(summary: s),
          if (s.habits.isNotEmpty) ...[
            const SizedBox(height: 2),
            SizedBox(
              height: 48,
              child: ListView.separated(
                clipBehavior: Clip.none,
                scrollDirection: Axis.horizontal,
                itemCount: s.habits.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (_, i) => MomentumHabitChip(habit: s.habits[i]),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// "5-day streak" (or an invitation), and the Focus button.
class _Header extends StatelessWidget {
  const _Header({required this.summary});
  final MomentumSummary summary;

  @override
  Widget build(BuildContext context) {
    final n = summary.streak;
    final text = n >= 1 ? '$n-day streak' : 'Start a streak today';
    return Row(
      children: [
        Expanded(
          child: Semantics(
            button: true,
            label: '$text. Open Momentum.',
            excludeSemantics: true,
            child: InkWell(
              borderRadius: BorderRadius.circular(Neon.rSm),
              onTap: () => Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => const MomentumScreen())),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: Row(
                  children: [
                    Icon(Icons.local_fire_department_rounded,
                        size: 20, color: n >= 1 ? Neon.violet : Neon.textDim),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(text,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: NeonType.sectionTitle.copyWith(color: Neon.textHi)),
                    ),
                    const SizedBox(width: 2),
                    Icon(Icons.chevron_right_rounded, size: 18, color: Neon.textDim),
                  ],
                ),
              ),
            ),
          ),
        ),
        const _FocusButton(),
      ],
    );
  }
}

class _FocusButton extends StatelessWidget {
  const _FocusButton();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: FocusService.instance,
      builder: (context, _) {
        // No countdown here: Home stays still. A running session just
        // says so, and the tap goes back to it.
        final on = FocusService.instance.active;
        return PressScale(
          child: Semantics(
            button: true,
            label: on ? 'Focus is on. Open it.' : 'Start a focus session',
            excludeSemantics: true,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                HapticFeedback.selectionClick();
                Navigator.of(context).push(MaterialPageRoute(builder: (_) => const FocusScreen()));
              },
              child: SizedBox(
                height: 48,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                    decoration: BoxDecoration(
                      color: Neon.violet.withValues(alpha: on ? 0.22 : 0.10),
                      borderRadius: BorderRadius.circular(Neon.rPill),
                      border: Border.all(color: Neon.violet.withValues(alpha: 0.35)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.timer_outlined, size: 16, color: Neon.violet),
                        const SizedBox(width: 6),
                        Text(on ? 'Focus on' : 'Focus',
                            style: NeonType.manrope(NeonType.footnote, FontWeight.w700)
                                .copyWith(color: Neon.textHi)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Today's 3 with its ring.
class _Today extends StatelessWidget {
  const _Today({required this.summary});
  final MomentumSummary summary;

  @override
  Widget build(BuildContext context) {
    final s = summary;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final p in s.priorities) MomentumPriorityRow(key: ValueKey('mp-${p.id}'), priority: p),
              if (s.priorities.length < MomentumService.maxPriorities)
                _AddRow(label: s.allDone ? 'Add another win' : 'Add a win'),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: MomentumRing(done: s.doneCount, total: MomentumService.maxPriorities),
        ),
      ],
    );
  }
}

class _AddRow extends StatelessWidget {
  const _AddRow({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(Neon.rSm),
      onTap: () => addPriority(context),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Row(
          children: [
            Icon(Icons.add_circle_outline_rounded, size: 24, color: Neon.textDim),
            const SizedBox(width: 12),
            Text(label, style: TextStyle(color: Neon.textLo, fontSize: NeonType.body)),
          ],
        ),
      ),
    );
  }
}

/// No list yet: ask the question, offer Add, and say it can be spoken.
class _EmptyToday extends StatelessWidget {
  const _EmptyToday();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('What are 3 wins for today?',
                    style: NeonType.manrope(NeonType.body, FontWeight.w600).copyWith(color: Neon.textHi)),
                const SizedBox(height: 2),
                Text('Tap Add, or just say "my top three today are…"',
                    style: TextStyle(color: Neon.textLo, fontSize: NeonType.footnote, height: 1.3)),
              ],
            ),
          ),
          const SizedBox(width: 10),
          FilledButton.icon(
            onPressed: () => addPriority(context),
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text('Add'),
            style: FilledButton.styleFrom(
              backgroundColor: Neon.violet,
              foregroundColor: Neon.onAccent,
              minimumSize: const Size(48, 48),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              textStyle: NeonType.manrope(NeonType.body, FontWeight.w700),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Neon.rPill)),
            ),
          ),
        ],
      ),
    );
  }
}
