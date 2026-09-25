import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design/apple_kit.dart';
import '../design/motion.dart';
import '../design/neon_tokens.dart';
import '../models/momentum.dart';
import '../services/app_feedback.dart';
import '../services/auth_service.dart';
import '../services/avatar_message_service.dart';
import '../services/momentum_service.dart';
import '../widgets/momentum_parts.dart';
import 'focus_screen.dart';

/// Opens Momentum's screens from anywhere: a tapped push or notification,
/// or the assistant. Waits a moment for the app to be ready after a cold
/// start, and never stacks a second copy of a screen already open.
abstract final class MomentumNav {
  static Future<void> open(String what) async {
    for (var i = 0; i < 24; i++) {
      final nav = AvatarMessageService.navigatorKey.currentState;
      if (nav != null && AuthService.instance.user != null) {
        if (what == 'focus') {
          if (FocusScreen.showing == 0) {
            unawaited(nav.push(MaterialPageRoute(builder: (_) => const FocusScreen())));
          }
        } else if (MomentumScreen.showing == 0) {
          unawaited(nav.push(MaterialPageRoute(builder: (_) => const MomentumScreen())));
        }
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }
}

/// ─────────────────────────────────────────────────────────────────────────
///  MOMENTUM (Hub → Your day → Momentum) — the streak, Today's 3, habits,
///  focus, the week and milestones on one page (2026-09-25).
///
///  Owner: "plan and add some features that make much better and keeps
///  user motivated and productive". Home carries the short version; this
///  is where things are edited and where progress is seen whole. Nothing
///  here scolds: a quiet day is shown as a quiet day, and one missed day a
///  week is marked as a rest day, not a failure.
/// ─────────────────────────────────────────────────────────────────────────
class MomentumScreen extends StatefulWidget {
  const MomentumScreen({super.key});

  /// How many are open (MomentumNav does not stack a second).
  static int showing = 0;

  @override
  State<MomentumScreen> createState() => _MomentumScreenState();
}

class _MomentumScreenState extends State<MomentumScreen> {
  final _svc = MomentumService.instance;

  @override
  void initState() {
    super.initState();
    MomentumScreen.showing++;
    unawaited(_svc.refresh());
  }

  @override
  void dispose() {
    MomentumScreen.showing--;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Neon.bg,
      appBar: appleAppBar(context, 'Momentum'),
      body: ListenableBuilder(
        listenable: _svc,
        builder: (context, _) {
          final s = _svc.summary;
          return LoadSwitch(
            loading: s == null && !_svc.failed,
            child: s == null
                ? _Offline(onRetry: () => _svc.refresh(force: true))
                : RefreshIndicator(
                    color: Neon.violet,
                    onRefresh: () => _svc.refresh(force: true),
                    child: MomentumCelebrationHost(
                      origin: const Alignment(0, -0.75),
                      builder: (context, line) => ListView(
                        padding: EdgeInsets.fromLTRB(16, 8, 16, 32 + MediaQuery.paddingOf(context).bottom),
                        children: [
                          _StreakCard(summary: s, line: line),
                          const SizedBox(height: 24),
                          _TodaySection(summary: s),
                          const SizedBox(height: 24),
                          _HabitsSection(summary: s),
                          const SizedBox(height: 24),
                          _FocusSection(summary: s),
                          const SizedBox(height: 24),
                          _WeekSection(summary: s),
                          const SizedBox(height: 24),
                          _MilestonesSection(summary: s),
                        ],
                      ),
                    ),
                  ),
          );
        },
      ),
    );
  }
}

class _Offline extends StatelessWidget {
  const _Offline({required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_rounded, color: Neon.textLo, size: 28),
            const SizedBox(height: 10),
            Text("Couldn't load your momentum — check your connection.",
                textAlign: TextAlign.center, style: TextStyle(color: Neon.textLo, fontSize: NeonType.body)),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Try again'),
            ),
          ],
        ),
      ),
    );
  }
}

const _dayLetters = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
const _dayNames = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];

DateTime? _parseDay(String d) {
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(d);
  if (m == null) return null;
  return DateTime(int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!));
}

String _minutes(int m) {
  if (m < 60) return '$m min';
  final h = m ~/ 60, r = m % 60;
  return r == 0 ? '$h h' : '$h h $r min';
}

/// The streak, the best, and the last seven days as dots.
class _StreakCard extends StatelessWidget {
  const _StreakCard({required this.summary, this.line});
  final MomentumSummary summary;
  final String? line;

  @override
  Widget build(BuildContext context) {
    final s = summary;
    final sub = s.streak == 0
        ? 'One small win today starts it.'
        : s.activeToday
            ? 'Today counts. Keep it going tomorrow.'
            : 'One small win today keeps it going.';
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Neon.surface,
        borderRadius: BorderRadius.circular(Neon.rLg),
        border: Border.all(color: Neon.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.local_fire_department_rounded,
                  size: 32, color: s.streak > 0 ? Neon.violet : Neon.textDim),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(s.streak == 1 ? '1-day streak' : '${s.streak}-day streak',
                        style: NeonType.manrope(NeonType.title3, FontWeight.w800).copyWith(color: Neon.textHi)),
                    const SizedBox(height: 2),
                    Text(line ?? sub,
                        style: line != null
                            ? NeonType.manrope(NeonType.footnote, FontWeight.w700).copyWith(color: Neon.violet)
                            : TextStyle(color: Neon.textLo, fontSize: NeonType.footnote, height: 1.3)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text('Best',
                      style: NeonType.manrope(NeonType.caption, FontWeight.w600).copyWith(color: Neon.textLo)),
                  Text('${s.bestStreak}',
                      style: NeonType.manrope(NeonType.headline, FontWeight.w800).copyWith(color: Neon.textHi)),
                ],
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              for (final d in s.week) _WeekDot(day: d, today: d.day == s.day),
            ],
          ),
          if (s.week.any((d) => d.forgiven)) ...[
            const SizedBox(height: 10),
            Text('One rest day a week keeps the streak.',
                style: TextStyle(color: Neon.textLo, fontSize: NeonType.caption)),
          ],
        ],
      ),
    );
  }
}

class _WeekDot extends StatelessWidget {
  const _WeekDot({required this.day, required this.today});
  final MomentumDay day;
  final bool today;

  @override
  Widget build(BuildContext context) {
    final date = _parseDay(day.day);
    final letter = date == null ? '' : _dayLetters[date.weekday - 1];
    final Color fill;
    final Color edge;
    if (day.active) {
      fill = Neon.violet;
      edge = Neon.violet;
    } else if (day.forgiven) {
      fill = Neon.violet.withValues(alpha: 0.18);
      edge = Neon.violet.withValues(alpha: 0.55);
    } else {
      fill = Colors.transparent;
      edge = today ? Neon.violet.withValues(alpha: 0.55) : Neon.line;
    }
    final what = day.active ? 'done' : day.forgiven ? 'rest day' : today ? 'not yet' : 'quiet';
    return Semantics(
      label: '${date == null ? day.day : _dayNames[date.weekday - 1]}: $what',
      excludeSemantics: true,
      child: Column(
        children: [
          Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(shape: BoxShape.circle, color: fill, border: Border.all(color: edge, width: 2)),
            child: day.active
                ? Icon(Icons.check_rounded, size: 16, color: Neon.onAccent)
                : day.forgiven
                    ? Icon(Icons.spa_rounded, size: 14, color: Neon.violet)
                    : null,
          ),
          const SizedBox(height: 4),
          Text(letter,
              style: NeonType.manrope(NeonType.caption, today ? FontWeight.w800 : FontWeight.w500)
                  .copyWith(color: today ? Neon.textHi : Neon.textLo)),
        ],
      ),
    );
  }
}

class _TodaySection extends StatelessWidget {
  const _TodaySection({required this.summary});
  final MomentumSummary summary;

  @override
  Widget build(BuildContext context) {
    final s = summary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(child: GroupLabel("Today's 3")),
            Padding(
              padding: const EdgeInsets.only(right: 4, bottom: 6),
              child: MomentumRing(done: s.doneCount, total: MomentumService.maxPriorities, size: 36),
            ),
          ],
        ),
        GroupedCard(
          children: [
            for (final p in s.priorities)
              Padding(
                key: ValueKey('msp-${p.id}'),
                padding: const EdgeInsets.fromLTRB(14, 2, 4, 2),
                child: Row(
                  children: [
                    Expanded(child: MomentumPriorityRow(priority: p)),
                    IconButton(
                      tooltip: 'More',
                      onPressed: p.id > 0 ? () => showPriorityActions(context, p) : null,
                      icon: Icon(Icons.more_horiz_rounded, color: Neon.textDim),
                    ),
                  ],
                ),
              ),
            if (s.priorities.length < MomentumService.maxPriorities)
              AppleRow(
                leading: Icon(Icons.add_circle_outline_rounded, color: Neon.violet),
                title: s.priorities.isEmpty ? 'What are 3 wins for today?' : 'Add a win',
                subtitle: s.priorities.isEmpty ? 'Or just say "my top three today are…"' : null,
                onTap: () => addPriority(context),
              ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text('Tap to tick. Hold for edit, move to tomorrow or remove.',
              style: TextStyle(color: Neon.textLo, fontSize: NeonType.caption, height: 1.3)),
        ),
      ],
    );
  }
}

class _HabitsSection extends StatefulWidget {
  const _HabitsSection({required this.summary});
  final MomentumSummary summary;

  @override
  State<_HabitsSection> createState() => _HabitsSectionState();
}

class _HabitsSectionState extends State<_HabitsSection> {
  /// Swiped away, waiting for Undo to have its moment.
  final Set<int> _leaving = {};

  Future<void> _remove(MomentumHabit h) async {
    HapticFeedback.mediumImpact();
    setState(() => _leaving.add(h.id));
    final svc = MomentumService.instance;
    // Gone from the list at once; the server is told only when Undo has
    // had its moment.
    final reason = await AppFeedback.showUndo(context, 'Habit removed', onUndo: () {});
    if (reason == SnackBarClosedReason.action) {
      if (mounted) setState(() => _leaving.remove(h.id));
      return;
    }
    final ok = await svc.deleteHabit(h.id);
    if (mounted) setState(() => _leaving.remove(h.id));
    if (!ok && mounted) {
      AppFeedback.show(svc.lastError ?? "Couldn't remove it.", context: context, tone: FeedbackTone.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.summary;
    final habits = s.habits.where((h) => !_leaving.contains(h.id)).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const GroupLabel('Habits'),
        GroupedCard(
          dividerInset: 60,
          children: [
            for (final h in habits)
              _HabitRow(key: ValueKey('mh-${h.id}'), habit: h, onRemove: () => _remove(h)),
            if (s.habits.length < MomentumService.maxHabits)
              AppleRow(
                leading: Icon(Icons.add_circle_outline_rounded, color: Neon.violet),
                title: s.habits.isEmpty ? 'Add a small daily habit' : 'Add a habit',
                subtitle: s.habits.isEmpty ? 'Water, a walk, ten pages — tick it off each day' : null,
                onTap: () => showHabitSheet(context),
              ),
          ],
        ),
      ],
    );
  }
}

class _HabitRow extends StatelessWidget {
  const _HabitRow({super.key, required this.habit, required this.onRemove});
  final MomentumHabit habit;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final h = habit;
    final sub = [
      if (h.streak > 0) h.streak == 1 ? '1 day' : '${h.streak} days',
      if (h.best > h.streak) 'best ${h.best}',
      if (h.remindAt != null) 'reminder ${h.remindAt}',
    ].join(' · ');
    return Dismissible(
      key: ValueKey('dismiss-${h.id}'),
      direction: h.id > 0 ? DismissDirection.endToStart : DismissDirection.none,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        color: Neon.error.withValues(alpha: 0.18),
        child: Icon(Icons.delete_outline_rounded, color: Neon.errorInk),
      ),
      onDismissed: (_) => onRemove(),
      child: InkWell(
        onTap: h.id <= 0
            ? null
            : () async {
                HapticFeedback.selectionClick();
                final ok = await MomentumService.instance.toggleHabit(h.id);
                if (!ok && context.mounted) {
                  AppFeedback.show(MomentumService.instance.lastError ?? "Couldn't save that.",
                      context: context, tone: FeedbackTone.error);
                }
              },
        onLongPress: h.id <= 0 ? null : () => showHabitSheet(context, habit: h),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
          child: Row(
            children: [
              SizedBox(
                width: 34,
                child: Text(h.emoji.isEmpty ? '✅' : h.emoji,
                    textAlign: TextAlign.center, style: const TextStyle(fontSize: NeonType.title3)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(h.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: NeonType.row.copyWith(color: Neon.textHi)),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        for (var i = 0; i < 7; i++) ...[
                          if (i > 0) const SizedBox(width: 4),
                          Container(
                            width: 9,
                            height: 9,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: h.last7[i] ? Neon.violet : Neon.line,
                            ),
                          ),
                        ],
                        if (sub.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(sub,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: Neon.textLo, fontSize: NeonType.caption)),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              MomentumTick(done: h.doneToday, size: 28),
            ],
          ),
        ),
      ),
    );
  }
}

/// A small set, not a keyboard: the habits people actually keep.
const habitEmojis = ['💧', '🚶', '📖', '🧘', '💪', '😴', '✍️', '🍎', '🎯', '🙏', '📞', '✅'];

/// Add a habit (or, with [habit], edit one): name, emoji, reminder time.
Future<void> showHabitSheet(BuildContext context, {MomentumHabit? habit}) async {
  final result = await showAppSheet<_HabitDraft>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Neon.surface,
    builder: (_) => _HabitSheet(habit: habit),
  );
  if (result == null || !context.mounted) return;
  final svc = MomentumService.instance;
  final ok = habit == null
      ? await svc.addHabit(result.title, emoji: result.emoji, remindAt: result.remindAt)
      : await svc.updateHabit(habit.id,
          title: result.title,
          emoji: result.emoji,
          remindAt: result.remindAt,
          clearReminder: result.remindAt == null);
  if (!ok && context.mounted) {
    AppFeedback.show(svc.lastError ?? "Couldn't save that.", context: context, tone: FeedbackTone.error);
  }
}

class _HabitDraft {
  const _HabitDraft(this.title, this.emoji, this.remindAt);
  final String title;
  final String emoji;
  final String? remindAt;
}

class _HabitSheet extends StatefulWidget {
  const _HabitSheet({this.habit});
  final MomentumHabit? habit;

  @override
  State<_HabitSheet> createState() => _HabitSheetState();
}

class _HabitSheetState extends State<_HabitSheet> {
  late final TextEditingController _title = TextEditingController(text: widget.habit?.title ?? '');
  late String _emoji = widget.habit?.emoji.isNotEmpty == true ? widget.habit!.emoji : habitEmojis.first;
  late String? _remind = widget.habit?.remindAt;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  String _time(String hhmm) {
    final p = hhmm.split(':');
    final h = int.tryParse(p.first) ?? 0, m = int.tryParse(p.last) ?? 0;
    final h12 = h % 12 == 0 ? 12 : h % 12;
    return '$h12:${m.toString().padLeft(2, '0')} ${h < 12 ? 'am' : 'pm'}';
  }

  Future<void> _pickTime() async {
    final p = (_remind ?? '09:00').split(':');
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: int.tryParse(p.first) ?? 9, minute: int.tryParse(p.last) ?? 0),
    );
    if (t == null || !mounted) return;
    setState(() => _remind = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}');
  }

  void _save() {
    final t = _title.text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (t.isEmpty) return;
    Navigator.of(context).pop(_HabitDraft(t, _emoji, _remind));
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 20, 20, 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.habit == null ? 'New habit' : 'Edit habit',
                style: NeonType.cardTitle.copyWith(color: Neon.textHi)),
            const SizedBox(height: 12),
            TextField(
              controller: _title,
              autofocus: widget.habit == null,
              maxLength: 80,
              textCapitalization: TextCapitalization.sentences,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _save(),
              style: TextStyle(color: Neon.textHi, fontSize: NeonType.body),
              decoration: InputDecoration(
                hintText: 'e.g. Drink water',
                hintStyle: TextStyle(color: Neon.textDim),
                filled: true,
                fillColor: Neon.surfaceHigh,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(Neon.rMd), borderSide: BorderSide(color: Neon.line)),
                enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(Neon.rMd), borderSide: BorderSide(color: Neon.line)),
                focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(Neon.rMd), borderSide: BorderSide(color: Neon.violet)),
              ),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                for (final e in habitEmojis)
                  Semantics(
                    button: true,
                    selected: e == _emoji,
                    label: 'Emoji $e',
                    excludeSemantics: true,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(Neon.rSm),
                      onTap: () => setState(() => _emoji = e),
                      child: Container(
                        width: 48,
                        height: 48,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: e == _emoji ? Neon.violet.withValues(alpha: 0.16) : Colors.transparent,
                          borderRadius: BorderRadius.circular(Neon.rSm),
                          border: Border.all(color: e == _emoji ? Neon.violet : Colors.transparent),
                        ),
                        child: Text(e, style: const TextStyle(fontSize: NeonType.title3)),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.notifications_none_rounded, color: Neon.textLo, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(_remind == null ? 'No reminder' : 'Reminder at ${_time(_remind!)}',
                      style: TextStyle(color: Neon.textHi, fontSize: NeonType.body)),
                ),
                if (_remind != null)
                  IconButton(
                    tooltip: 'No reminder',
                    onPressed: () => setState(() => _remind = null),
                    icon: Icon(Icons.close_rounded, color: Neon.textLo),
                  ),
                TextButton(onPressed: _pickTime, child: Text(_remind == null ? 'Set time' : 'Change')),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text('Cancel', style: TextStyle(color: Neon.textLo)),
                ),
                const SizedBox(width: 6),
                FilledButton(
                  onPressed: _save,
                  style: FilledButton.styleFrom(
                    backgroundColor: Neon.violet,
                    foregroundColor: Neon.onAccent,
                    minimumSize: const Size(88, 48),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Neon.rPill)),
                  ),
                  child: Text(widget.habit == null ? 'Add' : 'Save'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _FocusSection extends StatelessWidget {
  const _FocusSection({required this.summary});
  final MomentumSummary summary;

  @override
  Widget build(BuildContext context) {
    final s = summary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const GroupLabel('Focus'),
        Container(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          decoration: BoxDecoration(
            color: Neon.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Neon.line),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Today ${_minutes(s.todayMin)} · This week ${_minutes(s.weekMin)}',
                  style: NeonType.manrope(NeonType.body, FontWeight.w600).copyWith(color: Neon.textHi)),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final m in const [15, 25, 45, 60])
                    OutlinedButton(
                      onPressed: () {
                        HapticFeedback.selectionClick();
                        Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) => FocusScreen(minutes: m, autoStart: true)));
                      },
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(64, 48),
                        foregroundColor: Neon.textHi,
                        side: BorderSide(color: Neon.violet.withValues(alpha: 0.5)),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Neon.rPill)),
                        textStyle: NeonType.manrope(NeonType.body, FontWeight.w700),
                      ),
                      child: Text('$m min'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Seven bars — wins as the bar, focus minutes under it — and the totals.
class _WeekSection extends StatelessWidget {
  const _WeekSection({required this.summary});
  final MomentumSummary summary;

  @override
  Widget build(BuildContext context) {
    final s = summary;
    final most = s.week.fold<int>(1, (a, d) => d.wins > a ? d.wins : a);
    final best = s.bestDay == null ? null : _parseDay(s.bestDay!);
    final totals = [
      s.weekWins == 1 ? '1 win' : '${s.weekWins} wins',
      '${_minutes(s.weekFocusMin)} focus',
      s.weekHabitsKept == 1 ? '1 habit kept' : '${s.weekHabitsKept} habits kept',
    ].join(' · ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const GroupLabel('This week'),
        Container(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          decoration: BoxDecoration(
            color: Neon.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Neon.line),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height: 110,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    for (final d in s.week)
                      Expanded(
                        child: Semantics(
                          label: '${_dayNames[(_parseDay(d.day)?.weekday ?? 1) - 1]}: '
                              '${d.wins} wins, ${_minutes(d.focusMin)} focus',
                          excludeSemantics: true,
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              Text(d.wins > 0 ? '${d.wins}' : '',
                                  style: NeonType.manrope(NeonType.caption, FontWeight.w700)
                                      .copyWith(color: Neon.textHi)),
                              const SizedBox(height: 2),
                              Container(
                                width: 18,
                                height: 6 + 54 * (d.wins / most),
                                decoration: BoxDecoration(
                                  color: d.wins > 0 ? Neon.violet : Neon.line,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                              ),
                              const SizedBox(height: 3),
                              // Focus as a short cyan line under the bar.
                              Container(
                                width: 18,
                                height: 4,
                                decoration: BoxDecoration(
                                  color: d.focusMin > 0 ? Neon.cyan : Colors.transparent,
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(_dayLetters[(_parseDay(d.day)?.weekday ?? 1) - 1],
                                  style: NeonType.manrope(NeonType.caption,
                                          d.day == s.day ? FontWeight.w800 : FontWeight.w500)
                                      .copyWith(color: d.day == s.day ? Neon.textHi : Neon.textLo)),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Text(totals, style: NeonType.manrope(NeonType.footnote, FontWeight.w600).copyWith(color: Neon.textHi)),
              if (best != null) ...[
                const SizedBox(height: 2),
                Text('Best day: ${_dayNames[best.weekday - 1]}',
                    style: TextStyle(color: Neon.textLo, fontSize: NeonType.footnote)),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _MilestonesSection extends StatelessWidget {
  const _MilestonesSection({required this.summary});
  final MomentumSummary summary;

  @override
  Widget build(BuildContext context) {
    final list = summary.milestones;
    if (list.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const GroupLabel('Milestones'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final m in list)
              Semantics(
                label: '${m.label}${m.earned ? ', earned' : ', not yet'}',
                excludeSemantics: true,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: m.earned ? Neon.violet.withValues(alpha: 0.14) : Neon.surface,
                    borderRadius: BorderRadius.circular(Neon.rPill),
                    border: Border.all(color: m.earned ? Neon.violet.withValues(alpha: 0.6) : Neon.line),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(m.earned ? Icons.emoji_events_rounded : Icons.lock_outline_rounded,
                          size: 16, color: m.earned ? Neon.violet : Neon.textDim),
                      const SizedBox(width: 6),
                      Text(m.label,
                          style: NeonType.manrope(NeonType.footnote, FontWeight.w600)
                              .copyWith(color: m.earned ? Neon.textHi : Neon.textLo)),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}
