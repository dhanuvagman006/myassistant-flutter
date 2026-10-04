import 'dart:async';

import 'package:flutter/material.dart';

import '../../design/apple_kit.dart';
import '../../design/dock_metrics.dart';
import '../../design/neon_tokens.dart';
import '../../design/neon_widgets.dart';
import '../../services/app_feedback.dart';
import '../../services/meetings_service.dart';
import 'meeting_detail_screen.dart';
import 'meeting_recorder_screen.dart';
import '../../design/motion.dart';
import '../../services/api_service.dart';
import '../../widgets/chat_bubble.dart';
import '../chat_group_screen.dart';
import '../chat_new_screen.dart';
import '../chat_screen.dart' show ChatThreadScreen;
import '../../widgets/neon_cards.dart';

/// RECORDED MEETINGS — every recorded meeting and its minutes (a side
/// feature of Meetings since 2026-10-04).
class RecordedMeetingsScreen extends StatefulWidget {
  const RecordedMeetingsScreen({super.key});

  @override
  State<RecordedMeetingsScreen> createState() => _RecordedMeetingsScreenState();
}

class _RecordedMeetingsScreenState extends State<RecordedMeetingsScreen> {
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
      appBar: appleAppBar(context, 'Recorded meetings'),
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

/// MEETINGS (owner, 2026-10-04): the groups you meet and talk in, like
/// WhatsApp — create a group, chat, get a notification for every message.
/// Recording a meeting is a side feature, one card at the top.
class MeetingsScreen extends StatefulWidget {
  const MeetingsScreen({super.key});

  @override
  State<MeetingsScreen> createState() => _MeetingsScreenState();
}

class _GroupRow {
  _GroupRow(this.id, this.title, this.last, this.lastAt, this.unread, this.members);
  final int id, lastAt, unread, members;
  final String title, last;
}

class _ThreadRow {
  _ThreadRow(this.phone, this.name, this.last, this.lastAt, this.unread);
  final String phone, name, last;
  final int lastAt, unread;
}

class _MeetingsScreenState extends State<MeetingsScreen> {
  List<_GroupRow>? _groups;
  List<_ThreadRow> _threads = const [];
  int _recorded = 0;
  bool _failed = false;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _load();
    ChatGroupScreen.pushed.addListener(_onPush);
    ChatThreadScreen.pushed.addListener(_onPush);
    // New messages and unread counts while the list is on screen.
    _poll = Timer.periodic(const Duration(seconds: 15), (_) {
      if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
      if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) return;
      _load(quiet: true);
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    ChatGroupScreen.pushed.removeListener(_onPush);
    ChatThreadScreen.pushed.removeListener(_onPush);
    super.dispose();
  }

  void _onPush() => _load(quiet: true);

  Future<void> _load({bool quiet = false}) async {
    final results = await Future.wait<Object?>([
      ApiService.getJson('/chat/groups'),
      MeetingsService.list(),
      ApiService.getJson('/chat/threads'),
    ]);
    if (!mounted) return;
    final g = results[0] as Map<String, dynamic>?;
    final meetings = results[1] as List?;
    final t = results[2] as Map<String, dynamic>?;
    if (g == null && t == null) {
      if (_groups == null) setState(() => _failed = true);
      return;
    }
    setState(() {
      _failed = false;
      _recorded = meetings?.length ?? _recorded;
      if (t != null) {
        _threads = ((t['threads'] as List?) ?? const [])
            .whereType<Map>()
            .map((x) => _ThreadRow(
                  (x['phone'] ?? '').toString(),
                  (x['name'] ?? '').toString(),
                  (x['last'] ?? '').toString(),
                  (x['lastAt'] as num?)?.toInt() ?? 0,
                  (x['unread'] as num?)?.toInt() ?? 0,
                ))
            .toList();
      }
      _groups = ((g?['groups'] as List?) ?? const [])
          .whereType<Map>()
          .map((x) => _GroupRow(
                (x['id'] as num?)?.toInt() ?? 0,
                (x['title'] ?? 'Group').toString(),
                (x['last'] ?? '').toString(),
                (x['lastAt'] as num?)?.toInt() ?? 0,
                (x['unread'] as num?)?.toInt() ?? 0,
                (x['members'] as num?)?.toInt() ?? 0,
              ))
          .toList();
    });
  }

  Future<void> _newGroup() async {
    await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const ChatNewScreen(pickForGroup: true)));
    _load(quiet: true);
  }

  Future<void> _newChat() async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const ChatNewScreen()));
    _load(quiet: true);
  }

  Future<void> _openThread(_ThreadRow t) async {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ChatThreadScreen(phone: t.phone, name: t.name)));
    _load(quiet: true);
  }

  /// One button, two choices, like a chat app's new-chat button.
  Future<void> _start() async {
    final pick = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      backgroundColor: Neon.surface,
      builder: (c) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ListTile(
              minTileHeight: 56,
              leading: Icon(Icons.person_rounded, color: Neon.violet),
              title: Text('New chat',
                  style: TextStyle(color: Neon.textHi, fontWeight: FontWeight.w600)),
              subtitle: Text('Message one person', style: TextStyle(color: Neon.textLo)),
              onTap: () => Navigator.of(c).pop('chat'),
            ),
            ListTile(
              minTileHeight: 56,
              leading: Icon(Icons.group_add_rounded, color: Neon.violet),
              title: Text('New group',
                  style: TextStyle(color: Neon.textHi, fontWeight: FontWeight.w600)),
              subtitle: Text('Your team, family or friends together',
                  style: TextStyle(color: Neon.textLo)),
              onTap: () => Navigator.of(c).pop('group'),
            ),
          ]),
        ),
      ),
    );
    if (!mounted) return;
    if (pick == 'chat') await _newChat();
    if (pick == 'group') await _newGroup();
  }

  Future<void> _open(_GroupRow g) async {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ChatGroupScreen(groupId: g.id, title: g.title)));
    _load(quiet: true);
  }

  Future<void> _recordings() async {
    await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const RecordedMeetingsScreen()));
    _load(quiet: true);
  }

  Future<void> _record() async {
    await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const MeetingRecorderScreen()));
    _load(quiet: true);
  }

  static String _when(int ms) {
    if (ms <= 0) return '';
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    if (t.year == now.year && t.month == now.month && t.day == now.day) {
      return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    }
    final y = now.subtract(const Duration(days: 1));
    if (t.year == y.year && t.month == y.month && t.day == y.day) return 'Yesterday';
    return '${t.day}/${t.month}';
  }

  /// CHATS TAB (owner, 2026-10-04): this screen is now a dock tab. As a
  /// tab it draws like Nearby (large title, no Scaffold, clear of the
  /// dock) with New chat beside the title; pushed, it keeps its app bar.
  bool _tab = false;

  @override
  Widget build(BuildContext context) {
    _tab = !(ModalRoute.of(context)?.canPop ?? false);
    if (_tab) {
      return Material(
        type: MaterialType.transparency,
        child: SafeArea(bottom: false, child: StateSwitch.of(_body())),
      );
    }
    return NeonScaffold(
      appBar: appleAppBar(context, 'Chats'),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _start,
        icon: const Icon(Icons.edit_square),
        label: const Text('New chat'),
      ),
      body: SafeArea(child: StateSwitch.of(_body())),
    );
  }

  Widget _body() {
    final groups = _groups;
    if (groups == null && _failed) {
      return NeonErrorState(
        message: "Couldn't load your groups",
        onRetry: () {
          setState(() => _failed = false);
          _load();
        },
      );
    }
    if (groups == null) return const NeonLoader.page();
    return RefreshIndicator(
      color: Neon.violet,
      onRefresh: _load,
      child: ListView(
        padding: EdgeInsets.fromLTRB(
            16, _tab ? 18 : 8, 16, _tab ? Dock.clearance(context) : 120),
        children: [
          if (_tab)
            Row(children: [
              const Expanded(child: LargeTitle('Chats')),
              IconButton.filledTonal(
                tooltip: 'New chat',
                onPressed: _start,
                icon: const Icon(Icons.edit_square),
              ),
            ]),
          _recordCard(),
          const SizedBox(height: 22),
          _section('Groups'),
          if (groups.isEmpty)
            _emptyRow('No groups yet', 'New group', _newGroup)
          else
            _grouped([for (final g in groups) _groupTile(g)]),
          const SizedBox(height: 18),
          _section('Chats'),
          if (_threads.isEmpty)
            _emptyRow('No chats yet', 'New chat', _newChat)
          else
            _grouped([for (final t in _threads) _threadTile(t)]),
        ],
      ),
    );
  }

  /// A section's rows on one surface, divided like a chat list.
  Widget _grouped(List<Widget> rows) => Container(
        decoration: BoxDecoration(
          color: Neon.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Neon.lineBright),
        ),
        clipBehavior: Clip.antiAlias,
        child: Material(
          type: MaterialType.transparency,
          child: Column(children: [
            for (var i = 0; i < rows.length; i++) ...[
              if (i > 0) Divider(height: 1, indent: 72, color: Neon.lineBright),
              rows[i],
            ],
          ]),
        ),
      );

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 8),
        child: Text(title,
            style: NeonType.manrope(NeonType.footnote, FontWeight.w700)
                .copyWith(color: Neon.textLo, letterSpacing: 0.4)),
      );

  /// A quiet empty line with its one action (not a full-page empty state:
  /// the other section may be full).
  Widget _emptyRow(String text, String action, VoidCallback onTap) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: RimCard(
          onTap: onTap,
          child: Row(children: [
            Expanded(
                child: Text(text,
                    style: TextStyle(color: Neon.textLo, fontSize: NeonType.footnote))),
            Text(action,
                style: TextStyle(
                    color: Neon.violet,
                    fontSize: NeonType.footnote,
                    fontWeight: FontWeight.w700)),
          ]),
        ),
      );

  Widget _threadTile(_ThreadRow t) {
    final unread = t.unread > 0;
    return InkWell(
      onTap: () => _openThread(t),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
        child: Row(
          children: [
            ChatAvatar(name: t.name),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(t.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: NeonType.manrope(
                              NeonType.callout, unread ? FontWeight.w700 : FontWeight.w600)
                          .copyWith(color: Neon.textHi)),
                  const SizedBox(height: 2),
                  Text(t.last,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: unread ? Neon.textHi : Neon.textLo,
                          fontSize: NeonType.footnote)),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(_when(t.lastAt),
                    style: TextStyle(
                        color: unread ? Neon.violet : Neon.textDim,
                        fontSize: NeonType.caption)),
                if (unread) ...[
                  const SizedBox(height: 4),
                  ChatUnreadBadge(t.unread),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _recordCard() => RimCard(
        tone: NeonTone.tip,
        onTap: _recordings,
        child: Row(
          children: [
            const ChatAvatar(icon: Icons.mic_rounded),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Record a meeting',
                      style: NeonType.manrope(NeonType.callout, FontWeight.w600)
                          .copyWith(color: Neon.textHi)),
                  const SizedBox(height: 2),
                  Text(
                    _recorded == 0
                        ? 'Minutes, decisions and action items'
                        : '$_recorded recorded · minutes and action items',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: Neon.textLo, fontSize: NeonType.footnote),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              tooltip: 'Start recording',
              onPressed: _record,
              style: IconButton.styleFrom(
                backgroundColor: Neon.accentFill,
                foregroundColor: Neon.onAccent,
                fixedSize: const Size(44, 44),
              ),
              icon: const Icon(Icons.fiber_manual_record_rounded, size: 18),
            ),
          ],
        ),
      );

  Widget _groupTile(_GroupRow g) {
    final unread = g.unread > 0;
    return InkWell(
      onTap: () => _open(g),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
        child: Row(
          children: [
            const ChatAvatar(icon: Icons.groups_rounded),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(g.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: NeonType.manrope(
                              NeonType.callout, unread ? FontWeight.w700 : FontWeight.w600)
                          .copyWith(color: Neon.textHi)),
                  const SizedBox(height: 2),
                  Text(g.last.isEmpty ? '${g.members} members' : g.last,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: unread ? Neon.textHi : Neon.textLo,
                          fontSize: NeonType.footnote)),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(_when(g.lastAt),
                    style: TextStyle(
                        color: unread ? Neon.violet : Neon.textDim,
                        fontSize: NeonType.caption)),
                if (unread) ...[
                  const SizedBox(height: 4),
                  ChatUnreadBadge(g.unread),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
