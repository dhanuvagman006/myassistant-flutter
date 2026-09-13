import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../design/neon_tokens.dart';
import '../features/assistant/state/assistant_engine.dart';
import '../models/schedule_item.dart';

/// THE DAY'S COMMITMENTS, ON SCREEN.
///
/// Same reasoning as the news panel: a list is the wrong shape for a voice
/// reply. Twelve patients read aloud takes a minute and tells the user
/// nothing they can act on, so the assistant says the count and the next
/// one or two while the whole day sits here, scrollable.
///
/// Deliberately not "appointments". A doctor's clinic list, a lawyer's
/// hearings and a consultant's meetings are one question, so meetings,
/// bookings, recalls and time-bound reminders all appear together — and
/// the count at the top counts all of them.
class SchedulePanel extends StatefulWidget {
  const SchedulePanel({super.key});

  @override
  State<SchedulePanel> createState() => _SchedulePanelState();
}

class _SchedulePanelState extends State<SchedulePanel> {
  final engine = AssistantEngine.instance;
  int? _open;

  @override
  void initState() {
    super.initState();
    engine.addListener(_sync);
  }

  @override
  void dispose() {
    engine.removeListener(_sync);
    super.dispose();
  }

  void _sync() {
    if (!mounted) return;
    if (engine.scheduleItems.isEmpty) _open = null;
    setState(() {});
  }

  void _close() {
    engine.clearSchedule();
    setState(() => _open = null);
  }

  void _tap(int i, ScheduleItem item) {
    setState(() => _open = _open == i ? null : i);
    if (_open != i) return;
    // Goes through the ordinary turn pipeline, so whatever the assistant
    // knows about this person or this meeting is in the conversation
    // afterwards and follow-up questions just work.
    final who = item.who.isNotEmpty ? item.who : item.title;
    engine.askAssistant('Tell me about $who — what do I need to know '
        'before ${item.time.toLowerCase()}?');
  }

  static IconData _icon(String kind) => switch (kind) {
        'meeting' => Icons.groups_rounded,
        'appointment' => Icons.event_available_rounded,
        'patient' => Icons.medical_information_rounded,
        'client' => Icons.badge_rounded,
        'reminder' => Icons.alarm_rounded,
        _ => Icons.schedule_rounded,
      };

  @override
  Widget build(BuildContext context) {
    final items = engine.scheduleItems;
    if (items.isEmpty) return const SizedBox.shrink();
    final media = MediaQuery.of(context);

    return Positioned.fill(
      child: Stack(
        children: [
          GestureDetector(
            onTap: _close,
            child: Container(color: Colors.black.withValues(alpha: 0.55)),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              constraints:
                  BoxConstraints(maxHeight: media.size.height * 0.78),
              decoration: BoxDecoration(
                color: Neon.bg,
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(22)),
                border: Border.all(color: Neon.line),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _header(items.length),
                  if (engine.scheduleFailed.isNotEmpty) _incomplete(),
                  Flexible(
                    child: ListView.separated(
                      padding: EdgeInsets.fromLTRB(
                          16, 4, 16, 16 + media.padding.bottom),
                      itemCount: items.length,
                      separatorBuilder: (_, __) =>
                          Divider(height: 18, thickness: 1, color: Neon.line),
                      itemBuilder: (_, i) => _row(i, items[i]),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(int n) {
    final day = engine.scheduleDay.isEmpty ? 'today' : engine.scheduleDay;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 8, 6),
      child: Row(
        children: [
          Icon(Icons.event_note_rounded, size: 18, color: Neon.cyan),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              // The count IS the answer to "how many do I have".
              n == 1 ? '1 thing $day' : '$n things $day',
              style: GoogleFonts.spaceGrotesk(
                color: Neon.textHi,
                fontSize: 19,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.3,
              ),
            ),
          ),
          IconButton(
            onPressed: _close,
            icon: Icon(Icons.close_rounded, color: Neon.textLo),
            tooltip: 'Close',
          ),
        ],
      ),
    );
  }

  /// A SOURCE THAT FAILED IS NOT AN EMPTY SOURCE. Saying the day is clear
  /// when the calendar could not be read is the kind of wrong a user acts
  /// on, so the panel says so plainly rather than looking complete.
  Widget _incomplete() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
      child: Row(
        children: [
          Icon(Icons.info_outline_rounded, size: 15, color: Neon.warning),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Could not read ${engine.scheduleFailed.join(", ")} — this list '
              'may be incomplete.',
              style: GoogleFonts.spaceGrotesk(
                color: Neon.warning,
                fontSize: 12.5,
                height: 1.3,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(int i, ScheduleItem item) {
    final open = _open == i;
    final sub = [item.where, item.note].where((s) => s.isNotEmpty).join(' · ');
    return InkWell(
      onTap: () => _tap(i, item),
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // The time is the column a schedule is actually read down.
            SizedBox(
              width: 66,
              child: Text(
                item.time,
                style: GoogleFonts.spaceGrotesk(
                  color: open ? Neon.cyan : Neon.textLo,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            Icon(_icon(item.kind), size: 16, color: Neon.textDim),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    style: GoogleFonts.spaceGrotesk(
                      color: Neon.textHi,
                      fontSize: 15.5,
                      height: 1.3,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.2,
                    ),
                  ),
                  if (sub.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text(
                        sub,
                        maxLines: open ? 6 : 1,
                        overflow: open
                            ? TextOverflow.visible
                            : TextOverflow.ellipsis,
                        style: GoogleFonts.spaceGrotesk(
                          color: Neon.textDim,
                          fontSize: 12.5,
                          height: 1.35,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  if (open) ...[
                    const SizedBox(height: 7),
                    Row(
                      children: [
                        Icon(Icons.graphic_eq_rounded,
                            size: 15, color: Neon.cyan),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            'Looking this up — ask me anything about it',
                            style: GoogleFonts.spaceGrotesk(
                              color: Neon.cyan,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
