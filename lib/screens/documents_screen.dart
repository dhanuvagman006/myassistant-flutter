import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../design/neon_tokens.dart';
import '../features/assistant/widgets/action_cards.dart'
    show DocumentGalleryScreen;
import '../models/user_document.dart';
import '../services/api_service.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  DOCUMENTS — everything the user ever scanned, shared in, generated or
///  received, in one place. Tap any tile to open the swipe gallery
///  (pinch-zoom, share, PDF open); documents received from other people
///  land here too.
/// ─────────────────────────────────────────────────────────────────────────
class DocumentsScreen extends StatefulWidget {
  const DocumentsScreen({super.key});

  @override
  State<DocumentsScreen> createState() => _DocumentsScreenState();
}

class _DocumentsScreenState extends State<DocumentsScreen> {
  List<UserDocument>? _docs; // null = loading
  String? _error;

  @override
  void initState() {
    super.initState();
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

  @override
  Widget build(BuildContext context) {
    final docs = _docs;
    return Scaffold(
      backgroundColor: Neon.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: Text('Documents',
            style: GoogleFonts.spaceGrotesk(
                fontWeight: FontWeight.w700, letterSpacing: -0.3)),
      ),
      body: RefreshIndicator(
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
            : docs == null
                ? Center(
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Neon.textLo))
                : docs.isEmpty
                    ? ListView(children: [
                        Padding(
                          padding: const EdgeInsets.all(32),
                          child: Text(
                            'Nothing saved yet.\n\nScan from the Home tab, '
                            'share a photo or PDF into the app from anywhere, '
                            'or just ask your assistant to save something — '
                            'it all lands here.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                color: Neon.textLo, height: 1.5, fontSize: 14),
                          ),
                        ),
                      ])
                    : GridView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          mainAxisSpacing: 10,
                          crossAxisSpacing: 10,
                          childAspectRatio: 0.78,
                        ),
                        itemCount: docs.length,
                        itemBuilder: (_, i) => _tile(docs, i),
                      ),
      ),
    );
  }

  Widget _tile(List<UserDocument> docs, int i) {
    final d = docs[i];
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
        builder: (_) =>
            DocumentGalleryScreen(documents: docs, initialIndex: i),
      )),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox.expand(
                child: d.isPdf
                    ? Container(
                        color: Neon.surfaceHigh,
                        child: Icon(Icons.picture_as_pdf_rounded,
                            color: Neon.pink, size: 30),
                      )
                    : Image.network(
                        ApiService.documentFileUrl(d.id),
                        headers: ApiService.imageHeaders,
                        fit: BoxFit.cover,
                        cacheWidth: 300,
                        errorBuilder: (_, __, ___) => Container(
                          color: Neon.surfaceHigh,
                          child: Icon(Icons.description_rounded,
                              color: Neon.cyan, size: 26),
                        ),
                      ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            d.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                color: Neon.textHi, fontSize: 11.5, height: 1.25),
          ),
        ],
      ),
    );
  }
}
