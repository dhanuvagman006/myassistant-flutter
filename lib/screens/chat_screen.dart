import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../design/neon_tokens.dart';
import '../features/assistant/widgets/action_cards.dart'
    show DocumentGalleryScreen;
import '../models/user_document.dart';
import '../services/api_service.dart';

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

class _ChatScreenState extends State<ChatScreen> {
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
      if (!mounted || !TickerMode.of(context)) return;
      if (WidgetsBinding.instance.lifecycleState !=
          AppLifecycleState.resumed) return;
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
      final r = await ApiService.getJson('/chat/threads');
      if (!mounted) return;
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
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 10),
            child: Text('Chat',
                style: GoogleFonts.spaceGrotesk(
                    fontSize: 27,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.5,
                    color: Neon.textHi)),
          ),
          Expanded(
            child: RefreshIndicator(
              color: Neon.cyan,
              onRefresh: _load,
              child: _error != null
                  ? ListView(children: [
                      Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text(_error!,
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Neon.textLo)),
                      ),
                    ])
                  : threads == null
                      ? const Center(
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : threads.isEmpty
                          ? ListView(children: [
                              Padding(
                                padding: const EdgeInsets.all(32),
                                child: Text(
                                  'No chats yet.\n\nSay "send a message to '
                                  '<name>" or "send my <document> to <name>" '
                                  '— everything lands here.',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                      color: Neon.textLo,
                                      height: 1.5,
                                      fontSize: 14),
                                ),
                              ),
                            ])
                          : ListView.builder(
                              padding:
                                  const EdgeInsets.fromLTRB(12, 0, 12, 120),
                              itemCount: threads.length,
                              itemBuilder: (_, i) => _tile(threads[i]),
                            ),
            ),
          ),
        ],
      ),
    );
  }

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
                color: Neon.cyan, fontSize: 17, fontWeight: FontWeight.w700)),
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
              color: t.unread > 0 ? Neon.textHi : Neon.textLo, fontSize: 12.5)),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(_when(t.lastAt),
              style: TextStyle(color: Neon.textDim, fontSize: 11)),
          const SizedBox(height: 4),
          if (t.unread > 0)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: Neon.cyan,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text('${t.unread}',
                  style: TextStyle(
                      color: Neon.onInk,
                      fontSize: 11,
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
  final bool mine, auto;
  final String text;
  final int at;
  final int? documentId;
  _ChatItem(this.id, this.mine, this.text, this.at, this.auto, this.documentId);
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
              AppLifecycleState.resumed) return;
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
      final items = ((r?['items'] as List?) ?? const [])
          .whereType<Map>()
          .map((m) => _ChatItem(
                (m['id'] as num?)?.toInt() ?? 0,
                m['mine'] == true,
                (m['text'] ?? '').toString(),
                (m['at'] as num?)?.toInt() ?? 0,
                m['auto'] == true,
                (m['documentId'] as num?)?.toInt(),
              ))
          .toList();
      final grew = items.length != _items.length;
      setState(() {
        _items = items;
        _loading = false;
      });
      if (grew) _jumpToEnd();
    } catch (_) {
      if (mounted) setState(() => _loading = false);
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
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text("Couldn't send — are they on the app?")));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Couldn't send the message.")));
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
      ),
      body: Column(
        children: [
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
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
                      textCapitalization: TextCapitalization.sentences,
                      onSubmitted: (_) => _send(),
                      decoration: InputDecoration(
                        hintText: 'Message…',
                        filled: true,
                        fillColor: Neon.surface,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 10),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(22),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: _sending ? null : _send,
                    style: IconButton.styleFrom(backgroundColor: Neon.cyan),
                    icon: _sending
                        ? SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Neon.onInk),
                          )
                        : Icon(Icons.send_rounded, color: Neon.onInk, size: 20),
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
    final bg = m.mine ? Neon.cyan.withValues(alpha: 0.16) : Neon.surface;
    return Align(
      alignment: align,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
        constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.78),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(15),
            topRight: const Radius.circular(15),
            bottomLeft: Radius.circular(m.mine ? 15 : 4),
            bottomRight: Radius.circular(m.mine ? 4 : 15),
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
                    style: TextStyle(color: Neon.textDim, fontSize: 10.5)),
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
                      cacheWidth: 400,
                      errorBuilder: (_, __, ___) => Container(
                        width: 190,
                        height: 60,
                        color: Neon.surfaceHigh,
                        child: Icon(Icons.description_rounded,
                            color: Neon.cyan),
                      ),
                    ),
                  ),
                ),
              ),
            Text(m.text,
                style: TextStyle(
                    color: Neon.textHi, fontSize: 14, height: 1.35)),
          ],
        ),
      ),
    );
  }
}
