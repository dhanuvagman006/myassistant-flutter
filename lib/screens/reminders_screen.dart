import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/log.dart';
import '../design/apple_kit.dart';
import '../design/neon_tokens.dart';
import '../design/neon_widgets.dart';
import '../models/reminder.dart';
import '../services/api_service.dart';
import '../services/app_feedback.dart';
import '../services/brief_service.dart';
import '../services/notification_service.dart';
import '../design/motion.dart';
import '../widgets/neon_cards.dart';

/// REMINDERS — every reminder in one place.
///
/// Until now reminders lived only as the first six items on Home: there
/// was nowhere to see them all, add one without speaking, or tick one off
/// later. This lists them by when they are due, adds by typing with quick
/// times, ticks off with a tap and removes with a swipe — each undoable.
class RemindersScreen extends StatefulWidget {
  const RemindersScreen({super.key, this.loader = ApiService.fetchReminders});

  /// Where the list comes from — the server, or a test's own list.
  final Future<List<Reminder>> Function() loader;

  @override
  State<RemindersScreen> createState() => _RemindersScreenState();
}

class _RemindersScreenState extends State<RemindersScreen> {
  List<Reminder>? _items;
  String? _error;
  bool _showDone = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final items = await widget.loader();
      if (!mounted) return;
      setState(() {
        _items = items;
        _error = null;
      });
    } catch (_) {
      if (!mounted) return;
      if (_items == null) {
        setState(() => _error = "Couldn't load your reminders");
      } else {
        AppFeedback.show("Couldn't refresh.",
            context: context, tone: FeedbackTone.error);
      }
    }
  }

  /// Home and the phone's own alarms follow the list.
  void _afterChange() {
    unawaited(BriefService.instance.refresh(force: true));
    unawaited(ReminderNotifications.instance.sync());
  }

  /// The change is shown at once and SENT when the Undo toast closes — it
  /// now closes on its own after 4 s (an action toast used to stay until
  /// swiped, holding the change back and every later toast behind it).
  ///
  /// [commit] throws when the server did not confirm: the list is put back
  /// (via [undo]) and the toast offers [retry].
  void _snack(String text,
      {VoidCallback? undo,
      Future<void> Function()? commit,
      String? failed,
      VoidCallback? retry}) {
    void send() => commit!().then((_) => _afterChange()).catchError((Object e) {
          AppLog.add('reminders', '$text -> $e');
          if (!mounted) return;
          undo?.call();
          AppFeedback.showRetry('${failed ?? "Couldn't save that."} Check your connection.',
              context: context, onRetry: retry ?? () {});
        });
    if (undo == null) {
      AppFeedback.show(text, context: context, tone: FeedbackTone.success);
      if (commit != null) send();
      return;
    }
    AppFeedback.showUndo(context, text, onUndo: undo).then((r) {
      if (r != SnackBarClosedReason.action && commit != null) send();
    });
  }

  Reminder _with(Reminder r, {required bool done}) => Reminder(
      id: r.id, text: r.text, dueAt: r.dueAt, done: done, ring: r.ring, deliver: r.deliver);

  void _toggleDone(Reminder r) {
    HapticFeedback.mediumImpact();
    final items = _items!;
    final i = items.indexOf(r);
    setState(() => items[i] = _with(r, done: !r.done));
    final nowDone = !r.done;
    _snack(nowDone ? 'Done — nice.' : 'Moved back to your list',
        undo: () => setState(() {
              final j = items.indexWhere((x) => x.id == r.id);
              if (j >= 0) items[j] = r;
            }),
        failed: "Couldn't update that reminder.",
        retry: () {
          final j = items.indexWhere((x) => x.id == r.id);
          if (j >= 0) _toggleDone(items[j]);
        },
        commit: () => ApiService.setReminderDone(r.id, nowDone));
  }

  void _delete(Reminder r) {
    HapticFeedback.mediumImpact();
    final items = _items!;
    final i = items.indexOf(r);
    setState(() => items.removeAt(i));
    _snack('Reminder removed',
        undo: () => setState(() => items.insert(i.clamp(0, items.length), r)),
        failed: "Couldn't remove that reminder.",
        retry: () {
          if (mounted && _items != null && _items!.contains(r)) _delete(r);
        },
        commit: () => ApiService.deleteReminder(r.id));
  }

  Future<void> _create() async {
    // The theme's sheet (2026-09-30): the lit rim, the night scrim and the
    // handle, instead of a flat 20 dp local shape.
    final made = await showAppSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _NewReminderSheet(),
    );
    if (made == true) {
      await _load();
      _afterChange();
      if (mounted) _snack('Reminder set');
    }
  }

  @override
  Widget build(BuildContext context) {
    // The night sky under the list (2026-09-30), and the theme's lit FAB:
    // the page's one primary action glows.
    return NeonScaffold(
      appBar: appleAppBar(context, 'Reminders'),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _create,
        icon: const Icon(Icons.add_rounded),
        label: const Text('New reminder'),
      ),
      body: SafeArea(child: StateSwitch.of(_body())),
    );
  }

  Widget _body() {
    if (_error != null) {
      return NeonErrorState(
        message: _error!,
        onRetry: () {
          setState(() => _error = null);
          _load();
        },
      );
    }
    final items = _items;
    if (items == null) return const NeonLoader.page();

    final groups = groupReminders(items, DateTime.now());
    final open = groups.entries.where((e) => e.key != 'Done' && e.value.isNotEmpty);
    final done = groups['Done'] ?? const [];
    if (open.isEmpty && done.isEmpty) {
      return RefreshIndicator(
        color: Neon.violet,
        onRefresh: _load,
        child: ListView(children: [
          const SizedBox(height: 80),
          NeonEmptyState(
            icon: Icons.notifications_none_rounded,
            title: 'No reminders yet',
            body: 'Say "remind me to call the bank at 5", or tap New reminder.',
            actionLabel: 'New reminder',
            actionIcon: Icons.add_rounded,
            onAction: _create,
          ),
        ]),
      );
    }
    return RefreshIndicator(
      color: Neon.violet,
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
        children: [
          for (final g in open) ...[
            GroupLabel(g.key),
            ...g.value.map(_tile),
            const SizedBox(height: 18),
          ],
          if (done.isNotEmpty) ...[
            TextButton.icon(
              onPressed: () => setState(() => _showDone = !_showDone),
              icon: ExpandChevron(open: _showDone, color: Neon.textLo),
              label: Text('${_showDone ? 'Hide' : 'Show'} done (${done.length})',
                  style: TextStyle(color: Neon.textLo)),
            ),
            Collapse(
              open: _showDone,
              child: Column(children: [...done.take(30).map(_tile)]),
            ),
          ],
        ],
      ),
    );
  }

  Widget _tile(Reminder r) {
    final now = DateTime.now();
    final overdue = !r.done && r.dueAt != null && r.dueAt!.isBefore(now);
    final content = Row(
      children: [
        Semantics(
          button: true,
          label: r.done ? 'Mark not done' : 'Mark done',
          child: PressScale(
            scale: 0.9,
            child: InkResponse(
              onTap: () => _toggleDone(r),
              radius: 26,
              child: SizedBox(
                width: 52,
                height: 56,
                child: Icon(
                  r.done ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                  color: r.done ? Neon.success : Neon.violet,
                  size: 22,
                ),
              ),
            ),
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  r.text,
                  style: NeonType.manrope(NeonType.callout, FontWeight.w500).copyWith(
                    color: r.done ? Neon.textDim : Neon.textHi,
                    height: 1.3,
                    decoration: r.done ? TextDecoration.lineThrough : null,
                  ),
                ),
                if (r.dueAt != null) ...[
                  const SizedBox(height: 3),
                  Text(
                    dueLabel(r.dueAt!, now),
                    // warningInk: amber words were 3.19:1 on white — the
                    // most urgent line on the page, and the faintest.
                    style: NeonType.manrope(NeonType.footnote,
                            overdue ? FontWeight.w600 : FontWeight.w400)
                        .copyWith(
                      color: overdue ? Neon.warningInk : Neon.textLo,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (r.calls && !r.done)
          Tooltip(
            message: 'Your assistant will call you',
            child: Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Icon(Icons.phone_in_talk_rounded, size: 18, color: Neon.cyan),
            ),
          ),
        if (r.isAlarm && !r.done)
          Tooltip(
            message: 'Rings like an alarm',
            child: Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Icon(Icons.alarm_rounded, size: 18, color: Neon.pink),
            ),
          ),
        const SizedBox(width: 14),
      ],
    );
    // DUE NOW GLOWS (2026-09-30, the client's neon direction): a reminder
    // whose time has come is the thing to act on, so it is lit in the
    // action tone; the rest sit on the quiet raised card.
    final Widget card = isDueNow(r, now)
        ? GlowCard(
            tone: NeonTone.action,
            radius: Neon.rMd,
            halo: 0.6,
            rimWidth: 1.8,
            child: content)
        : RimCard(padding: EdgeInsets.zero, child: content);
    return Dismissible(
      key: ValueKey('reminder-${r.id}-${r.done}'),
      background: _swipe(Alignment.centerLeft),
      secondaryBackground: _swipe(Alignment.centerRight),
      onDismissed: (_) => _delete(r),
      child: Padding(padding: const EdgeInsets.only(bottom: 8), child: card),
    );
  }

  static Widget _swipe(Alignment a) => Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 18),
        alignment: a,
        decoration: BoxDecoration(
          color: Neon.error.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(Neon.rMd),
        ),
        child: Icon(Icons.delete_outline_rounded, color: Neon.error, size: 20),
      );
}

/// Due now: not done, and its time has come or comes within 15 minutes —
/// the reminders lit on the list. Public for tests.
bool isDueNow(Reminder r, DateTime now) =>
    !r.done &&
    r.dueAt != null &&
    r.dueAt!.isBefore(now.add(const Duration(minutes: 15)));

/// Sections, in the order a busy day reads them. Public for tests.
Map<String, List<Reminder>> groupReminders(List<Reminder> all, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  final tomorrow = today.add(const Duration(days: 1));
  final dayAfter = today.add(const Duration(days: 2));
  final out = <String, List<Reminder>>{
    'Overdue': [], 'Today': [], 'Tomorrow': [], 'Later': [], 'Anytime': [], 'Done': [],
  };
  for (final r in all) {
    final d = r.dueAt;
    if (r.done) {
      out['Done']!.add(r);
    } else if (d == null) {
      out['Anytime']!.add(r);
    } else if (d.isBefore(now)) {
      out['Overdue']!.add(r);
    } else if (d.isBefore(tomorrow)) {
      out['Today']!.add(r);
    } else if (d.isBefore(dayAfter)) {
      out['Tomorrow']!.add(r);
    } else {
      out['Later']!.add(r);
    }
  }
  int byDue(Reminder a, Reminder b) =>
      (a.dueAt ?? DateTime(9999)).compareTo(b.dueAt ?? DateTime(9999));
  for (final k in ['Overdue', 'Today', 'Tomorrow', 'Later']) {
    out[k]!.sort(byDue);
  }
  return out;
}

/// "Today, 5:00 pm" · "Tomorrow, 9:00 am" · "Wed, 4:30 pm" · "3 Oct, 10:00 am".
String dueLabel(DateTime d, DateTime now) {
  const wk = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const mo = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  final time = '$h:${d.minute.toString().padLeft(2, '0')} ${d.hour < 12 ? 'am' : 'pm'}';
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(d.year, d.month, d.day);
  final diff = day.difference(today).inDays;
  if (diff == 0) return 'Today, $time';
  if (diff == 1) return 'Tomorrow, $time';
  if (diff == -1) return 'Yesterday, $time';
  if (diff > 1 && diff < 7) return '${wk[d.weekday - 1]}, $time';
  return '${d.day} ${mo[d.month - 1]}, $time';
}

class _NewReminderSheet extends StatefulWidget {
  const _NewReminderSheet();

  @override
  State<_NewReminderSheet> createState() => _NewReminderSheetState();
}

class _NewReminderSheetState extends State<_NewReminderSheet> {
  final _text = TextEditingController();
  DateTime? _when;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  List<(String, DateTime)> _quick() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return [
      ('In 1 hour', now.add(const Duration(hours: 1))),
      if (now.hour < 18) ('This evening', today.add(const Duration(hours: 19))),
      ('Tomorrow 9 am', today.add(const Duration(days: 1, hours: 9))),
    ];
  }

  Future<void> _pick() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: _when ?? now,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: now.add(const Duration(days: 365 * 3)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_when ?? now.add(const Duration(hours: 1))),
    );
    if (time == null) return;
    setState(() => _when = DateTime(date.year, date.month, date.day, time.hour, time.minute));
  }

  Future<void> _save() async {
    final text = _text.text.trim();
    if (text.isEmpty || _saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ApiService.createReminder(text, _when);
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = "Couldn't save it — check your connection.";
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 18, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('New reminder', style: NeonType.cardTitle.copyWith(color: Neon.textHi)),
          const SizedBox(height: 12),
          TextField(
            controller: _text,
            autofocus: true,
            textCapitalization: TextCapitalization.sentences,
            style: TextStyle(color: Neon.textHi),
            decoration: const InputDecoration(hintText: 'What should I remind you about?'),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (label, at) in _quick())
                ChoiceChip(
                  label: Text(label),
                  selected: _when == at,
                  onSelected: (_) => setState(() => _when = at),
                ),
              ActionChip(
                avatar: const Icon(Icons.event_rounded, size: 18),
                label: Text(_when == null || _quick().any((q) => q.$2 == _when)
                    ? 'Pick date & time'
                    : dueLabel(_when!, now)),
                onPressed: _pick,
              ),
              if (_when != null)
                ActionChip(
                  avatar: const Icon(Icons.close_rounded, size: 18),
                  label: const Text('No time'),
                  onPressed: () => setState(() => _when = null),
                ),
            ],
          ),
          if (_when != null) ...[
            const SizedBox(height: 10),
            Text('Reminds you ${dueLabel(_when!, now).replaceFirst(',', ' at')}',
                style: TextStyle(color: Neon.textLo, fontSize: NeonType.footnote)),
          ],
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!, style: TextStyle(color: Neon.errorInk, fontSize: NeonType.footnote)),
          ],
          const SizedBox(height: 16),
          // The theme's lit primary button (2026-09-30): the sheet's one
          // strong glow.
          FilledButton(
            onPressed: _text.text.trim().isEmpty || _saving ? null : _save,
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
            child: _saving
                ? const NeonLoader.inline(size: 20, semanticLabel: 'Saving')
                : const Text('Save reminder'),
          ),
        ],
      ),
    );
  }
}
