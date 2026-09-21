import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../design/neon_tokens.dart';
import '../services/api_service.dart';

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

  @override
  State<ChatGroupScreen> createState() => _ChatGroupScreenState();
}

class _Msg {
  final int id;
  final String name, text;
  final bool mine, deleted;
  final int at;
  const _Msg(this.id, this.name, this.text, this.mine, this.at, this.deleted);
}

class _ChatGroupScreenState extends State<ChatGroupScreen> {
  final _c = TextEditingController();
  final _scroll = ScrollController();
  List<_Msg> _messages = const [];
  bool _loading = true;
  bool _agentReplies = false;
  bool _muted = false;
  int _members = 0;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _load();
    // The push nudge is the real-time signal; this keeps an open screen
    // honest without a socket.
    _poll = Timer.periodic(const Duration(seconds: 12), (_) {
      if (mounted && ModalRoute.of(context)?.isCurrent == true) _load(quiet: true);
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    _c.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load({bool quiet = false}) async {
    try {
      final r = await ApiService.getJson('/chat/groups/${widget.groupId}');
      if (!mounted || r == null) return;
      final list = ((r['messages'] as List?) ?? const [])
          .whereType<Map>()
          .map((m) => _Msg(
                (m['id'] as num?)?.toInt() ?? 0,
                (m['name'] ?? '').toString(),
                (m['text'] ?? '').toString(),
                m['mine'] == true,
                (m['at'] as num?)?.toInt() ?? 0,
                m['deleted'] == true,
              ))
          .toList();
      final grew = list.length != _messages.length;
      setState(() {
        _messages = list;
        _loading = false;
        _agentReplies = ((r['group'] as Map?)?['agentReplies'] == true);
        _muted = ((r['group'] as Map?)?['muted'] == true);
        _members = ((r['members'] as List?) ?? const []).length;
      });
      if (grew) _toBottom();
    } catch (_) {
      if (mounted && !quiet) setState(() => _loading = false);
    }
  }

  void _toBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 240), curve: Curves.easeOut);
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
    final r = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: Neon.surface,
        title: Text(title,
            style: GoogleFonts.spaceGrotesk(
                color: Neon.textHi, fontWeight: FontWeight.w700, fontSize: 17)),
        content: Text(body,
            style: TextStyle(color: Neon.textLo, height: 1.4, fontSize: 13.5)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(c).pop(false),
            child: Text('Cancel', style: TextStyle(color: Neon.textLo)),
          ),
          TextButton(
            onPressed: () => Navigator.of(c).pop(true),
            style: TextButton.styleFrom(foregroundColor: Neon.error),
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
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Neon.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
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
                    style: TextStyle(color: Neon.error)),
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
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Copied')));
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
    return Scaffold(
      backgroundColor: Neon.bg,
      appBar: AppBar(
        backgroundColor: Neon.bg,
        titleSpacing: 0,
        actions: [
          PopupMenuButton<String>(
            color: Neon.surface,
            onSelected: _onMenu,
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'mute',
                child: Text(_muted ? 'Unmute' : 'Mute notifications',
                    style: TextStyle(color: Neon.textHi)),
              ),
              PopupMenuItem(
                value: 'clear',
                child: Text('Clear chat', style: TextStyle(color: Neon.textHi)),
              ),
              PopupMenuItem(
                value: 'leave',
                child: Text('Leave group', style: TextStyle(color: Neon.error)),
              ),
            ],
          ),
        ],
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.title,
                style: GoogleFonts.spaceGrotesk(
                    fontWeight: FontWeight.w700, fontSize: 17)),
            Text(
              _members > 0 ? '$_members members' : 'Group',
              style: TextStyle(color: Neon.textLo, fontSize: 11.5),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          _agentBar(),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                : _messages.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(32),
                          child: Text(
                            'No messages yet. Say hello.',
                            style: TextStyle(color: Neon.textLo),
                          ),
                        ),
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
  Widget _agentBar() => Container(
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(14, 6, 14, 2),
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
        decoration: BoxDecoration(
          color: Neon.surface,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            Icon(Icons.support_agent_rounded,
                size: 19, color: _agentReplies ? Neon.violet : Neon.textLo),
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
                        color: Neon.textLo, fontSize: 11.5, height: 1.35),
                  ),
                ],
              ),
            ),
            Switch(
              value: _agentReplies,
              activeThumbColor: Colors.white,
              activeTrackColor: Neon.violet,
              onChanged: _toggleAgent,
            ),
          ],
        ),
      );

  Widget _bubble(_Msg m) {
    final mine = m.mine;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: () => _messageMenu(m),
        child: Container(
        constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.74),
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.fromLTRB(13, 9, 13, 9),
        decoration: BoxDecoration(
          color: mine ? Neon.violet.withValues(alpha: 0.22) : Neon.surface,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(mine ? 16 : 5),
            bottomRight: Radius.circular(mine ? 5 : 16),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!mine && m.name.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text(
                  m.name.split(' ').first,
                  style: GoogleFonts.spaceGrotesk(
                    color: Neon.violet,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            m.deleted
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.block_rounded,
                          size: 14, color: Neon.textLo),
                      const SizedBox(width: 6),
                      Text('This message was deleted',
                          style: TextStyle(
                              color: Neon.textLo,
                              fontSize: 14,
                              fontStyle: FontStyle.italic)),
                    ],
                  )
                : Text(m.text,
                    style: TextStyle(
                        color: Neon.textHi, fontSize: 15, height: 1.32)),
          ],
        ),
      ),
      ),
    );
  }

  Widget _composer() => Padding(
        padding: EdgeInsets.fromLTRB(
            12, 4, 12, 10 + MediaQuery.of(context).viewInsets.bottom),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _c,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _send(),
                style: TextStyle(color: Neon.textHi),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'Message',
                  hintStyle: TextStyle(color: Neon.textLo),
                  filled: true,
                  fillColor: Neon.surface,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              onPressed: _send,
              style: IconButton.styleFrom(backgroundColor: Neon.violet),
              icon: const Icon(Icons.arrow_upward_rounded, color: Colors.white),
            ),
          ],
        ),
      );
}
