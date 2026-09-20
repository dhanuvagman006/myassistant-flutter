import 'package:flutter/material.dart';

import '../design/neon_tokens.dart';
import '../models/call_outcome.dart';
import '../services/api_service.dart';

/// CALLS THE ASSISTANT MADE — and what the other person said back.
///
/// His ask, 2026-09-20: "there is no any page where I can visit and see
/// what they have responded". The outcome used to exist only as a spoken
/// line in the moment the call ended: miss it, and it was gone. Every
/// call now leaves a row here with the reply and the full exchange.
class CallsScreen extends StatefulWidget {
  const CallsScreen({super.key});

  @override
  State<CallsScreen> createState() => _CallsScreenState();
}

class _CallsScreenState extends State<CallsScreen> {
  List<CallOutcome>? _calls;
  String? _error;
  final _expanded = <int>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final calls = await ApiService.fetchCallOutcomes();
      if (mounted) setState(() { _calls = calls; _error = null; });
    } catch (_) {
      if (mounted) {
        setState(() => _error = "Couldn't load your calls — pull down to try again.");
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Neon.bg,
      appBar: AppBar(
        backgroundColor: Neon.bg,
        title: const Text('Calls'),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        color: Neon.violet,
        backgroundColor: Neon.surface,
        child: _body(),
      ),
    );
  }

  Widget _body() {
    if (_calls == null && _error == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final calls = _calls ?? const <CallOutcome>[];
    if (calls.isEmpty) {
      // A scrollable empty state, or pull-to-refresh cannot be reached.
      return ListView(
        padding: const EdgeInsets.fromLTRB(20, 80, 20, 20),
        children: [
          Icon(Icons.phone_in_talk_rounded, size: 40, color: Neon.textDim),
          const SizedBox(height: 14),
          Text(
            _error ?? 'No calls yet',
            textAlign: TextAlign.center,
            style: TextStyle(color: Neon.textHi, fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(
            _error == null
                ? 'Ask me to call someone and pass on a message — "call Ravi '
                    'and tell him I\'ll be late". What they say back appears here.'
                : '',
            textAlign: TextAlign.center,
            style: TextStyle(color: Neon.textLo, fontSize: 13.5, height: 1.45),
          ),
        ],
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
      itemCount: calls.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (_, i) => _card(calls[i]),
    );
  }

  Widget _card(CallOutcome c) {
    final open = _expanded.contains(c.id);
    final tint = c.inProgress
        ? Neon.cyan
        : c.answered
            ? const Color(0xFF35C48D)
            : c.missed
                ? Neon.violet
                : Neon.error;
    final said = c.theirLines;

    return Material(
      color: Neon.surface,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: c.transcript.isEmpty
            ? null
            : () => setState(() =>
                open ? _expanded.remove(c.id) : _expanded.add(c.id)),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Neon.line),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(color: tint, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      c.contact.isEmpty ? 'Someone' : c.contact,
                      style: TextStyle(
                          color: Neon.textHi,
                          fontSize: 15,
                          fontWeight: FontWeight.w700),
                    ),
                  ),
                  Text(_when(c.createdAt),
                      style: TextStyle(color: Neon.textDim, fontSize: 11.5)),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                _headline(c),
                style: TextStyle(color: Neon.textLo, fontSize: 13.5, height: 1.4),
              ),
              // THE ANSWER IS THE POINT OF THE SCREEN, so their words get
              // their own block rather than being buried in the result line.
              if (said.isNotEmpty) ...[
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(11, 9, 11, 9),
                  decoration: BoxDecoration(
                    color: Neon.surfaceHigh,
                    borderRadius: BorderRadius.circular(11),
                    border: Border(left: BorderSide(color: tint, width: 2.5)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('They said',
                          style: TextStyle(
                              color: Neon.textDim,
                              fontSize: 10.5,
                              letterSpacing: 0.4,
                              fontWeight: FontWeight.w700)),
                      const SizedBox(height: 4),
                      Text(said.join('  ·  '),
                          style: TextStyle(
                              color: Neon.textHi, fontSize: 13.5, height: 1.4)),
                    ],
                  ),
                ),
              ],
              if (c.transcript.isNotEmpty) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Text(open ? 'Hide the call' : 'Read the whole call',
                        style: TextStyle(
                            color: tint, fontSize: 12.5, fontWeight: FontWeight.w600)),
                    Icon(open ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                        size: 17, color: tint),
                  ],
                ),
              ],
              if (open) ...[
                const SizedBox(height: 6),
                for (final turn in c.exchange)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 7),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 62,
                          child: Text(
                            turn.them
                                ? (c.contact.split(' ').first)
                                : 'Assistant',
                            style: TextStyle(
                                color: turn.them ? tint : Neon.textDim,
                                fontSize: 11.5,
                                fontWeight: FontWeight.w700),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(turn.text,
                              style: TextStyle(
                                  color: Neon.textLo, fontSize: 13, height: 1.4)),
                        ),
                      ],
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _headline(CallOutcome c) {
    if (c.detail.isNotEmpty) return c.detail;
    if (c.inProgress) return 'On the call now…';
    if (c.missed) return 'They did not pick up.';
    if (c.reason.isNotEmpty) return c.reason;
    return 'The call did not go through.';
  }

  String _when(int ms) {
    if (ms <= 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final diff = DateTime.now().difference(d);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    return '${d.day} ${months[d.month - 1]}';
  }
}
