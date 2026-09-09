import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../design/neon_tokens.dart';
import '../design/neon_widgets.dart';
import '../models/user_document.dart';
import '../services/api_service.dart';
import '../services/document_events.dart';
import '../widgets/document_tile.dart';

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
      setState(() => _error = "Couldn't load your documents.");
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
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text("Couldn't delete. Check your connection and try again.")));
      }
      return false;
    }
  }

  void _open(UserDocument d) =>
      openDocument(context, d, within: _docs, onDelete: _delete);

  @override
  Widget build(BuildContext context) {
    final docs = _docs;
    return Scaffold(
      backgroundColor: Neon.bg,
      appBar: AppBar(
        backgroundColor: Neon.bg,
        surfaceTintColor: Colors.transparent,
        title: Text('My documents',
            style: GoogleFonts.spaceGrotesk(
                fontWeight: FontWeight.w700, letterSpacing: -0.3)),
      ),
      body: _body(docs),
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
    if (docs == null) return const Center(child: NeonLoader());
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
    final columns = width >= 900 ? 5 : width >= 600 ? 4 : 3;
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
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 120),
            sliver: SliverGrid(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 0.72,
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
