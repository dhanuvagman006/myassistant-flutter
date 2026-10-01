import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../design/apple_kit.dart';
import '../design/motion.dart';
import '../design/neon_tokens.dart';
import '../design/neon_widgets.dart';
import '../models/call_outcome.dart';
import '../services/api_service.dart';
import '../services/app_feedback.dart';
import '../services/assistant_identity.dart';
import '../widgets/neon_cards.dart';

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
  // One player for the screen: the call being heard, if any.
  final AudioPlayer _player = AudioPlayer(playerId: 'agent_call_recording');
  int? _playingId;

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _togglePlay(CallOutcome c) async {
    if (_playingId == c.id) {
      await _player.stop();
      if (mounted) setState(() => _playingId = null);
      return;
    }
    try {
      await _player.stop();
      await _player.play(UrlSource(c.recordingUrl));
      if (mounted) setState(() => _playingId = c.id);
      _player.onPlayerComplete.first.then((_) {
        if (mounted && _playingId == c.id) setState(() => _playingId = null);
      });
    } catch (_) {
      if (mounted) {
        AppFeedback.show("Couldn't play the recording", context: context, tone: FeedbackTone.error);
      }
    }
  }

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
      if (!mounted) return;
      final have = _calls;
      if (have != null && have.isNotEmpty) {
        // The list on screen is still good: say the refresh missed.
        AppFeedback.show("Couldn't refresh.",
            context: context, tone: FeedbackTone.error);
      } else {
        setState(() => _error = "Couldn't load your calls");
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Under the night sky (2026-09-30).
    return NeonScaffold(
      appBar: appleAppBar(context, 'Calls'),
      body: RefreshIndicator(
        onRefresh: _load,
        color: Neon.violet,
        backgroundColor: Neon.surface,
        // No spinner flash on a quick load, and the list fades in.
        child: LoadSwitch(
          loading: _calls == null && _error == null,
          spinner: const NeonLoader.page(),
          child: StateSwitch.of(_body()),
        ),
      ),
    );
  }

  Widget _body() {
    if (_calls == null && _error == null) {
      return const NeonLoader.page();
    }
    final calls = _calls ?? const <CallOutcome>[];
    if (calls.isEmpty && _error != null) {
      // In a list, so pulling down still retries too.
      return ListView(
        padding: const EdgeInsets.only(top: 32),
        children: [
          NeonErrorState(
            message: _error!,
            onRetry: () {
              setState(() => _error = null);
              _load();
            },
          ),
        ],
      );
    }
    if (calls.isEmpty) {
      // A scrollable empty state, or pull-to-refresh cannot be reached.
      return ListView(
        padding: const EdgeInsets.only(top: 48),
        children: const [
          NeonEmptyState(
            icon: Icons.phone_in_talk_rounded,
            title: 'No calls yet',
            body: 'Ask me to call someone and pass on a message — "call Ravi '
                'and tell him I\'ll be late". What they say back appears here.',
            tone: NeonTone.success,
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
    final tone = callTone(c);
    final tint = tone.ink;
    final said = c.theirLines;
    final canOpen = c.transcript.isNotEmpty;
    final toggle = canOpen
        ? () => setState(
            () => open ? _expanded.remove(c.id) : _expanded.add(c.id))
        : null;

    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            // The state's own light, a lit dot.
            Container(
              width: 9,
              height: 9,
              decoration: BoxDecoration(
                color: tone.rim.first,
                shape: BoxShape.circle,
                boxShadow: Neon.halo(tone.rim.first, strength: 0.6),
              ),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                c.contact.isEmpty ? 'Someone' : c.contact,
                style: NeonType.manrope(NeonType.callout, FontWeight.w700)
                    .copyWith(color: Neon.textHi),
              ),
            ),
            Text(_when(c.createdAt),
                style: TextStyle(color: Neon.textDim, fontSize: NeonType.caption)),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          _headline(c),
          style: TextStyle(color: Neon.textLo, fontSize: NeonType.body, height: 1.4),
        ),
        // 2026-09-30 visual QA: a call that did not happen said so only
        // with a red dot when it had a task line ("Ask if a table…"); the
        // outcome is now written under it, in the dot's colour.
        if (c.detail.isNotEmpty && !c.answered && !c.inProgress) ...[
          const SizedBox(height: 4),
          Text(
            c.missed
                ? 'They did not pick up.'
                : c.reason.isNotEmpty
                    ? c.reason
                    : 'The call did not go through.',
            style: NeonType.manrope(NeonType.footnote, FontWeight.w600)
                .copyWith(color: tint, height: 1.35),
          ),
        ],
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
              border: Border(left: BorderSide(color: tone.rim.first, width: 2.5)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('They said',
                    style: NeonType.manrope(NeonType.caption, FontWeight.w700)
                        .copyWith(color: Neon.textDim, letterSpacing: 0.4)),
                const SizedBox(height: 4),
                Text(said.join('  ·  '),
                    style: TextStyle(
                        color: Neon.textHi, fontSize: NeonType.body, height: 1.4)),
              ],
            ),
          ),
        ],
        // What the caller wrote down for the user during the call.
        if (c.notes.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text('Noted for you',
              style: NeonType.manrope(NeonType.caption, FontWeight.w700)
                  .copyWith(color: Neon.textDim, letterSpacing: 0.4)),
          const SizedBox(height: 3),
          Text(c.notes.join(' '),
              style: TextStyle(color: Neon.textHi, fontSize: NeonType.body, height: 1.4)),
        ],
        // The recording itself, when the calling service kept one.
        if (c.recordingUrl.isNotEmpty) ...[
          const SizedBox(height: 8),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _togglePlay(c),
            child: Row(
              children: [
                Icon(_playingId == c.id ? Icons.stop_circle_rounded : Icons.play_circle_fill_rounded,
                    color: tint, size: 20),
                const SizedBox(width: 6),
                Text(_playingId == c.id ? 'Stop' : 'Hear the call',
                    style: NeonType.manrope(NeonType.footnote, FontWeight.w600)
                        .copyWith(color: tint)),
              ],
            ),
          ),
        ],
        if (canOpen) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Text(open ? 'Hide the call' : 'Read the whole call',
                  style: NeonType.manrope(NeonType.footnote, FontWeight.w600)
                      .copyWith(color: tint)),
              ExpandChevron(open: open, color: tint, size: 17),
            ],
          ),
        ],
        // The whole call opens in place, on the app's clock (2026-09-30).
        Collapse(
          open: open,
          child: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final turn in c.exchange)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 7),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // The name the user gave their assistant, in a
                        // column that grows with large text instead of
                        // cutting it to "Assis…".
                        ConstrainedBox(
                          constraints: BoxConstraints(
                              minWidth: 62,
                              maxWidth: MediaQuery.sizeOf(context).width * 0.3),
                          child: Text(
                            turn.them
                                ? (c.contact.split(' ').first)
                                : AssistantIdentity.name,
                            style: NeonType.manrope(NeonType.caption, FontWeight.w700)
                                .copyWith(color: turn.them ? tint : Neon.textDim),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(turn.text,
                              style: TextStyle(
                                  color: Neon.textLo,
                                  fontSize: NeonType.footnote,
                                  height: 1.4)),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );

    // A call on now is the one lit card on the page; a missed or failed
    // call wears its tone on the rim; an answered one sits quiet.
    if (c.inProgress) {
      return GlowCard(
        tone: tone,
        radius: Neon.rMd,
        padding: const EdgeInsets.all(14),
        onTap: toggle,
        child: body,
      );
    }
    return RimCard(
      tone: c.answered ? null : tone,
      onTap: toggle,
      tapHint: open ? 'hide the call' : 'read the whole call',
      child: body,
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

/// WHAT HAPPENED, AS LIGHT (2026-09-30): on the call now is the
/// assistant's cyan, answered is green, a missed call is danger red, a
/// call that did not go through is amber. Public for tests.
NeonTone callTone(CallOutcome c) => c.inProgress
    ? NeonTone.tip
    : c.answered
        ? NeonTone.success
        : c.missed
            ? NeonTone.danger
            : NeonTone.warning;
