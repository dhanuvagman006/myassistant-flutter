import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../design/neon_tokens.dart';
import '../design/neon_widgets.dart';
import '../services/api_service.dart';
import '../services/app_feedback.dart';
import '../design/motion.dart';
import '../widgets/chat_bubble.dart';
import '../widgets/task_list_card.dart';

/// ─────────────────────────────────────────────────────────────────────
///  A GROUP, WITH THE ASSISTANT IN IT.
///
///  Text only for now, at his instruction. What makes this different
///  from any other group chat is the switch at the top: when it is on,
///  and a message arrives that you have not read for a few minutes, your
///  assistant may answer it for you — from your real schedule and the
///  things you have asked it to remember, never from a guess.
///
///  THE ONE LINE UNDER THE TITLE IS LOAD-BEARING. He asked that replies
///  not be labelled message by message and read as the person's own, and
///  they are not. What makes that fair rather than a trick is that every
///  member is told, plainly and in the room itself, that this is how the
///  room works. Nobody here is under an illusion; they simply are not
///  reminded on every line.
/// ─────────────────────────────────────────────────────────────────────
class ChatGroupScreen extends StatefulWidget {
  const ChatGroupScreen({super.key, required this.groupId, required this.title});

  final int groupId;
  final String title;

  /// The group on screen right now (its pushes are not shown as banners;
  /// the chat itself refreshes).
  static int? openGroupId;

  /// Bumped with the group id whenever a group message push arrives.
  static final ValueNotifier<int> pushed = ValueNotifier<int>(0);

  @override
  State<ChatGroupScreen> createState() => _ChatGroupScreenState();
}

class _Msg {
  final int id;
  final String name, text;
  final bool mine, deleted;
  final int at;

  /// A shared task list (2026-10-04); null for a plain message.
  final TaskList? tasks;
  const _Msg(this.id, this.name, this.text, this.mine, this.at, this.deleted,
      [this.tasks]);
}

class _ChatGroupScreenState extends State<ChatGroupScreen> {
  final _c = TextEditingController();
  final _scroll = ScrollController();
  List<_Msg> _messages = const [];
  bool _loading = true;

  /// The first load failed (offline): say so instead of spinning forever.
  bool _failed = false;
  bool _agentReplies = false;
  bool _muted = false;
  int _members = 0;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    ChatGroupScreen.openGroupId = widget.groupId;
    ChatGroupScreen.pushed.addListener(_onPush);
    _load();
    // The push nudge is the real-time signal; this keeps an open screen
    // honest without a socket.
    _poll = Timer.periodic(const Duration(seconds: 12), (_) {
      // LOADING THIS SCREEN MARKS THE GROUP READ, so polling it while
      // nobody is looking is not a harmless refresh. A phone in a pocket
      // with this screen still open marked every arriving message read
      // within 12 seconds, and the assistant then declined to answer on
      // the member's behalf — silently, in precisely the "they are away"
      // case the feature exists for. Both sibling pollers in
      // chat_screen.dart already gate on the app being on screen.
      if (!mounted ||
          ModalRoute.of(context)?.isCurrent != true ||
          WidgetsBinding.instance.lifecycleState !=
              AppLifecycleState.resumed) {
        return;
      }
      _load(quiet: true);
    });
  }

  @override
  void dispose() {
    if (ChatGroupScreen.openGroupId == widget.groupId) ChatGroupScreen.openGroupId = null;
    ChatGroupScreen.pushed.removeListener(_onPush);
    _poll?.cancel();
    _c.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// A message for this group just arrived: show it now, not in 12 s.
  void _onPush() {
    if (mounted && ChatGroupScreen.pushed.value == widget.groupId) _load(quiet: true);
  }

  Future<void> _load({bool quiet = false}) async {
    try {
      final r = await ApiService.getJson('/chat/groups/${widget.groupId}');
      if (!mounted) return;
      if (r == null) {
        if (!quiet) {
          setState(() {
            _loading = false;
            _failed = true;
          });
        }
        return;
      }
      final list = ((r['messages'] as List?) ?? const [])
          .whereType<Map>()
          .map((m) => _Msg(
                (m['id'] as num?)?.toInt() ?? 0,
                (m['name'] ?? '').toString(),
                (m['text'] ?? '').toString(),
                m['mine'] == true,
                (m['at'] as num?)?.toInt() ?? 0,
                m['deleted'] == true,
                TaskList.fromJson(m['tasks']),
              ))
          .toList();
      final grew = list.length != _messages.length;
      setState(() {
        _messages = list;
        _loading = false;
        _failed = false;
        _agentReplies = ((r['group'] as Map?)?['agentReplies'] == true);
        _muted = ((r['group'] as Map?)?['muted'] == true);
        _members = ((r['members'] as List?) ?? const []).length;
      });
      if (grew) _toBottom();
    } catch (_) {
      if (mounted && !quiet) {
        setState(() {
          _loading = false;
          _failed = true;
        });
      }
    }
  }

  void _toBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        final end = _scroll.position.maxScrollExtent;
        // Motion tokens (2026-09-30); a jump with animations off.
        if (Motion.reduced(context)) {
          _scroll.jumpTo(end);
        } else {
          _scroll.animateTo(end,
              duration: Motion.pageBack, curve: Motion.easeMove);
        }
      }
    });
  }

  Future<void> _send() async {
    final t = _c.text.trim();
    if (t.isEmpty) return;
    _c.clear();
    HapticFeedback.lightImpact();
    // Show it immediately; the reload reconciles with the server's id.
    setState(() {
      _messages = [
        ..._messages,
        _Msg(0, 'You', t, true, DateTime.now().millisecondsSinceEpoch, false),
      ];
    });
    _toBottom();
    await ApiService.postJson('/chat/groups/${widget.groupId}/send', {'text': t});
    await _load(quiet: true);
  }

  Future<void> _newTaskList() async {
    final shared = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => NewTaskListSheet(groupId: widget.groupId),
    );
    if (shared == true) await _load(quiet: true);
  }

  /// CLEARING AND LEAVING ARE NOT UNDOABLE, SO THEY ASK FIRST. Muting is,
  /// so it does not.
  Future<void> _onMenu(String v) async {
    if (v == 'mute') {
      final next = !_muted;
      setState(() => _muted = next);
      final r = await ApiService.postJson(
          '/chat/groups/${widget.groupId}/mute', {'muted': next});
      if (mounted) setState(() => _muted = r?['muted'] == true);
      return;
    }
    final leaving = v == 'leave';
    final ok = await _confirm(
      leaving ? 'Leave this group?' : 'Clear this chat?',
      leaving
          ? 'You will stop receiving messages here. What you have already '
              'sent stays for everyone else.'
          : 'This removes the messages from your copy only. Everyone else '
              'keeps theirs.',
      leaving ? 'Leave' : 'Clear',
    );
    if (!ok || !mounted) return;
    await ApiService.postJson(
        '/chat/groups/${widget.groupId}/${leaving ? 'leave' : 'clear'}', const {});
    if (!mounted) return;
    if (leaving) {
      Navigator.of(context).pop();
    } else {
      setState(() => _messages = const []);
      _load(quiet: true);
    }
  }

  Future<bool> _confirm(String title, String body, String action) async {
    final r = await showAppDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(c).pop(false),
            child: Text('Cancel', style: TextStyle(color: Neon.textLo)),
          ),
          TextButton(
            onPressed: () => Navigator.of(c).pop(true),
            style: TextButton.styleFrom(foregroundColor: Neon.errorInk),
            child: Text(action,
                style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    return r == true;
  }

  /// Long-press a message: copy it, or take it back.
  Future<void> _messageMenu(_Msg m) async {
    if (m.deleted || m.id == 0) return;
    HapticFeedback.selectionClick();
    final choice = await showAppSheet<String>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(Icons.copy_rounded, color: Neon.textHi),
              title: Text('Copy', style: TextStyle(color: Neon.textHi)),
              onTap: () => Navigator.of(c).pop('copy'),
            ),
            if (m.mine)
              ListTile(
                leading: Icon(Icons.undo_rounded, color: Neon.error),
                title: Text('Delete for everyone',
                    style: TextStyle(color: Neon.errorInk)),
                onTap: () => Navigator.of(c).pop('everyone'),
              ),
            ListTile(
              leading: Icon(Icons.visibility_off_rounded, color: Neon.textHi),
              title: Text('Delete for me', style: TextStyle(color: Neon.textHi)),
              onTap: () => Navigator.of(c).pop('me'),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == 'copy') {
      await Clipboard.setData(ClipboardData(text: m.text));
      if (mounted) {
        AppFeedback.copied(context);
      }
      return;
    }
    await ApiService.deleteJson(
        '/chat/groups/${widget.groupId}/messages/${m.id}'
        '${choice == 'everyone' ? '?everyone=1' : ''}');
    if (mounted) _load(quiet: true);
  }

  Future<void> _toggleAgent(bool v) async {
    setState(() => _agentReplies = v);
    HapticFeedback.selectionClick();
    final r = await ApiService.postJson(
        '/chat/groups/${widget.groupId}/agent', {'enabled': v});
    if (!mounted) return;
    // The server's answer wins — never leave a switch showing something
    // that did not take.
    setState(() => _agentReplies = r?['enabled'] == true);
  }

  @override
  Widget build(BuildContext context) {
    // 2026-09-30: under the app's sky; the menu takes the theme's surface.
    return NeonScaffold(
      appBar: AppBar(
        actions: [
          PopupMenuButton<String>(
            popUpAnimationStyle: appMenuAnimation(context),
            onSelected: _onMenu,
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'mute',
                child: Text(_muted ? 'Unmute' : 'Mute notifications'),
              ),
              const PopupMenuItem(
                value: 'clear',
                child: Text('Clear chat'),
              ),
              PopupMenuItem(
                value: 'leave',
                child: Text('Leave group', style: TextStyle(color: Neon.errorInk)),
              ),
            ],
          ),
        ],
        titleSpacing: 0,
        title: Row(children: [
          const ChatAvatar(icon: Icons.groups_rounded, radius: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.spaceGrotesk(
                        fontWeight: FontWeight.w700, fontSize: 17)),
                Text(
                  _members > 0 ? '$_members members' : 'Group',
                  style: TextStyle(color: Neon.textLo, fontSize: 12),
                ),
              ],
            ),
          ),
        ]),
      ),
      body: Column(
        children: [
          _agentBar(),
          Expanded(
            child: _loading
                ? const NeonLoader.page()
                : _failed && _messages.isEmpty
                    // Scrolls when the keyboard leaves little room.
                    ? NeonErrorState(
                        message: "Couldn't load this group",
                        onRetry: () {
                          setState(() {
                            _failed = false;
                            _loading = true;
                          });
                          _load();
                        },
                      )
                : _messages.isEmpty
                    // The shared empty state (2026-09-30); the box below
                    // is the next step.
                    ? const NeonEmptyState(
                        icon: Icons.forum_outlined,
                        title: 'No messages yet',
                        body: 'Say hello.',
                      )
                    : ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
                        itemCount: _messages.length,
                        itemBuilder: (_, i) => _bubble(_messages[i]),
                      ),
          ),
          _composer(),
        ],
      ),
    );
  }

  /// The switch, and the sentence that makes the whole design honest.
  /// LIT WHEN ON (2026-09-30): the room's one important state, so the
  /// card glows while assistants may answer here and sits quiet when not.
  Widget _agentBar() => Padding(
        padding: const EdgeInsets.fromLTRB(14, 4, 14, 4),
        child: GlowCard(
          tone: NeonTone.brand,
          radius: Neon.rMd,
          // Calm (2026-10-04): a setting, not an alert.
          rimWidth: 1,
          halo: 0,
          padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
          // One node for a screen reader: the switch is named by the words
          // beside it (it was an unlabelled toggle).
          child: MergeSemantics(
            child: Row(
              children: [
                Icon(Icons.support_agent_rounded,
                    size: 18,
                    color: _agentReplies ? Neon.violet : Neon.textLo),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Let my assistant reply here',
                        style: TextStyle(
                            color: Neon.textHi,
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'In this group, members’ assistants may answer for '
                        'them while they are away.',
                        style: TextStyle(
                            color: Neon.textLo, fontSize: 11.5, height: 1.3),
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: _agentReplies,
                  onChanged: _toggleAgent,
                ),
              ],
            ),
          ),
        ),
      );

  /// 2026-09-30: the shared bubble (lib/widgets/chat_bubble.dart) — yours
  /// in the brand gradient with its halo, theirs on the raised surface
  /// with a rim and the sender's first name in the accent.
  Widget _bubble(_Msg m) {
    final mine = m.mine;
    if (m.tasks != null && !m.deleted) {
      return TaskListCard(
        groupId: widget.groupId,
        list: m.tasks!,
        mine: mine,
        sender: mine ? '' : m.name,
        at: m.at,
        onLongPress: () => _messageMenu(m),
      );
    }
    final quiet = ChatBubble.quietInk(mine);
    return ChatBubble(
      mine: mine,
      at: m.at,
      maxWidthFactor: 0.74,
      onLongPress: m.deleted || m.id == 0 ? null : () => _messageMenu(m),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!mine && m.name.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Text(
                m.name.split(' ').first,
                style: GoogleFonts.spaceGrotesk(
                  color: Neon.cyanInk,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          m.deleted
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.block_rounded, size: 14, color: quiet),
                    const SizedBox(width: 6),
                    Text('This message was deleted',
                        style: TextStyle(
                            color: quiet,
                            fontSize: 14,
                            fontStyle: FontStyle.italic)),
                  ],
                )
              : Text(m.text,
                  style: TextStyle(
                      color: ChatBubble.ink(mine), fontSize: 15, height: 1.32)),
        ],
      ),
    );
  }

  // The Scaffold already lifts the body above the keyboard: adding the
  // keyboard's height again floated the box a keyboard-height too high and
  // overflowed the page. SafeArea keeps it off the gesture bar, as in the
  // one-to-one chat.
  Widget _composer() => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
          // The shared composer (2026-09-30): the rim lights while typing,
          // the send button glows.
          child: Row(children: [
            // TEAM TASK LIST (2026-10-04): share a checklist the group ticks off.
            IconButton(
              tooltip: 'Share a task list',
              onPressed: _newTaskList,
              icon: Icon(Icons.checklist_rounded, color: Neon.cyanInk),
            ),
            Expanded(
              child: ChatComposer(
                controller: _c,
                onSend: _send,
                hintText: 'Message',
                sendIcon: Icons.send_rounded,
                textCapitalization: TextCapitalization.none,
              ),
            ),
          ]),
        ),
      );
}
