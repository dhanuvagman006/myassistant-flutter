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
  // Only images live in the in-app gallery. PDFs, and now the decks,
  // documents and sheets the assistant writes, go to whichever app on the
  // phone can open that type.
  if (!d.isImage) {
    openDocumentFile(d);
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
///
/// The one open path for anything that is not an image: the Documents
/// list, the recall gallery's Open button and a document received in chat.
Future<void> openDocumentFile(UserDocument d) async {
  AppFeedback.toast('Opening…', tone: FeedbackTone.progress);
  try {
    final file = await ApiService.downloadDocument(d.id);
    final dir = await getTemporaryDirectory();
    final safe = (d.title.isEmpty ? 'document' : d.title)
        .replaceAll(RegExp(r'[^A-Za-z0-9 _-]'), '')
        .trim();
    // The type the server sent wins over the card's: a chat attachment
    // from an older server arrives with none.
    final mime = extensionForMime(file.mime) != null ? file.mime : d.mime;
    final ext = extensionForMime(mime) ?? d.fileExtension;
    final path = '${dir.path}/${safe.isEmpty ? 'document' : safe}-${d.id}$ext';
    await File(path).writeAsBytes(file.bytes, flush: true);
    final res = await OpenFilex.open(path, type: mime);
    if (res.type != ResultType.done) {
      // Not an error the user caused, and not a dead end: Share hands the
      // same file to Google Slides/Docs/Sheets, Drive or WhatsApp, which
      // is how most phones open these without an Office app installed.
      AppFeedback.toast(d.isPdf
          ? 'No app on this phone can open PDFs — install a PDF reader.'
          : 'No app here opens a ${documentTypeLabel(d)} — use Share to open it in a '
              '${d.kind == 'sheet' ? 'spreadsheet' : d.kind == 'slides' ? 'slides' : 'documents'} app.');
    }
  } catch (_) {
    AppFeedback.toast("Couldn't open that document — try again.");
  }
}

/// Human name for the file type, used in labels and error copy.
String documentTypeLabel(UserDocument d) {
  // A video is kind "other" (it opens like any other file), but on the
  // grid it deserves its own name and glyph, not the blank grey one.
  if (d.mime.startsWith('video/')) return 'Video';
  switch (d.kind) {
    case 'pdf':
      return 'PDF';
    case 'slides':
      return 'PowerPoint';
    case 'doc':
      return 'Word document';
    case 'sheet':
      return d.mime == 'text/csv' ? 'CSV' : 'Excel sheet';
    case 'text':
      return 'Text file';
    default:
      return '';
  }
}

/// Icon + colour for a file that cannot be previewed as an image.
({IconData icon, Color color}) documentGlyph(UserDocument d) {
  if (d.mime.startsWith('video/')) {
    return (icon: Icons.movie_rounded, color: Neon.violet);
  }
  switch (d.kind) {
    case 'pdf':
      return (icon: Icons.picture_as_pdf_rounded, color: Neon.pink);
    case 'slides':
      return (icon: Icons.slideshow_rounded, color: Neon.violet);
    case 'doc':
      return (icon: Icons.description_rounded, color: Neon.cyan);
    case 'sheet':
      return (icon: Icons.table_chart_rounded, color: Neon.lime);
    case 'text':
      return (icon: Icons.notes_rounded, color: Neon.textLo);
    default:
      return (icon: Icons.insert_drive_file_rounded, color: Neon.textLo);
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
            child: Text('Delete', style: TextStyle(color: Neon.errorInk))),
      ],
    ),
  );
  return ok == true;
}

/// Thumbnail: image preview, or a type glyph on a neutral ground.
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
        child: !document.isImage
            ? Builder(builder: (_) {
                final g = documentGlyph(document);
                return Container(
                  color: Neon.surfaceHigh,
                  child: Icon(g.icon, color: g.color, size: 28),
                );
              })
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
              title: Text('Delete', style: TextStyle(color: Neon.errorInk)))),
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
    final type = documentTypeLabel(d);
    final meta = [
      if (date.isNotEmpty) date,
      if (cat.isNotEmpty) cat,
      if (cat.isEmpty && type.isNotEmpty) type,
    ].join(' · ');
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
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            height: 1.25)),
                    if (meta.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(meta,
                          style: TextStyle(color: Neon.textLo, fontSize: 13)),
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

/// "20 Sept 2026" inside an automatic title.
final _titleDate = RegExp(r'(\d{1,2}) ([A-Za-z]{3,4}) (\d{4})');

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
    // The file TYPE matters more than the date on a grid of thumbnails
    // that all look alike — a deck and a sheet are otherwise two identical
    // tiles. Images keep the plain date; they show what they are.
    final type = documentTypeLabel(d);
    // THE DATE ONCE (2026-09-24). Automatic titles already carry it, and
    // the line under them said it again in another spelling ("Document ·
    // 20 Sept 2026" over "PDF · 20 Sep 2026"). A date inside the title is
    // also held together, so it never breaks as "20 / Sept 2026".
    final titleHasDate = _titleDate.hasMatch(d.title);
    final title = d.title.replaceAllMapped(
        _titleDate, (m) => '${m[1]} ${m[2]} ${m[3]}');
    final date = [
      if (type.isNotEmpty) type,
      if (!titleHasDate) documentDateLabel(d),
    ].where((s) => s.isNotEmpty).join(' · ');
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
              Expanded(
                child: Stack(
                  children: [
                    Positioned.fill(
                        child: DocumentThumb(document: d, radius: 10)),
                    // Bills by email: it came from an outside sender.
                    if (d.fromEmail)
                      Positioned(
                        top: 4,
                        right: 4,
                        child: Semantics(
                          label: 'From email',
                          child: Container(
                            padding: const EdgeInsets.all(3),
                            decoration: BoxDecoration(
                              color: Neon.surface,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: Neon.line),
                            ),
                            child: Icon(Icons.mail_outline_rounded,
                                size: 14, color: Neon.textLo),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text(title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: NeonType.manrope(NeonType.footnote, FontWeight.w600)
                      .copyWith(color: Neon.textHi, height: 1.25)),
              if (date.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(date,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: Neon.textDim, fontSize: NeonType.caption)),
              ],
              if (d.expiryLabel() != null) ...[
                const SizedBox(height: 3),
                ExpiryBadge(document: d),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// When a policy, licence or passport runs out — amber inside a month,
/// red once lapsed. Renewal reminders are already set by the server.
class ExpiryBadge extends StatelessWidget {
  final UserDocument document;
  const ExpiryBadge({super.key, required this.document});

  @override
  Widget build(BuildContext context) {
    final label = document.expiryLabel();
    if (label == null) return const SizedBox.shrink();
    final days = document.daysToExpiry() ?? 999;
    final tint = days < 0
        ? Neon.error
        : days <= 30
            ? Neon.warning
            : Neon.success;
    // The words take the *Ink shade: amber words were 3.19:1 on white.
    final ink = days < 0
        ? Neon.errorInk
        : days <= 30
            ? Neon.warningInk
            : Neon.successInk;
    return Row(
      children: [
        Icon(days < 0 ? Icons.event_busy_rounded : Icons.event_available_rounded,
            size: 12, color: tint),
        const SizedBox(width: 4),
        Flexible(
          child: Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: NeonType.manrope(NeonType.caption, FontWeight.w600)
                  .copyWith(color: ink)),
        ),
      ],
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
          if (d.fromEmail)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 6, 20, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    d.sourceLabel.isEmpty
                        ? 'From email'
                        : 'From email · ${d.sourceLabel}',
                    style: TextStyle(
                        color: Neon.textLo, fontSize: NeonType.footnote),
                  ),
                  if (!d.sourceVerified)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        'Sender not confirmed — check it before paying.',
                        style: TextStyle(
                            color: Neon.warningInk,
                            fontSize: NeonType.footnote),
                      ),
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
            title: Text('Delete', style: TextStyle(color: Neon.errorInk)),
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
          AppFeedback.show("Couldn't prepare that to share.", context: context);
        }
      }
    case DocumentMenuAction.delete:
      onDelete();
  }
}
