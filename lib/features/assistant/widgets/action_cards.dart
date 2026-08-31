import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../design/gyro_tilt.dart';
import '../../../design/neon_tokens.dart';
import '../../../models/user_document.dart';
import '../../../services/api_service.dart';
import '../../../theme/app_theme.dart';
import '../state/assistant_state.dart';

/// Shared glass card chrome for the dark assistant screen.
class _Glass extends StatelessWidget {
  final Widget child;
  final Color? borderTint;
  const _Glass({required this.child, this.borderTint});

  @override
  Widget build(BuildContext context) {
    return Padding(
      // Margin stays OUTSIDE the tilt so the layout box never moves —
      // only the painted card floats with the device.
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: GyroTilt(
        radius: 18,
        shadowColor: borderTint ?? Neon.violet,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: (borderTint ?? Colors.white).withValues(alpha: 0.14),
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Small "what I'm doing" chip — one per tool run.
class ToolCard extends StatelessWidget {
  final ToolActivity activity;
  const ToolCard({super.key, required this.activity});

  @override
  Widget build(BuildContext context) {
    return _Glass(
      child: Row(
        children: [
          activity.completed
              ? const Icon(Icons.check_circle_rounded,
                  size: 18, color: Color(0xFF35C48D))
              : const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: AppColors.peacockLight),
                ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              activity.label,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.85),
                fontSize: 13.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One web search hit — tappable to open the source.
class SearchResultCard extends StatelessWidget {
  final SearchResult result;
  const SearchResultCard({super.key, required this.result});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: () {
        final u = Uri.tryParse(result.url);
        if (u != null) launchUrl(u, mode: LaunchMode.externalApplication);
      },
      child: _Glass(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.public_rounded,
                    size: 14, color: AppColors.peacockLight),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    result.source,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.55),
                      fontSize: 12,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Icon(Icons.open_in_new_rounded,
                    size: 14, color: Colors.white.withValues(alpha: 0.4)),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              result.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (result.snippet.isNotEmpty) ...[
              const SizedBox(height: 5),
              Text(
                result.snippet,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.7),
                  fontSize: 13,
                  height: 1.35,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A resolved (or candidate) contact.
class ContactCard extends StatelessWidget {
  final ContactMatch contact;
  final VoidCallback? onTap; // set when the user must choose among several
  final bool selected;
  const ContactCard({
    super.key,
    required this.contact,
    this.onTap,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    final initial =
        contact.name.isNotEmpty ? contact.name[0].toUpperCase() : '?';
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      child: _Glass(
        borderTint: selected ? AppColors.peacockLight : null,
        child: Row(
          children: [
            CircleAvatar(
              radius: 20,
              backgroundColor: AppColors.peacock.withValues(alpha: 0.6),
              child: Text(initial,
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w700)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(contact.name,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w600)),
                  Text(contact.phone,
                      style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.6),
                          fontSize: 13)),
                ],
              ),
            ),
            if (onTap != null)
              Icon(Icons.chevron_right_rounded,
                  color: Colors.white.withValues(alpha: 0.5)),
          ],
        ),
      ),
    );
  }
}

/// Live call status — timeline dots for dialing → ringing → in call → done.
class CallStatusCard extends StatelessWidget {
  final CallStatusInfo status;
  const CallStatusCard({super.key, required this.status});

  // Mirrors the backend's agent-call state machine (dialing → in_progress →
  // summarizing → completed), so the progress dots actually advance while
  // Hari is on the phone instead of sitting on step one the whole time.
  static const _steps = ['dialing', 'in_progress', 'summarizing', 'completed'];

  @override
  Widget build(BuildContext context) {
    final failed = status.status == 'failed' || status.status == 'no_answer';
    final idx = _steps.indexOf(status.status);
    return _Glass(
      borderTint: failed ? AppColors.danger : const Color(0xFF35C48D),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                failed ? Icons.phone_missed_rounded : Icons.phone_in_talk_rounded,
                size: 18,
                color: failed ? AppColors.danger : const Color(0xFF35C48D),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${status.label} — ${status.contactName}',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          if (!failed) ...[
            const SizedBox(height: 12),
            Row(
              children: List.generate(_steps.length * 2 - 1, (i) {
                if (i.isOdd) {
                  final done = i ~/ 2 < idx;
                  return Expanded(
                    child: Container(
                      height: 2,
                      color: done
                          ? const Color(0xFF35C48D)
                          : Colors.white.withValues(alpha: 0.15),
                    ),
                  );
                }
                final step = i ~/ 2;
                final done = step <= idx;
                final current = step == idx && status.status != 'completed';
                return Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: done
                        ? const Color(0xFF35C48D)
                        : Colors.white.withValues(alpha: 0.2),
                    boxShadow: current
                        ? [
                            BoxShadow(
                                color: const Color(0xFF35C48D)
                                    .withValues(alpha: 0.6),
                                blurRadius: 8)
                          ]
                        : null,
                  ),
                );
              }),
            ),
            const SizedBox(height: 6),
            const Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _StepLabel('Dialing'),
                _StepLabel('Ringing'),
                _StepLabel('In call'),
                _StepLabel('Done'),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _StepLabel extends StatelessWidget {
  final String text;
  const _StepLabel(this.text);
  @override
  Widget build(BuildContext context) => Text(
        text,
        style:
            TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 10.5),
      );
}

/// "Should I place this call?" — always shown before dialing.
class ConfirmationCard extends StatelessWidget {
  final PendingConfirmation pending;
  final void Function(bool approved) onDecision;
  const ConfirmationCard({
    super.key,
    required this.pending,
    required this.onDecision,
  });

  @override
  Widget build(BuildContext context) {
    final isCall = pending.action == 'place_call';
    return _Glass(
      borderTint: AppColors.marigold,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.verified_user_outlined,
                  size: 18, color: AppColors.marigold),
              const SizedBox(width: 8),
              Text(
                isCall ? 'Confirm this call' : 'Confirm',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (isCall && pending.contact != null) ...[
            Text(
              'Call ${pending.contact!.name} (${pending.contact!.phone}) and say:',
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.75), fontSize: 13.5),
            ),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '“${pending.spokenPreview ?? pending.message ?? ''}”',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontStyle: FontStyle.italic,
                    height: 1.4),
              ),
            ),
          ] else
            Text(
              pending.question ?? 'Shall I go ahead?',
              style: const TextStyle(color: Colors.white, fontSize: 14.5),
            ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white70,
                    side: BorderSide(
                        color: Colors.white.withValues(alpha: 0.25)),
                  ),
                  onPressed: () => onDecision(false),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                      backgroundColor: AppColors.peacock),
                  onPressed: () => onDecision(true),
                  icon: Icon(isCall ? Icons.call_rounded : Icons.check_rounded,
                      size: 18),
                  label: Text(isCall ? 'Place call' : 'Confirm'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A saved document Hari just recalled ("show me my Aadhaar card") — image
/// thumbnail or PDF badge + title/date/summary, with a Send button that
/// shares the real file out (WhatsApp, email, Drive…). Tap the card to
/// view: images open in a pinch-zoom viewer, PDFs in the system viewer.
class DocumentCard extends StatefulWidget {
  final UserDocument document;
  const DocumentCard({super.key, required this.document});

  @override
  State<DocumentCard> createState() => _DocumentCardState();
}

class _DocumentCardState extends State<DocumentCard> {
  bool _sending = false;

  UserDocument get document => widget.document;

  String get _date {
    if (document.docDate.isNotEmpty) return document.docDate;
    if (document.createdAt <= 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(document.createdAt);
    return '${d.day}/${d.month}/${d.year}';
  }

  void _open(BuildContext context) {
    final url = ApiService.documentFileUrl(document.id);
    if (document.isPdf) {
      // No in-app PDF renderer (kept the app light) — hand to the system.
      launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      return;
    }
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _DocumentViewer(document: document),
    ));
  }

  /// Downloads the real bytes to a temp file with a clean, human name and
  /// opens the system share sheet. The temp file is safe to leave — the OS
  /// clears the cache dir; naming it well means the recipient sees
  /// "Aadhaar Card.jpg", never "voice_save_1785…jpg".
  Future<void> _send() async {
    if (_sending) return;
    setState(() => _sending = true);
    try {
      final file = await ApiService.downloadDocument(document.id);
      final dir = await getTemporaryDirectory();
      final safeName = _shareName(document, file.mime);
      final path = '${dir.path}/$safeName';
      await File(path).writeAsBytes(file.bytes, flush: true);
      await Share.shareXFiles(
        [XFile(path, mimeType: file.mime, name: safeName)],
        subject: document.title,
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't prepare that to send.")),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return _Glass(
      borderTint: Neon.cyan,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => _open(context),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: SizedBox(
                    width: 56,
                    height: 56,
                    child: document.isPdf
                        ? Container(
                            color: Neon.surfaceHigh,
                            child: const Icon(Icons.picture_as_pdf_rounded,
                                color: Neon.pink, size: 26),
                          )
                        : Image.network(
                            ApiService.documentFileUrl(document.id),
                            headers: ApiService.imageHeaders,
                            fit: BoxFit.cover,
                            // Decode at ~2x the 56px display size, not full
                            // resolution — a big memory saving in a list.
                            cacheWidth: 130,
                            errorBuilder: (_, __, ___) => Container(
                              color: Neon.surfaceHigh,
                              child: const Icon(Icons.description_rounded,
                                  color: Neon.cyan, size: 24),
                            ),
                          ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        document.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (_date.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(_date,
                            style: const TextStyle(
                                color: Neon.textLo, fontSize: 12)),
                      ],
                      if (document.summary.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          document.summary,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.7),
                            fontSize: 12.5,
                            height: 1.3,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                Icon(Icons.open_in_full_rounded,
                    size: 16, color: Colors.white.withValues(alpha: 0.4)),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _sending ? null : _send,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Neon.cyan,
                    side: BorderSide(color: Neon.cyan.withValues(alpha: 0.5)),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                  icon: _sending
                      ? const SizedBox(
                          width: 15,
                          height: 15,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Neon.cyan),
                        )
                      : const Icon(Icons.send_rounded, size: 16),
                  label: Text(_sending ? 'Preparing…' : 'Send'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A clean filename for sharing — the document's own title (so the
/// recipient sees "Aadhaar Card.jpg", not the internal save name), with a
/// correct extension derived from the mime type.
String _shareName(UserDocument d, String mime) {
  var base = d.title.trim();
  if (base.isEmpty) base = 'document';
  // Strip anything filesystem-hostile; collapse whitespace.
  base = base.replaceAll(RegExp(r'[\\/:*?"<>|]+'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  const extByMime = {
    'application/pdf': '.pdf',
    'image/png': '.png',
    'image/webp': '.webp',
    'image/jpeg': '.jpg',
  };
  final ext = extByMime[mime] ?? (d.isPdf ? '.pdf' : '.jpg');
  return base.toLowerCase().endsWith(ext) ? base : '$base$ext';
}

/// Full-screen pinch-zoom viewer for a recalled image document.
/// A written piece Hari just COMPOSED ("generate a script for my speech")
/// — title + preview with one tap into a full-screen reader built for
/// actually delivering the speech: big type, scroll, copy, share.
class ScriptCard extends StatelessWidget {
  final String title;
  final String content;
  final VoidCallback? onClose;
  const ScriptCard(
      {super.key, required this.title, required this.content, this.onClose});

  void _openReader(BuildContext context) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _TextReaderPage(title: title, content: content),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return _Glass(
      borderTint: Neon.cyan,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _openReader(context),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.description_rounded,
                    color: Neon.cyan, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => Share.share(content, subject: title),
                  child: const Padding(
                    padding: EdgeInsets.all(4),
                    child:
                        Icon(Icons.share_rounded, color: Neon.cyan, size: 19),
                  ),
                ),
                if (onClose != null) ...[
                  const SizedBox(width: 6),
                  InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: onClose,
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Icon(Icons.close_rounded,
                          color: Colors.white.withValues(alpha: 0.65),
                          size: 19),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 8),
            Flexible(
              child: Text(
                content,
                maxLines: 7,
                overflow: TextOverflow.fade,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.82),
                  fontSize: 13.5,
                  height: 1.45,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Tap to open full screen',
              style: TextStyle(
                color: Neon.cyan.withValues(alpha: 0.8),
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.3,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Full-screen reader — the "deliver the speech from your phone" view.
class _TextReaderPage extends StatelessWidget {
  final String title;
  final String content;
  const _TextReaderPage({required this.title, required this.content});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B0B12),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0B0B12),
        foregroundColor: Colors.white,
        title:
            Text(title, style: const TextStyle(fontSize: 16), maxLines: 1),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy_rounded, size: 20),
            tooltip: 'Copy',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: content));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Copied')),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.share_rounded, size: 20),
            tooltip: 'Share',
            onPressed: () => Share.share(content, subject: title),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(22, 14, 22, 48),
        child: SelectableText(
          content,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 17,
            height: 1.6,
          ),
        ),
      ),
    );
  }
}

/// An image Hari just CREATED ("draw me a poster for the café") — shown
/// big, because this is the showpiece moment: the full square render with
/// a share button so it can go straight to WhatsApp. Tap for pinch-zoom.
/// The file is already saved server-side as a document.
class GeneratedImageCard extends StatefulWidget {
  final UserDocument document;
  final String prompt;
  final VoidCallback? onClose;
  const GeneratedImageCard(
      {super.key, required this.document, this.prompt = '', this.onClose});

  @override
  State<GeneratedImageCard> createState() => _GeneratedImageCardState();
}

class _GeneratedImageCardState extends State<GeneratedImageCard> {
  bool _sending = false;

  bool get _isVideo => widget.document.mime.startsWith('video/');

  Future<void> _share() async {
    if (_sending) return;
    setState(() => _sending = true);
    try {
      final file = await ApiService.downloadDocument(widget.document.id);
      final dir = await getTemporaryDirectory();
      final safeName = _shareName(widget.document, file.mime);
      final path = '${dir.path}/$safeName';
      await File(path).writeAsBytes(file.bytes, flush: true);
      await Share.shareXFiles(
        [XFile(path, mimeType: file.mime, name: safeName)],
        subject: widget.document.title,
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't prepare that to share.")),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return _Glass(
      borderTint: Neon.violet,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Flexible(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: _isVideo
                  ? Container(
                      height: 160,
                      alignment: Alignment.center,
                      color: Neon.surfaceHigh,
                      child: const Icon(Icons.movie_rounded,
                          color: Neon.cyan, size: 42),
                    )
                  : GestureDetector(
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) =>
                              _DocumentViewer(document: widget.document),
                        ),
                      ),
                      child: Image.network(
                        ApiService.documentFileUrl(widget.document.id),
                        headers: ApiService.imageHeaders,
                        fit: BoxFit.cover,
                        width: double.infinity,
                        loadingBuilder: (context, child, p) => p == null
                            ? child
                            : Container(
                                height: 200,
                                alignment: Alignment.center,
                                color: Neon.surfaceHigh,
                                child: const CircularProgressIndicator(
                                    color: Neon.violet, strokeWidth: 2.5),
                              ),
                        errorBuilder: (_, __, ___) => Container(
                          height: 120,
                          alignment: Alignment.center,
                          color: Neon.surfaceHigh,
                          child: const Text("Couldn't load the image.",
                              style: TextStyle(color: Colors.white70)),
                        ),
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              const Icon(Icons.auto_awesome_rounded,
                  color: Neon.violet, size: 16),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  widget.prompt.isNotEmpty
                      ? widget.prompt
                      : widget.document.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.75),
                    fontSize: 12.5,
                    height: 1.3,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _sending
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          color: Neon.cyan, strokeWidth: 2),
                    )
                  : InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: _share,
                      child: const Padding(
                        padding: EdgeInsets.all(4),
                        child: Icon(Icons.share_rounded,
                            color: Neon.cyan, size: 20),
                      ),
                    ),
              if (widget.onClose != null) ...[
                const SizedBox(width: 6),
                InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: widget.onClose,
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(Icons.close_rounded,
                        color: Colors.white.withValues(alpha: 0.65),
                        size: 20),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _DocumentViewer extends StatelessWidget {
  final UserDocument document;
  const _DocumentViewer({required this.document});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(document.title,
            style: const TextStyle(fontSize: 16), maxLines: 1),
      ),
      body: Center(
        child: InteractiveViewer(
          maxScale: 6,
          child: Image.network(
            ApiService.documentFileUrl(document.id),
            headers: ApiService.imageHeaders,
            fit: BoxFit.contain,
            loadingBuilder: (context, child, p) => p == null
                ? child
                : const CircularProgressIndicator(color: Neon.cyan),
            errorBuilder: (_, __, ___) => const Padding(
              padding: EdgeInsets.all(24),
              child: Text("Couldn't load this document.",
                  style: TextStyle(color: Colors.white70)),
            ),
          ),
        ),
      ),
    );
  }
}
