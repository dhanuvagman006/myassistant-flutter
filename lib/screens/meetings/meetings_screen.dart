import 'package:flutter/material.dart';

import '../../design/apple_kit.dart';
import '../../design/neon_tokens.dart';
import '../../design/neon_widgets.dart';
import '../../services/meetings_service.dart';
import 'meeting_detail_screen.dart';
import 'meeting_recorder_screen.dart';

/// MEETINGS — every recorded meeting and its minutes.
class MeetingsScreen extends StatefulWidget {
  const MeetingsScreen({super.key});

  @override
  State<MeetingsScreen> createState() => _MeetingsScreenState();
}

class _MeetingsScreenState extends State<MeetingsScreen> {
  List<Map<String, dynamic>>? _items;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final items = await MeetingsService.list();
    if (mounted) setState(() => _items = items);
  }

  Future<void> _record() async {
    await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const MeetingRecorderScreen()));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Neon.bg,
      appBar: appleAppBar(context, 'Meetings'),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _record,
        backgroundColor: Neon.violet,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.fiber_manual_record_rounded),
        label: const Text('Record a meeting'),
      ),
      body: SafeArea(child: _body()),
    );
  }

  Widget _body() {
    final items = _items;
    if (items == null) return const Center(child: NeonLoader());
    if (items.isEmpty) {
      return RefreshIndicator(
        onRefresh: _load,
        child: ListView(children: const [
          SizedBox(height: 80),
          NeonEmptyState(
            icon: Icons.groups_rounded,
            title: 'No meetings yet',
            body: 'Tap Record a meeting, or say "record this meeting". You '
                'get minutes, decisions and action items when it ends.',
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
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: Neon.surface,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () async {
            await Navigator.of(context).push(MaterialPageRoute(
                builder: (_) =>
                    MeetingDetailScreen(id: (m['id'] as num).toInt())));
            _load();
          },
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Neon.line),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Expanded(
                    child: Text((m['title'] ?? 'Meeting').toString(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: Neon.textHi,
                            fontSize: 15,
                            fontWeight: FontWeight.w600)),
                  ),
                  if (status == 'processing')
                    SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                            strokeWidth: 1.8, color: Neon.cyan)),
                ]),
                const SizedBox(height: 3),
                Text(
                  [
                    '${at.day}/${at.month}',
                    if (mins > 0) '$mins min',
                    if (status == 'done' && actions > 0)
                      '$actions action item${actions == 1 ? '' : 's'}',
                  ].join(' · '),
                  style: TextStyle(color: Neon.textDim, fontSize: 12),
                ),
                if (sub.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(sub,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: status == 'failed'
                              ? Neon.warning
                              : status == 'processing'
                                  ? Neon.cyan
                                  : Neon.textLo,
                          fontSize: 13,
                          height: 1.4)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
