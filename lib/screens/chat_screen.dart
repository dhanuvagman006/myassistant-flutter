import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../design/apple_kit.dart' show GroupedCard;
import '../design/dock_metrics.dart';
import '../design/motion.dart';
import '../design/neon_tokens.dart';
import '../design/neon_widgets.dart';
import '../features/assistant/widgets/action_cards.dart'
    show DocumentGalleryScreen;
import '../models/user_document.dart';
import '../services/api_service.dart';
import '../widgets/document_tile.dart'
    show documentGlyph, documentTypeLabel, openDocumentFile;
import '../widgets/chat_bubble.dart';
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

  /// The tab's name in the app's light at night, as [LargeTitle] draws it.
  static Widget _litTitle(Widget title) => Neon.isDark
      ? ShaderMask(
          blendMode: BlendMode.srcIn,
          shaderCallback: (r) =>
              LinearGradient(colors: [Neon.cyan, Neon.pink]).createShader(r),
          child: title,
        )
      : title;

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
                // 2026-09-30 visual QA: lit like Hub's and You's LargeTitle
                // (cyan into magenta at night); it was the one plain white
                // tab name.
                _litTitle(Text('Chat',
                    style: GoogleFonts.spaceGrotesk(
                        fontSize: 32,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.6,
                        color: Neon.isDark ? Colors.white : Neon.textHi))),
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
                  onPressed: _newChat,
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
              spinner: const NeonLoader.page(),
              // In a list, so pulling down still retries too.
              child: _error != null
                  ? ListView(children: [
                      const SizedBox(height: 32),
                      NeonErrorState(
                        message: _error!,
                        onRetry: () {
                          setState(() => _error = null);
                          _load();
                        },
                      ),
                    ])
                  : threads == null
                      ? const NeonLoader.page()
                      : (threads.isEmpty && _groups.isEmpty)
                          // 2026-09-30: the shared empty state, with the
                          // next step as its action.
                          ? ListView(children: [
                              const SizedBox(height: 32),
                              NeonEmptyState(
                                icon: Icons.forum_outlined,
                                title: 'No chats yet',
                                body: 'Say "send a message to <name>" or "send '
                                    'my <document> to <name>" — everything '
                                    'lands here.',
                                actionLabel: 'New chat',
                                actionIcon: Icons.edit_square,
                                onAction: _newChat,
                              ),
                            ])
                          // 2026-09-30: one lit group, like every list in
                          // the app, instead of bare Material rows.
                          : ListView(
                              // Clears the dock and the mic on every phone.
                              padding: EdgeInsets.fromLTRB(
                                  16, 4, 16, Dock.clearance(context)),
                              children: [
                                GroupedCard(
                                  dividerInset: 76,
                                  children: [
                                    for (final g in _groups) _groupTile(g),
                                    for (final t in threads) _tile(t),
                                  ],
                                ),
                              ],
                            ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _newChat() => Navigator.of(context)
      .push(MaterialPageRoute(builder: (_) => const ChatNewScreen()))
      .then((_) => _load());

  /// One row of the inbox: who, the last line, and on the right when and
  /// how many are unread. It dips under the finger, as every row does.
  Widget _row({
    required Widget leading,
    required String title,
    required String subtitle,
    required bool unread,
    required Widget trailing,
    required VoidCallback onTap,
  }) =>
      PressScale(
        scale: 0.985,
        child: InkWell(
          onTap: () {
            HapticFeedback.selectionClick();
            onTap();
          },
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 68),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
              child: Row(
                children: [
                  leading,
                  const SizedBox(width: 13),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: NeonType.manrope(NeonType.callout,
                                    unread ? FontWeight.w700 : FontWeight.w600)
                                .copyWith(color: Neon.textHi)),
                        const SizedBox(height: 2),
                        Text(subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: unread ? Neon.textHi : Neon.textLo,
                                fontSize: NeonType.footnote)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  trailing,
                ],
              ),
            ),
          ),
        ),
      );

  Widget _groupTile(_ChatGroup g) => _row(
        onTap: () => Navigator.of(context)
            .push(MaterialPageRoute(
              builder: (_) =>
                  ChatGroupScreen(groupId: g.id, title: g.title),
            ))
            .then((_) => _load()),
        leading: const ChatAvatar(icon: Icons.groups_rounded),
        title: g.title,
        subtitle: g.last.isEmpty ? '${g.members} members' : g.last,
        unread: g.unread > 0,
        trailing: g.unread > 0
            ? ChatUnreadBadge(g.unread)
            : const SizedBox.shrink(),
      );

  Widget _tile(_ChatThread t) => _row(
        onTap: () => Navigator.of(context)
            .push(MaterialPageRoute(
              builder: (_) => ChatThreadScreen(phone: t.phone, name: t.name),
            ))
            .then((_) => _load()),
        leading: ChatAvatar(name: t.name),
        title: t.name,
        subtitle: t.last,
        unread: t.unread > 0,
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(_when(t.lastAt),
                style: TextStyle(
                    color: t.unread > 0 ? Neon.cyanInk : Neon.textDim,
                    fontSize: NeonType.caption)),
            if (t.unread > 0) ...[
              const SizedBox(height: 4),
              ChatUnreadBadge(t.unread),
            ],
          ],
        ),
      );
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

  /// What the attached document IS, from the server (2026-09-27 on).
  final String? documentMime, documentTitle, media;
  _ChatItem(this.id, this.mine, this.text, this.at, this.auto, this.documentId,
      {this.deleted = false, this.documentMime, this.documentTitle, this.media});

  UserDocument? get document => documentId == null
      ? null
      : chatDocument(
          id: documentId!, mime: documentMime, title: documentTitle, media: media);
}

/// The document a chat message carries, shaped for the gallery and the
/// open path. Every attachment used to be built as a JPEG, so a PDF sent
/// by a contact showed "Couldn't load this document" and a video note sat
/// there as a broken picture. The server now says the type; a video note
/// is known by `media` even without it, and anything still unknown (an
/// older server) keeps the old guess, a photo.
@visibleForTesting
UserDocument chatDocument(
    {required int id, String? mime, String? title, String? media}) {
  final type = (mime ?? '').trim().isNotEmpty
      ? mime!.trim()
      : media == 'video'
          ? 'video/mp4'
          : 'image/jpeg';
  return UserDocument(
    id: id,
    filename: '',
    mime: type,
    title: (title ?? '').trim().isEmpty ? 'Document' : title!.trim(),
    category: 'other',
    docDate: '',
    summary: '',
    note: '',
    createdAt: 0,
  );
}

/// A chat attachment that is not a picture: the type's glyph, its title
/// and what it is ("PDF", "Video"). Tapping opens it.
class _AttachmentTile extends StatelessWidget {
  final UserDocument document;
  const _AttachmentTile({required this.document});

  @override
  Widget build(BuildContext context) {
    final g = documentGlyph(document);
    final type = documentTypeLabel(document);
    return Container(
      width: 190,
      constraints: const BoxConstraints(minHeight: 56),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Neon.surfaceHigh,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Neon.lineBright),
      ),
      child: Row(
        children: [
          Icon(g.icon, color: g.color, size: 26),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(document.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: Neon.textHi,
                        fontSize: 14,
                        fontWeight: FontWeight.w600)),
                if (type.isNotEmpty)
                  Text(type,
                      style: TextStyle(color: Neon.textLo, fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
    );
  }
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
                documentMime: m['documentMime'] as String?,
                documentTitle: m['documentTitle'] as String?,
                media: m['media'] as String?,
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

  Future<void> _openDocument(UserDocument doc) async {
    // The id references OUR copy of the file, so the gallery's viewer and
    // share button work exactly like any owned document. A photo or a
    // video note opens in the gallery (the video plays there); a PDF or
    // an office file goes through the signed-in download to the phone's
    // own viewer, as it does from My documents.
    if (!doc.isImage && !doc.mime.startsWith('video/')) {
      await openDocumentFile(doc);
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => DocumentGalleryScreen(documents: [doc]),
    ));
  }

  @override
  Widget build(BuildContext context) {
    // 2026-09-30: under the app's sky (NeonScaffold); the menu takes the
    // theme's floating surface.
    return NeonScaffold(
      appBar: AppBar(
        title: Text(widget.name,
            style: const TextStyle(fontSize: 17), maxLines: 1),
        actions: [
          PopupMenuButton<String>(
            popUpAnimationStyle: appMenuAnimation(context),
            onSelected: _onMenu,
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'mute',
                child: Text(_muted ? 'Unmute' : 'Mute notifications'),
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
                ? const NeonLoader.page()
                : _failed
                    // Scrolls when the keyboard leaves little room.
                    ? NeonErrorState(
                        message: "Couldn't load this conversation",
                        onRetry: () {
                          setState(() => _loading = true);
                          _load();
                        },
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
              // The keyboard's Send key sends, as in group chat; the rim
              // lights while typing, the send button glows (2026-09-30).
              child: ChatComposer(
                controller: _input,
                onSend: _send,
                sending: _sending,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 2026-09-30: the shared bubble (lib/widgets/chat_bubble.dart) — yours
  /// in the brand gradient with its halo, theirs on the raised surface
  /// with a rim.
  Widget _bubble(_ChatItem m) {
    final ink = ChatBubble.ink(m.mine), quiet = ChatBubble.quietInk(m.mine);
    final doc = m.document;
    return ChatBubble(
      mine: m.mine,
      onLongPress: m.deleted || m.id == 0 ? null : () => _messageMenu(m),
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
          if (doc != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Tappable(
                onTap: () => _openDocument(doc),
                semanticLabel: doc.isImage ? 'Photo: ${doc.title}' : null,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: !doc.isImage
                      // Not a picture: its type's glyph and title, not
                      // an Image.network that can only fail.
                      ? _AttachmentTile(document: doc)
                      : Image.network(
                          ApiService.documentFileUrl(m.documentId!),
                          headers: ApiService.imageHeaders,
                          width: 190,
                          height: 140,
                          fit: BoxFit.cover,
                          // Decoded at the size it is drawn (2026-09-24):
                          // 400 px was upscaled about 1.25x on his phone
                          // (190 dp at 2.625) and looked soft. A tenth
                          // over, for the crop.
                          cacheWidth: (190 *
                                  MediaQuery.devicePixelRatioOf(context) *
                                  1.1)
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
                    Icon(Icons.block_rounded, size: 13, color: quiet),
                    const SizedBox(width: 5),
                    Text('This message was deleted',
                        style: TextStyle(
                            color: quiet,
                            fontSize: 14,
                            fontStyle: FontStyle.italic)),
                  ],
                )
              : Text(m.text,
                  style: TextStyle(color: ink, fontSize: 14, height: 1.35)),
        ],
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
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Clear this chat?'),
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
