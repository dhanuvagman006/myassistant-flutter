import 'package:flutter/material.dart';

import '../design/apple_kit.dart';
import '../design/motion.dart' show StateSwitch, Tappable;
import '../design/neon_tokens.dart';
import '../design/neon_widgets.dart';
import '../models/user_document.dart';
import '../services/api_service.dart';
import '../services/document_events.dart';
import '../widgets/document_tile.dart';
import '../services/app_feedback.dart';

/// MY DOCUMENTS — the user's OWN documents: scans, shared-in files, IDs,
/// receipts. Strictly the personal area: anything filed under a client or
/// patient lives in that case file (Clients & patients) and is never
/// listed here. Reads straight from the account, so it is identical after
/// a reinstall; the only way something leaves is an explicit delete.
class DocumentsScreen extends StatefulWidget {
  const DocumentsScreen({super.key});

  @override
  State<DocumentsScreen> createState() => _DocumentsScreenState();
}

class _DocumentsScreenState extends State<DocumentsScreen> {
  List<UserDocument>? _docs; // null = loading
  String? _error;
  int _seenVersion = DocumentEvents.version.value;

  @override
  void initState() {
    super.initState();
    DocumentEvents.version.addListener(_onDocumentsChanged);
    _load();
  }

  @override
  void dispose() {
    DocumentEvents.version.removeListener(_onDocumentsChanged);
    super.dispose();
  }

  void _onDocumentsChanged() {
    if (DocumentEvents.version.value == _seenVersion) return;
    _seenVersion = DocumentEvents.version.value;
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await ApiService.fetchDocuments();
      if (!mounted) return;
      setState(() {
        _docs = d;
        _error = null;
      });
    } catch (_) {
      if (!mounted) return;
      // Already loaded: keep the list and say the refresh missed.
      if (_docs != null) {
        AppFeedback.show("Couldn't refresh.",
            context: context, tone: FeedbackTone.error);
        return;
      }
      setState(() => _error = "Couldn't load your documents");
    }
  }

  /// Deletes on the server first; the list only changes once it confirmed.
  Future<bool> _delete(UserDocument d) async {
    final ok = await confirmDeleteDocument(context, d, where: 'My documents');
    if (!ok || !mounted) return false;
    try {
      await ApiService.deleteDocument(d.id);
      if (!mounted) return true;
      setState(() =>
          _docs = _docs?.where((x) => x.id != d.id).toList(growable: false));
      _seenVersion = DocumentEvents.version.value; // our own bump
      return true;
    } catch (_) {
      if (mounted) {
        AppFeedback.show("Couldn't delete. Check your connection and try again.", context: context);
      }
      return false;
    }
  }

  void _open(UserDocument d) =>
      openDocument(context, d, within: _docs, onDelete: _delete);

  @override
  Widget build(BuildContext context) {
    final docs = _docs;
    // 2026-09-30: under the app's sky; loading, empty and the grid
    // replace one another softly.
    return NeonScaffold(
      appBar: appleAppBar(context, 'My documents'),
      body: StateSwitch.of(_body(docs)),
    );
  }

  /// Policies, licences and passports running out within two months (or
  /// already lapsed), soonest first. Their reminders are already set.
  List<UserDocument> _renewals(List<UserDocument> docs) {
    final due = docs
        .where((d) => (d.daysToExpiry() ?? 999) <= 60)
        .toList()
      ..sort((a, b) => a.daysToExpiry()!.compareTo(b.daysToExpiry()!));
    return due;
  }

  /// What is running out: the screen's one lit card, in the warning tone
  /// (2026-09-30). Each line opens its document.
  Widget _renewalsCard(List<UserDocument> docs) {
    final due = _renewals(docs);
    return GlowCard(
      tone: NeonTone.warning,
      radius: Neon.rMd,
      rimWidth: 1.6,
      halo: 0.5,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.autorenew_rounded, size: 18, color: Neon.warning),
            const SizedBox(width: 8),
            Text(due.length == 1 ? '1 renewal coming up' : '${due.length} renewals coming up',
                style: TextStyle(
                    color: Neon.textHi,
                    fontSize: 14,
                    fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: 2),
          Text("You'll get reminders 30 days and 7 days before, and on the day.",
              style: TextStyle(color: Neon.textLo, fontSize: 12)),
          const SizedBox(height: 6),
          for (final d in due.take(4))
            Tappable(
              onTap: () => _open(d),
              scale: 0.985,
              // 48 dp to the finger: a 13 sp line was a 30 dp target.
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: Row(children: [
                  Expanded(
                    child: Text(d.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: Neon.textHi, fontSize: 13)),
                  ),
                  const SizedBox(width: 8),
                  // Bounded (2026-09-30): the badge's own Row flexes its
                  // words, which an unbounded slot here cannot allow.
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 170),
                    child: IntrinsicWidth(child: ExpiryBadge(document: d)),
                  ),
                ]),
              ),
            ),
        ],
      ),
    );
  }

  Widget _body(List<UserDocument>? docs) {
    if (_error != null) {
      return NeonErrorState(
        message: _error!,
        onRetry: () {
          setState(() {
            _error = null;
            _docs = null;
          });
          _load();
        },
      );
    }
    if (docs == null) return const NeonLoader.page();
    if (docs.isEmpty) {
      return RefreshIndicator(
        color: Neon.violet,
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(
              height: MediaQuery.of(context).size.height * 0.6,
              child: const NeonEmptyState(
                icon: Icons.description_outlined,
                title: 'No documents yet',
                body: 'Scan from the Home tab, share a photo or PDF into '
                    'the app, or ask your assistant to save something. '
                    'Documents filed under a client or patient appear in '
                    'their case file instead.',
              ),
            ),
          ],
        ),
      );
    }
    final width = MediaQuery.of(context).size.width;
    // 2026-09-30 visual QA: two across on a phone. At three (≈114 dp a
    // tile) the neon type cut every date and expiry to "12 Sep 20…" and
    // "Expires in 3…", and a two-line title shrank its thumbnail out of
    // line with its neighbours.
    final columns = width >= 900 ? 5 : width >= 600 ? 4 : width >= 440 ? 3 : 2;
    return RefreshIndicator(
      color: Neon.violet,
      onRefresh: _load,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
            sliver: SliverToBoxAdapter(
              child: Text(
                docs.length == 1 ? '1 document' : '${docs.length} documents',
                style: TextStyle(color: Neon.textLo, fontSize: 13),
              ),
            ),
          ),
          if (_renewals(docs).isNotEmpty)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              sliver: SliverToBoxAdapter(child: _renewalsCard(docs)),
            ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 120),
            sliver: SliverGrid(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: columns == 2 ? 0.95 : 0.72,
              ),
              delegate: SliverChildBuilderDelegate(
                (_, i) {
                  final d = docs[i];
                  return DocumentGridTile(
                    document: d,
                    onOpen: () => _open(d),
                    onLongPress: () => showDocumentActions(
                      context,
                      d,
                      onOpen: () => _open(d),
                      onDelete: () => _delete(d),
                    ),
                  );
                },
                childCount: docs.length,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
