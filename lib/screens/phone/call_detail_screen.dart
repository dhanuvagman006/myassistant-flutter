import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../design/apple_kit.dart';
import '../../design/motion.dart';
import '../../design/neon_tokens.dart';
import '../../design/neon_widgets.dart';
import '../../widgets/neon_cards.dart';
import '../../services/api_service.dart';
import '../../services/call_service.dart';
import '../../services/app_feedback.dart';

/// EVERYTHING THE ASSISTANT UNDERSTOOD ABOUT ONE CALL.
/// Summary, every extracted fact, what was filed onto the agenda, and the
/// full transcript — plus one tap to share the notes. This is the payoff
/// screen of call analysis: the difference between "it recorded" and
/// "it understood".
class CallDetailScreen extends StatefulWidget {
  final int callId;
  final String peerLabel;

  /// The list's own row for this call (Call notes), shown in the header
  /// while the full call loads — and what the row flies into.
  final Map<String, dynamic>? preview;
  const CallDetailScreen(
      {super.key, required this.callId, required this.peerLabel, this.preview});

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
      AppFeedback.show(r == null
              ? "Couldn't draft one right now — try again."
              : 'Nothing on this call needs a follow-up.', context: context);
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
        AppFeedback.copied(context, 'Copied — paste it anywhere.');
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
      AppFeedback.show(how == 'whatsapp'
              ? "The chat app isn't installed — try SMS."
              : "Couldn't open messages.", context: context);
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

  String get _when => _whenOf(_call ?? const {});

  String _whenOf(Map<String, dynamic> c) {
    final at = DateTime.fromMillisecondsSinceEpoch(
        (c['started_at'] as num?)?.toInt() ?? 0);
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
    // The header shows from the first frame when the list handed over its
    // row, so the row has somewhere to fly to (2026-09-30).
    final head = c ?? widget.preview;
    return NeonScaffold(
      appBar: appleAppBar(context, widget.peerLabel, actions: [
        if (c != null)
          IconButton(
            tooltip: 'Share call notes',
            onPressed: _share,
            icon: Icon(Icons.share_rounded, color: Neon.cyan, size: 20),
          ),
      ]),
      body: SafeArea(
        child: c == null
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (head != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                      child: _headerCard(head),
                    ),
                  Expanded(
                    child: StateSwitch(
                      state: _loading,
                      child: _loading
                          ? const NeonLoader.page()
                          : NeonErrorState(
                              message: "Couldn't load this call",
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
                      _headerCard(c),
                      const SizedBox(height: 12),
                      if ((c['summary'] ?? '').toString().isNotEmpty)
                        Reveal(
                            delayMs: 60,
                            child: NeonSection(
                              icon: Icons.subject_rounded,
                              title: 'What the call was about',
                              tone: NeonTone.info,
                              child: Text((c['summary'] ?? '').toString(),
                                  style: TextStyle(
                                      color: Neon.textLo,
                                      fontSize: NeonType.body,
                                      height: 1.5)),
                            )),
                      const SizedBox(height: 12),
                      Reveal(delayMs: 90, child: _followUpCard(c)),
                      if (_facts.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Reveal(
                            delayMs: 120,
                            child: NeonSection(
                              icon: Icons.fact_check_rounded,
                              title: 'Key points',
                              tone: NeonTone.tip,
                              child: Column(
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
                                                    fontSize:
                                                        NeonType.footnote,
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
                            child: NeonSection(
                              icon: Icons.event_available_rounded,
                              title: 'Added to your agenda',
                              tone: NeonTone.success,
                              child: Column(
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
                                                  fontSize:
                                                      NeonType.footnote)),
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
                        child: NeonSection(
                          icon: Icons.notes_rounded,
                          title: 'Transcript',
                          tone: NeonTone.discovery,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // Opens in place on the app's clock
                              // (2026-09-30; was a 220 ms cross-fade).
                              Collapse(
                                open: _showTranscript,
                                child: Padding(
                                  padding: const EdgeInsets.only(bottom: 8),
                                  child: Text(
                                      (c['transcript'] ?? '').toString(),
                                      style: TextStyle(
                                          color: Neon.textLo,
                                          fontSize: NeonType.footnote,
                                          height: 1.5)),
                                ),
                              ),
                              TextButton.icon(
                                onPressed: () => setState(
                                    () => _showTranscript = !_showTranscript),
                                style: TextButton.styleFrom(
                                  foregroundColor: Neon.pink,
                                  minimumSize: const Size(48, 48),
                                  padding: EdgeInsets.zero,
                                ),
                                icon: ExpandChevron(
                                    open: _showTranscript,
                                    color: Neon.pink,
                                    size: 18),
                                label: Text(
                                    _showTranscript
                                        ? 'Hide transcript'
                                        : 'Show full transcript',
                                    style: NeonType.manrope(
                                        NeonType.footnote, FontWeight.w600)),
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
    // THE PAGE'S NEXT STEP (2026-09-30): lit in the action tone, and its
    // buttons are the lit pills.
    return NeonSection(
      icon: Icons.send_rounded,
      title: 'Follow up with ${widget.peerLabel}',
      tone: NeonTone.action,
      lit: true,
      child: !has
          ? Align(
              alignment: Alignment.centerLeft,
              child: NeonPill(
                label: _drafting ? 'Drafting…' : 'Draft a follow-up message',
                icon: Icons.auto_awesome_rounded,
                tone: NeonTone.action,
                busy: _drafting,
                onPressed: _drafting ? null : _draftFollowUp,
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('What you agreed, ready to send. Edit it if you like.',
                    style: TextStyle(
                        color: Neon.textDim, fontSize: NeonType.caption)),
                const SizedBox(height: 8),
                Container(
                  decoration: BoxDecoration(
                    color: Neon.bg,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Neon.lineBright),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: TextField(
                    controller: _followUp,
                    minLines: 2,
                    maxLines: 6,
                    style: TextStyle(
                        color: Neon.textHi,
                        fontSize: NeonType.body,
                        height: 1.45),
                    decoration: const InputDecoration(
                      filled: false,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      contentPadding: EdgeInsets.symmetric(vertical: 10),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  children: [
                    NeonPill(
                        label: 'Chat app',
                        icon: Icons.chat_rounded,
                        tone: NeonTone.success,
                        onPressed: () => _sendVia('whatsapp')),
                    NeonPill(
                        label: 'SMS',
                        icon: Icons.sms_rounded,
                        tone: NeonTone.tip,
                        onPressed: () => _sendVia('sms')),
                    // Named at last: it was a bare icon a screen reader
                    // could not say.
                    NeonPill(
                        label: 'Copy',
                        icon: Icons.copy_rounded,
                        tone: NeonTone.info,
                        onPressed: () => _sendVia('copy')),
                  ],
                ),
              ],
            ),
    );
  }

  Widget _headerCard(Map<String, dynamic> c) {
    final dur = (c['duration_s'] as num?)?.toInt() ?? 0;
    final inc = c['direction'] == 'incoming';
    return cardHero(
      context,
      callHeroTag(widget.callId),
      RimCard(
        radius: Neon.rLg,
        tone: NeonTone.success,
        child: Row(children: [
          ToneTile(
              inc ? Icons.call_received_rounded : Icons.call_made_rounded,
              NeonTone.success,
              size: 40),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_whenOf(c),
                      style: NeonType.manrope(NeonType.body, FontWeight.w600)
                          .copyWith(color: Neon.textHi)),
                  if (dur > 0)
                    Text('${dur ~/ 60} min ${dur % 60} sec',
                        style: TextStyle(
                            color: Neon.textDim, fontSize: NeonType.caption)),
                ]),
          ),
        ]),
      ),
      cardRadius: Neon.rMd,
      pageRadius: Neon.rLg,
    );
  }
}

/// The tag a Call notes row and its call's header card fly under.
Object callHeroTag(int id) => cardHeroTag(('call', id));
