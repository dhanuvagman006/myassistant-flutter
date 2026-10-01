import 'dart:async';

import 'package:flutter/material.dart';

import '../design/apple_kit.dart';
import '../design/neon_tokens.dart';
import '../design/neon_widgets.dart';
import '../features/assistant/widgets/action_cards.dart'
    show DocumentGalleryScreen;
import '../models/client.dart';
import '../models/reminder.dart';
import '../models/user_document.dart';
import '../services/api_service.dart';
import 'chat_screen.dart';
import 'clients_screen.dart';
import 'reminders_screen.dart';
import '../design/motion.dart';

/// One chat thread as the search sees it.
class SearchChat {
  const SearchChat(this.phone, this.name, this.last);
  final String phone, name, last;
}

/// Everything search looks through, fetched once when it opens.
class SearchCorpus {
  const SearchCorpus({
    this.documents = const [],
    this.clients = const [],
    this.reminders = const [],
    this.chats = const [],
  });
  final List<UserDocument> documents;
  final List<Client> clients;
  final List<Reminder> reminders;
  final List<SearchChat> chats;

  /// The four lists side by side; one that fails leaves the rest usable.
  static Future<SearchCorpus> load() async {
    var failures = 0;
    Future<T> safe<T>(Future<T> f, T empty) => f.catchError((_) {
          failures++;
          return empty;
        });
    final r = await Future.wait([
      safe<List<UserDocument>>(
          ApiService.fetchDocuments(scope: 'all'), const []),
      safe<List<Client>>(ApiService.fetchClients(), const []),
      safe<List<Reminder>>(ApiService.fetchReminders(), const []),
      safe<Map<String, dynamic>?>(ApiService.getJson('/chat/threads'), null),
    ]);
    // getJson answers null for a failure; a real reply is at least a map.
    if (r[3] == null) failures++;
    // All four down is the network, not an empty account: let the screen
    // show its retry instead of "No results".
    if (failures >= 4) throw Exception('search: every fetch failed');
    final threads =
        (((r[3] as Map<String, dynamic>?)?['threads'] as List?) ?? const [])
            .whereType<Map>()
            .map((t) => SearchChat((t['phone'] ?? '').toString(),
                (t['name'] ?? '').toString(), (t['last'] ?? '').toString()))
            .toList();
    return SearchCorpus(
      documents: r[0] as List<UserDocument>,
      clients: r[1] as List<Client>,
      reminders: r[2] as List<Reminder>,
      chats: threads,
    );
  }
}

/// Matches for a query, per kind. Public for tests.
class SearchResults {
  const SearchResults(this.documents, this.clients, this.reminders, this.chats);
  final List<UserDocument> documents;
  final List<Client> clients;
  final List<Reminder> reminders;
  final List<SearchChat> chats;
  bool get isEmpty =>
      documents.isEmpty &&
      clients.isEmpty &&
      reminders.isEmpty &&
      chats.isEmpty;
}

/// Every word of the query must appear somewhere in the item — "ramesh
/// report" finds Ramesh's report, not every report and every Ramesh.
SearchResults searchCorpus(SearchCorpus c, String query) {
  final words = query
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .toList();
  if (words.isEmpty) return const SearchResults([], [], [], []);
  bool hit(List<String> fields) {
    final hay = fields.join(' ').toLowerCase();
    return words.every(hay.contains);
  }

  return SearchResults(
    c.documents
        .where((d) => hit(
            [d.title, d.summary, d.note, d.category, d.filename, d.docDate]))
        .take(20)
        .toList(),
    c.clients
        .where(
            (x) => hit([x.name, x.summary, x.tags, x.phone, x.email, x.kind]))
        .take(20)
        .toList(),
    c.reminders.where((x) => hit([x.text])).take(20).toList(),
    c.chats.where((x) => hit([x.name, x.last, x.phone])).take(20).toList(),
  );
}

/// SEARCH — find anything you have given the assistant, from one box.
///
/// Documents (yours and those filed under clients), clients and patients,
/// reminders and chats were each only findable from their own screen, or
/// by asking out loud. Everything is fetched once when search opens and
/// filtered as you type, so results appear with every keystroke.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, this.loader = SearchCorpus.load});

  final Future<SearchCorpus> Function() loader;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _query = TextEditingController();
  SearchCorpus? _corpus;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _failed = false);
    try {
      final c = await widget.loader();
      if (mounted) setState(() => _corpus = c);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  // The row gives the tick (AppleRow).
  void _open(Widget screen) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));

  @override
  Widget build(BuildContext context) {
    // 2026-09-30: under the app's sky.
    return NeonScaffold(
      appBar: AppBar(
        iconTheme: IconThemeData(color: Neon.textHi),
        titleSpacing: 0,
        title: TextField(
          controller: _query,
          autofocus: true,
          textInputAction: TextInputAction.search,
          style: TextStyle(color: Neon.textHi, fontSize: 17),
          decoration: InputDecoration(
            hintText: 'Search documents, clients, reminders…',
            hintStyle: TextStyle(color: Neon.textDim),
            border: InputBorder.none,
          ),
          onChanged: (_) => setState(() {}),
        ),
        actions: [
          if (_query.text.isNotEmpty)
            IconButton(
              tooltip: 'Clear',
              icon: const Icon(Icons.close_rounded),
              onPressed: () => setState(_query.clear),
            ),
        ],
      ),
      body: StateSwitch.of(_body()),
    );
  }

  Widget _body() {
    if (_failed) {
      return NeonErrorState(
          message: "Couldn't load your data to search", onRetry: _load);
    }
    final c = _corpus;
    if (c == null) {
      return const NeonLoader.page();
    }
    final q = _query.text.trim();
    if (q.isEmpty) {
      final total = c.documents.length +
          c.clients.length +
          c.reminders.length +
          c.chats.length;
      // "Search across 0 documents, 0 clients…" read like a fault.
      return _hint(
          Icons.search_rounded,
          'Find anything',
          total == 0
              ? 'Search your documents, clients, reminders and chats.'
              : 'Search across ${c.documents.length} documents, ${c.clients.length} clients, '
                  '${c.reminders.length} reminders and ${c.chats.length} chats.');
    }
    final r = searchCorpus(c, q);
    if (r.isEmpty) {
      return _hint(Icons.search_off_rounded, 'Nothing matches "$q".');
    }
    return ListView(
      padding: EdgeInsets.fromLTRB(
          12, 4, 12, 40 + MediaQuery.paddingOf(context).bottom),
      children: [
        if (r.documents.isNotEmpty) ...[
          _section('Documents', r.documents.length),
          _group([
            for (var i = 0; i < r.documents.length; i++)
              _row(
                icon: Icons.description_rounded,
                color: Neon.accentC,
                title: r.documents[i].title.isEmpty
                    ? r.documents[i].filename
                    : r.documents[i].title,
                subtitle: r.documents[i].summary,
                onTap: () => _open(DocumentGalleryScreen(
                    documents: r.documents, initialIndex: i)),
              ),
          ]),
        ],
        if (r.clients.isNotEmpty) ...[
          _section('Clients & patients', r.clients.length),
          _group([
            for (final x in r.clients)
              _row(
                icon: Icons.folder_shared_rounded,
                color: Neon.accentF,
                title: x.name,
                subtitle: x.summary.isNotEmpty ? x.summary : x.kind,
                onTap: () => _open(ClientDetailScreen(clientId: x.id)),
              ),
          ]),
        ],
        if (r.reminders.isNotEmpty) ...[
          _section('Reminders', r.reminders.length),
          _group([
            for (final x in r.reminders)
              _row(
                icon: x.done
                    ? Icons.check_circle_rounded
                    : Icons.notifications_active_rounded,
                color: Neon.accentA,
                title: x.text,
                subtitle: x.dueAt == null
                    ? 'Anytime'
                    : dueLabel(x.dueAt!, DateTime.now()),
                onTap: () => _open(const RemindersScreen()),
              ),
          ]),
        ],
        if (r.chats.isNotEmpty) ...[
          _section('Chats', r.chats.length),
          _group([
            for (final x in r.chats)
              _row(
                icon: Icons.forum_rounded,
                color: Neon.violet,
                title: x.name.isEmpty ? x.phone : x.name,
                subtitle: x.last,
                onTap: () =>
                    _open(ChatThreadScreen(phone: x.phone, name: x.name)),
              ),
          ]),
        ],
      ],
    );
  }

  /// The shared empty state (2026-09-30): the icon lit, [title] bold,
  /// [body] under it.
  Widget _hint(IconData icon, String title, [String? body]) =>
      NeonEmptyState(icon: icon, title: title, body: body);

  Widget _section(String title, int n) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 6, 8),
        child: Text('$title · $n',
            style: NeonType.manrope(NeonType.footnote, FontWeight.w700)
                .copyWith(color: Neon.textLo, letterSpacing: 0.3)),
      );

  /// A kind's matches: one lit group of rows, each with its kind's tile;
  /// the row dips and ticks under the finger (AppleRow, 2026-09-30).
  Widget _group(List<Widget> rows) =>
      GroupedCard(dividerInset: 64, children: rows);

  Widget _row({
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) =>
      AppleRow(
        leading: IconTile(icon, color),
        title: title,
        subtitle: subtitle,
        onTap: onTap,
      );
}
