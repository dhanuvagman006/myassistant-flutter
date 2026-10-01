import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/log.dart';
import '../../design/motion.dart';
import '../../design/neon_tokens.dart';
import '../../design/neon_widgets.dart';
import '../../models/reminder.dart';
import '../../services/api_service.dart';
import '../../services/app_feedback.dart';
import '../../services/avatar_message_service.dart';
import '../../services/brief_service.dart';
import '../../services/notification_service.dart';

/// What the pop-up's buttons do. The real ones by default; tests hand in
/// their own.
class ReminderPopupApi {
  const ReminderPopupApi();

  Future<bool> done(Reminder r) async =>
      await ApiService.sendJson('/reminders/${r.id}', method: 'PATCH', body: {'done': true}) != null;

  Future<bool> snooze(Reminder r, DateTime to) async =>
      await ApiService.sendJson('/reminders/${r.id}',
          method: 'PATCH', body: {'dueAt': to.millisecondsSinceEpoch}) !=
      null;

  /// The phone's alarms and Home follow the change.
  void changed() {
    unawaited(ReminderNotifications.instance.sync());
    unawaited(BriefService.instance.refresh(force: true));
  }
}

/// ─────────────────────────────────────────────────────────────────────────
///  THE REMINDER POP-UP (2026-09-30, owner: "need reminder pop up like this
///  style", with a "Today's focus" task card as the example). The day's
///  progress, the reminder as the one big card with Done and Snooze, what
///  is next, and the week with a dot on every day that has something. It
///  opens from the reminder's notification, and on its own when a reminder
///  comes due while the app is open.
/// ─────────────────────────────────────────────────────────────────────────
class ReminderPopup {
  ReminderPopup._();

  static bool _open = false;
  static final _shown = <int>{};
  static Timer? _next;
  static bool _watching = false;

  @visibleForTesting
  static ReminderPopupApi api = const ReminderPopupApi();

  /// "reminder:<id>" from a notification tap.
  static Future<void> openFromPayload(String what) async {
    final id = int.tryParse(what.substring(ReminderNotifications.reminderPayload.length));
    if (id == null) return;
    var all = ReminderNotifications.instance.synced.value;
    if (!all.any((r) => r.id == id)) all = await ReminderNotifications.instance.sync();
    final r = all.where((r) => r.id == id).firstOrNull;
    if (r == null) {
      AppLog.add('remind', 'pop-up: reminder #$id is gone');
      return;
    }
    await show(r, all: all);
  }

  /// Shows [focus] over whatever is on screen (the root navigator).
  static Future<void> show(Reminder focus, {List<Reminder>? all}) async {
    final ctx = AvatarMessageService.navigatorKey.currentContext;
    if (ctx == null || _open) return;
    _open = true;
    _shown.add(focus.id);
    HapticFeedback.mediumImpact();
    try {
      await showAppSheet<void>(
        context: ctx,
        isScrollControlled: true,
        useRootNavigator: true,
        backgroundColor: Colors.transparent,
        builder: (_) => ReminderPopupSheet(
          focus: focus,
          all: all ?? ReminderNotifications.instance.synced.value,
          api: api,
        ),
      );
    } finally {
      _open = false;
    }
  }

  /// While the app is open, the next reminder due pops up by itself (the
  /// notification still rings; this is the same moment, on screen).
  static void startWatching() {
    if (_watching) return;
    _watching = true;
    ReminderNotifications.instance.synced.addListener(_arm);
    _arm();
  }

  static void _arm() {
    _next?.cancel();
    final now = DateTime.now();
    final due = ReminderNotifications.instance.synced.value
        .where((r) => !r.done && r.dueAt != null && r.dueAt!.isAfter(now) && !_shown.contains(r.id))
        .toList()
      ..sort((a, b) => a.dueAt!.compareTo(b.dueAt!));
    if (due.isEmpty) return;
    final r = due.first;
    final wait = r.dueAt!.difference(now);
    if (wait > const Duration(hours: 12)) return; // re-armed by the next sync
    _next = Timer(wait, () {
      final foreground = WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
      if (foreground) unawaited(show(r));
      _shown.add(r.id);
      _arm();
    });
  }
}

class ReminderPopupSheet extends StatefulWidget {
  const ReminderPopupSheet({
    super.key,
    required this.focus,
    required this.all,
    this.api = const ReminderPopupApi(),
    this.clock = DateTime.now,
  });

  final Reminder focus;
  final List<Reminder> all;
  final ReminderPopupApi api;
  final DateTime Function() clock;

  @override
  State<ReminderPopupSheet> createState() => _ReminderPopupSheetState();
}

class _ReminderPopupSheetState extends State<ReminderPopupSheet> {
  late Reminder _focus = widget.focus;
  bool _done = false;

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  List<Reminder> get _today {
    final now = widget.clock();
    return [
      for (final r in widget.all)
        if (r.dueAt != null && _sameDay(r.dueAt!, now)) r,
    ];
  }

  Reminder? get _nextUp {
    final now = widget.clock();
    final list = [
      for (final r in widget.all)
        if (!r.done && r.id != _focus.id && r.dueAt != null && r.dueAt!.isAfter(now)) r,
    ]..sort((a, b) => a.dueAt!.compareTo(b.dueAt!));
    return list.firstOrNull;
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    final today = _today;
    final doneCount = today.where((r) => r.done || (_done && r.id == _focus.id)).length;
    final total = math.max(today.length, 1);
    final progress = doneCount / total;
    return Container(
      decoration: BoxDecoration(
        color: Neon.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(Neon.rXl)),
        border: Border(top: BorderSide(color: Neon.lineBright, width: 1.2)),
        boxShadow: Neon.halo(Neon.violet, strength: 0.6),
      ),
      padding: EdgeInsets.fromLTRB(18, 10, 18, 18 + bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                  color: Neon.lineBright, borderRadius: BorderRadius.circular(2)),
            ),
          ),
          const SizedBox(height: 14),
          _progressRow(progress, doneCount, today.length),
          const SizedBox(height: 14),
          _focusCard(),
          if (_nextUp != null) ...[
            const SizedBox(height: 12),
            _nextRow(_nextUp!),
          ],
          const SizedBox(height: 18),
          _week(),
        ],
      ),
    );
  }

  // ── today's progress ─────────────────────────────────────────────────
  Widget _progressRow(double p, int done, int total) {
    return Semantics(
      label: 'Today: $done of $total reminders done',
      child: ExcludeSemantics(
        child: Row(
          children: [
            SizedBox(
              width: 26,
              height: 26,
              child: TweenAnimationBuilder<double>(
                tween: Tween(end: p),
                duration: const Duration(milliseconds: 500),
                curve: Motion.easeMove,
                builder: (_, v, __) => CustomPaint(painter: _Ring(v)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                  total == 0 ? "Today's reminders" : '$done of $total done today',
                  style: NeonType.manrope(NeonType.body, FontWeight.w600)
                      .copyWith(color: Neon.textHi)),
            ),
            Text('${(p * 100).round()}%',
                style: NeonType.manrope(NeonType.body, FontWeight.w700)
                    .copyWith(color: Neon.cyan)),
          ],
        ),
      ),
    );
  }

  // ── the reminder ─────────────────────────────────────────────────────
  Widget _focusCard() {
    final r = _focus;
    final now = widget.clock();
    final at = r.dueAt;
    return GlowCard(
      tone: _done ? NeonTone.success : NeonTone.brand,
      halo: 1,
      radius: Neon.rXl,
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(r.isAlarm ? 'Wake-up reminder' : 'Reminder',
                  style: TextStyle(color: Neon.textLo, fontSize: NeonType.footnote)),
              const Spacer(),
              if (at != null)
                Row(
                  children: [
                    Icon(Icons.schedule_rounded, size: 16, color: Neon.textLo),
                    const SizedBox(width: 4),
                    Text(_clock(at),
                        style: TextStyle(color: Neon.textLo, fontSize: NeonType.footnote)),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 14),
          Text(r.text,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: NeonType.manrope(28, FontWeight.w700).copyWith(
                  color: Neon.textHi,
                  height: 1.15,
                  decoration: _done ? TextDecoration.lineThrough : null,
                  decorationColor: Neon.textLo)),
          const SizedBox(height: 8),
          Text(_done ? 'Done — nicely handled.' : _when(at, now),
              style: TextStyle(color: Neon.textLo, fontSize: NeonType.body, height: 1.4)),
          const SizedBox(height: 22),
          // Side by side when they fit; the second wraps under the first
          // with large text rather than overflowing.
          Wrap(
            spacing: 10,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _DoneButton(done: _done, onTap: _done ? null : _markDone),
              // Ten minutes; the toast says until when.
              if (!_done)
                NeonPill(
                  label: 'Snooze',
                  icon: Icons.snooze_rounded,
                  tone: NeonTone.info,
                  onPressed: _snooze,
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _nextRow(Reminder n) {
    return Tappable(
      semanticLabel: 'Next up: ${n.text}, ${_clock(n.dueAt!)}',
      onTap: () => setState(() {
        _focus = n;
        _done = false;
      }),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          color: Neon.surfaceHigh,
          borderRadius: BorderRadius.circular(Neon.rMd),
          border: Border.all(color: Neon.line),
        ),
        child: Row(
          children: [
            Text('Next up', style: TextStyle(color: Neon.textLo, fontSize: NeonType.footnote)),
            const SizedBox(width: 12),
            Expanded(
              child: Text(n.text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: NeonType.manrope(NeonType.body, FontWeight.w600)
                      .copyWith(color: Neon.textHi)),
            ),
            const SizedBox(width: 8),
            Text(_clock(n.dueAt!),
                style: TextStyle(color: Neon.cyan, fontSize: NeonType.footnote, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }

  // ── this week ────────────────────────────────────────────────────────
  Widget _week() {
    final now = widget.clock();
    final monday = DateTime(now.year, now.month, now.day).subtract(Duration(days: now.weekday - 1));
    final days = [for (var i = 0; i < 7; i++) monday.add(Duration(days: i))];
    const letters = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final end = days.last;
    final range = monday.month == end.month
        ? '${months[monday.month - 1]} ${monday.day}–${end.day}'
        : '${months[monday.month - 1]} ${monday.day} – ${months[end.month - 1]} ${end.day}';
    int open(DateTime d) => widget.all
        .where((r) => !r.done && r.dueAt != null && _sameDay(r.dueAt!, d))
        .length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text('This week', style: TextStyle(color: Neon.textLo, fontSize: NeonType.footnote)),
            const Spacer(),
            Text(range,
                style: NeonType.manrope(NeonType.footnote, FontWeight.w700)
                    .copyWith(color: Neon.textHi)),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            for (var i = 0; i < 7; i++)
              Expanded(
                child: Semantics(
                  label: '${letters[i]} ${days[i].day}: ${open(days[i])} reminders',
                  child: ExcludeSemantics(
                    child: _Day(
                      letter: letters[i],
                      day: days[i].day,
                      today: _sameDay(days[i], now),
                      dots: math.min(open(days[i]), 3),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }

  // ── actions: on the touch, the server behind ─────────────────────────
  Future<void> _markDone() async {
    HapticFeedback.lightImpact();
    setState(() => _done = true);
    final ok = await widget.api.done(_focus);
    if (!mounted) return;
    if (!ok) {
      setState(() => _done = false);
      AppFeedback.showRetry("Couldn't mark it done. Check your connection.",
          context: context, onRetry: _markDone);
      return;
    }
    widget.api.changed();
    await Future<void>.delayed(const Duration(milliseconds: 700));
    if (mounted) Navigator.of(context).maybePop();
  }

  Future<void> _snooze() async {
    HapticFeedback.lightImpact();
    final to = widget.clock().add(const Duration(minutes: 10));
    final r = _focus;
    final api = widget.api;
    Navigator.of(context).maybePop();
    AppFeedback.show('Snoozed until ${_clock(to)}', tone: FeedbackTone.success);
    final ok = await api.snooze(r, to);
    if (ok) {
      api.changed();
    } else {
      AppFeedback.toast("Couldn't snooze it. Check your connection.", tone: FeedbackTone.error);
    }
  }

  static String _clock(DateTime t) {
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    return '$h:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'am' : 'pm'}';
  }

  static String _when(DateTime? at, DateTime now) {
    if (at == null) return 'No time set';
    final m = at.difference(now).inMinutes;
    if (m.abs() <= 1) return 'Due now';
    if (m > 0) return m < 60 ? 'In $m minutes' : 'In ${(m / 60).round()} hours';
    final ago = -m;
    return ago < 60 ? '$ago minutes ago' : '${(ago / 60).round()} hours ago';
  }
}

/// The big button: the brand's light, a white tick in a ring.
class _DoneButton extends StatelessWidget {
  const _DoneButton({required this.done, this.onTap});
  final bool done;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    // Deepened a fifth toward the night so the white words read (AA).
    final fill = [
      for (final c in done ? NeonTone.success.rim : [Neon.violet, Neon.pink])
        Color.lerp(c, Neon.bg, 0.22)!,
    ];
    return Tappable(
      onTap: onTap,
      semanticLabel: done ? 'Done' : 'Mark done',
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        height: 52,
        padding: const EdgeInsets.fromLTRB(6, 6, 20, 6),
        decoration: BoxDecoration(
          gradient: LinearGradient(colors: fill),
          borderRadius: BorderRadius.circular(Neon.rPill),
          boxShadow: Neon.halo(fill.first, strength: 0.9),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Neon.bg.withValues(alpha: 0.35),
                border: Border.all(color: Neon.textHi.withValues(alpha: 0.7), width: 1.5),
              ),
              child: Icon(Icons.check_rounded, color: Neon.textHi, size: 22),
            ),
            const SizedBox(width: 10),
            Text(done ? 'Done' : 'Mark done',
                style: NeonType.manrope(NeonType.body + 2, FontWeight.w800).copyWith(
                  color: Neon.textHi,
                  shadows: [Shadow(color: Neon.bg.withValues(alpha: 0.45), blurRadius: 6)],
                )),
          ],
        ),
      ),
    );
  }
}

class _Day extends StatelessWidget {
  const _Day({required this.letter, required this.day, required this.today, required this.dots});
  final String letter;
  final int day;
  final bool today;
  final int dots;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 3),
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: today
          ? BoxDecoration(
              color: Neon.cyan.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(Neon.rMd),
              border: Border.all(color: Neon.cyan.withValues(alpha: 0.65)),
              boxShadow: Neon.halo(Neon.cyan, strength: 0.4),
            )
          : null,
      child: Column(
        children: [
          Text(letter,
              style: TextStyle(
                  color: today ? Neon.cyan : Neon.textDim,
                  fontSize: NeonType.caption,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text('$day',
              style: NeonType.manrope(18, FontWeight.w700)
                  .copyWith(color: today ? Neon.textHi : Neon.textLo)),
          const SizedBox(height: 6),
          SizedBox(
            height: 5,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < dots; i++)
                  Container(
                    width: 5,
                    height: 5,
                    margin: const EdgeInsets.symmetric(horizontal: 1.5),
                    decoration: BoxDecoration(shape: BoxShape.circle, color: Neon.pink),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Today's progress: a ring filling cyan into violet.
class _Ring extends CustomPainter {
  _Ring(this.p);
  final double p;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(2.5);
    canvas.drawArc(
        rect,
        0,
        math.pi * 2,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3.5
          ..color = Neon.line);
    if (p <= 0) return;
    canvas.drawArc(
        rect,
        -math.pi / 2,
        math.pi * 2 * p.clamp(0, 1),
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3.5
          ..strokeCap = StrokeCap.round
          ..shader = SweepGradient(
            startAngle: -math.pi / 2,
            endAngle: math.pi * 1.5,
            colors: [Neon.cyan, Neon.violet, Neon.cyan],
          ).createShader(rect));
  }

  @override
  bool shouldRepaint(_Ring old) => old.p != p;
}
