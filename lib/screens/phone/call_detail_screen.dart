import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:share_plus/share_plus.dart';

import '../../design/motion.dart';
import '../../design/neon_tokens.dart';
import '../../services/api_service.dart';

/// EVERYTHING THE ASSISTANT UNDERSTOOD ABOUT ONE CALL.
/// Summary, every extracted fact, what was filed onto the agenda, and the
/// full transcript — plus one tap to share the notes. This is the payoff
/// screen of call analysis: the difference between "it recorded" and
/// "it understood".
class CallDetailScreen extends StatefulWidget {
  final int callId;
  final String peerLabel;
  const CallDetailScreen(
      {super.key, required this.callId, required this.peerLabel});

  @override
  State<CallDetailScreen> createState() => _CallDetailScreenState();
}

class _CallDetailScreenState extends State<CallDetailScreen> {
  Map<String, dynamic>? _call;
  bool _loading = true;
  bool _showTranscript = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await ApiService.getJson('/calls/${widget.callId}');
    if (!mounted) return;
    setState(() {
      _call = (r?['call'] as Map?)?.cast<String, dynamic>();
      _loading = false;
    });
  }

  List<String> get _facts {
    try {
      return ((jsonDecode((_call?['facts'] ?? '[]').toString()) as List))
          .map((e) => e.toString())
          .toList();
    } catch (_) {
      return const [];
    }
  }

  List<Map<String, dynamic>> get _actions {
    try {
      return ((jsonDecode((_call?['actions'] ?? '[]').toString()) as List))
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
    } catch (_) {
      return const [];
    }
  }

  String get _when {
    final at = DateTime.fromMillisecondsSinceEpoch(
        (_call?['started_at'] as num?)?.toInt() ?? 0);
    const mo = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    final h = at.hour % 12 == 0 ? 12 : at.hour % 12;
    return '${at.day} ${mo[at.month - 1]} · '
        '$h:${at.minute.toString().padLeft(2, '0')} '
        '${at.hour < 12 ? 'am' : 'pm'}';
  }

  void _share() {
    final c = _call;
    if (c == null) return;
    final b = StringBuffer()
      ..writeln('Call notes — ${widget.peerLabel} ($_when)')
      ..writeln()
      ..writeln((c['summary'] ?? '').toString());
    final facts = _facts;
    if (facts.isNotEmpty) {
      b.writeln();
      b.writeln('Key points:');
      for (final f in facts) {
        b.writeln('• $f');
      }
    }
    Share.share(b.toString().trim(), subject: 'Call notes');
  }

  @override
  Widget build(BuildContext context) {
    final c = _call;
    return Scaffold(
      backgroundColor: Neon.bg,
      appBar: AppBar(
        backgroundColor: Neon.bg,
        elevation: 0,
        iconTheme: IconThemeData(color: Neon.textHi),
        title: Text(widget.peerLabel,
            style: GoogleFonts.spaceGrotesk(
                color: Neon.textHi,
                fontWeight: FontWeight.w700,
                fontSize: 19)),
        actions: [
          if (c != null)
            IconButton(
              onPressed: _share,
              icon: Icon(Icons.share_rounded, color: Neon.cyan, size: 20),
            ),
        ],
      ),
      body: SafeArea(
        child: _loading
            ? Center(
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Neon.textLo))
            : c == null
                ? Center(
                    child: Text("Couldn't load this call.",
                        style: TextStyle(color: Neon.textDim, fontSize: 13)))
                : ListView(
                    padding: const EdgeInsets.fromLTRB(16, 6, 16, 30),
                    children: [
                      Reveal(child: _headerCard(c)),
                      const SizedBox(height: 12),
                      if ((c['summary'] ?? '').toString().isNotEmpty)
                        Reveal(
                            delayMs: 60,
                            child: _section(
                              Icons.subject_rounded,
                              'What the call was about',
                              Neon.violet,
                              Text((c['summary'] ?? '').toString(),
                                  style: TextStyle(
                                      color: Neon.textLo,
                                      fontSize: 13.5,
                                      height: 1.5)),
                            )),
                      if (_facts.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Reveal(
                            delayMs: 120,
                            child: _section(
                              Icons.fact_check_rounded,
                              'Key points',
                              Neon.cyan,
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  for (final f in _facts)
                                    Padding(
                                      padding:
                                          const EdgeInsets.only(bottom: 7),
                                      child: Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Padding(
                                            padding: const EdgeInsets.only(
                                                top: 6),
                                            child: Container(
                                                width: 5,
                                                height: 5,
                                                decoration: BoxDecoration(
                                                    shape: BoxShape.circle,
                                                    color: Neon.cyan)),
                                          ),
                                          const SizedBox(width: 9),
                                          Expanded(
                                            child: Text(f,
                                                style: TextStyle(
                                                    color: Neon.textLo,
                                                    fontSize: 13,
                                                    height: 1.45)),
                                          ),
                                        ],
                                      ),
                                    ),
                                ],
                              ),
                            )),
                      ],
                      if (_actions.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Reveal(
                            delayMs: 180,
                            child: _section(
                              Icons.event_available_rounded,
                              'Added to your agenda',
                              Neon.success,
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  for (final a in _actions)
                                    Padding(
                                      padding:
                                          const EdgeInsets.only(bottom: 6),
                                      child: Row(children: [
                                        Icon(
                                            a['kind'] == 'meeting'
                                                ? Icons.groups_rounded
                                                : a['kind'] == 'promise'
                                                    ? Icons.handshake_rounded
                                                    : Icons.alarm_rounded,
                                            size: 15,
                                            color: Neon.success),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text(
                                              (a['text'] ?? '').toString(),
                                              style: TextStyle(
                                                  color: Neon.textLo,
                                                  fontSize: 13)),
                                        ),
                                      ]),
                                    ),
                                ],
                              ),
                            )),
                      ],
                      const SizedBox(height: 12),
                      Reveal(
                        delayMs: 220,
                        child: _section(
                          Icons.notes_rounded,
                          'Transcript',
                          Neon.pink,
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              AnimatedCrossFade(
                                duration: const Duration(milliseconds: 220),
                                crossFadeState: _showTranscript
                                    ? CrossFadeState.showSecond
                                    : CrossFadeState.showFirst,
                                firstChild: const SizedBox(width: double.infinity),
                                secondChild: Padding(
                                  padding: const EdgeInsets.only(bottom: 8),
                                  child: Text(
                                      (c['transcript'] ?? '').toString(),
                                      style: TextStyle(
                                          color: Neon.textLo,
                                          fontSize: 12.5,
                                          height: 1.5)),
                                ),
                              ),
                              InkWell(
                                onTap: () => setState(
                                    () => _showTranscript = !_showTranscript),
                                child: Padding(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 4),
                                  child: Text(
                                      _showTranscript
                                          ? 'Hide transcript'
                                          : 'Show full transcript',
                                      style: TextStyle(
                                          color: Neon.pink,
                                          fontSize: 12.5,
                                          fontWeight: FontWeight.w600)),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
      ),
    );
  }

  Widget _headerCard(Map<String, dynamic> c) {
    final dur = (c['duration_s'] as num?)?.toInt() ?? 0;
    final inc = c['direction'] == 'incoming';
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Neon.surface,
        borderRadius: BorderRadius.circular(Neon.rLg),
        border: Border.all(color: Neon.line),
      ),
      child: Row(children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: Neon.success.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(
              inc ? Icons.call_received_rounded : Icons.call_made_rounded,
              color: Neon.success,
              size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_when,
                style: TextStyle(
                    color: Neon.textHi,
                    fontSize: 14,
                    fontWeight: FontWeight.w600)),
            if (dur > 0)
              Text(
                  '${dur ~/ 60} min ${dur % 60} sec',
                  style: TextStyle(color: Neon.textDim, fontSize: 12)),
          ]),
        ),
      ]),
    );
  }

  Widget _section(IconData icon, String title, Color tint, Widget body) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Neon.surface,
        borderRadius: BorderRadius.circular(Neon.rLg),
        border: Border.all(color: Neon.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                color: tint.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, size: 15, color: tint),
            ),
            const SizedBox(width: 9),
            Text(title,
                style: TextStyle(
                    color: Neon.textHi,
                    fontSize: 14,
                    fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: 10),
          body,
        ],
      ),
    );
  }
}
