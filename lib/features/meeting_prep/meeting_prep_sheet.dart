import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../design/motion.dart';
import '../../design/neon_tokens.dart';
import '../../design/neon_widgets.dart';
import '../../services/app_feedback.dart';
import 'meeting_prep.dart';

/// Opens Meeting Prep: [prep] when it is already here (the voice
/// directive), else it is fetched for [meetingId] (Home's Prepare) or the
/// next meeting.
Future<void> showMeetingPrep(
  BuildContext context, {
  MeetingPrep? prep,
  String? meetingId,
  MeetingPrepApi api = const MeetingPrepApi(),
}) =>
    showAppSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      useRootNavigator: true,
      backgroundColor: Neon.surface,
      showDragHandle: true,
      builder: (_) => MeetingPrepSheet(prep: prep, meetingId: meetingId, api: api),
    );

/// ─────────────────────────────────────────────────────────────────────────
///  MEETING PREP (2026-09-30): one glance before the door opens — the
///  meeting, in blue light (information); who is in it; the talking
///  points, numbered; what was promised either way; what to watch. One
///  primary action, lit: "Remind me 10 min before". When nothing is known
///  about the people, the summary says so plainly.
/// ─────────────────────────────────────────────────────────────────────────
class MeetingPrepSheet extends StatefulWidget {
  const MeetingPrepSheet({
    super.key,
    this.prep,
    this.meetingId,
    this.api = const MeetingPrepApi(),
  });

  final MeetingPrep? prep;
  final String? meetingId;
  final MeetingPrepApi api;

  @override
  State<MeetingPrepSheet> createState() => _MeetingPrepSheetState();
}

class _MeetingPrepSheetState extends State<MeetingPrepSheet> {
  MeetingPrep? _prep;
  bool _failed = false;
  bool _reminding = false;
  bool _reminded = false;

  @override
  void initState() {
    super.initState();
    _prep = widget.prep;
    if (_prep == null) unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _failed = false;
      _prep = null;
    });
    MeetingPrep? p;
    try {
      p = await widget.api.fetch(meetingId: widget.meetingId);
    } catch (_) {
      p = null;
    }
    if (!mounted) return;
    setState(() {
      _prep = p;
      _failed = p == null;
    });
  }

  Future<void> _remind() async {
    final p = _prep;
    if (p == null || _reminding || _reminded) return;
    setState(() => _reminding = true);
    var ok = false;
    try {
      ok = await widget.api.remindBefore(p);
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    setState(() {
      _reminding = false;
      _reminded = ok;
    });
    if (ok) {
      AppFeedback.show("I'll remind you 10 minutes before.",
          context: context, tone: FeedbackTone.success);
    } else {
      AppFeedback.showRetry("Couldn't set the reminder. Check your connection.",
          context: context, onRetry: () => unawaited(_remind()));
    }
  }

  Future<void> _join(String link) async {
    final uri = Uri.tryParse(link);
    if (uri == null || uri.scheme != 'https') return;
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok && mounted) {
        AppFeedback.show("Couldn't open the call link.", context: context, tone: FeedbackTone.error);
      }
    } catch (_) {
      if (mounted) {
        AppFeedback.show("Couldn't open the call link.", context: context, tone: FeedbackTone.error);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final maxH = MediaQuery.sizeOf(context).height * 0.88;
    final p = _prep;
    final Widget body;
    if (p == null && !_failed) {
      body = const Padding(
        padding: EdgeInsets.symmetric(vertical: 56),
        child: NeonLoader.page(
          label: 'Getting your meeting ready…',
          semanticLabel: 'Preparing your meeting',
        ),
      );
    } else if (p == null) {
      body = Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: NeonErrorState(
          message: "Couldn't prepare this meeting",
          hint: 'Check your connection and try again.',
          onRetry: () => unawaited(_load()),
        ),
      );
    } else if (p.meeting == null) {
      body = Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: NeonEmptyState(
          icon: Icons.event_available_rounded,
          title: widget.meetingId == null
              ? 'No meetings in the next 24 hours'
              : "That meeting isn't in the next 24 hours",
          body: 'Nothing to prepare for right now.',
          tone: NeonTone.success,
        ),
      );
    } else {
      body = _content(p);
    }
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxH),
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.paddingOf(context).bottom),
        child: StateSwitch(
          state: p == null ? (_failed ? 'failed' : 'loading') : (p.meeting == null ? 'none' : 'prep'),
          child: body,
        ),
      ),
    );
  }

  Widget _content(MeetingPrep p) {
    final m = p.meeting!;
    final when = [
      if (m.whenText.isNotEmpty) _cap(m.whenText),
      if (m.timeText.isNotEmpty && !m.whenText.contains(m.timeText)) m.timeText,
      if (m.location.isNotEmpty) m.location,
    ].join(' · ');
    final canRemind = p.remindAtMs != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // THE MEETING, in information blue.
        GlowCard(
          tone: NeonTone.info,
          halo: 1,
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  ExcludeSemantics(child: _tile(Icons.groups_rounded, NeonTone.info)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Semantics(
                          header: true,
                          child: Text(m.title,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: NeonType.cardTitle.copyWith(color: Neon.textHi, height: 1.25)),
                        ),
                        if (when.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(when,
                              style: TextStyle(color: Neon.textLo, fontSize: NeonType.footnote, height: 1.3)),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
              if (p.summary.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(p.summary,
                    style: NeonType.manrope(NeonType.rowTitle, FontWeight.w500)
                        .copyWith(color: Neon.textHi, height: 1.45)),
              ],
            ],
          ),
        ),
        const SizedBox(height: 14),
        // THE ONE THING TO DO, lit.
        Wrap(
          spacing: 10,
          runSpacing: 6,
          children: [
            if (canRemind)
              DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(Neon.rPill),
                  boxShadow: _reminded ? null : Neon.halo(NeonTone.brand.rim.first, strength: 1.2),
                ),
                child: NeonPill(
                  label: _reminded ? 'Reminder set' : 'Remind me 10 min before',
                  icon: _reminded ? Icons.check_rounded : Icons.alarm_add_rounded,
                  tone: _reminded ? NeonTone.success : NeonTone.brand,
                  busy: _reminding,
                  onPressed: _reminded ? null : () => unawaited(_remind()),
                ),
              ),
            if (m.link.isNotEmpty)
              NeonPill(
                label: 'Join the call',
                icon: Icons.videocam_rounded,
                tone: NeonTone.info,
                onPressed: () => unawaited(_join(m.link)),
              ),
          ],
        ),
        if (p.people.isNotEmpty) ...[
          _header("Who's there"),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [for (final x in p.people) _PersonChip(person: x)],
          ),
          for (final x in p.people.where((x) => x.notes.isNotEmpty || x.lastContact.isNotEmpty))
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                [
                  x.name,
                  if (x.lastContact.isNotEmpty) 'last in touch ${x.lastContact}',
                  if (x.notes.isNotEmpty) x.notes,
                ].join(' · '),
                style: TextStyle(color: Neon.textLo, fontSize: NeonType.body, height: 1.35),
              ),
            ),
        ],
        if (p.talkingPoints.isNotEmpty) ...[
          _header('Talking points'),
          for (var i = 0; i < p.talkingPoints.length; i++) _numbered(i + 1, p.talkingPoints[i]),
        ],
        if (p.context.isNotEmpty) ...[
          _header('Worth knowing'),
          for (final c in p.context) _bullet(c, NeonTone.discovery),
        ],
        if (p.asks.isNotEmpty) ...[
          _header('Promises'),
          for (final a in p.asks) _bullet(a, NeonTone.action),
        ],
        if (p.risks.isNotEmpty) ...[
          _header('Watch out'),
          for (final r in p.risks) _bullet(r, NeonTone.warning),
        ],
      ],
    );
  }

  static String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  Widget _header(String text) => Padding(
        padding: const EdgeInsets.only(top: 22, bottom: 10),
        child: Semantics(
          header: true,
          child: Text(text, style: NeonType.sectionTitle.copyWith(color: Neon.textHi)),
        ),
      );

  Widget _numbered(int n, String text) {
    final ink = NeonTone.tip.ink;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Semantics(
        label: 'Point $n: $text',
        excludeSemantics: true,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 28,
              height: 28,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: NeonTone.tip.fill,
                border: Border.all(color: ink, width: 1.4),
                boxShadow: Neon.halo(ink, strength: 0.5),
              ),
              child: Text('$n',
                  style: NeonType.manrope(NeonType.footnote, FontWeight.w800).copyWith(color: ink)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text(text,
                    style: NeonType.manrope(NeonType.rowTitle, FontWeight.w500)
                        .copyWith(color: Neon.textHi, height: 1.35)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bullet(String text, NeonTone tone) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ExcludeSemantics(
              child: Container(
                width: 8,
                height: 8,
                margin: const EdgeInsets.only(top: 7, right: 12),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: tone.ink,
                  boxShadow: Neon.halo(tone.ink, strength: 0.6),
                ),
              ),
            ),
            Expanded(
              child: Text(text,
                  style: TextStyle(color: Neon.textHi, fontSize: NeonType.body, height: 1.4)),
            ),
          ],
        ),
      );

  static Widget _tile(IconData icon, NeonTone tone) {
    final c = tone.rim.first;
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        gradient: Neon.tile(c),
        borderRadius: BorderRadius.circular(14),
        boxShadow: Neon.halo(c, strength: 0.6),
      ),
      child: Icon(icon, size: 24, color: Neon.onTile(c)),
    );
  }
}

/// A person in the meeting: a lit chip with their name, and their role when
/// a record says it.
class _PersonChip extends StatelessWidget {
  const _PersonChip({required this.person});
  final PrepPerson person;

  @override
  Widget build(BuildContext context) {
    const tone = NeonTone.info;
    final initial = person.name.trim().isEmpty ? '?' : person.name.trim()[0].toUpperCase();
    return Semantics(
      label: person.role.isEmpty ? person.name : '${person.name}, ${person.role}',
      excludeSemantics: true,
      child: Container(
        constraints: const BoxConstraints(minHeight: 44),
        padding: const EdgeInsets.fromLTRB(4, 4, 14, 4),
        decoration: BoxDecoration(
          color: tone.fill,
          borderRadius: BorderRadius.circular(Neon.rPill),
          border: Border.all(color: tone.rim.first.withValues(alpha: 0.8), width: 1.2),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: Neon.tile(tone.rim.first),
              ),
              child: Text(initial,
                  style: NeonType.manrope(NeonType.body, FontWeight.w700)
                      .copyWith(color: Neon.onTile(tone.rim.first))),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(person.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: NeonType.manrope(NeonType.body, FontWeight.w700)
                          .copyWith(color: Neon.textHi)),
                  if (person.role.isNotEmpty)
                    Text(person.role,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: Neon.textLo, fontSize: NeonType.caption)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
