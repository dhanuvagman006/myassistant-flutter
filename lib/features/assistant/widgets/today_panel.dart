import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../design/motion.dart';
import '../../../design/neon_tokens.dart';
import '../../../models/brief.dart';
import '../../../widgets/month_calendar.dart';
import '../../../widgets/whats_new_card.dart';
import '../../../services/api_service.dart';
import '../../../services/brief_service.dart';
import '../state/assistant_engine.dart';
import '../../../services/app_feedback.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  TODAY — the Home tab's feed: suggestions that fit the hour, messages
///  other people's assistants left for you, the agenda (reminders and
///  meetings), promises Hari heard you make, and the month. Quick actions
///  feed straight into the running conversation, so the page and the
///  voice agent are one system.
///
///  The collapsed "Today" pill, its blurred sheet and the person sheet
///  were removed on 2026-09-24: none of them could be reached any more,
///  and each blurred everything behind it on every frame, under a surface
///  90% opaque that hid most of the blur anyway. If one comes back, give
///  it an opaque Neon.surface and no BackdropFilter.
/// ─────────────────────────────────────────────────────────────────────────
class _KeepAlive extends StatefulWidget {
  const _KeepAlive({required this.child});
  final Widget child;

  @override
  State<_KeepAlive> createState() => _KeepAliveState();
}

class _KeepAliveState extends State<_KeepAlive>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

/// The whole day as a scrollable feed: the Home dashboard tab.
class TodayBriefBody extends StatelessWidget {
  final bool showHeader;
  final EdgeInsets padding;

  /// Scrolls as the first item of the feed (Home's greeting and quote).
  final Widget? leading;
  const TodayBriefBody({
    super.key,
    this.showHeader = false,
    this.leading,
    // 120 at the bottom, not 28: the floating mic and the dock sit OVER
    // this list, and the last card was being cut in half by them.
    this.padding = const EdgeInsets.fromLTRB(20, 10, 20, 120),
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
            animation: BriefService.instance,
            builder: (context, _) {
              final svc = BriefService.instance;
              final b = svc.brief;
              return ListView(
                shrinkWrap: true,
                padding: padding,
                children: [
                  // Kept alive: scrolled away and back, it must not replay
                  // its entrance animation.
                  if (leading != null) ...[
                    _KeepAlive(child: leading!),
                    const SizedBox(height: 14),
                  ],
                  if (showHeader) _header(b),
                  const SizedBox(height: 16),
                  // Staggered entrance, top to bottom — the page settles
                  // in once; brief refreshes never replay it (Reveal
                  // keeps its state across rebuilds).
                  // The three action tiles are gone (2026-09-19): the
                  // quote now sits under the date in the header, and the
                  // suggestions below do the same job without shouting.
                  // WHAT ELSE IT CAN DO, at the moment it is useful.
                  // People use the two things they discovered on day one
                  // unless something shows them the rest; these rotate
                  // with the clock so the app stays worth opening.
                  // Once per release, on Home only: what just got better.
                  if (!showHeader) const WhatsNewCard(),
                  Reveal(delayMs: 40, child: _tryAsking(context)),
                  const SizedBox(height: 20),
                  if (!svc.loaded && svc.failed)
                    // Offline with nothing saved yet: say so, and offer the
                    // retry — a spinner here used to turn forever.
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 28),
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.cloud_off_rounded,
                                color: Neon.textLo, size: 28),
                            const SizedBox(height: 10),
                            Text("Couldn't load your day — check your connection.",
                                textAlign: TextAlign.center,
                                style: TextStyle(color: Neon.textLo, fontSize: 14)),
                            const SizedBox(height: 8),
                            TextButton.icon(
                              onPressed: () => svc.refresh(force: true),
                              icon: const Icon(Icons.refresh_rounded, size: 18),
                              label: const Text('Try again'),
                            ),
                          ],
                        ),
                      ),
                    )
                  else if (!svc.loaded)
                    // The shape of what is coming, not a spinner: the
                    // first load reads as the page arriving, not waiting.
                    const _SkeletonTiles()
                  else ...[
                    if (b.messages.isNotEmpty)
                      Reveal(
                        delayMs: 60,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _sectionTitle(Icons.mark_email_unread_rounded,
                                'Messages for you', Neon.cyan),
                            ...b.messages.take(4).map(_messageTile),
                            const SizedBox(height: 18),
                          ],
                        ),
                      ),
                    Reveal(
                      delayMs: 100,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _sectionTitle(Icons.event_note_rounded,
                              'Today’s agenda', Neon.violet),
                          if (b.agenda.isEmpty)
                            _emptyLine('Nothing scheduled — enjoy the calm.',
                                icon: Icons.wb_sunny_rounded,
                                tint: Neon.warning)
                          else
                            ...b.agenda.take(6).map((a) => _agendaTile(context, a)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 18),
                    Reveal(
                      delayMs: 160,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _sectionTitle(Icons.handshake_rounded,
                              'Promises you made', Neon.pink),
                          if (b.promises.isEmpty)
                            _emptyLine('No open promises. Clean slate.')
                          else
                            ...b.promises.take(5).map((p) => _promiseTile(context, p)),
                        ],
                      ),
                    ),
                    // The month at a glance — everything the user has told
                    // their agent about, on the day it happens. News lives
                    // in the Updates tab now; Home is the user's own life.
                    const SizedBox(height: 18),
                    const Reveal(delayMs: 220, child: MonthCalendar()),

                  ],
                ],
              );
            });
  }

  Widget _header(TodayBrief b) {
    final now = DateTime.now();
    const wk = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const mo = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Today',
                style: TextStyle(
                    color: Neon.textHi,
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.4)),
            const SizedBox(height: 2),
            Text(
              '${wk[now.weekday - 1]}, ${mo[now.month - 1]} ${now.day}',
              style: TextStyle(color: Neon.textLo, fontSize: 13),
            ),
            if (b.screenTime != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.timelapse_rounded,
                        size: 12, color: Neon.textDim),
                    const SizedBox(width: 4),
                    Text(b.screenTime!,
                        style: TextStyle(
                            color: Neon.textDim, fontSize: NeonType.caption)),
                  ],
                ),
              ),
          ],
        ),
        const Spacer(),
        if (b.weatherLine != null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: Neon.cyan.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(Neon.rPill),
              border: Border.all(color: Neon.cyan.withValues(alpha: 0.28)),
            ),
            child: Text(
              b.weatherLine!,
              style: TextStyle(
                  color: Neon.textHi, fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
      ],
    );
  }

  /// The dashboard drives the CONVERSATION — each action hands a request to
  /// whichever session (live or classic) currently owns the audio, so the
  /// buttons and the voice agent are one brain, not two features.
  /// Three suggestions that fit the hour. Tapping runs the request for
  /// real — these are shortcuts, not screenshots of features.
  Widget _tryAsking(BuildContext context) {
    final h = DateTime.now().hour;
    final ideas = h < 12
        ? const [
            ('Brief me for today', 'Give me my brief for today.'),
            ('What is on my calendar?', 'What is on my calendar today?'),
            ('Remind me tonight', 'Remind me tonight at 8 to plan tomorrow.'),
          ]
        : h < 17
            ? const [
                ('What did I promise?', 'What have I promised anyone recently?'),
                ('Any mail worth reading?', 'Any important mail I should know about?'),
                ('Track an expense', 'I spent money today — note it for me.'),
              ]
            : const [
                ('Summarise my day', 'Summarise what happened today for me.'),
                ('What is tomorrow like?', 'What does my day tomorrow look like?'),
                ('Write an email', 'I want to send an email — ask me the details.'),
              ];
    // 48 DP TO THE FINGER, 34 TO THE EYE (2026-09-24). The chips were 34
    // dp tall with a bare GestureDetector: the most-used shortcut on the
    // first screen was a small target. The row is now 48 tall and every
    // chip takes the whole height; the chip itself looks the same.
    //
    // Clip.none: clipped at the page padding, the third chip was sliced
    // through its border 20 dp short of the screen edge, which looked
    // like a rendering fault rather than "scroll for more".
    return SizedBox(
      height: 48,
      child: ListView.separated(
        clipBehavior: Clip.none,
        scrollDirection: Axis.horizontal,
        itemCount: ideas.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, i) => PressScale(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              HapticFeedback.selectionClick();
              final nav = Navigator.of(context);
              if (nav.canPop()) nav.pop();
              AssistantEngine.instance.askAssistant(ideas[i].$2);
            },
            child: SizedBox(
              height: 48,
              child: Center(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
                  decoration: BoxDecoration(
                    color: Neon.violet.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(Neon.rPill),
                    border: Border.all(
                        color: Neon.violet.withValues(alpha: 0.28)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.graphic_eq_rounded,
                          size: 13, color: Neon.violet),
                      const SizedBox(width: 6),
                      Text(ideas[i].$1,
                          style: NeonType.manrope(
                                  NeonType.footnote, FontWeight.w600)
                              .copyWith(color: Neon.textHi)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _sectionTitle(IconData icon, String title, Color tint) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          children: [
            // The tint was passed in and then ignored — every header icon
            // painted white, which is a good part of why the page read
            // flat. Small tinted squares, same language as the Hub.
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                gradient: Neon.tile(tint),
                borderRadius: BorderRadius.circular(9),
              ),
              // Dark ink on the evening pastels (Neon.onTile).
              child: Icon(icon, size: 15, color: Neon.onTile(tint)),
            ),
            const SizedBox(width: 10),
            // Bold for real (NeonType): it drew from the regular file,
            // no heavier than the cards under it.
            Text(title,
                style: NeonType.sectionTitle.copyWith(color: Neon.textHi)),
          ],
        ),
      );

  /// An empty section still deserves a warm line, not gray silence.
  Widget _emptyLine(String text,
          {IconData icon = Icons.check_circle_rounded, Color? tint}) =>
      // Flush with the section header above and the calendar below: the
      // extra 4 dp on the left made these the only indented cards on Home.
      Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: Neon.surface,
            borderRadius: BorderRadius.circular(Neon.rSm),
            border: Border.all(color: Neon.line),
          ),
          child: Row(
            children: [
              Icon(icon, size: 16, color: tint ?? Neon.success),
              const SizedBox(width: 9),
              Expanded(
                child: Text(text,
                    style: TextStyle(color: Neon.textLo, fontSize: 13)),
              ),
            ],
          ),
        ),
      );

  static String _timeLabel(int? atMs) {
    if (atMs == null) return 'anytime';
    final t = DateTime.fromMillisecondsSinceEpoch(atMs);
    final now = DateTime.now();
    final sameDay =
        t.year == now.year && t.month == now.month && t.day == now.day;
    final hh = t.hour % 12 == 0 ? 12 : t.hour % 12;
    final mm = t.minute.toString().padLeft(2, '0');
    final ap = t.hour < 12 ? 'am' : 'pm';
    if (sameDay) return '$hh:$mm $ap';
    const wk = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return '${wk[t.weekday - 1]} $hh:$mm $ap';
  }

  /// Offers Undo for a moment; [commit] runs only if it was not taken.
  /// The toast closes on its own after 4 s (with nowhere to show it, the
  /// change simply commits).
  static void _withUndo(BuildContext context, String message,
      {required VoidCallback undo, required Future<void> Function() commit}) {
    AppFeedback.showUndo(context, message, onUndo: () {
      HapticFeedback.selectionClick();
      undo();
    }).then((reason) {
      if (reason != SnackBarClosedReason.action) commit();
    });
  }

  Widget _agendaTile(BuildContext context, AgendaItem a) {
    final isMeeting = a.kind == 'meeting';
    final tile = _glassTile(
      leading: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: (isMeeting ? Neon.cyan : Neon.violet).withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(Neon.rSm),
        ),
        // cyanInk: plain cyan words on this tint were 2.75:1.
        child: Text(
          _timeLabel(a.atMs),
          style: NeonType.manrope(NeonType.caption, FontWeight.w700)
              .copyWith(color: isMeeting ? Neon.cyanInk : Neon.violet),
        ),
      ),
      child: Text(a.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
              color: Neon.textHi, fontSize: NeonType.body, height: 1.25)),
    );
    // Meetings live in Google Calendar — nothing to delete here. Reminders
    // are ours: swipe either way to clear one.
    if (isMeeting || a.id == null) return tile;
    return Dismissible(
      key: ValueKey('agenda-${a.id}'),
      background: _swipeBackdrop(),
      secondaryBackground: _swipeBackdrop(right: true),
      onDismissed: (_) {
        HapticFeedback.mediumImpact();
        final svc = BriefService.instance;
        final at = svc.hideReminder(a);
        _withUndo(context, 'Reminder removed',
            undo: () => svc.restoreReminder(a, at),
            commit: () => svc.commitReminderDelete(a));
      },
      child: tile,
    );
  }

  /// Promise cards: tap the circle = "I kept it" (marks done), swipe either
  /// direction = "never mind" (cancels it). Both are instant and silent.
  Widget _promiseTile(BuildContext context, PromiseItem p) {
    void finish({required bool done}) {
      final svc = BriefService.instance;
      final at = svc.hidePromise(p);
      _withUndo(context, done ? 'Marked as kept' : 'Promise dismissed',
          undo: () => svc.restorePromise(p, at),
          commit: () => svc.commitPromise(p, done: done));
    }

    final tile = _glassTile(
      leading: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          HapticFeedback.mediumImpact();
          finish(done: true);
        },
        child: Padding(
          // 15 on each side of an 18 px icon: a 48 px target (was 42).
          padding: const EdgeInsets.all(15),
          child: Icon(Icons.radio_button_unchecked_rounded,
              size: 18, color: Neon.pink),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(p.text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: Neon.textHi, fontSize: NeonType.body, height: 1.25)),
          if (p.dueLabel != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              // warningInk: amber words were 2.78:1 on this card, the
              // least readable line on Home for the most urgent news.
              child: Text(p.dueLabel!,
                  style: NeonType.manrope(NeonType.caption, FontWeight.w600)
                      .copyWith(color: Neon.warningInk)),
            ),
        ],
      ),
    );
    if (p.id == null) return tile;
    return Dismissible(
      key: ValueKey('promise-${p.id}'),
      background: _swipeBackdrop(),
      secondaryBackground: _swipeBackdrop(right: true),
      onDismissed: (_) {
        HapticFeedback.mediumImpact();
        finish(done: false);
      },
      child: tile,
    );
  }

  /// The red "delete" strip revealed under a swiped card.
  static Widget _swipeBackdrop({bool right = false}) => Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        alignment: right ? Alignment.centerRight : Alignment.centerLeft,
        decoration: BoxDecoration(
          color: const Color(0xFFE5484D).withValues(alpha: 0.22),
          borderRadius: BorderRadius.circular(Neon.rMd),
        ),
        child: const Icon(Icons.delete_outline_rounded,
            size: 18, color: Color(0xFFFF8A8E)),
      );

  Widget _messageTile(BriefMessage m) => _glassTile(
        leading: _initialsDot(m.from, Neon.gVioletCyan),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(m.from,
                style: NeonType.manrope(NeonType.caption, FontWeight.w700)
                    .copyWith(color: Neon.cyanInk)),
            const SizedBox(height: 2),
            Text(m.text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: Neon.textHi, fontSize: NeonType.body, height: 1.25)),
          ],
        ),
      );


  static Widget _initialsDot(String name, Gradient g, {double size = 34}) {
    final parts =
        name.trim().split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
    final initials = parts.isEmpty
        ? '?'
        : parts.length == 1
            ? parts.first.characters.first.toUpperCase()
            : (parts.first.characters.first + parts.last.characters.first)
                .toUpperCase();
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(shape: BoxShape.circle, gradient: g),
      alignment: Alignment.center,
      child: Text(initials,
          style: TextStyle(
              color: Colors.white,
              fontSize: size * 0.34,
              fontWeight: FontWeight.w700)),
    );
  }

  static Widget _glassTile({required Widget leading, required Widget child}) =>
      PressScale(
          child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: Neon.surfaceHigh,
          borderRadius: BorderRadius.circular(Neon.rMd),
          border: Border.all(color: Neon.line),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            leading,
            const SizedBox(width: 12),
            Expanded(child: child),
          ],
        ),
      ));
}

/// ─────────────────────────────────────────────────────────────────────────
///  REMINDER COMPOSER — the "Remind me" quick action. Fully silent: type
///  what, tap when, done. No voice turn, works on a muted phone in a
///  meeting, and the new reminder appears on the agenda immediately.
/// ─────────────────────────────────────────────────────────────────────────
class _ReminderComposer extends StatefulWidget {
  const _ReminderComposer();

  @override
  State<_ReminderComposer> createState() => _ReminderComposerState();
}

class _ReminderComposerState extends State<_ReminderComposer> {
  final _text = TextEditingController();
  DateTime? _due;
  String _dueLabel = 'No time';
  bool _saving = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _pickCustom() async {
    final now = DateTime.now();
    final day = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
    );
    if (day == null || !mounted) return;
    final time = await showTimePicker(
        context: context, initialTime: TimeOfDay.fromDateTime(now));
    if (time == null) return;
    setState(() {
      _due = DateTime(day.year, day.month, day.day, time.hour, time.minute);
      final hh = time.hourOfPeriod == 0 ? 12 : time.hourOfPeriod;
      final mm = time.minute.toString().padLeft(2, '0');
      _dueLabel =
          '${day.day}/${day.month} $hh:$mm ${time.period == DayPeriod.am ? 'am' : 'pm'}';
    });
  }

  Future<void> _save() async {
    final t = _text.text.trim();
    if (t.isEmpty || _saving) return;
    setState(() => _saving = true);
    try {
      await ApiService.createReminder(t, _due);
      BriefService.instance.refresh(force: true);
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) {
        setState(() => _saving = false);
        AppFeedback.show("Couldn't save that reminder — check connection.", context: context);
      }
    }
  }

  Widget _chip(String label, DateTime? Function() when) {
    final selected = _dueLabel == label;
    return GestureDetector(
      onTap: () => setState(() {
        _due = when();
        _dueLabel = label;
      }),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: selected
              ? Neon.violet.withValues(alpha: 0.12)
              : Neon.surfaceHigh,
          borderRadius: BorderRadius.circular(Neon.rPill),
          border: Border.all(
              color: selected ? Neon.violet : Neon.line),
        ),
        child: Text(label,
            style: TextStyle(
                color: selected ? Neon.textHi : Neon.textLo,
                fontSize: 12,
                fontWeight: FontWeight.w600)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    return Dialog(
      backgroundColor: Neon.surface.withValues(alpha: 0.97),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Neon.rXl),
          side: BorderSide(color: Neon.lineBright)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('New reminder',
                style: TextStyle(
                    color: Neon.textHi,
                    fontSize: 17,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 14),
            TextField(
              controller: _text,
              autofocus: true,
              minLines: 1,
              maxLines: 3,
              style: TextStyle(color: Neon.textHi, fontSize: 14),
              decoration: InputDecoration(
                hintText: 'Remind me to…',
                hintStyle: TextStyle(color: Neon.textDim),
                filled: true,
                fillColor: Neon.surfaceHigh,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(Neon.rMd),
                  borderSide: BorderSide(color: Neon.line),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(Neon.rMd),
                  borderSide: BorderSide(color: Neon.line),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(Neon.rMd),
                  borderSide: BorderSide(color: Neon.violet),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _chip('No time', () => null),
                _chip('In 1 hour', () => now.add(const Duration(hours: 1))),
                _chip('This evening', () {
                  final e =
                      DateTime(now.year, now.month, now.day, 18);
                  return e.isAfter(now)
                      ? e
                      : e.add(const Duration(days: 1));
                }),
                _chip('Tomorrow 9 am', () {
                  final t = now.add(const Duration(days: 1));
                  return DateTime(t.year, t.month, t.day, 9);
                }),
                GestureDetector(
                  onTap: _pickCustom,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 7),
                    decoration: BoxDecoration(
                      color: !const [
                        'No time',
                        'In 1 hour',
                        'This evening',
                        'Tomorrow 9 am'
                      ].contains(_dueLabel)
                          ? Neon.violet.withValues(alpha: 0.12)
                          : Neon.surfaceHigh,
                      borderRadius: BorderRadius.circular(Neon.rPill),
                      border: Border.all(color: Neon.line),
                    ),
                    child: Text(
                      const ['No time', 'In 1 hour', 'This evening', 'Tomorrow 9 am']
                              .contains(_dueLabel)
                          ? 'Pick time…'
                          : _dueLabel,
                      style: TextStyle(
                          color: Neon.textLo,
                          fontSize: 12,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child:
                      Text('Cancel', style: TextStyle(color: Neon.textLo)),
                ),
                const SizedBox(width: 6),
                FilledButton(
                  onPressed: _saving ? null : _save,
                  style: FilledButton.styleFrom(
                      backgroundColor: Neon.violet,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(Neon.rPill))),
                  child: Text(_saving ? 'Saving…' : 'Set reminder'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Placeholder cards in the shape of the agenda, breathing gently while
/// the first brief loads.
class _SkeletonTiles extends StatefulWidget {
  const _SkeletonTiles();

  @override
  State<_SkeletonTiles> createState() => _SkeletonTilesState();
}

class _SkeletonTilesState extends State<_SkeletonTiles>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 900))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  Widget _bar(double widthFactor, double height) => FractionallySizedBox(
        alignment: Alignment.centerLeft,
        widthFactor: widthFactor,
        child: Container(
          height: height,
          decoration: BoxDecoration(
            color: Neon.textDim.withValues(alpha: 0.35),
            borderRadius: BorderRadius.circular(6),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Loading your day',
      child: RepaintBoundary(
        child: FadeTransition(
          opacity: Tween(begin: 0.45, end: 1.0).animate(_pulse),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _bar(0.35, 14),
              const SizedBox(height: 12),
              for (final w in const [0.8, 0.6, 0.7, 0.5])
                Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                  decoration: BoxDecoration(
                    color: Neon.surfaceHigh,
                    borderRadius: BorderRadius.circular(Neon.rMd),
                    border: Border.all(color: Neon.line),
                  ),
                  child: Row(children: [
                    Container(
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(
                        color: Neon.textDim.withValues(alpha: 0.35),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(child: _bar(w, 12)),
                  ]),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
