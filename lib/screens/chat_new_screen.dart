import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:share_plus/share_plus.dart';

import '../design/neon_tokens.dart';
import '../services/api_service.dart';
import 'chat_group_screen.dart';
import 'chat_screen.dart';

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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open the invite.')),
        );
      }
    }
  }

  Future<void> _createGroup() async {
    if (_picked.isEmpty || _creating) return;
    final name = await showDialog<String>(
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not create the group.')),
      );
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
    return Scaffold(
      backgroundColor: Neon.bg,
      appBar: AppBar(
        backgroundColor: Neon.bg,
        title: Text(
          widget.pickForGroup ? 'Add people' : 'New chat',
          style: GoogleFonts.spaceGrotesk(fontWeight: FontWeight.w700),
        ),
      ),
      floatingActionButton: widget.pickForGroup && _picked.isNotEmpty
          ? FloatingActionButton.extended(
              onPressed: _creating ? null : _createGroup,
              backgroundColor: Neon.violet,
              icon: _creating
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.arrow_forward_rounded, color: Colors.white),
              label: Text('${_picked.length} selected',
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w700)),
            )
          : null,
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(_error!,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Neon.textLo)),
              ),
            )
          : _onApp == null
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
              : Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                      child: TextField(
                        onChanged: (v) =>
                            setState(() => _query = v.trim().toLowerCase()),
                        style: TextStyle(color: Neon.textHi),
                        decoration: InputDecoration(
                          isDense: true,
                          prefixIcon: Icon(Icons.search_rounded,
                              color: Neon.textLo, size: 20),
                          hintText: 'Search contacts',
                          hintStyle: TextStyle(color: Neon.textLo),
                          filled: true,
                          fillColor: Neon.surface,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.only(bottom: 110),
                        children: [
                          if (onApp.isEmpty && invite.isEmpty)
                            Padding(
                              padding: const EdgeInsets.all(32),
                              child: Text(
                                'No contacts synced yet. Allow contacts '
                                'access and they will appear here.',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                    color: Neon.textLo, height: 1.5),
                              ),
                            ),
                          if (onApp.isNotEmpty)
                            _header('On My Assistant', onApp.length),
                          ...onApp.map(_personTile),
                          if (!widget.pickForGroup && invite.isNotEmpty) ...[
                            _header('Invite to My Assistant', invite.length),
                            ...invite.map(_inviteTile),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
    );
  }

  Widget _header(String text, int n) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
        child: Text(
          '${text.toUpperCase()}  ·  $n',
          style: GoogleFonts.spaceGrotesk(
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.6,
            color: Neon.textLo,
          ),
        ),
      );

  Widget _avatar(String name, {bool selected = false}) => CircleAvatar(
        radius: 22,
        backgroundColor: selected ? Neon.violet : Neon.surfaceHigh,
        child: selected
            ? const Icon(Icons.check_rounded, color: Colors.white, size: 22)
            : Text(
                name.isNotEmpty ? name.characters.first.toUpperCase() : '?',
                style: TextStyle(
                    color: Neon.textHi, fontWeight: FontWeight.w700),
              ),
      );

  Widget _personTile(_Person p) {
    final selected = _picked.contains(p.userId);
    return ListTile(
      onTap: () {
        HapticFeedback.selectionClick();
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
      leading: _avatar(p.name, selected: selected),
      title: Text(p.name.isEmpty ? p.phone : p.name,
          style: TextStyle(color: Neon.textHi, fontWeight: FontWeight.w600)),
      subtitle: Text(p.phone, style: TextStyle(color: Neon.textLo, fontSize: 12.5)),
    );
  }

  Widget _inviteTile(_Person p) => ListTile(
        leading: _avatar(p.name),
        title: Text(p.name.isEmpty ? p.phone : p.name,
            style: TextStyle(color: Neon.textHi, fontWeight: FontWeight.w600)),
        subtitle:
            Text(p.phone, style: TextStyle(color: Neon.textLo, fontSize: 12.5)),
        trailing: TextButton(
          onPressed: () => _sendInvite(p),
          style: TextButton.styleFrom(foregroundColor: Neon.violet),
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
        backgroundColor: Neon.surface,
        title: Text('Name this group',
            style: GoogleFonts.spaceGrotesk(
                color: Neon.textHi, fontWeight: FontWeight.w700)),
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
