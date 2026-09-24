import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../design/motion.dart';
import '../../design/neon_tokens.dart';
import '../../services/api_service.dart';
import '../../services/call_service.dart';

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

  // FOLLOW-UP. What the call agreed, as a message ready to send them.
  final _followUp = TextEditingController();
  bool _drafting = false;
  String? _number; // their number, from the call or the address book

  @override
  void dispose() {
    _followUp.dispose();
    super.dispose();
  }

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
      _followUp.text = (_call?['follow_up'] ?? '').toString();
    });
    _resolveNumber();
  }

  /// Their number: the call's own, else the saved contact by name —
  /// the phone's recorder names files by contact, not number.
  Future<void> _resolveNumber() async {
    final n = (_call?['peer_number'] ?? '').toString().trim();
    if (n.isNotEmpty) {
      _number = n;
      return;
    }
    final name = (_call?['peer_name'] ?? '').toString().trim();
    if (name.isEmpty) return;
    try {
      final found = await CallService.instance.findContacts(name);
      if (found.isNotEmpty) {
        final best = CallService.instance.bestNumber(found.first);
        if (best.isNotEmpty) {
          _number = best;
          return;
        }
      }
    } catch (_) {}
    try {
      final r = await ApiService.getJson(
          '/contacts/resolve?name=${Uri.encodeQueryComponent(name)}');
      final phone = ((r?['match'] as Map?)?['phone'] ?? '').toString();
      if (phone.isNotEmpty) _number = phone;
    } catch (_) {}
  }

  Future<void> _draftFollowUp() async {
    setState(() => _drafting = true);
    final r = await ApiService.sendJson('/calls/${widget.callId}/follow-up');
    if (!mounted) return;
    final text = (r?['followUp'] ?? '').toString();
    setState(() {
      _drafting = false;
      if (text.isNotEmpty) _followUp.text = text;
    });
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(r == null
              ? "Couldn't draft one right now — try again."
              : 'Nothing on this call needs a follow-up.')));
    }
  }

  /// WhatsApp wants the number with its country code and no symbols.
  String? get _waNumber {
    final d = (_number ?? '').replaceAll(RegExp(r'[^0-9]'), '');
    if (d.isEmpty) return null;
    if (d.length == 10) return '91$d';
    if (d.length == 11 && d.startsWith('0')) return '91${d.substring(1)}';
    return d;
  }

  Future<void> _sendVia(String how) async {
    final text = _followUp.text.trim();
    if (text.isEmpty) return;
    HapticFeedback.lightImpact();
    if (how == 'copy') {
      await Clipboard.setData(ClipboardData(text: text));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Copied — paste it anywhere.')));
      }
      return;
    }
    final enc = Uri.encodeComponent(text);
    final Uri uri;
    if (how == 'whatsapp') {
      final wa = _waNumber;
      uri = Uri.parse(wa == null
          ? 'whatsapp://send?text=$enc'
          : 'whatsapp://send?phone=$wa&text=$enc');
    } else {
      final to = (_number ?? '').replaceAll(RegExp(r'[^0-9+]'), '');
      uri = Uri.parse('sms:$to?body=$enc');
    }
    // Opens the app with the message filled in — the user taps send.
    var ok = false;
    try {
      ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(how == 'whatsapp'
              ? "WhatsApp isn't installed — try SMS."
              : "Couldn't open messages.")));
    }
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
                      const SizedBox(height: 12),
                      Reveal(delayMs: 90, child: _followUpCard(c)),
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

  Widget _followUpCard(Map<String, dynamic> c) {
    final has = _followUp.text.trim().isNotEmpty;
    return _section(
      Icons.send_rounded,
      'Follow up with ${widget.peerLabel}',
      Neon.success,
      !has
          ? Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: _drafting ? null : _draftFollowUp,
                icon: _drafting
                    ? SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                            strokeWidth: 1.8, color: Neon.success))
                    : Icon(Icons.auto_awesome_rounded,
                        size: 16, color: Neon.success),
                label: Text(
                    _drafting ? 'Drafting…' : 'Draft a follow-up message',
                    style: TextStyle(color: Neon.textHi, fontSize: 13)),
                style: OutlinedButton.styleFrom(
                  side: BorderSide(
                      color: Neon.success.withValues(alpha: 0.45)),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('What you agreed, ready to send. Edit it if you like.',
                    style: TextStyle(color: Neon.textDim, fontSize: 12)),
                const SizedBox(height: 8),
                Container(
                  decoration: BoxDecoration(
                    color: Neon.bg,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Neon.line),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: TextField(
                    controller: _followUp,
                    minLines: 2,
                    maxLines: 6,
                    style: TextStyle(
                        color: Neon.textHi, fontSize: 13.5, height: 1.45),
                    decoration: const InputDecoration(
                      filled: false,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      contentPadding: EdgeInsets.symmetric(vertical: 10),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(
                    child: _sendButton(Icons.chat_rounded, 'WhatsApp',
                        const Color(0xFF25D366), () => _sendVia('whatsapp')),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _sendButton(Icons.sms_rounded, 'SMS', Neon.cyan,
                        () => _sendVia('sms')),
                  ),
                  const SizedBox(width: 8),
                  _sendButton(Icons.copy_rounded, '', Neon.textLo,
                      () => _sendVia('copy')),
                ]),
              ],
            ),
    );
  }

  Widget _sendButton(
      IconData icon, String label, Color tint, VoidCallback onTap) {
    return Material(
      color: tint.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(
              horizontal: label.isEmpty ? 14 : 10, vertical: 11),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 16, color: tint),
              if (label.isNotEmpty) ...[
                const SizedBox(width: 6),
                Text(label,
                    style: TextStyle(
                        color: Neon.textHi,
                        fontSize: 13,
                        fontWeight: FontWeight.w600)),
              ],
            ],
          ),
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
