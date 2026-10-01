import 'dart:async';

import 'package:flutter/material.dart';

import '../../design/apple_kit.dart';
import '../../design/neon_tokens.dart';
import '../../design/neon_widgets.dart';
import '../../services/app_feedback.dart';
import '../../services/meetings_service.dart';
import 'meeting_detail_screen.dart';
import 'meeting_recorder_screen.dart';
import '../../design/motion.dart';
import '../../widgets/neon_cards.dart';

/// MEETINGS — every recorded meeting and its minutes.
class MeetingsScreen extends StatefulWidget {
  const MeetingsScreen({super.key});

  @override
  State<MeetingsScreen> createState() => _MeetingsScreenState();
}

class _MeetingsScreenState extends State<MeetingsScreen> {
  List<Map<String, dynamic>>? _items;
  bool _failed = false;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  /// [quiet] — the background poll: a miss keeps what is on screen.
  Future<void> _load({bool quiet = false}) async {
    final items = await MeetingsService.list();
    if (!mounted) return;
    if (items == null) {
      if (_items == null) {
        setState(() => _failed = true);
      } else if (!quiet) {
        AppFeedback.show("Couldn't refresh.",
            context: context, tone: FeedbackTone.error);
      }
      return;
    }
    setState(() {
      _items = items;
      _failed = false;
    });
    // Minutes being written arrive on their own: look again every ~10 s
    // while any row is still processing.
    _poll?.cancel();
    if (items.any((m) => m['status'] == 'processing')) {
      _poll = Timer(const Duration(seconds: 10), () => _load(quiet: true));
    }
  }

  Future<void> _record() async {
    await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const MeetingRecorderScreen()));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    // Under the night sky, with the theme's lit FAB (2026-09-30).
    return NeonScaffold(
      appBar: appleAppBar(context, 'Meetings'),
      // One "Record" on an empty screen: the empty state's (2026-09-30).
      floatingActionButton: (_items?.isEmpty ?? true)
          ? null
          : FloatingActionButton.extended(
              onPressed: _record,
              icon: const Icon(Icons.fiber_manual_record_rounded),
              label: const Text('Record a meeting'),
            ),
      body: SafeArea(child: StateSwitch.of(_body())),
    );
  }

  Widget _body() {
    final items = _items;
    if (items == null && _failed) {
      return NeonErrorState(
        message: "Couldn't load your meetings",
        onRetry: () {
          setState(() => _failed = false);
          _load();
        },
      );
    }
    if (items == null) return const NeonLoader.page();
    if (items.isEmpty) {
      return RefreshIndicator(
        color: Neon.violet,
        onRefresh: _load,
        child: ListView(children: [
          const SizedBox(height: 80),
          NeonEmptyState(
            icon: Icons.groups_rounded,
            title: 'No meetings yet',
            body: 'Tap Record a meeting, or say "record this meeting". You '
                'get minutes, decisions and action items when it ends.',
            actionLabel: 'Record a meeting',
            actionIcon: Icons.fiber_manual_record_rounded,
            onAction: _record,
          ),
        ]),
      );
    }
    return RefreshIndicator(
      color: Neon.violet,
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
        itemCount: items.length,
        itemBuilder: (_, i) => _tile(items[i]),
      ),
    );
  }

  Widget _tile(Map<String, dynamic> m) {
    final status = (m['status'] ?? 'done').toString();
    final at = DateTime.fromMillisecondsSinceEpoch(
        (m['created_at'] as num?)?.toInt() ?? 0);
    final mins = (((m['duration_s'] as num?) ?? 0) / 60).round();
    final actions = (m['actions'] as List?)?.length ?? 0;
    final sub = switch (status) {
      'processing' => 'Writing the minutes…',
      'failed' => (m['summary'] ?? "Couldn't process this recording.").toString(),
      _ => (m['summary'] ?? '').toString(),
    };
    final id = (m['id'] as num).toInt();
    // The row grows into its minutes (2026-09-30); one being written is lit
    // in the assistant's cyan, one that failed in amber.
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: RimCard(
        tone: status == 'processing'
            ? NeonTone.tip
            : status == 'failed'
                ? NeonTone.warning
                : null,
        heroTag: meetingHeroTag(id),
        onTap: () async {
          await Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => MeetingDetailScreen(id: id, preview: m)));
          _load();
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(
                child: Text((m['title'] ?? 'Meeting').toString(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: NeonType.manrope(NeonType.callout, FontWeight.w600)
                        .copyWith(color: Neon.textHi)),
              ),
              if (status == 'processing')
                const NeonLoader.inline(
                    size: 14, semanticLabel: 'Writing the minutes'),
            ]),
            const SizedBox(height: 3),
            Text(
              [
                '${at.day}/${at.month}',
                if (mins > 0) '$mins min',
                if (status == 'done' && actions > 0)
                  '$actions action item${actions == 1 ? '' : 's'}',
              ].join(' · '),
              style: TextStyle(color: Neon.textDim, fontSize: NeonType.caption),
            ),
            if (sub.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(sub,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: status == 'failed'
                          ? Neon.warningInk
                          : status == 'processing'
                              ? Neon.cyanInk
                              : Neon.textLo,
                      fontSize: NeonType.footnote,
                      height: 1.4)),
            ],
          ],
        ),
      ),
    );
  }
}
