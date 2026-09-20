import 'dart:io';

import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import '../services/app_feedback.dart';

import '../design/neon_tokens.dart';
import '../features/assistant/widgets/action_cards.dart'
    show DocumentGalleryScreen, shareDocumentFile;
import '../models/user_document.dart';
import '../services/api_service.dart';

/// Shared document presentation for the two document areas (My documents,
/// a client's case file). One look, one set of actions — open, share,
/// delete — so the areas differ only in WHAT they list, never in how.

String documentCategoryLabel(String category) {
  switch (category) {
    case 'medical':
      return 'Medical';
    case 'prescription':
      return 'Prescription';
    case 'receipt':
      return 'Receipt';
    case 'bill':
      return 'Bill';
    case 'id':
      return 'ID';
    case 'ticket':
      return 'Ticket';
    default:
      return '';
  }
}

String documentDateLabel(UserDocument d) {
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];
  DateTime? dt;
  if (d.docDate.isNotEmpty) dt = DateTime.tryParse(d.docDate);
  if (dt == null && d.createdAt > 0) {
    dt = DateTime.fromMillisecondsSinceEpoch(d.createdAt);
  }
  if (dt == null) return '';
  return '${dt.day} ${months[dt.month - 1]} ${dt.year}';
}

/// Opens the document: images in the in-app gallery (with the optional
/// delete action), PDFs in the system viewer.
void openDocument(BuildContext context, UserDocument d,
    {List<UserDocument>? within,
    Future<bool> Function(UserDocument)? onDelete}) {
  if (d.isPdf) {
    _openPdf(context, d);
    return;
  }
  final list = within ?? [d];
  final idx = list.indexWhere((x) => x.id == d.id);
  Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => DocumentGalleryScreen(
      documents: list,
      initialIndex: idx < 0 ? 0 : idx,
      onDelete: onDelete,
    ),
  ));
}

/// PDFs OPEN THROUGH THE APP, NOT THE BROWSER.
///
/// This used to hand /docs/<id>/file straight to an external browser —
/// but that endpoint needs the session token, which a browser does not
/// have, so the server answered 404 and every saved PDF looked like it
/// had vanished ("I saved it to your documents" → "not found", reported
/// 2026-09-20). Images never hit this because they are fetched in-app
/// with auth headers. So: fetch the bytes with auth, write them to the
/// cache, and hand THAT file to whichever viewer the phone has.
Future<void> _openPdf(BuildContext context, UserDocument d) async {
  AppFeedback.toast('Opening…');
  try {
    final file = await ApiService.downloadDocument(d.id);
    final dir = await getTemporaryDirectory();
    final safe = (d.title.isEmpty ? 'document' : d.title)
        .replaceAll(RegExp(r'[^A-Za-z0-9 _-]'), '')
        .trim();
    final path =
        '${dir.path}/${safe.isEmpty ? 'document' : safe}-${d.id}.pdf';
    await File(path).writeAsBytes(file.bytes, flush: true);
    final res = await OpenFilex.open(path, type: 'application/pdf');
    if (res.type != ResultType.done) {
      AppFeedback.toast(
          'No app on this phone can open PDFs — install a PDF reader.');
    }
  } catch (_) {
    AppFeedback.toast("Couldn't open that document — try again.");
  }
}

/// "Delete this document?" — the only path that removes a document from
/// the account. Returns true when the user confirmed.
Future<bool> confirmDeleteDocument(BuildContext context, UserDocument d,
    {String? where}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: Neon.surface,
      surfaceTintColor: Colors.transparent,
      title: Text('Delete this document?',
          style: TextStyle(color: Neon.textHi)),
      content: Text(
        '"${d.title}" will be permanently removed from '
        '${where ?? 'your account'}. This cannot be undone.',
        style: TextStyle(color: Neon.textLo, height: 1.4),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel')),
        TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Delete', style: TextStyle(color: Neon.error))),
      ],
    ),
  );
  return ok == true;
}

/// Thumbnail: image preview, or a PDF glyph on a neutral ground.
class DocumentThumb extends StatelessWidget {
  final UserDocument document;
  final double radius;
  final int cacheWidth;
  const DocumentThumb(
      {super.key,
      required this.document,
      this.radius = 12,
      this.cacheWidth = 240});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox.expand(
        child: document.isPdf
            ? Container(
                color: Neon.surfaceHigh,
                child: Icon(Icons.picture_as_pdf_rounded,
                    color: Neon.pink, size: 28),
              )
            : Image.network(
                ApiService.documentFileUrl(document.id),
                headers: ApiService.imageHeaders,
                fit: BoxFit.cover,
                cacheWidth: cacheWidth,
                loadingBuilder: (_, child, p) => p == null
                    ? child
                    : Container(color: Neon.surfaceHigh),
                errorBuilder: (_, __, ___) => Container(
                  color: Neon.surfaceHigh,
                  child: Icon(Icons.broken_image_outlined,
                      color: Neon.textDim, size: 24),
                ),
              ),
      ),
    );
  }
}

enum DocumentMenuAction { open, share, delete }

/// Overflow menu shared by list and grid tiles.
Widget documentMenu({
  required VoidCallback onOpen,
  required VoidCallback onShare,
  required VoidCallback onDelete,
  Color? iconColor,
}) {
  return PopupMenuButton<DocumentMenuAction>(
    tooltip: 'More',
    icon: Icon(Icons.more_vert_rounded, color: iconColor ?? Neon.textLo, size: 20),
    onSelected: (a) {
      switch (a) {
        case DocumentMenuAction.open:
          onOpen();
        case DocumentMenuAction.share:
          onShare();
        case DocumentMenuAction.delete:
          onDelete();
      }
    },
    itemBuilder: (_) => [
      const PopupMenuItem(
          value: DocumentMenuAction.open,
          child: ListTile(
              dense: true,
              leading: Icon(Icons.open_in_full_rounded),
              title: Text('Open'))),
      const PopupMenuItem(
          value: DocumentMenuAction.share,
          child: ListTile(
              dense: true,
              leading: Icon(Icons.share_rounded),
              title: Text('Share'))),
      PopupMenuItem(
          value: DocumentMenuAction.delete,
          child: ListTile(
              dense: true,
              leading: Icon(Icons.delete_outline_rounded, color: Neon.error),
              title: Text('Delete', style: TextStyle(color: Neon.error)))),
    ],
  );
}

/// One row in a case file's document list.
class DocumentListTile extends StatelessWidget {
  final UserDocument document;
  final VoidCallback onOpen;
  final VoidCallback onShare;
  final VoidCallback onDelete;
  const DocumentListTile({
    super.key,
    required this.document,
    required this.onOpen,
    required this.onShare,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final d = document;
    final cat = documentCategoryLabel(d.category);
    final date = documentDateLabel(d);
    final meta = [if (date.isNotEmpty) date, if (cat.isNotEmpty) cat].join(' · ');
    return Material(
      color: Neon.surface,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onOpen,
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 12, 4, 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Neon.line),
          ),
          child: Row(
            children: [
              SizedBox(
                  width: 56,
                  height: 56,
                  child: DocumentThumb(document: d, radius: 10, cacheWidth: 130)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(d.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: Neon.textHi,
                            fontSize: 14.5,
                            fontWeight: FontWeight.w600,
                            height: 1.25)),
                    if (meta.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(meta,
                          style: TextStyle(color: Neon.textLo, fontSize: 12.5)),
                    ],
                  ],
                ),
              ),
              documentMenu(onOpen: onOpen, onShare: onShare, onDelete: onDelete),
            ],
          ),
        ),
      ),
    );
  }
}

/// One cell in the My documents grid.
class DocumentGridTile extends StatelessWidget {
  final UserDocument document;
  final VoidCallback onOpen;
  final VoidCallback onLongPress;
  const DocumentGridTile({
    super.key,
    required this.document,
    required this.onOpen,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final d = document;
    final date = documentDateLabel(d);
    return Material(
      color: Neon.surface,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onOpen,
        onLongPress: onLongPress,
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Neon.line),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: DocumentThumb(document: d, radius: 10)),
              const SizedBox(height: 8),
              Text(d.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: Neon.textHi,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      height: 1.25)),
              if (date.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(date,
                    style: TextStyle(color: Neon.textDim, fontSize: 11)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Bottom sheet of actions for a document (long-press on a grid tile).
Future<void> showDocumentActions(
  BuildContext context,
  UserDocument d, {
  required VoidCallback onOpen,
  required VoidCallback onDelete,
}) async {
  final action = await showModalBottomSheet<DocumentMenuAction>(
    context: context,
    backgroundColor: Neon.surface,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
            child: Row(
              children: [
                SizedBox(
                    width: 44,
                    height: 44,
                    child: DocumentThumb(document: d, radius: 8, cacheWidth: 100)),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(d.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: Neon.textHi,
                          fontWeight: FontWeight.w600,
                          fontSize: 15)),
                ),
              ],
            ),
          ),
          ListTile(
            leading: Icon(Icons.open_in_full_rounded, color: Neon.textHi),
            title: Text('Open', style: TextStyle(color: Neon.textHi)),
            onTap: () => Navigator.pop(ctx, DocumentMenuAction.open),
          ),
          ListTile(
            leading: Icon(Icons.share_rounded, color: Neon.textHi),
            title: Text('Share', style: TextStyle(color: Neon.textHi)),
            onTap: () => Navigator.pop(ctx, DocumentMenuAction.share),
          ),
          ListTile(
            leading: Icon(Icons.delete_outline_rounded, color: Neon.error),
            title: Text('Delete', style: TextStyle(color: Neon.error)),
            onTap: () => Navigator.pop(ctx, DocumentMenuAction.delete),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
  if (action == null || !context.mounted) return;
  switch (action) {
    case DocumentMenuAction.open:
      onOpen();
    case DocumentMenuAction.share:
      try {
        await shareDocumentFile(d);
      } catch (_) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text("Couldn't prepare that to share.")));
        }
      }
    case DocumentMenuAction.delete:
      onDelete();
  }
}
