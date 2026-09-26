import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart' show MediaType;
import 'package:path_provider/path_provider.dart';

import '../core/log.dart';
import '../features/assistant/state/assistant_engine.dart';
import '../widgets/avatar_message_popup.dart';
import 'api_service.dart';
import 'app_lock.dart';
import 'auth_service.dart';
import 'notification_service.dart';
import 'recording_guard.dart';

/// PERSONALIZED AVATAR MESSAGES — receiving half.
///
/// When someone in the user's circle sends a message and THEIR avatar was
/// rendered for it, our inbox rows carry `media` ('video' | 'audio') and a
/// `media_url`. This service fetches those rows, downloads the media with
/// the normal bearer auth (the backend serves it to the addressed
/// recipient only — no public URLs), and shows the popup player.
///
/// Text-only messages keep their existing path: the assistant SPEAKS them
/// (AssistantEngine.announceIncomingMessages). This service only ever
/// handles rows with media, and marks them read as their popup opens; the
/// words are always shown, and the popup fetches the clip itself, with
/// Try again when it does not come.
class AvatarMessageService {
  AvatarMessageService._();
  static final AvatarMessageService instance = AvatarMessageService._();

  /// Registered on the MaterialApp so the popup can appear from a push
  /// tap regardless of which screen is on top.
  static final navigatorKey = GlobalKey<NavigatorState>();

  bool _showing = false;

  /// Asked for again while a sweep was running (2026-09-26). A second
  /// video note used to be dropped here: the running sweep had fetched its
  /// rows before that note existed, and no notification was left to tap.
  bool _again = false;

  /// A note waits while the speaker and microphone are in use — a voice
  /// session would hear the clip and answer it, a recording would keep its
  /// sound — and while the app lock is up, which the popup would otherwise
  /// open on top of (2026-09-26). Tests pass their own.
  @visibleForTesting
  bool Function() mustWait = () {
    final e = AssistantEngine.instance;
    return e.liveActive ||
        e.inlineVoice ||
        RecordingGuard.busy ||
        AppLock.instance.shouldLock;
  };

  /// How often, and for how long at most, a note waits for [mustWait].
  @visibleForTesting
  Duration freePoll = const Duration(seconds: 1);
  @visibleForTesting
  Duration freeCap = const Duration(minutes: 10);

  // The server, the clip and the tray, as seams for the tests.
  @visibleForTesting
  Future<List<Map<String, dynamic>>?> Function() fetchUnread = _fetchUnread;
  @visibleForTesting
  Future<void> Function(Object? id) markRead = _markRead;
  @visibleForTesting
  Future<File?> Function(Map<String, dynamic> row) download = _download;
  @visibleForTesting
  Future<void> Function(String title, String body) notify = _notify;

  /// Fetch unread media messages and show them one after another.
  /// Returns true when the notes were taken care of — shown, or left in
  /// the tray to open later — so callers know the tap was consumed and the
  /// voice announcement can skip those rows.
  Future<bool> showPending() async {
    if (_showing) {
      // A sweep is running: it fetches once more when it is done.
      _again = true;
      return true;
    }
    _showing = true;
    var shown = false;
    try {
      // Session may still be restoring on a cold start from a push tap.
      for (var i = 0; i < 20 && ApiService.sessionToken == null; i++) {
        await Future.delayed(const Duration(milliseconds: 500));
      }
      do {
        _again = false;
        final rows = await fetchUnread() ?? const [];
        for (var i = 0; i < rows.length; i++) {
          final m = rows[i];
          // Checked right before it opens, not only when the push came:
          // a conversation or a recording may have started since.
          if (!await _whenFree()) return await _leaveInTray(m);
          // Nowhere to show it (no screen yet): leave it UNREAD for the
          // next tap. Marking it first lost the note for good.
          final ctx = navigatorKey.currentContext;
          if (ctx == null || !ctx.mounted) return shown;
          await markRead(m['id']);
          if (!ctx.mounted) return shown;
          shown = true;
          File? fetched;
          final later = await showAvatarMessagePopup(
            ctx,
            senderName: (m['from'] as String?) ?? 'Someone',
            text: (m['message'] as String?) ?? '',
            kind: (m['media'] as String?) ?? 'audio',
            fetch: () async => fetched = await download(m),
            videoNote: m['media'] == 'video',
            index: i + 1,
            total: rows.length,
          );
          // Someone else's clip does not stay on this phone once seen.
          _deleteQuietly(fetched);
          if (later == true) {
            // The rest stay unread, and the tray keeps the way back.
            final left = rows.length - i - 1;
            await notify(
                left == 1
                    ? 'A video note is waiting'
                    : '$left video notes are waiting',
                'Tap to watch. Made by AI from the sender’s recorded video.');
            return true;
          }
        }
      } while (_again);
      return shown;
    } catch (e) {
      AppLog.add('avatarmsg', 'showPending failed: $e');
      return shown;
    } finally {
      _showing = false;
      _again = false;
    }
  }

  /// Waits, up to [freeCap], until nothing is using the speaker and mic.
  Future<bool> _whenFree() async {
    var waited = Duration.zero;
    while (mustWait()) {
      if (waited >= freeCap) return false;
      await Future.delayed(freePoll);
      waited += freePoll;
    }
    return true;
  }

  /// It could not open for a long while (a long conversation, a long
  /// recording, a lock nobody opened): a notification, whose tap comes
  /// back here, instead of a note left unread with nothing to tap.
  Future<bool> _leaveInTray(Map<String, dynamic> m) async {
    final from = (m['from'] as String?)?.trim() ?? '';
    await notify(
        from.isEmpty ? 'You have a video note' : '$from sent you a video note',
        'Tap to watch. Made by AI from their recorded video.');
    return true;
  }

  static Future<List<Map<String, dynamic>>?> _fetchUnread() async {
    final j = await ApiService.getJson('/messages/unread',
        timeout: const Duration(seconds: 12));
    return (j?['messages'] as List?)
        ?.whereType<Map<String, dynamic>>()
        .where((m) => (m['media'] ?? '') != '')
        .toList();
  }

  static Future<void> _markRead(Object? id) async {
    await ApiService.sendJson('/messages/read', body: {
      'ids': [id]
    });
  }

  static Future<void> _notify(String title, String body) => ReminderNotifications
      .instance
      .showNow(title, body, payload: videoNotePayload);

  /// The tray notification's payload: its tap opens the notes again.
  static const String videoNotePayload = 'video_note';

  /// Where a row's `media_url` may be fetched from, WITH our bearer token.
  /// The server sends a path ("/messages/12/media"); a full URL is taken
  /// only when it is on our own server — the token never goes anywhere
  /// else, whatever a row says.
  @visibleForTesting
  static Uri? mediaUri(String? url, {String? base}) {
    final b = base ?? ApiService.baseUrl;
    final u = (url ?? '').trim();
    if (u.isEmpty) return null;
    if (u.startsWith('/')) return Uri.tryParse('$b$u');
    final full = Uri.tryParse(u);
    final home = Uri.tryParse(b);
    if (full == null || home == null) return null;
    final same = full.scheme == home.scheme &&
        full.host == home.host &&
        full.port == home.port;
    return same ? full : null;
  }

  /// Downloads a note's media STRAIGHT TO A FILE, then it plays locally —
  /// no player-side auth or range quirks. Streamed, not held in memory:
  /// an AI video note is a real video (several MB), where the first
  /// version of this assumed a 1–3 MB clip and a 30 s budget.
  static Future<File?> _download(Map<String, dynamic> m) async {
    final uri = mediaUri(m['media_url']?.toString());
    if (uri == null) return null;
    final client = http.Client();
    File? f;
    try {
      final req = http.Request('GET', uri)
        ..headers.addAll(ApiService.authHeaders..remove('Content-Type'));
      final res = await client.send(req).timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) {
        AppLog.add('avatarmsg', 'media fetch → ${res.statusCode}');
        return null;
      }
      final dir = await getTemporaryDirectory();
      final ext = (m['media'] == 'video') ? 'mp4' : 'wav';
      f = File('${dir.path}/$_notePrefix${m['id']}.$ext');
      final sink = f.openWrite();
      try {
        // An IDLE limit, not a total one: a slow line still finishes, a
        // dead one gives up after 30 s with nothing arriving.
        await res.stream.timeout(const Duration(seconds: 30)).pipe(sink);
      } catch (_) {
        await sink.close().catchError((_) {});
        rethrow;
      }
      if (await f.length() == 0) throw const FileSystemException('empty body');
      return f;
    } catch (e) {
      AppLog.add('avatarmsg', 'media download failed: $e');
      _deleteQuietly(f);
      return null;
    } finally {
      client.close();
    }
  }

  /// Downloaded notes are named so, in the temporary folder.
  static const String _notePrefix = 'avatarmsg_';

  static void _deleteQuietly(File? f) {
    if (f != null) f.delete().then((_) {}, onError: (_) {});
  }

  /* ------------------------------- sign-out ------------------------------ */

  static bool _wired = false;

  /// Signing out, a rejected session and a deleted account also clear what
  /// this phone holds of video notes: the copy of the user's own identity
  /// video, other people's downloaded notes, and a take the camera left
  /// behind when the app was closed mid-review (2026-09-26: the server
  /// deleted the video, and the phone kept a face-and-voice clip for good).
  static void wireSignOut() {
    if (_wired) return;
    _wired = true;
    AuthService.instance.onSignOut(forgetThisPhone);
  }

  static Future<void> forgetThisPhone() async {
    await deleteLocalCopy();
    await sweepTemporary();
  }

  /// Other people's notes in the temporary folder, and takes the camera
  /// left there ("REC….mp4") when the app was closed mid-review. Nothing
  /// else in the app names files so. The recorder sweeps [takesOnly] as
  /// it opens, and only files from [before] it opened, never its own.
  static Future<void> sweepTemporary(
      {Directory? dir, bool takesOnly = false, DateTime? before}) async {
    try {
      final d = dir ?? await getTemporaryDirectory();
      await for (final e in d.list()) {
        if (e is! File) continue;
        final name = e.uri.pathSegments.last;
        final note = !takesOnly && name.startsWith(_notePrefix);
        final take = name.startsWith('REC') && name.endsWith('.mp4');
        if (!note && !take) continue;
        try {
          if (before != null && !(await e.lastModified()).isBefore(before)) {
            continue;
          }
          await e.delete();
        } catch (_) {}
      }
    } catch (_) {}
  }

  /* ------------------- sender-side identity management ------------------- */

  /// GET /avatar-profile. Null when it could not be read (offline, server
  /// down) — the screen then says so and offers Try again, instead of the
  /// spinner that never stopped when the route did not exist yet.
  static Future<AvatarProfile?> profile() async {
    final j = await ApiService.getJson('/avatar-profile',
        timeout: const Duration(seconds: 10));
    return j == null ? null : AvatarProfile.fromJson(j);
  }

  /// A 409 from sendJson comes back as {..., rejected: true} — a refusal,
  /// not a success.
  static bool _accepted(Map<String, dynamic>? r) =>
      r != null && r['rejected'] != true;

  static Future<bool> grantConsent() async =>
      _accepted(await ApiService.sendJson('/avatar-profile/consent', method: 'POST'));

  static Future<bool> revokeConsent() async =>
      _accepted(await ApiService.sendJson('/avatar-profile/consent', method: 'DELETE'));

  /// Turning video notes on needs consent and a recorded video; the
  /// server refuses (409) otherwise, with its reason in [PrefsResult.error].
  static Future<PrefsResult> setEnabled(bool enabled) async {
    final r = await ApiService.sendJson('/avatar-profile/prefs',
        method: 'PUT', body: {'enabled': enabled});
    if (r == null) return const PrefsResult(false);
    if (r['rejected'] == true) {
      return PrefsResult(false, error: (r['error'] ?? '').toString());
    }
    return const PrefsResult(true);
  }

  /// Deletes the video, the consent and everything stored for it on the
  /// server — and the copy kept on this phone for the preview.
  static Future<bool> deleteIdentity() async {
    final ok = _accepted(
        await ApiService.sendJson('/avatar-profile', method: 'DELETE'));
    if (ok) await deleteLocalCopy();
    return ok;
  }

  static Future<bool> _uploadFile(String path, File file, String mime) async {
    try {
      final req = http.MultipartRequest(
          'POST', Uri.parse('${ApiService.baseUrl}$path'))
        ..headers.addAll(ApiService.authHeaders..remove('Content-Type'))
        ..files.add(await http.MultipartFile.fromPath('file', file.path,
            contentType: MediaType.parse(mime)));
      final res = await req.send().timeout(const Duration(seconds: 45));
      return res.statusCode == 200;
    } catch (e) {
      AppLog.add('avatarmsg', 'upload $path failed: $e');
      return false;
    }
  }

  // The photo and voice sample are no longer asked for — the identity
  // video carries both (2026-09-26). Kept for the routes installed builds
  // (≤117) still call.
  static Future<bool> uploadFace(File photo) =>
      _uploadFile('/avatar-profile/face', photo, 'image/jpeg');

  static Future<bool> uploadVoice(File sample) =>
      _uploadFile('/avatar-profile/voice', sample, 'audio/mp4');

  /// THE IDENTITY VIDEO — POST /avatar-profile/video.
  ///
  /// Streamed from disk as it is sent (MultipartFile.fromPath), never read
  /// into memory, with [onProgress] told how many bytes have gone. A 403
  /// (no consent) comes back as its own case.
  ///
  /// It gives up when NOTHING moves for [idleLimit], not after a fixed
  /// total: a slow mobile uplink still making progress used to be cut at
  /// five minutes, and every Try again started from zero and was cut the
  /// same way (2026-09-26). [totalLimit] only stops a line that trickles
  /// for ever.
  static Future<IdentityUploadResult> uploadVideo(
    File video, {
    required int durationMs,
    required int scriptVersion,
    void Function(int sent, int total)? onProgress,
    // Tests pass their own; otherwise one client per upload, closed after.
    http.Client? client,
    Duration idleLimit = const Duration(seconds: 60),
    Duration totalLimit = const Duration(minutes: 20),
  }) async {
    final c = client ?? http.Client();
    final stalled = Completer<void>();
    Timer? idle;
    void moved() {
      idle?.cancel();
      idle = Timer(idleLimit, () {
        if (!stalled.isCompleted) stalled.complete();
      });
    }

    try {
      final req = ProgressMultipartRequest('POST',
          Uri.parse('${ApiService.baseUrl}/avatar-profile/video'),
          onProgress: (sent, total) {
        moved();
        onProgress?.call(sent, total);
      })
        ..headers.addAll(ApiService.authHeaders..remove('Content-Type'))
        ..fields['duration_ms'] = '$durationMs'
        ..fields['script_version'] = '$scriptVersion'
        ..files.add(await http.MultipartFile.fromPath('file', video.path,
            filename: 'identity.mp4',
            contentType: MediaType('video',
                video.path.toLowerCase().endsWith('.mov') ? 'quicktime' : 'mp4')));
      moved();
      // After the last byte the same limit waits for the answer: the
      // server writes as it receives, so it answers soon after.
      final streamed = await Future.any([
        c.send(req),
        stalled.future.then<http.StreamedResponse>(
            (_) => throw TimeoutException('upload stalled', idleLimit)),
      ]).timeout(totalLimit);
      idle?.cancel();
      final res = await http.Response.fromStream(streamed)
          .timeout(const Duration(seconds: 30));
      ApiService.noteAuthStatus(res.statusCode);
      return IdentityUploadResult.fromResponse(res.statusCode, res.body);
    } catch (e) {
      AppLog.add('avatarmsg', 'identity video upload failed: $e');
      return const IdentityUploadResult(status: 0);
    } finally {
      idle?.cancel();
      // Closing the client also cuts an upload that was given up on.
      if (client == null) c.close();
    }
  }

  /* ----------------- this phone's copy, for the preview ----------------- */

  // The server keeps the video; there is no route that hands it back. The
  // screen shows a small preview from the copy saved here at upload time
  // (app-private storage, deleted with "Delete everything").
  static Future<Directory?> _localDir() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      return Directory('${docs.path}/identity_video');
    } catch (_) {
      return null;
    }
  }

  /// This phone's copy of the video [id], if it was recorded here.
  static Future<File?> localCopy(String? id) async {
    if (id == null || id.isEmpty) return null;
    final dir = await _localDir();
    if (dir == null) return null;
    final f = File('${dir.path}/${_safe(id)}.mp4');
    try {
      return await f.exists() ? f : null;
    } catch (_) {
      return null;
    }
  }

  /// Keeps [recorded] as the preview for video [id]; any older one goes.
  static Future<void> keepLocalCopy(File recorded, String? id) async {
    if (id == null || id.isEmpty) return;
    final dir = await _localDir();
    if (dir == null) return;
    try {
      await deleteLocalCopy();
      await dir.create(recursive: true);
      await recorded.copy('${dir.path}/${_safe(id)}.mp4');
    } catch (e) {
      AppLog.add('avatarmsg', 'keeping the preview copy failed: $e');
    }
  }

  static Future<void> deleteLocalCopy() async {
    final dir = await _localDir();
    try {
      if (dir != null && await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }

  static String _safe(String id) => id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
}

/// What the server says about the user's own identity (GET /avatar-profile).
/// A user with nothing stored reads as all false / null.
class AvatarProfile {
  const AvatarProfile({
    this.consented = false,
    this.consentedAt,
    this.enabled = false,
    this.hasVideo = false,
    this.video,
    this.hasFace = false,
    this.hasVoice = false,
    this.scriptVersion = 0,
  });

  final bool consented;

  /// When consent was given (ms since epoch), if it was.
  final int? consentedAt;

  /// Video notes are sent in the user's likeness.
  final bool enabled;
  final bool hasVideo;
  final IdentityVideo? video;

  // Builds ≤117 captured a photo and a voice sample; still reported.
  final bool hasFace;
  final bool hasVoice;

  /// The script version the server expects now.
  final int scriptVersion;

  factory AvatarProfile.fromJson(Map<String, dynamic> j) {
    final v = j['video'];
    final video = v is Map ? IdentityVideo.fromJson(v.cast<String, dynamic>()) : null;
    return AvatarProfile(
      consented: _flag(j['consented']),
      consentedAt: _int(j['consented_at']),
      enabled: _flag(j['enabled']),
      hasVideo: _flag(j['has_video']) || video != null,
      video: video,
      hasFace: _flag(j['has_face']),
      hasVoice: _flag(j['has_voice']),
      scriptVersion: _int(j['script_version']) ?? 0,
    );
  }
}

/// The identity video on the server.
class IdentityVideo {
  const IdentityVideo({
    required this.id,
    this.durationMs = 0,
    this.bytes = 0,
    this.createdAt,
    this.scriptVersion = 0,
  });

  final String id;
  final int durationMs;
  final int bytes;

  /// When it was saved (ms since epoch).
  final int? createdAt;
  final int scriptVersion;

  Duration get length => Duration(milliseconds: durationMs);

  factory IdentityVideo.fromJson(Map<String, dynamic> j) => IdentityVideo(
        id: (j['id'] ?? '').toString(),
        durationMs: _int(j['duration_ms']) ?? 0,
        bytes: _int(j['bytes']) ?? 0,
        createdAt: _int(j['created_at']),
        scriptVersion: _int(j['script_version']) ?? 0,
      );
}

/// The answer to PUT /avatar-profile/prefs.
class PrefsResult {
  const PrefsResult(this.ok, {this.error});
  final bool ok;

  /// The server's reason when it refused (409), e.g. no video yet.
  final String? error;
}

/// The answer to POST /avatar-profile/video. [status] 0 means it never got
/// an answer (offline, timed out).
class IdentityUploadResult {
  const IdentityUploadResult({required this.status, this.video, this.error});

  final int status;
  final IdentityVideo? video;

  /// The server's own `error` string, when it sent one.
  final String? error;

  bool get ok => status == 200;

  /// No consent on the server: the one refusal the user fixes elsewhere.
  bool get consentRequired => status == 403 || error == 'consent_required';

  bool get tooLarge => status == 413;

  factory IdentityUploadResult.fromResponse(int status, String body) {
    Map<String, dynamic>? j;
    try {
      final d = jsonDecode(body);
      if (d is Map<String, dynamic>) j = d;
    } catch (_) {}
    final v = j?['video'];
    return IdentityUploadResult(
      status: status,
      video: v is Map ? IdentityVideo.fromJson(v.cast<String, dynamic>()) : null,
      error: j?['error']?.toString(),
    );
  }

  /// One sentence for the user. The recording is always kept on a failure,
  /// so every message that can be retried says so.
  String get message {
    if (ok) return 'Your video is saved.';
    if (consentRequired) {
      return 'Consent is off, so nothing was saved. Go back and give it first.';
    }
    if (tooLarge) {
      return 'That video is too large to save. Record it again — '
          'about 30 seconds is plenty.';
    }
    if (status == 0) {
      return "Couldn't save — check your connection. Your video is kept; "
          'tap Try again.';
    }
    if (status == 400 && (error ?? '').isNotEmpty) {
      return "Couldn't save: $error";
    }
    return "Couldn't save your video (error $status). It is kept; "
        'tap Try again.';
  }
}

/// A multipart upload that reports how much of its body has been sent.
/// The file part streams from disk; this only counts the bytes going by.
class ProgressMultipartRequest extends http.MultipartRequest {
  ProgressMultipartRequest(super.method, super.url, {this.onProgress});

  final void Function(int sent, int total)? onProgress;

  @override
  http.ByteStream finalize() {
    final body = super.finalize();
    final report = onProgress;
    if (report == null) return body;
    final total = contentLength;
    var sent = 0;
    return http.ByteStream(body.transform(
      StreamTransformer<List<int>, List<int>>.fromHandlers(
        handleData: (chunk, sink) {
          sent += chunk.length;
          report(sent, total);
          sink.add(chunk);
        },
      ),
    ));
  }
}

bool _flag(Object? v) => v == true || v == 1 || v == '1' || v == 'true';

int? _int(Object? v) => switch (v) {
      int() => v,
      num() => v.toInt(),
      String() => int.tryParse(v) ?? double.tryParse(v)?.toInt(),
      _ => null,
    };
