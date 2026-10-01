import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:share_plus/share_plus.dart';

import '../design/apple_kit.dart';
import '../design/neon_tokens.dart';
import '../design/neon_widgets.dart';
import '../services/api_service.dart';
import '../widgets/chat_bubble.dart' show ChatAvatar;
import 'chat_group_screen.dart';
import 'chat_screen.dart';
import '../services/app_feedback.dart';
import '../design/motion.dart';

/// ─────────────────────────────────────────────────────────────────────
///  WHO CAN I TALK TO, AND WHO DO I HAVE TO INVITE.
///
///  His ask, 2026-09-22: "in the chat section I need an icon like we
///  have in WhatsApp to create a new chat and chat with those who are
///  using our app, and then down we need an invite section where we can
///  send invite for them who is not using our app."
///
///  One screen, two lists, from one server call: the people in your
///  address book who already have the app, and — below them — everybody
///  else, each with an invite button. The split is made on the server
///  from verified numbers, so it is never a guess.
///
///  THE LIST IS YOUR ADDRESS BOOK, NEVER A USER DIRECTORY. It answers
///  "which of my contacts are here", never "who else exists".
/// ─────────────────────────────────────────────────────────────────────
class ChatNewScreen extends StatefulWidget {
  const ChatNewScreen({super.key, this.pickForGroup = false});

  /// True when this is the member picker for a new group: taps select
  /// instead of opening a chat, and the invite list is hidden — you
  /// cannot put somebody who has no account into a group.
  final bool pickForGroup;

  @override
  State<ChatNewScreen> createState() => _ChatNewScreenState();
}

class _Person {
  final int userId;
  final String name, phone;
  const _Person(this.userId, this.name, this.phone);
}

class _ChatNewScreenState extends State<ChatNewScreen> {
  List<_Person>? _onApp;
  List<_Person> _invite = const [];
  final Set<int> _picked = {};
  String _query = '';
  String? _error;
  bool _creating = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await ApiService.getJson('/chat/directory');
      if (!mounted) return;
      List<_Person> read(String key) =>
          ((r?[key] as List?) ?? const [])
              .whereType<Map>()
              .map((p) => _Person(
                    (p['userId'] as num?)?.toInt() ?? 0,
                    (p['name'] ?? '').toString(),
                    (p['phone'] ?? '').toString(),
                  ))
              .toList();
      setState(() {
        _onApp = read('onApp');
        _invite = read('invite');
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not load your contacts.');
    }
  }

  Future<void> _sendInvite(_Person p) async {
    try {
      final r = await ApiService.getJson('/chat/invite');
      final text = (r?['text'] ?? '').toString();
      if (text.isEmpty) return;
      await Share.share(text);
    } catch (_) {
      if (mounted) {
        AppFeedback.show('Could not open the invite.', context: context);
      }
    }
  }

  Future<void> _createGroup() async {
    if (_picked.isEmpty || _creating) return;
    final name = await showAppDialog<String>(
      context: context,
      builder: (_) => const _NameDialog(),
    );
    if (name == null || name.trim().isEmpty) return;
    setState(() => _creating = true);
    final r = await ApiService.postJson('/chat/groups', {
      'title': name.trim(),
      'members': _picked.toList(),
    });
    if (!mounted) return;
    setState(() => _creating = false);
    final id = ((r?['group'] as Map?)?['id'] as num?)?.toInt();
    if (id == null) {
      AppFeedback.show('Could not create the group.', context: context);
      return;
    }
    Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) => ChatGroupScreen(groupId: id, title: name.trim()),
    ));
  }

  bool _matches(_Person p) =>
      _query.isEmpty ||
      p.name.toLowerCase().contains(_query) ||
      p.phone.contains(_query);

  @override
  Widget build(BuildContext context) {
    final onApp = (_onApp ?? const <_Person>[]).where(_matches).toList();
    final invite = _invite.where(_matches).toList();
    // 2026-09-30: under the app's sky; the FAB, the one primary action,
    // takes the theme's lit fill.
    return NeonScaffold(
      appBar: AppBar(
        title: Text(
          widget.pickForGroup ? 'Add people' : 'New chat',
          style: GoogleFonts.spaceGrotesk(fontWeight: FontWeight.w700),
        ),
      ),
      floatingActionButton: widget.pickForGroup && _picked.isNotEmpty
          ? FloatingActionButton.extended(
              onPressed: _creating ? null : _createGroup,
              icon: _creating
                  ? const NeonLoader.inline(semanticLabel: 'Creating the group')
                  : Icon(Icons.arrow_forward_rounded, color: Neon.onAccent),
              label: Text('${_picked.length} selected',
                  style: TextStyle(
                      color: Neon.onAccent, fontWeight: FontWeight.w700)),
            )
          : null,
      body: StateSwitch.of(_body(onApp, invite)),
    );
  }

  Widget _body(List<_Person> onApp, List<_Person> invite) {
    if (_error != null) {
      return NeonErrorState(
        message: _error!,
        onRetry: () {
          setState(() => _error = null);
          _load();
        },
      );
    }
    if (_onApp == null) return const NeonLoader.page();
    // Built as they scroll into view: an address book runs to hundreds.
    final rows = <Widget Function()>[
      if (onApp.isNotEmpty)
        () => _header('On My Assistant', onApp.length),
      for (var i = 0; i < onApp.length; i++)
        () => _segment(_personTile(onApp[i]),
            first: i == 0, last: i == onApp.length - 1),
      if (!widget.pickForGroup && invite.isNotEmpty) ...[
        () => _header('Invite to My Assistant', invite.length),
        for (var i = 0; i < invite.length; i++)
          () => _segment(_inviteTile(invite[i]),
              first: i == 0, last: i == invite.length - 1),
      ],
    ];
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
          child: AppleSearchField(
            hint: 'Search contacts',
            onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
          ),
        ),
        Expanded(
          child: onApp.isEmpty && invite.isEmpty
              // The shared empty state (2026-09-30). With a search typed,
              // the address book is not empty — nothing matched.
              ? (_query.isNotEmpty
                  ? NeonEmptyState(
                      icon: Icons.search_off_rounded,
                      title: 'No contacts match "$_query"',
                    )
                  : const NeonEmptyState(
                      icon: Icons.contacts_rounded,
                      title: 'No contacts synced yet',
                      body: 'Allow contacts access and they will appear '
                          'here.',
                    ))
              : ListView.builder(
                  padding: EdgeInsets.fromLTRB(
                      16, 0, 16, 110 + MediaQuery.paddingOf(context).bottom),
                  itemCount: rows.length,
                  itemBuilder: (_, i) => rows[i](),
                ),
        ),
      ],
    );
  }

  Widget _header(String text, int n) => Padding(
        padding: const EdgeInsets.only(top: 14),
        child: GroupLabel('$text  ·  $n'),
      );

  /// One row of a group that is built as it scrolls in: the same raised,
  /// violet-cast surface as [GroupedCard], rounded at the group's ends,
  /// with the inset hairline between rows.
  Widget _segment(Widget row, {required bool first, required bool last}) {
    const r = Radius.circular(18);
    return Material(
      color: Color.alphaBlend(Neon.violet.withValues(alpha: 0.06), Neon.surface),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
            top: first ? r : Radius.zero, bottom: last ? r : Radius.zero),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!first)
            Padding(
              padding: const EdgeInsets.only(left: 76),
              child: Divider(height: 1, thickness: 0.5, color: Neon.line),
            ),
          row,
        ],
      ),
    );
  }

  Widget _personTile(_Person p) {
    final selected = _picked.contains(p.userId);
    // AppleRow dips, ticks and ripples; a picked person's round turns into
    // the lit tick (2026-09-30).
    return Semantics(
      selected: widget.pickForGroup ? selected : null,
      child: AppleRow(
        onTap: () {
          if (widget.pickForGroup) {
            setState(() {
              selected ? _picked.remove(p.userId) : _picked.add(p.userId);
            });
          } else {
            Navigator.of(context).pushReplacement(MaterialPageRoute(
              builder: (_) => ChatThreadScreen(phone: p.phone, name: p.name),
            ));
          }
        },
        leading: ChatAvatar(name: p.name, selected: selected, radius: 22),
        title: p.name.isEmpty ? p.phone : p.name,
        subtitle: p.phone,
        trailing: widget.pickForGroup ? const SizedBox.shrink() : null,
      ),
    );
  }

  /// Invite is a secondary action on every row: a rim, no glow.
  Widget _inviteTile(_Person p) => AppleRow(
        leading: ChatAvatar(name: p.name, radius: 22),
        title: p.name.isEmpty ? p.phone : p.name,
        subtitle: p.phone,
        trailing: OutlinedButton(
          onPressed: () => _sendInvite(p),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(48, 40),
            tapTargetSize: MaterialTapTargetSize.padded,
          ),
          child: const Text('Invite',
              style: TextStyle(fontWeight: FontWeight.w700)),
        ),
      );
}

class _NameDialog extends StatefulWidget {
  const _NameDialog();
  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  final _c = TextEditingController();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Name this group'),
        content: TextField(
          controller: _c,
          autofocus: true,
          maxLength: 60,
          style: TextStyle(color: Neon.textHi),
          onSubmitted: (v) => Navigator.of(context).pop(v),
          decoration: InputDecoration(
            hintText: 'Weekend plans',
            hintStyle: TextStyle(color: Neon.textLo),
            counterText: '',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('Cancel', style: TextStyle(color: Neon.textLo)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(_c.text),
            style: TextButton.styleFrom(foregroundColor: Neon.violet),
            child: const Text('Create',
                style: TextStyle(fontWeight: FontWeight.w700)),
          ),
        ],
      );
}
