import 'dart:async';
import 'dart:io';

import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import '../core/log.dart';
import '../features/assistant/state/assistant_engine.dart';
import 'api_service.dart';
import 'auth_service.dart';
import 'app_feedback.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  SHARE-TO-ASSISTANT — a photo or PDF shared from ANY app (WhatsApp,
///  gallery, file manager) lands straight in the document pipeline, same
///  as a scan: OCR'd, titled, searchable, linkable to a person ("that's
///  Chetan's invoice").
///
///  Covers both entry points: the app cold-started by a share (initial
///  media) and a share arriving while it already runs (stream).
/// ─────────────────────────────────────────────────────────────────────────
class ShareIntakeService {
  ShareIntakeService._();
  static final ShareIntakeService instance = ShareIntakeService._();

  StreamSubscription<List<SharedMediaFile>>? _sub;
  bool _started = false;

  /// Call once from the signed-in shell — uploads need a session.
  void start() {
    if (_started) return;
    _started = true;
    _sub = ReceiveSharingIntent.instance.getMediaStream().listen(
          _handle,
          onError: (_) {},
        );
    ReceiveSharingIntent.instance.getInitialMedia().then((files) {
      _handle(files);
      // Consumed — otherwise the same share replays on every resume.
      ReceiveSharingIntent.instance.reset();
    }).catchError((_) {});
  }

  void stop() {
    _sub?.cancel();
    _sub = null;
    _started = false;
  }

  bool _lastWasText = false;

  /// A shared URL or passage of text. A link becomes "read this page and
  /// tell me what it says"; a passage becomes the thing to talk about.
  /// Either way the assistant handles it in a normal turn, so the answer
  /// is subject to the same gates as anything else it says.
  Future<bool> _handleSharedText(String raw) async {
    final text = raw.trim();
    if (text.isEmpty) return false;
    _lastWasText = true;
    // A share often arrives as "Some title https://example.com/x" — take
    // the URL when there is one, so read_webpage gets something usable.
    final url = RegExp(r'https?://\S+').firstMatch(text)?.group(0);
    final ask = url != null
        ? 'Read this page and tell me what it says: $url'
        : 'Here is something I shared with you — summarise it for me:\n$text';
    try {
      await AssistantEngine.instance.askAssistant(ask);
      AppFeedback.toast(url != null ? 'Reading that page…' : 'Reading that…');
      return true;
    } catch (e) {
      AppLog.add('share', 'shared text failed: $e');
      AppFeedback.toast("Couldn't hand that to the assistant — try again.");
      return false;
    }
  }

  static const _mimeByExt = {
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'png': 'image/png',
    'webp': 'image/webp',
    'heic': 'image/heic',
    'pdf': 'application/pdf',
  };

  /// Anything above this never fits the server's 18 MB document cap.
  static const _maxShareBytes = 20 * 1024 * 1024;

  Future<void> _handle(List<SharedMediaFile> files) async {
    if (files.isEmpty) return;
    if (!AuthService.instance.isSignedIn) {
      AppFeedback.toast('Sign in first, then share it again — nothing was saved.');
      return;
    }
    var saved = 0;
    var failed = 0;
    var skipped = 0;
    for (final f in files) {
      // A SHARED LINK IS A QUESTION, NOT A DOCUMENT. "Share → Hari" from a
      // browser hands over a URL; filing that as a file would save nothing
      // and answer nothing. It goes to the assistant, which reads the page.
      if (f.type == SharedMediaType.text || f.type == SharedMediaType.url) {
        if (await _handleSharedText(f.path)) {
          saved++;
        } else {
          skipped++;
        }
        continue;
      }
      if (f.type != SharedMediaType.image && f.type != SharedMediaType.file) {
        skipped++;
        continue;
      }
      final path = f.path;
      if (path.isEmpty) continue;
      final ext = path.split('.').last.toLowerCase();
      final mime = f.mimeType ?? _mimeByExt[ext];
      if (mime == null ||
          !(mime.startsWith('image/') || mime == 'application/pdf')) {
        skipped++; // extension-less or exotic type — SAY so below, the old
        continue; // silent drop looked like the share simply vanished
      }
      try {
        if (await File(path).length() > _maxShareBytes) {
          failed++;
          AppFeedback.toast('That file is too large to save (20 MB max).');
          continue;
        }
        final bytes = await File(path).readAsBytes();
        if (bytes.isEmpty) continue;
        final name = path.split('/').last;
        await ApiService.uploadDocument(
          bytes: bytes,
          filename: name.isEmpty ? 'Shared.jpg' : name,
          mimeType: mime,
          note: 'shared from another app',
        );
        saved++;
      } catch (e) {
        failed++;
        AppLog.add('share', 'upload failed: $e');
      }
    }
    if (_lastWasText) {
      _lastWasText = false;
      return; // its own message was already shown
    }
    if (saved > 0) {
      AppFeedback.toast(saved == 1
          ? "Saved to your documents — tell me who it's for."
          : "Saved $saved files to your documents — tell me who they're for.");
    } else if (failed > 0) {
      AppFeedback.toast("Couldn't save that — check your connection.");
    } else if (skipped > 0) {
      AppFeedback.toast("Couldn't read that file type — photos and PDFs work.");
    }
  }
}
