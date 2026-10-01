import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../design/apple_kit.dart';
import '../../design/motion.dart';
import '../../design/neon_tokens.dart';
import '../../design/neon_widgets.dart';
import '../../widgets/neon_cards.dart';
import '../../services/meetings_service.dart';
import '../../services/app_feedback.dart';

/// THE MINUTES. Summary, what was decided, who does what by when, a
/// follow-up message ready to send, and the whole thing as a PDF.
class MeetingDetailScreen extends StatefulWidget {
  const MeetingDetailScreen({super.key, required this.id, this.preview});
  final int id;

  /// The Meetings list's row, shown in the header while the minutes load
  /// — and what the row flies into (2026-09-30).
  final Map<String, dynamic>? preview;

  @override
  State<MeetingDetailScreen> createState() => _MeetingDetailScreenState();
}

class _MeetingDetailScreenState extends State<MeetingDetailScreen> {
  Map<String, dynamic>? _m;
  bool _loading = true;
  bool _sharing = false;
  bool _showTranscript = false;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _load();
    // The minutes are written in the background — check back while waiting.
    _poll = Timer.periodic(const Duration(seconds: 8), (_) {
      if (_m?['status'] == 'processing') _load();
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final m = await MeetingsService.get(widget.id);
    if (!mounted) return;
    setState(() {
      if (m != null) _m = m;
      _loading = false;
    });
  }

  Future<void> _sharePdf() async {
    setState(() => _sharing = true);
    try {
      final bytes = await MeetingsService.pdf(widget.id);
      final dir = await getTemporaryDirectory();
      final name = 'minutes-${widget.id}.pdf';
      final f = File('${dir.path}/$name');
      await f.writeAsBytes(bytes, flush: true);
      await Share.shareXFiles(
          [XFile(f.path, mimeType: 'application/pdf', name: name)],
          subject: 'Minutes — ${_m?['title'] ?? 'meeting'}');
    } catch (_) {
      if (mounted) {
        AppFeedback.show("Couldn't make the PDF — try again.", context: context);
      }
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = _m;
    final head = m ?? widget.preview;
    final done = m?['status'] == 'done';
    // Under the night sky (2026-09-30).
    return NeonScaffold(
      appBar: appleAppBar(context, (head?['title'] ?? 'Meeting').toString(),
          actions: [
            if (done)
              IconButton(
                tooltip: 'Share minutes (PDF)',
                onPressed: _sharing ? null : _sharePdf,
                icon: _sharing
                    ? const NeonLoader.inline(semanticLabel: 'Preparing PDF')
                    : Icon(Icons.picture_as_pdf_rounded, color: Neon.cyan),
              ),
          ]),
      body: SafeArea(
        child: m == null
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (head != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                      child: _header(head),
                    ),
                  Expanded(
                    child: StateSwitch(
                      state: _loading,
                      child: _loading
                          ? const NeonLoader.page()
                          : NeonErrorState(
                              message: "Couldn't load this meeting",
                              onRetry: () {
                                setState(() => _loading = true);
                                _load();
                              },
                            ),
                    ),
                  ),
                ],
              )
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 30),
                children: [
                  _header(m),
                  const SizedBox(height: 12),
                  ..._body(m),
                ],
              ),
      ),
    );
  }

  Widget _header(Map<String, dynamic> m) {
    final at = DateTime.fromMillisecondsSinceEpoch((m['created_at'] as num?)?.toInt() ?? 0);
    final mins = (((m['duration_s'] as num?) ?? 0) / 60).round();
    const mo = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final line = [
      '${at.day} ${mo[at.month - 1]} · ${at.hour % 12 == 0 ? 12 : at.hour % 12}:'
          '${at.minute.toString().padLeft(2, '0')} ${at.hour < 12 ? 'am' : 'pm'}',
      if (mins > 0) '$mins min',
    ].join(' · ');
    final people = (m['participants'] ?? '').toString();
    return cardHero(
      context,
      meetingHeroTag(widget.id),
      RimCard(
        radius: Neon.rLg,
        child: Row(children: [
          const ToneTile(Icons.groups_rounded, NeonTone.info, size: 40),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(line,
                    style: NeonType.manrope(NeonType.body, FontWeight.w600)
                        .copyWith(color: Neon.textHi)),
                if (people.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(people,
                        style: TextStyle(
                            color: Neon.textDim, fontSize: NeonType.footnote)),
                  ),
              ],
            ),
          ),
        ]),
      ),
      cardRadius: Neon.rMd,
      pageRadius: Neon.rLg,
    );
  }

  List<Widget> _body(Map<String, dynamic> m) {
    final status = (m['status'] ?? 'done').toString();
    if (status == 'processing') {
      return [
        RimCard(tone: NeonTone.tip, radius: Neon.rLg, child: Row(children: [
          const NeonLoader.inline(semanticLabel: 'Writing your minutes'),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
                'Writing your minutes — this takes a few minutes. You can '
                'leave; a notification comes when they are ready.',
                style: TextStyle(color: Neon.textLo, fontSize: NeonType.body, height: 1.45)),
          ),
        ])),
      ];
    }
    if (status == 'failed') {
      return [
        RimCard(tone: NeonTone.warning, radius: Neon.rLg, child: Row(children: [
          Icon(Icons.error_outline_rounded, color: Neon.warning),
          const SizedBox(width: 12),
          Expanded(
            child: Text((m['summary'] ?? "Couldn't process this recording.").toString(),
                style: TextStyle(color: Neon.textLo, fontSize: 14)),
          ),
        ])),
      ];
    }
    final decisions = ((m['decisions'] as List?) ?? const []).map((e) => e.toString()).toList();
    final actions = ((m['actions'] as List?) ?? const [])
        .whereType<Map>()
        .map((a) => a.cast<String, dynamic>())
        .toList();
    final follow = (m['follow_up'] ?? '').toString();
    final transcript = (m['transcript'] ?? '').toString();
    return [
      if ((m['summary'] ?? '').toString().isNotEmpty)
        Reveal(child: _section(Icons.subject_rounded, 'Summary', NeonTone.info,
            Text(m['summary'].toString(),
                style: TextStyle(color: Neon.textLo, fontSize: 14, height: 1.5)))),
      if (decisions.isNotEmpty) ...[
        const SizedBox(height: 12),
        Reveal(
          delayMs: 60,
          child: _section(Icons.gavel_rounded, 'Decisions', NeonTone.tip, Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [for (final d in decisions) _bullet(d, Neon.cyan)],
          )),
        ),
      ],
      if (actions.isNotEmpty) ...[
        const SizedBox(height: 12),
        Reveal(
          delayMs: 120,
          child: _section(Icons.task_alt_rounded, 'Action items', NeonTone.success, Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final a in actions)
                Padding(
                  padding: const EdgeInsets.only(bottom: 9),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Icon(a['mine'] == true ? Icons.person_rounded : Icons.group_rounded,
                        size: 16, color: a['mine'] == true ? Neon.success : Neon.textDim),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text((a['text'] ?? '').toString(),
                            style: TextStyle(color: Neon.textHi, fontSize: 14)),
                        Text(
                          [
                            if ((a['owner'] ?? '').toString().isNotEmpty) a['owner'],
                            if ((a['when'] ?? '').toString().isNotEmpty) a['when'],
                            if (a['mine'] == true) 'added to your promises',
                          ].join(' · '),
                          style: TextStyle(color: Neon.textDim, fontSize: 12),
                        ),
                      ]),
                    ),
                  ]),
                ),
            ],
          )),
        ),
      ],
      if (follow.isNotEmpty) ...[
        const SizedBox(height: 12),
        Reveal(
          delayMs: 180,
          child: _section(Icons.send_rounded, 'Follow-up message', NeonTone.action, Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(follow, style: TextStyle(color: Neon.textLo, fontSize: 14, height: 1.5)),
              const SizedBox(height: 10),
              Row(children: [
                TextButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: follow));
                    if (mounted) {
                      AppFeedback.copied(context, 'Copied.');
                    }
                  },
                  icon: const Icon(Icons.copy_rounded, size: 16),
                  label: const Text('Copy'),
                ),
                TextButton.icon(
                  onPressed: () => Share.share(follow),
                  icon: const Icon(Icons.share_rounded, size: 16),
                  label: const Text('Send…'),
                ),
              ]),
            ],
          )),
        ),
      ],
      const SizedBox(height: 12),
      SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: _sharing ? null : _sharePdf,
          icon: const Icon(Icons.picture_as_pdf_rounded),
          label: Text(_sharing ? 'Preparing PDF…' : 'Share minutes as PDF'),
        ),
      ),
      if (transcript.isNotEmpty) ...[
        const SizedBox(height: 12),
        _section(Icons.notes_rounded, 'Transcript', NeonTone.discovery, Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Opens in place on the app's clock (2026-09-30; it jumped).
            Collapse(
              open: _showTranscript,
              child: Text(transcript,
                  style: TextStyle(color: Neon.textLo, fontSize: NeonType.footnote, height: 1.5)),
            ),
            TextButton.icon(
              onPressed: () => setState(() => _showTranscript = !_showTranscript),
              icon: ExpandChevron(open: _showTranscript, size: 18),
              label: Text(_showTranscript ? 'Hide transcript' : 'Show full transcript'),
            ),
          ],
        )),
      ],
    ];
  }

  Widget _bullet(String text, Color tint) => Padding(
        padding: const EdgeInsets.only(bottom: 7),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Container(width: 5, height: 5, decoration: BoxDecoration(shape: BoxShape.circle, color: tint)),
          ),
          const SizedBox(width: 9),
          Expanded(child: Text(text, style: TextStyle(color: Neon.textLo, fontSize: 14, height: 1.45))),
        ]),
      );

  Widget _section(IconData icon, String title, NeonTone tone, Widget body) =>
      NeonSection(icon: icon, title: title, tone: tone, child: body);
}

/// The tag a Meetings row and its minutes' header card fly under.
Object meetingHeroTag(int id) => cardHeroTag(('meeting', id));
