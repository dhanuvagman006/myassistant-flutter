import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../design/motion.dart';
import '../../design/neon_tokens.dart';
import '../../services/meetings_service.dart';
import '../../services/app_feedback.dart';

/// THE MINUTES. Summary, what was decided, who does what by when, a
/// follow-up message ready to send, and the whole thing as a PDF.
class MeetingDetailScreen extends StatefulWidget {
  const MeetingDetailScreen({super.key, required this.id});
  final int id;

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
    final done = m?['status'] == 'done';
    return Scaffold(
      backgroundColor: Neon.bg,
      appBar: AppBar(
        backgroundColor: Neon.bg,
        elevation: 0,
        iconTheme: IconThemeData(color: Neon.textHi),
        title: Text((m?['title'] ?? 'Meeting').toString(),
            style: TextStyle(color: Neon.textHi, fontWeight: FontWeight.w700)),
        actions: [
          if (done)
            IconButton(
              tooltip: 'Share minutes (PDF)',
              onPressed: _sharing ? null : _sharePdf,
              icon: _sharing
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Neon.cyan))
                  : Icon(Icons.picture_as_pdf_rounded, color: Neon.cyan),
            ),
        ],
      ),
      body: SafeArea(
        child: _loading
            ? Center(child: CircularProgressIndicator(color: Neon.textLo, strokeWidth: 2))
            : m == null
                ? Center(
                    child: Text("Couldn't load this meeting.",
                        style: TextStyle(color: Neon.textDim)))
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
    return _card(Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(line, style: TextStyle(color: Neon.textHi, fontSize: 14, fontWeight: FontWeight.w600)),
        if (people.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(people, style: TextStyle(color: Neon.textDim, fontSize: 13)),
          ),
      ],
    ));
  }

  List<Widget> _body(Map<String, dynamic> m) {
    final status = (m['status'] ?? 'done').toString();
    if (status == 'processing') {
      return [
        _card(Row(children: [
          SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Neon.cyan)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
                'Writing your minutes — this takes a few minutes. You can '
                'leave; a notification comes when they are ready.',
                style: TextStyle(color: Neon.textLo, fontSize: 14, height: 1.45)),
          ),
        ])),
      ];
    }
    if (status == 'failed') {
      return [
        _card(Row(children: [
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
        Reveal(child: _section(Icons.subject_rounded, 'Summary', Neon.violet,
            Text(m['summary'].toString(),
                style: TextStyle(color: Neon.textLo, fontSize: 14, height: 1.5)))),
      if (decisions.isNotEmpty) ...[
        const SizedBox(height: 12),
        Reveal(
          delayMs: 60,
          child: _section(Icons.gavel_rounded, 'Decisions', Neon.cyan, Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [for (final d in decisions) _bullet(d, Neon.cyan)],
          )),
        ),
      ],
      if (actions.isNotEmpty) ...[
        const SizedBox(height: 12),
        Reveal(
          delayMs: 120,
          child: _section(Icons.task_alt_rounded, 'Action items', Neon.success, Column(
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
          child: _section(Icons.send_rounded, 'Follow-up message', Neon.pink, Column(
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
        _section(Icons.notes_rounded, 'Transcript', Neon.textLo, Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_showTranscript)
              Text(transcript,
                  style: TextStyle(color: Neon.textLo, fontSize: 13, height: 1.5)),
            TextButton(
              onPressed: () => setState(() => _showTranscript = !_showTranscript),
              child: Text(_showTranscript ? 'Hide transcript' : 'Show full transcript'),
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

  Widget _card(Widget child) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Neon.surface,
          borderRadius: BorderRadius.circular(Neon.rLg),
          border: Border.all(color: Neon.line),
        ),
        child: child,
      );

  Widget _section(IconData icon, String title, Color tint, Widget body) => _card(Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(color: tint.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(8)),
              child: Icon(icon, size: 15, color: tint),
            ),
            const SizedBox(width: 9),
            Text(title, style: TextStyle(color: Neon.textHi, fontSize: 14, fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: 10),
          body,
        ],
      ));
}
