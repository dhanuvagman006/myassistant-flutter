import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../design/dock_metrics.dart';
import '../design/motion.dart';
import '../design/neon_tokens.dart';
import '../features/assistant/state/assistant_engine.dart';
import '../models/schedule_item.dart';
import 'neon_cards.dart';

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
    final media = MediaQuery.of(context);

    // IT OPENS LIKE A SHEET, NOT IN ONE FRAME (2026-09-24). The scrim and
    // a sheet 78% of the screen tall used to appear (and vanish) in a
    // single frame. The scrim now fades in and the sheet fades in as it
    // grows from 96%, anchored where its list ends — the dock's top edge,
    // which the list must never cross, not even mid-animation. Closing
    // leaves the same way (2026-09-29): it fades out as it sinks, in 120 ms.
    return Positioned.fill(
      child: ExitPresence(
        child: items.isEmpty
            ? null
            : Stack(
                children: [
                  GestureDetector(
                    onTap: _close,
                    child: EnterOnce(
                      duration: Motion.short,
                      // The night scrim, not grey-black (2026-09-30).
                      child: ColoredBox(color: Neon.scrim),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: EnterOnce(
                      duration: Motion.pageIn,
                      scaleFrom: 0.96,
                      alignment: Alignment.bottomCenter,
                      origin: Offset(0, -media.padding.bottom),
                      child: Container(
                        constraints: BoxConstraints(maxHeight: media.size.height * 0.78),
                        // The list ends at the dock's top edge; below it is plain
                        // ground, so no row shows through the ring around the mic.
                        padding: EdgeInsets.only(bottom: media.padding.bottom),
                        // A lit edge and its soft light (2026-09-30), as the
                        // theme's sheets have; the ground stays the page's.
                        decoration: BoxDecoration(
                          color: Neon.bg,
                          borderRadius: const BorderRadius.vertical(top: Radius.circular(Neon.rXl)),
                          border: Border.all(color: Neon.lineBright),
                          boxShadow: Neon.halo(Neon.violet, strength: 0.5),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _header(items.length),
                            if (engine.scheduleFailed.isNotEmpty) _incomplete(),
                            Flexible(
                              child: ListView.separated(
                                padding: const EdgeInsets.fromLTRB(16, 4, 16, Dock.orbRise + 16),
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
                  ),
                ],
              ),
      ),
    );
  }

  Widget _header(int n) {
    final day = engine.scheduleDay.isEmpty ? 'today' : engine.scheduleDay;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 8, 6),
      child: Row(
        children: [
          const ToneTile(Icons.event_note_rounded, NeonTone.tip),
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
                color: Neon.warningInk,
                fontSize: 13,
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
    const tip = NeonTone.tip;
    final reduced = Motion.reduced(context);
    // The row dips under the finger, and the one being looked up is lit in
    // the assistant's own tone while it answers (2026-09-30).
    return Tappable(
      onTap: () => _tap(i, item),
      scale: 0.985,
      tapHint: open ? 'close' : 'ask about it',
      child: AnimatedContainer(
        duration: reduced ? Duration.zero : Motion.micro,
        curve: Motion.easeMove,
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
        decoration: BoxDecoration(
          color: open ? tip.fill : Neon.bg.withValues(alpha: 0),
          borderRadius: BorderRadius.circular(Neon.rSm),
          border: Border.all(
              color: open
                  ? tip.rim.first.withValues(alpha: 0.6)
                  : tip.rim.first.withValues(alpha: 0)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // The time is the column a schedule is actually read down.
            SizedBox(
              width: 66,
              child: Text(
                item.time,
                style: GoogleFonts.spaceGrotesk(
                  color: open ? Neon.cyanInk : Neon.textLo,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            Icon(_icon(item.kind), size: 16, color: Neon.textDim),
            const SizedBox(width: 10),
            Expanded(
              // The row opens smoothly (it used to jump open in one frame).
              child: AnimatedSize(
                duration: reduced ? Duration.zero : Motion.short,
                curve: Motion.easeMove,
                alignment: Alignment.topCenter,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      style: GoogleFonts.spaceGrotesk(
                        color: Neon.textHi,
                        fontSize: 16,
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
                          overflow: open ? TextOverflow.visible : TextOverflow.ellipsis,
                          style: GoogleFonts.spaceGrotesk(
                            color: Neon.textDim,
                            fontSize: 13,
                            height: 1.35,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    if (open) ...[
                      const SizedBox(height: 7),
                      EnterOnce(
                        duration: Motion.micro,
                        child: Row(
                          children: [
                            Icon(Icons.graphic_eq_rounded, size: 15, color: Neon.cyan),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                'Looking this up — ask me anything about it',
                                style: GoogleFonts.spaceGrotesk(
                                  color: Neon.cyanInk,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
