import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../design/dock_metrics.dart';
import '../design/motion.dart';
import '../design/neon_tokens.dart';
import '../features/assistant/widgets/action_cards.dart'
    show DocumentGalleryScreen;
import '../models/user_document.dart';
import '../services/api_service.dart';
import 'chat_group_screen.dart';
import 'chat_new_screen.dart';
import '../services/app_feedback.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  CHAT — the WhatsApp-style face of the agent-message rail.
///
///  Everything sent by voice ("message Allen that…"), typed here, or
///  delivered as a document shows in one thread per person. Reading a
///  thread marks it read server-side, so the assistant never re-speaks
///  what was already read on screen.
/// ─────────────────────────────────────────────────────────────────────────
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatThread {
  final String phone, name, last;
  final int lastAt, unread;
  _ChatThread(this.phone, this.name, this.last, this.lastAt, this.unread);
}

/// A group row. Kept as its own type rather than a flag on _ChatThread
/// because the two are addressed differently — a direct thread by phone,
/// a group by id — and one nullable field standing for "which kind" is
/// how the wrong screen gets opened.
class _ChatGroup {
  final int id, lastAt, unread, members;
  final String title, last;
  _ChatGroup(this.id, this.title, this.last, this.lastAt, this.unread, this.members);
}

class _ChatScreenState extends State<ChatScreen> {
  List<_ChatGroup> _groups = const [];
  List<_ChatThread>? _threads;
  String? _error;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _load();
    // Cheap staleness guard while the tab is visible; the push nudge is
    // the real-time signal, this just keeps the list honest.
    _poll = Timer.periodic(const Duration(seconds: 20), (_) {
      // IndexedStack keeps this alive from app start: without the gate it
      // polled the server every 20 s forever, even with the tab never
      // opened and the app in the background. TickerMode is false for
      // offstage IndexedStack children.
      // TickerMode alone was not enough: IndexedStack marks an offstage
      // child through its visibility scope, not TickerMode, so the gate
      // never closed and Chat polled from launch. Visibility.of reads it.
      if (!mounted ||
          !TickerMode.valuesOf(context).enabled ||
          !Visibility.of(context)) {
        return;
      }
      if (WidgetsBinding.instance.lifecycleState !=
          AppLifecycleState.resumed) {
        return;
      }
      _load();
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      // Both lists in parallel: a slow one must not hold up the other,
      // and a failed one must not blank the screen.
      final results = await Future.wait([
        ApiService.getJson('/chat/threads'),
        ApiService.getJson('/chat/groups'),
      ]);
      final r = results[0];
      final g = results[1];
      // getJson answers a failure with null rather than throwing, so being
      // offline read as "no chats yet" — an empty inbox, and the error
      // state below could never appear. Both failing is a failure.
      if (r == null && g == null) throw Exception('chats unreachable');
      if (!mounted) return;
      _groups = ((g?['groups'] as List?) ?? const [])
          .whereType<Map>()
          .map((x) => _ChatGroup(
                (x['id'] as num?)?.toInt() ?? 0,
                (x['title'] ?? '').toString(),
                (x['last'] ?? '').toString(),
                (x['lastAt'] as num?)?.toInt() ?? 0,
                (x['unread'] as num?)?.toInt() ?? 0,
                (x['members'] as num?)?.toInt() ?? 0,
              ))
          .toList();
      setState(() {
        _threads = ((r?['threads'] as List?) ?? const [])
            .whereType<Map>()
            .map((t) => _ChatThread(
                  (t['phone'] ?? '').toString(),
                  (t['name'] ?? '').toString(),
                  (t['last'] ?? '').toString(),
                  (t['lastAt'] as num?)?.toInt() ?? 0,
                  (t['unread'] as num?)?.toInt() ?? 0,
                ))
            .toList();
        _error = null;
      });
    } catch (_) {
      if (mounted && _threads == null) {
        setState(() => _error = "Couldn't load your chats.");
      }
    }
  }

  String _when(int ms) {
    if (ms <= 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    if (d.year == now.year && d.month == now.month && d.day == now.day) {
      final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
      return '$h:${d.minute.toString().padLeft(2, '0')} ${d.hour < 12 ? 'am' : 'pm'}';
    }
    return '${d.day}/${d.month}';
  }

  @override
  Widget build(BuildContext context) {
    final threads = _threads;
    return SafeArea(
      bottom: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The same large title as the other tabs (Hub, You).
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 10, 8),
            child: Row(
              children: [
                Text('Chat',
                    style: GoogleFonts.spaceGrotesk(
                        fontSize: 32,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.6,
                        color: Neon.textHi)),
                const Spacer(),
                // NEW GROUP, then NEW CHAT — the order they are reached
                // in: you make a group rarely and message somebody often,
                // so the common one sits nearest the thumb.
                IconButton(
                  tooltip: 'New group',
                  onPressed: () => Navigator.of(context)
                      .push(MaterialPageRoute(
                          builder: (_) =>
                              const ChatNewScreen(pickForGroup: true)))
                      .then((_) => _load()),
                  icon: Icon(Icons.group_add_rounded, color: Neon.textHi),
                ),
                IconButton(
                  tooltip: 'New chat',
                  onPressed: () => Navigator.of(context)
                      .push(MaterialPageRoute(
                          builder: (_) => const ChatNewScreen()))
                      .then((_) => _load()),
                  icon: Icon(Icons.edit_square, color: Neon.textHi),
                ),
              ],
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              color: Neon.violet,
              onRefresh: _load,
              // No spinner flash on a quick load, and the list fades in.
              child: LoadSwitch(
              loading: _error == null && threads == null,
              child: _error != null
                  ? ListView(children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(32, 64, 32, 32),
                        child: Column(children: [
                          Icon(Icons.cloud_off_rounded,
                              size: 34, color: Neon.textLo),
                          const SizedBox(height: 12),
                          Text("$_error Check your connection.",
                              textAlign: TextAlign.center,
                              style: TextStyle(color: Neon.textLo, height: 1.45)),
                          const SizedBox(height: 10),
                          TextButton.icon(
                            onPressed: () {
                              setState(() => _error = null);
                              _load();
                            },
                            icon: const Icon(Icons.refresh_rounded, size: 18),
                            label: const Text('Try again'),
                          ),
                        ]),
                      ),
                    ])
                  : threads == null
                      ? const Center(
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : (threads.isEmpty && _groups.isEmpty)
                          ? ListView(children: [
                              Padding(
                                padding: const EdgeInsets.fromLTRB(32, 64, 32, 32),
                                child: Column(children: [
                                  Icon(Icons.forum_outlined,
                                      size: 38, color: Neon.violet),
                                  const SizedBox(height: 14),
                                  Text(
                                    'No chats yet.\n\nSay "send a message to '
                                    '<name>" or "send my <document> to <name>" '
                                    '— everything lands here.',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                        color: Neon.textLo,
                                        height: 1.5,
                                        fontSize: 14),
                                  ),
                                ]),
                              ),
                            ])
                          : ListView.builder(
                              // Clears the dock and the mic on every phone.
                              padding: EdgeInsets.fromLTRB(
                                  12, 0, 12, Dock.clearance(context)),
                              itemCount: _groups.length + threads.length,
                              itemBuilder: (_, i) => i < _groups.length
                                  ? _groupTile(_groups[i])
                                  : _tile(threads[i - _groups.length]),
                            ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _groupTile(_ChatGroup g) => ListTile(
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        onTap: () => Navigator.of(context)
            .push(MaterialPageRoute(
              builder: (_) =>
                  ChatGroupScreen(groupId: g.id, title: g.title),
            ))
            .then((_) => _load()),
        leading: CircleAvatar(
          radius: 23,
          backgroundColor: Neon.violet.withValues(alpha: 0.18),
          child: Icon(Icons.groups_rounded, color: Neon.violet, size: 24),
        ),
        title: Text(g.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                color: Neon.textHi, fontWeight: FontWeight.w700, fontSize: 15)),
        subtitle: Text(
          g.last.isEmpty ? '${g.members} members' : g.last,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: Neon.textLo, fontSize: 13),
        ),
        trailing: g.unread > 0
            ? Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: Neon.violet,
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Text('${g.unread}',
                    style: TextStyle(
                        color: Neon.onAccent,
                        fontSize: 12,
                        fontWeight: FontWeight.w700)),
              )
            : null,
      );

  Widget _tile(_ChatThread t) {
    final initial =
        t.name.isNotEmpty ? t.name.characters.first.toUpperCase() : '?';
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      onTap: () => Navigator.of(context)
          .push(MaterialPageRoute(
            builder: (_) => ChatThreadScreen(phone: t.phone, name: t.name),
          ))
          .then((_) => _load()),
      leading: CircleAvatar(
        radius: 23,
        backgroundColor: Neon.surfaceHigh,
        child: Text(initial,
            style: TextStyle(
                color: Neon.violet,
                fontSize: 17,
                fontWeight: FontWeight.w700)),
      ),
      title: Text(t.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
              color: Neon.textHi,
              fontSize: 15,
              fontWeight: t.unread > 0 ? FontWeight.w700 : FontWeight.w600)),
      subtitle: Text(t.last,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
              color: t.unread > 0 ? Neon.textHi : Neon.textLo, fontSize: 13)),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(_when(t.lastAt),
              style: TextStyle(color: Neon.textDim, fontSize: 12)),
          const SizedBox(height: 4),
          if (t.unread > 0)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: Neon.violet,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text('${t.unread}',
                  style: TextStyle(
                      color: Neon.onAccent,
                      fontSize: 12,
                      fontWeight: FontWeight.w700)),
            ),
        ],
      ),
    );
  }
}

/* ====================================================================== */
/* One conversation                                                        */
/* ====================================================================== */

class _ChatItem {
  final int id;
  final bool mine, auto, deleted;
  final String text;
  final int at;
  final int? documentId;
  _ChatItem(this.id, this.mine, this.text, this.at, this.auto, this.documentId,
      {this.deleted = false});
}

class ChatThreadScreen extends StatefulWidget {
  final String phone, name;
  const ChatThreadScreen({super.key, required this.phone, required this.name});

  @override
  State<ChatThreadScreen> createState() => _ChatThreadScreenState();
}

class _ChatThreadScreenState extends State<ChatThreadScreen> {
  List<_ChatItem> _items = const [];
  bool _loading = true;

  /// Could not load (offline) and nothing to show: say so, don't show an
  /// empty conversation as if there were none.
  bool _failed = false;
  bool _muted = false;
  bool _sending = false;
  final _input = TextEditingController();
  final _scroll = ScrollController();
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _load();
    _poll = Timer.periodic(const Duration(seconds: 10), (_) {
      if (!mounted ||
          WidgetsBinding.instance.lifecycleState !=
              AppLifecycleState.resumed) {
        return;
      }
      _load();
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final r = await ApiService.getJson(
          '/chat/thread/${Uri.encodeComponent(widget.phone)}');
      if (!mounted) return;
      if (r == null) {
        // A failed refresh keeps what is on screen.
        setState(() {
          _loading = false;
          _failed = _items.isEmpty;
        });
        return;
      }
      final items = ((r['items'] as List?) ?? const [])
          .whereType<Map>()
          .map((m) => _ChatItem(
                (m['id'] as num?)?.toInt() ?? 0,
                m['mine'] == true,
                (m['text'] ?? '').toString(),
                (m['at'] as num?)?.toInt() ?? 0,
                m['auto'] == true,
                (m['documentId'] as num?)?.toInt(),
                deleted: m['deleted'] == true,
              ))
          .toList();
      final grew = items.length != _items.length;
      setState(() {
        _items = items;
        // The server owns this; without reading it back the menu label
        // reset to "Mute notifications" on every reopen.
        _muted = r['muted'] == true;
        _loading = false;
        _failed = false;
      });
      if (grew) _jumpToEnd();
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _failed = _items.isEmpty;
        });
      }
    }
  }

  void _jumpToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      final r = await ApiService.sendJson('/chat/send',
          method: 'POST', body: {'phone': widget.phone, 'text': text});
      if (r?['ok'] == true && mounted) {
        _input.clear();
        final m = r!['item'] as Map;
        setState(() => _items = [
              ..._items,
              _ChatItem((m['id'] as num).toInt(), true, text,
                  (m['at'] as num).toInt(), false, null),
            ]);
        _jumpToEnd();
      } else if (mounted) {
        AppFeedback.show("Couldn't send — are they on the app?", context: context);
      }
    } catch (_) {
      if (mounted) {
        AppFeedback.show("Couldn't send the message.", context: context);
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _openDocument(int id) async {
    // The id references OUR copy of the file, so the gallery's viewer and
    // share button work exactly like any owned document.
    final doc = UserDocument(
      id: id,
      filename: '',
      mime: 'image/jpeg',
      title: 'Document',
      category: 'other',
      docDate: '',
      summary: '',
      note: '',
      createdAt: 0,
    );
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => DocumentGalleryScreen(documents: [doc]),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Neon.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: Text(widget.name,
            style: const TextStyle(fontSize: 17), maxLines: 1),
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
                child:
                    Text('Clear chat', style: TextStyle(color: Neon.errorInk)),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                : _failed
                    ? Center(
                        // Scrolls: with the keyboard up there is little room.
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.all(32),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.cloud_off_rounded,
                                  size: 34, color: Neon.textLo),
                              const SizedBox(height: 12),
                              Text(
                                "Couldn't load this conversation. Check "
                                'your connection.',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                    color: Neon.textLo, height: 1.45),
                              ),
                              const SizedBox(height: 10),
                              TextButton.icon(
                                onPressed: () {
                                  setState(() => _loading = true);
                                  _load();
                                },
                                icon: const Icon(Icons.refresh_rounded,
                                    size: 18),
                                label: const Text('Try again'),
                              ),
                            ],
                          ),
                        ),
                      )
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
                    itemCount: _items.length,
                    itemBuilder: (_, i) => _bubble(_items[i]),
                  ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      minLines: 1,
                      maxLines: 4,
                      // The keyboard's Send key sends, as in group chat
                      // (a multi-line field made it type a newline).
                      keyboardType: TextInputType.text,
                      textInputAction: TextInputAction.send,
                      textCapitalization: TextCapitalization.sentences,
                      onSubmitted: (_) => _send(),
                      onEditingComplete: () {},
                      decoration: InputDecoration(
                        hintText: 'Message…',
                        filled: true,
                        fillColor: Neon.surfaceHigh,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 10),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: _sending ? null : _send,
                    style:
                        IconButton.styleFrom(backgroundColor: Neon.violet),
                    icon: _sending
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.send_rounded,
                            color: Colors.white, size: 20),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _bubble(_ChatItem m) {
    final align = m.mine ? Alignment.centerRight : Alignment.centerLeft;
    final bg = m.mine ? Neon.violet : Neon.surface;
    return Align(
      alignment: align,
      child: GestureDetector(
      onLongPress: () => _messageMenu(m),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
        constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.78),
        decoration: BoxDecoration(
          color: bg,
          border: m.mine ? null : Border.all(color: Neon.line),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(m.mine ? 16 : 4),
            bottomRight: Radius.circular(m.mine ? 4 : 16),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (m.auto)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text('assistant · auto-reply',
                    style: TextStyle(
                        color: m.mine
                            ? Neon.onAccent.withValues(alpha: 0.7)
                            : Neon.textDim,
                        fontSize: 12)),
              ),
            if (m.documentId != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: InkWell(
                  onTap: () => _openDocument(m.documentId!),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Image.network(
                      ApiService.documentFileUrl(m.documentId!),
                      headers: ApiService.imageHeaders,
                      width: 190,
                      height: 140,
                      fit: BoxFit.cover,
                      // Decoded at the size it is drawn (2026-09-24): 400
                      // px was upscaled about 1.25x on his phone (190 dp at
                      // 2.625) and looked soft. A tenth over, for the crop.
                      cacheWidth:
                          (190 * MediaQuery.devicePixelRatioOf(context) * 1.1)
                              .round(),
                      errorBuilder: (_, __, ___) => Container(
                        width: 190,
                        height: 60,
                        color: Neon.surfaceHigh,
                        child: Icon(Icons.description_rounded,
                            color: Neon.violet),
                      ),
                    ),
                  ),
                ),
              ),
            m.deleted
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.block_rounded,
                          size: 13,
                          color: m.mine
                              ? Neon.onAccent.withValues(alpha: 0.75)
                              : Neon.textLo),
                      const SizedBox(width: 5),
                      Text('This message was deleted',
                          style: TextStyle(
                              color: m.mine
                                  ? Neon.onAccent.withValues(alpha: 0.75)
                                  : Neon.textLo,
                              fontSize: 14,
                              fontStyle: FontStyle.italic)),
                    ],
                  )
                : Text(m.text,
                    style: TextStyle(
                        color: m.mine ? Neon.onAccent : Neon.textHi,
                        fontSize: 14,
                        height: 1.35)),
          ],
        ),
      ),
      ),
    );
  }

  /// Mute is reversible so it just happens; clearing is not, so it asks.
  Future<void> _onMenu(String v) async {
    if (v == 'mute') {
      final next = !_muted;
      setState(() => _muted = next);
      final r = await ApiService.postJson(
          '/chat/thread/${widget.phone}/mute', {'muted': next});
      if (mounted) setState(() => _muted = r?['muted'] == true);
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: Neon.surface,
        title: Text('Clear this chat?',
            style: TextStyle(color: Neon.textHi, fontWeight: FontWeight.w700)),
        content: Text(
          'This removes the messages from your copy only. '
          '${widget.name} keeps theirs.',
          style: TextStyle(color: Neon.textLo, height: 1.4, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(c).pop(false),
            child: Text('Cancel', style: TextStyle(color: Neon.textLo)),
          ),
          TextButton(
            onPressed: () => Navigator.of(c).pop(true),
            style: TextButton.styleFrom(foregroundColor: Neon.errorInk),
            child: const Text('Clear',
                style: TextStyle(fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await ApiService.postJson('/chat/thread/${widget.phone}/clear', const {});
    if (mounted) {
      setState(() => _items = []);
      _load();
    }
  }

  /// Long-press a message: copy it, or take it back. Same shape as the
  /// group screen's — one gesture, one sheet, no hidden swipe.
  Future<void> _messageMenu(_ChatItem m) async {
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
                    style: TextStyle(color: Neon.errorInk)),
                onTap: () => Navigator.of(c).pop('everyone'),
              ),
            ListTile(
              leading: Icon(Icons.visibility_off_rounded, color: Neon.textHi),
              title:
                  Text('Delete for me', style: TextStyle(color: Neon.textHi)),
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
        '/chat/message/${m.id}${choice == 'everyone' ? '?everyone=1' : ''}');
    if (mounted) _load();
  }
}
