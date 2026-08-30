import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../design/neon_tokens.dart';
import '../../../models/brief.dart';
import '../../../services/api_service.dart';
import '../../../services/brief_service.dart';
import '../../../services/call_service.dart';
import '../state/assistant_engine.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  TODAY PANEL — the home screen's command center.
///
///  Collapsed: one glass pill above the control bar with a live summary
///  ("3 on your plate · 1 message"). The live conversation stays the star;
///  the pill only whispers what's waiting.
///
///  Tap: a glass sheet with the whole day — agenda (reminders + meetings),
///  promises Hari heard you make, messages other people's assistants left
///  for you, and which of your contacts are on the app. Quick actions feed
///  straight into the running conversation (spoken brief, new reminder,
///  document scan) — the dashboard and the voice agent are one system.
/// ─────────────────────────────────────────────────────────────────────────
class TodayPill extends StatelessWidget {
  const TodayPill({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: BriefService.instance,
      builder: (context, _) {
        final b = BriefService.instance.brief;
        final hasUrgent = b.messages.isNotEmpty;
        return Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 10),
          child: GestureDetector(
            onTap: () {
              HapticFeedback.selectionClick();
              BriefService.instance.refresh(force: true);
              _openTodaySheet(context);
            },
            child: ClipRRect(
              borderRadius: BorderRadius.circular(Neon.rPill),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.07),
                    borderRadius: BorderRadius.circular(Neon.rPill),
                    border: Border.all(
                      color: hasUrgent
                          ? Neon.cyan.withValues(alpha: 0.45)
                          : Colors.white.withValues(alpha: 0.10),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 22,
                        height: 22,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: Neon.gVioletCyan,
                        ),
                        child: const Icon(Icons.wb_twilight_rounded,
                            size: 13, color: Colors.white),
                      ),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          b.summary,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Neon.textHi,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.1,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Icon(Icons.keyboard_arrow_up_rounded,
                          size: 18, color: Colors.white.withValues(alpha: 0.6)),
                    ],
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

void _openTodaySheet(BuildContext context) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.45),
    builder: (_) => const _TodaySheet(),
  );
}

class _TodaySheet extends StatelessWidget {
  const _TodaySheet();

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.of(context).size.height;
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(Neon.rXl)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 26, sigmaY: 26),
        child: Container(
          constraints: BoxConstraints(maxHeight: h * 0.82),
          decoration: BoxDecoration(
            color: Neon.surface.withValues(alpha: 0.86),
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(Neon.rXl)),
            border: Border(top: BorderSide(color: Neon.lineBright)),
          ),
          child: AnimatedBuilder(
            animation: BriefService.instance,
            builder: (context, _) {
              final svc = BriefService.instance;
              final b = svc.brief;
              return ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 28),
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.22),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  _header(b),
                  const SizedBox(height: 16),
                  _quickActions(context),
                  const SizedBox(height: 20),
                  if (!svc.loaded)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 32),
                      child: Center(
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Neon.violet)),
                    )
                  else ...[
                    if (b.messages.isNotEmpty) ...[
                      _sectionTitle(Icons.mark_email_unread_rounded,
                          'Messages for you', Neon.cyan),
                      ...b.messages.take(4).map(_messageTile),
                      const SizedBox(height: 18),
                    ],
                    _sectionTitle(
                        Icons.event_note_rounded, 'Today’s agenda', Neon.violet),
                    if (b.agenda.isEmpty)
                      _emptyLine('Nothing scheduled — enjoy the calm.')
                    else
                      ...b.agenda.take(6).map(_agendaTile),
                    const SizedBox(height: 18),
                    _sectionTitle(
                        Icons.handshake_rounded, 'Promises you made', Neon.pink),
                    if (b.promises.isEmpty)
                      _emptyLine('No open promises. Clean slate.')
                    else
                      ...b.promises.take(5).map(_promiseTile),
                    if (b.people.isNotEmpty) ...[
                      const SizedBox(height: 18),
                      _sectionTitle(Icons.group_rounded,
                          'Your circle on the app', Neon.lime),
                      const SizedBox(height: 8),
                      _peopleRow(b),
                    ],
                    if (b.headlines.isNotEmpty) ...[
                      const SizedBox(height: 18),
                      _sectionTitle(Icons.public_rounded,
                          'While you were busy', Neon.warning),
                      ...b.headlines.take(3).map(_headlineTile),
                    ],
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
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
            const Text('Today',
                style: TextStyle(
                    color: Neon.textHi,
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.4)),
            const SizedBox(height: 2),
            Text(
              '${wk[now.weekday - 1]}, ${mo[now.month - 1]} ${now.day}',
              style: const TextStyle(color: Neon.textLo, fontSize: 13),
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
              style: const TextStyle(
                  color: Neon.textHi, fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
      ],
    );
  }

  /// The dashboard drives the CONVERSATION — each action hands a request to
  /// whichever session (live or classic) currently owns the audio, so the
  /// buttons and the voice agent are one brain, not two features.
  Widget _quickActions(BuildContext context) {
    Widget act(IconData icon, String label, Gradient g, VoidCallback onTap) {
      return Expanded(
        child: GestureDetector(
          onTap: () {
            HapticFeedback.mediumImpact();
            onTap();
          },
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 4),
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(Neon.rMd),
              border: Border.all(color: Neon.line),
            ),
            child: Column(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration:
                      BoxDecoration(shape: BoxShape.circle, gradient: g),
                  child: Icon(icon, size: 17, color: Colors.white),
                ),
                const SizedBox(height: 6),
                Text(label,
                    style: const TextStyle(
                        color: Neon.textLo,
                        fontSize: 11,
                        fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        // Brief me is the one action that IS a conversation — hand it to
        // whichever session owns the audio and get out of the way.
        act(Icons.auto_awesome_rounded, 'Brief me', Neon.gVioletCyan, () {
          Navigator.of(context).pop();
          AssistantEngine.instance.askAssistant(
              'Give me my brief for today — my agenda, my messages and the promises I have open.');
        }),
        // Remind me and Scan are DETERMINISTIC: a silent phone, a muted
        // speaker, a meeting — the buttons must work with zero audio.
        act(Icons.alarm_add_rounded, 'Remind me', Neon.gPinkViolet, () {
          showDialog(
            context: context,
            builder: (_) => const _ReminderComposer(),
          );
        }),
        act(Icons.document_scanner_rounded, 'Scan', Neon.gCyanLime, () {
          Navigator.of(context).pop();
          AssistantEngine.instance.startScan();
        }),
      ],
    );
  }

  Widget _sectionTitle(IconData icon, String title, Color tint) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          children: [
            Icon(icon, size: 15, color: tint),
            const SizedBox(width: 7),
            Text(title,
                style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.85),
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.2)),
          ],
        ),
      );

  Widget _emptyLine(String text) => Padding(
        padding: const EdgeInsets.only(left: 22, bottom: 4),
        child: Text(text,
            style: const TextStyle(color: Neon.textDim, fontSize: 13)),
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

  Widget _agendaTile(AgendaItem a) {
    final isMeeting = a.kind == 'meeting';
    final tile = _glassTile(
      leading: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: (isMeeting ? Neon.cyan : Neon.violet).withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(Neon.rSm),
        ),
        child: Text(
          _timeLabel(a.atMs),
          style: TextStyle(
              color: isMeeting ? Neon.cyan : const Color(0xFFB79CFF),
              fontSize: 11.5,
              fontWeight: FontWeight.w700),
        ),
      ),
      child: Text(a.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
              color: Neon.textHi, fontSize: 13.5, height: 1.25)),
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
        BriefService.instance.deleteReminder(a);
      },
      child: tile,
    );
  }

  /// Promise cards: tap the circle = "I kept it" (marks done), swipe either
  /// direction = "never mind" (cancels it). Both are instant and silent.
  Widget _promiseTile(PromiseItem p) {
    final tile = _glassTile(
      leading: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          HapticFeedback.mediumImpact();
          BriefService.instance.completePromise(p);
        },
        child: const Padding(
          padding: EdgeInsets.all(6),
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
              style: const TextStyle(
                  color: Neon.textHi, fontSize: 13.5, height: 1.25)),
          if (p.dueLabel != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(p.dueLabel!,
                  style: const TextStyle(
                      color: Neon.warning,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600)),
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
        BriefService.instance.dismissPromise(p);
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
                style: const TextStyle(
                    color: Neon.cyan,
                    fontSize: 12,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(m.text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: Neon.textHi, fontSize: 13.5, height: 1.25)),
          ],
        ),
      );

  Widget _headlineTile(Headline hl) => _glassTile(
        leading: const Icon(Icons.circle, size: 6, color: Neon.warning),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(hl.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: Neon.textHi, fontSize: 13, height: 1.25)),
            if (hl.source.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(hl.source,
                    style:
                        const TextStyle(color: Neon.textDim, fontSize: 11)),
              ),
          ],
        ),
      );

  Widget _peopleRow(TodayBrief b) {
    return SizedBox(
      height: 64,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: b.people.length.clamp(0, 12),
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (context, i) {
          final p = b.people[i];
          return GestureDetector(
            onTap: () {
              HapticFeedback.selectionClick();
              _openPersonSheet(context, p);
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _initialsDot(p.name, Neon.gVioletPink, size: 40),
                const SizedBox(height: 5),
                SizedBox(
                  width: 52,
                  child: Text(
                    p.name.split(' ').first,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Neon.textLo, fontSize: 10.5),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

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
      Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.05),
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
      );
}

/// ─────────────────────────────────────────────────────────────────────────
///  PERSON SHEET — tap a circle avatar to act on that person: message them
///  through their assistant, or call them. Their agent is on the app, which
///  is exactly why they're in this row.
/// ─────────────────────────────────────────────────────────────────────────
void _openPersonSheet(BuildContext context, CirclePerson p) {
  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.35),
    builder: (_) => _PersonSheet(person: p),
  );
}

class _PersonSheet extends StatefulWidget {
  const _PersonSheet({required this.person});
  final CirclePerson person;

  @override
  State<_PersonSheet> createState() => _PersonSheetState();
}

class _PersonSheetState extends State<_PersonSheet> {
  final _msg = TextEditingController();
  bool _composing = false;

  @override
  void dispose() {
    _msg.dispose();
    super.dispose();
  }

  void _sendMessage() {
    final text = _msg.text.trim();
    if (text.isEmpty) return;
    final name = widget.person.name;
    // Pop the person sheet AND the today sheet underneath so the user sees
    // the conversation reacting to what they just asked for.
    Navigator.of(context).popUntil((r) => r.isFirst);
    AssistantEngine.instance
        .askAssistant('Send a message to $name saying: $text');
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.person;
    final inset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: inset),
      child: ClipRRect(
        borderRadius:
            const BorderRadius.vertical(top: Radius.circular(Neon.rXl)),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 26, sigmaY: 26),
          child: Container(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 26),
            decoration: BoxDecoration(
              color: Neon.surface.withValues(alpha: 0.92),
              border: Border(top: BorderSide(color: Neon.lineBright)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    _TodaySheet._initialsDot(p.name, Neon.gVioletPink,
                        size: 44),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(p.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: Neon.textHi,
                                  fontSize: 17,
                                  fontWeight: FontWeight.w700)),
                          const SizedBox(height: 2),
                          Text(
                            p.phone.isNotEmpty
                                ? '${p.phone} · on Hari'
                                : 'on Hari',
                            style: const TextStyle(
                                color: Neon.textLo, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                if (_composing) ...[
                  TextField(
                    controller: _msg,
                    autofocus: true,
                    minLines: 1,
                    maxLines: 3,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _sendMessage(),
                    style:
                        const TextStyle(color: Neon.textHi, fontSize: 14),
                    decoration: InputDecoration(
                      hintText: 'Message for ${p.name.split(' ').first}…',
                      hintStyle: const TextStyle(color: Neon.textDim),
                      filled: true,
                      fillColor: Colors.white.withValues(alpha: 0.06),
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
                        borderSide: const BorderSide(color: Neon.violet),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  _actionButton(Icons.send_rounded, 'Send via Hari',
                      Neon.gVioletCyan, _sendMessage),
                ] else ...[
                  _actionButton(Icons.chat_bubble_rounded, 'Message via Hari',
                      Neon.gVioletCyan, () => setState(() => _composing = true)),
                  const SizedBox(height: 8),
                  if (p.phone.isNotEmpty)
                    _actionButton(Icons.call_rounded, 'Call', Neon.gCyanLime,
                        () {
                      Navigator.of(context).pop();
                      CallService.instance.call(p.phone);
                    }),
                  const SizedBox(height: 8),
                  _actionButton(Icons.auto_awesome_rounded,
                      'Ask Hari about them', Neon.gPinkViolet, () {
                    Navigator.of(context).popUntil((r) => r.isFirst);
                    AssistantEngine.instance
                        .askAssistant('What do you know about ${p.name}?');
                  }),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _actionButton(
      IconData icon, String label, Gradient g, VoidCallback onTap) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.mediumImpact();
        onTap();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(Neon.rMd),
          border: Border.all(color: Neon.line),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(shape: BoxShape.circle, gradient: g),
              child: Icon(icon, size: 14, color: Colors.white),
            ),
            const SizedBox(width: 10),
            Text(label,
                style: const TextStyle(
                    color: Neon.textHi,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
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
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text("Couldn't save that reminder — check connection.")));
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
              ? Neon.violet.withValues(alpha: 0.25)
              : Colors.white.withValues(alpha: 0.06),
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
            const Text('New reminder',
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
              style: const TextStyle(color: Neon.textHi, fontSize: 14),
              decoration: InputDecoration(
                hintText: 'Remind me to…',
                hintStyle: const TextStyle(color: Neon.textDim),
                filled: true,
                fillColor: Colors.white.withValues(alpha: 0.06),
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
                  borderSide: const BorderSide(color: Neon.violet),
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
                          ? Neon.violet.withValues(alpha: 0.25)
                          : Colors.white.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(Neon.rPill),
                      border: Border.all(color: Neon.line),
                    ),
                    child: Text(
                      const ['No time', 'In 1 hour', 'This evening', 'Tomorrow 9 am']
                              .contains(_dueLabel)
                          ? 'Pick time…'
                          : _dueLabel,
                      style: const TextStyle(
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
                      const Text('Cancel', style: TextStyle(color: Neon.textLo)),
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
