import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
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
    // Office and plain-text files: the server reads the words out of
    // these before understanding them, so a shared spreadsheet or deck is
    // as answerable as a photographed report.
    'docx':
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'xlsx':
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'pptx':
        'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    'csv': 'text/csv',
    'tsv': 'text/tab-separated-values',
    'txt': 'text/plain',
    'md': 'text/markdown',
    'json': 'application/json',
    'rtf': 'application/rtf',
  };

  /// Types the server will store. Anything else is reported as skipped
  /// rather than silently dropped.
  static bool _acceptable(String mime) =>
      mime.startsWith('image/') ||
      mime == 'application/pdf' ||
      _mimeByExt.containsValue(mime) ||
      mime == 'application/msword' ||
      mime == 'application/vnd.ms-excel' ||
      mime == 'application/vnd.ms-powerpoint';

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
      if (mime == null || !_acceptable(mime)) {
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
        final doc = await ApiService.uploadDocument(
          bytes: bytes,
          filename: name.isEmpty ? 'Shared.jpg' : name,
          mimeType: mime,
          note: 'shared from another app',
        );
        saved++;
        // THE WHOLE POINT: the user shared it and is done. The server is
        // now reading it; when it has understood — timetable, invite,
        // legal paper — we mirror any events into the phone's calendar
        // and say what happened. Fire-and-forget; failures stay quiet
        // (the server's own notification still tells the outcome).
        unawaited(_followUnderstanding(doc.id));
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
          ? 'Got it — reading it now…'
          : 'Got them — reading $saved files now…');
    } else if (failed > 0) {
      AppFeedback.toast("Couldn't save that — check your connection.");
    } else if (skipped > 0) {
      AppFeedback.toast("Couldn't read that file type — photos and PDFs work.");
    }
  }

  static const _calendar = MethodChannel('hari/calendar');

  /// Polls the server's understanding of one uploaded document, then acts
  /// on it: events go into the PHONE'S calendar (10-minute alert each) and
  /// the user is told the outcome in one line. Analysis takes seconds to
  /// low tens of seconds; poll gently and give up quietly — the server's
  /// push notification is the fallback messenger.
  Future<void> _followUnderstanding(int docId) async {
    Map<String, dynamic>? u;
    for (var i = 0; i < 15; i++) {
      await Future.delayed(Duration(seconds: i < 4 ? 3 : 6));
      final r = await ApiService.getJson('/docs/$docId/understanding');
      if (r == null) continue;
      if (r['ready'] == true) {
        u = r;
        break;
      }
    }
    if (u == null) return;
    final events = ((u['events'] as List?) ?? const [])
        .whereType<Map>()
        .toList();
    final title = (u['title'] ?? 'Document').toString();
    if (events.isEmpty) {
      AppFeedback.toast('"$title" understood and remembered — ask me about '
          'it any time.');
      return;
    }
    // Mirror into the phone's own calendar. Ask for the permission the
    // first time; declining still leaves the in-app reminders ringing.
    var onCalendar = 0;
    try {
      final perm = await Permission.calendarFullAccess.request();
      if (perm.isGranted) {
        for (final e in events) {
          final ok = await _calendar.invokeMethod<bool>('insertEvent', {
                'title': (e['title'] ?? '').toString(),
                'startMs': (e['atMs'] as num?)?.toInt() ?? 0,
                'durationMin': 60,
              }) ??
              false;
          if (ok) onCalendar++;
        }
      }
    } catch (e) {
      AppLog.add('share', 'calendar mirror failed: $e');
    }
    final n = events.length;
    AppFeedback.toast(onCalendar > 0
        ? '$n reminder${n == 1 ? '' : 's'} set from "$title" — '
            'also on your calendar.'
        : '$n reminder${n == 1 ? '' : 's'} set from "$title".');
  }
}
