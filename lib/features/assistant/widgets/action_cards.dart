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
import 'package:video_player/video_player.dart';

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
            color: Neon.surface,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: (borderTint ?? const Color(0xFF141627)).withValues(alpha: 0.18),
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
              : SizedBox(
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
                color: Neon.textHi,
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
                Icon(Icons.public_rounded,
                    size: 14, color: AppColors.peacockLight),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    result.source,
                    style: TextStyle(
                      color: Neon.textDim,
                      fontSize: 12,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Icon(Icons.open_in_new_rounded,
                    size: 14, color: Neon.textDim),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              result.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Neon.textHi,
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
                  color: Neon.textLo,
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
                  style: TextStyle(
                      color: Neon.textHi, fontWeight: FontWeight.w700)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(contact.name,
                      style: TextStyle(
                          color: Neon.textHi,
                          fontSize: 15,
                          fontWeight: FontWeight.w600)),
                  Text(contact.phone,
                      style: TextStyle(
                          color: Neon.textDim,
                          fontSize: 13)),
                ],
              ),
            ),
            if (onTap != null)
              Icon(Icons.chevron_right_rounded,
                  color: Neon.textDim),
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
                  style: TextStyle(
                      color: Neon.textHi,
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
                          : Neon.line,
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
                        : Neon.lineBright,
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
            TextStyle(color: Neon.textDim, fontSize: 10.5),
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
              Icon(Icons.verified_user_outlined,
                  size: 18, color: AppColors.marigold),
              const SizedBox(width: 8),
              Text(
                isCall ? 'Confirm this call' : 'Confirm',
                style: TextStyle(
                    color: Neon.textHi,
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
                  color: Neon.textLo, fontSize: 13.5),
            ),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Neon.surfaceHigh,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '“${pending.spokenPreview ?? pending.message ?? ''}”',
                style: TextStyle(
                    color: Neon.textHi,
                    fontSize: 14,
                    fontStyle: FontStyle.italic,
                    height: 1.4),
              ),
            ),
          ] else
            Text(
              pending.question ?? 'Shall I go ahead?',
              style: TextStyle(color: Neon.textHi, fontSize: 14.5),
            ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Neon.textLo,
                    side: BorderSide(
                        color: Neon.lineBright),
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
      builder: (_) => DocumentGalleryScreen(documents: [document]),
    ));
  }

  Future<void> _send() async {
    if (_sending) return;
    setState(() => _sending = true);
    try {
      await shareDocumentFile(document);
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
                            child: Icon(Icons.picture_as_pdf_rounded,
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
                              child: Icon(Icons.description_rounded,
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
                        style: TextStyle(
                          color: Neon.textHi,
                          fontSize: 14.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (_date.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(_date,
                            style: TextStyle(
                                color: Neon.textLo, fontSize: 12)),
                      ],
                      if (document.summary.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          document.summary,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Neon.textLo,
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
                    size: 16, color: Neon.textDim),
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
                      ? SizedBox(
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

/// Downloads the real bytes to a temp file with a clean, human name and
/// opens the system share sheet. The temp file is safe to leave — the OS
/// clears the cache dir; naming it well means the recipient sees
/// "Aadhaar Card.jpg", never "voice_save_1785…jpg". Throws on failure so
/// callers can show their own error UI.
Future<void> shareDocumentFile(UserDocument document) async {
  final file = await ApiService.downloadDocument(document.id);
  final dir = await getTemporaryDirectory();
  final safeName = _shareName(document, file.mime);
  final path = '${dir.path}/$safeName';
  await File(path).writeAsBytes(file.bytes, flush: true);
  await Share.shareXFiles(
    [XFile(path, mimeType: file.mime, name: safeName)],
    subject: document.title,
  );
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
                Icon(Icons.description_rounded,
                    color: Neon.cyan, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Neon.textHi,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => Share.share(content, subject: title),
                  child: Padding(
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
                      padding: EdgeInsets.all(4),
                      child: Icon(Icons.close_rounded,
                          color: Neon.textLo,
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
                  color: Neon.textHi,
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
      backgroundColor: Neon.bg,
      appBar: AppBar(
        backgroundColor: Neon.bg,
        foregroundColor: Neon.textHi,
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
          style: TextStyle(
            color: Neon.textHi,
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

  // A generated video used to render as a static film icon — there was no
  // way to watch the thing the assistant had just said was on screen.
  VideoPlayerController? _video;
  bool _videoFailed = false;

  @override
  void initState() {
    super.initState();
    if (_isVideo) _startVideo();
  }

  @override
  void dispose() {
    _video?.dispose();
    super.dispose();
  }

  Future<void> _startVideo() async {
    try {
      final c = VideoPlayerController.networkUrl(
        Uri.parse(ApiService.documentFileUrl(widget.document.id)),
        httpHeaders: ApiService.imageHeaders,
      );
      _video = c;
      await c.initialize();
      await c.setLooping(true);
      await c.play();
      if (mounted) setState(() {});
    } catch (_) {
      if (mounted) setState(() => _videoFailed = true);
    }
  }

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
                  ? (_video != null && _video!.value.isInitialized
                      ? GestureDetector(
                          onTap: () => setState(() {
                            _video!.value.isPlaying
                                ? _video!.pause()
                                : _video!.play();
                          }),
                          child: AspectRatio(
                            aspectRatio: _video!.value.aspectRatio,
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                VideoPlayer(_video!),
                                if (!_video!.value.isPlaying)
                                  Container(
                                    alignment: Alignment.center,
                                    color: Colors.black26,
                                    child: const Icon(Icons.play_arrow_rounded,
                                        color: Colors.white, size: 54),
                                  ),
                              ],
                            ),
                          ),
                        )
                      : Container(
                          height: 160,
                          alignment: Alignment.center,
                          color: Neon.surfaceHigh,
                          child: _videoFailed
                              ? Icon(Icons.movie_rounded,
                                  color: Neon.cyan, size: 42)
                              : CircularProgressIndicator(
                                  strokeWidth: 2.4, color: Neon.violet),
                        ))
                  : GestureDetector(
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => DocumentGalleryScreen(
                              documents: [widget.document]),
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
                                child: CircularProgressIndicator(
                                    color: Neon.violet, strokeWidth: 2.5),
                              ),
                        errorBuilder: (_, __, ___) => Container(
                          height: 120,
                          alignment: Alignment.center,
                          color: Neon.surfaceHigh,
                          child: Text("Couldn't load the image.",
                              style: TextStyle(color: Neon.textLo)),
                        ),
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Icon(Icons.auto_awesome_rounded,
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
                    color: Neon.textLo,
                    fontSize: 12.5,
                    height: 1.3,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _sending
                  ? SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          color: Neon.cyan, strokeWidth: 2),
                    )
                  : InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: _share,
                      child: Padding(
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
                    padding: EdgeInsets.all(4),
                    child: Icon(Icons.close_rounded,
                        color: Neon.textLo,
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

/// Full-screen gallery for recalled documents — "show me Chetan's
/// evidence" pops this over whatever screen the user is on. Swipe
/// sideways through the set, pinch to zoom, share the real file, close
/// with the X, back, or a downward swipe on the black margins.
class DocumentGalleryScreen extends StatefulWidget {
  final List<UserDocument> documents;
  final int initialIndex;

  /// When given, a Delete action appears. It must perform the deletion
  /// (with its own confirmation) and return true ONLY when the server
  /// confirmed — the gallery then drops the page, or closes if empty.
  final Future<bool> Function(UserDocument)? onDelete;

  const DocumentGalleryScreen(
      {super.key,
      required this.documents,
      this.initialIndex = 0,
      this.onDelete});

  @override
  State<DocumentGalleryScreen> createState() => _DocumentGalleryScreenState();
}

class _DocumentGalleryScreenState extends State<DocumentGalleryScreen> {
  late final PageController _page =
      PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;
  bool _sharing = false;
  bool _deleting = false;
  late final List<UserDocument> _docs = List.of(widget.documents);

  UserDocument get _current => _docs[_index];

  Future<void> _delete() async {
    final cb = widget.onDelete;
    if (cb == null || _deleting) return;
    setState(() => _deleting = true);
    bool ok = false;
    try {
      ok = await cb(_current);
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
    if (!ok || !mounted) return;
    setState(() {
      _docs.removeAt(_index);
      if (_index >= _docs.length) _index = _docs.length - 1;
    });
    if (_docs.isEmpty) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _page.dispose();
    super.dispose();
  }

  Future<void> _share() async {
    if (_sharing) return;
    setState(() => _sharing = true);
    try {
      await shareDocumentFile(_current);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't prepare that to send.")),
        );
      }
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final docs = _docs;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          tooltip: 'Close',
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_current.title,
                style: const TextStyle(fontSize: 16),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
            if (docs.length > 1)
              Text('${_index + 1} of ${docs.length}',
                  style: TextStyle(
                      fontSize: 11.5,
                      color: Colors.white.withValues(alpha: 0.6))),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Share',
            icon: _sharing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.share_rounded),
            onPressed: _sharing ? null : _share,
          ),
          if (widget.onDelete != null)
            IconButton(
              tooltip: 'Delete',
              icon: _deleting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.delete_outline_rounded),
              onPressed: _deleting ? null : _delete,
            ),
          const SizedBox(width: 4),
        ],
      ),
      body: Dismissible(
        key: const ValueKey('document-gallery'),
        direction: DismissDirection.down,
        onDismissed: (_) => Navigator.of(context).pop(),
        child: PageView.builder(
          controller: _page,
          itemCount: docs.length,
          onPageChanged: (i) => setState(() => _index = i),
          itemBuilder: (_, i) {
            final d = docs[i];
            if (d.isPdf) {
              // No in-app PDF renderer (kept the app light) — badge + open.
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.picture_as_pdf_rounded,
                        color: Neon.pink, size: 64),
                    const SizedBox(height: 14),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      child: Text(d.title,
                          textAlign: TextAlign.center,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white)),
                    ),
                    const SizedBox(height: 14),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: BorderSide(
                            color: Colors.white.withValues(alpha: 0.5)),
                      ),
                      onPressed: () => launchUrl(
                          Uri.parse(ApiService.documentFileUrl(d.id)),
                          mode: LaunchMode.externalApplication),
                      icon: const Icon(Icons.open_in_new_rounded, size: 16),
                      label: const Text('Open PDF'),
                    ),
                  ],
                ),
              );
            }
            if (d.mime.startsWith('video/')) {
              // Without this an MP4 fell through to Image.network and drew
              // the broken-image placeholder full screen.
              return _GalleryVideo(key: ValueKey('gv-${d.id}'), document: d);
            }
            return Center(
              child: InteractiveViewer(
                maxScale: 6,
                child: Image.network(
                  ApiService.documentFileUrl(d.id),
                  headers: ApiService.imageHeaders,
                  fit: BoxFit.contain,
                  loadingBuilder: (context, child, p) => p == null
                      ? child
                      : const Center(
                          child: CircularProgressIndicator(
                              color: Colors.white70)),
                  errorBuilder: (_, __, ___) => Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text("Couldn't load this document.",
                        style: TextStyle(color: Neon.textLo)),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}


/// One video page inside the full-screen gallery. Owns its controller so
/// swiping between pages cannot leave a player running off screen.
class _GalleryVideo extends StatefulWidget {
  final UserDocument document;
  const _GalleryVideo({super.key, required this.document});

  @override
  State<_GalleryVideo> createState() => _GalleryVideoState();
}

class _GalleryVideoState extends State<_GalleryVideo> {
  VideoPlayerController? _c;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      final c = VideoPlayerController.networkUrl(
        Uri.parse(ApiService.documentFileUrl(widget.document.id)),
        httpHeaders: ApiService.imageHeaders,
      );
      _c = c;
      await c.initialize();
      await c.setLooping(true);
      await c.play();
      if (mounted) setState(() {});
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) {
      return const Center(
        child: Icon(Icons.movie_rounded, color: Colors.white54, size: 64),
      );
    }
    final c = _c;
    if (c == null || !c.value.isInitialized) {
      return const Center(
          child: CircularProgressIndicator(color: Colors.white70));
    }
    return Center(
      child: GestureDetector(
        onTap: () => setState(
            () => c.value.isPlaying ? c.pause() : c.play()),
        child: AspectRatio(
          aspectRatio: c.value.aspectRatio,
          child: Stack(
            fit: StackFit.expand,
            children: [
              VideoPlayer(c),
              if (!c.value.isPlaying)
                Container(
                  alignment: Alignment.center,
                  color: Colors.black26,
                  child: const Icon(Icons.play_arrow_rounded,
                      color: Colors.white, size: 64),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
