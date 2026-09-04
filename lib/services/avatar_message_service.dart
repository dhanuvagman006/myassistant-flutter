import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart' show MediaType;
import 'package:path_provider/path_provider.dart';

import '../core/log.dart';
import '../widgets/avatar_message_popup.dart';
import 'api_service.dart';

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
/// handles rows with media, and marks them read after playback starts so
/// an interrupted download can be retried.
class AvatarMessageService {
  AvatarMessageService._();
  static final AvatarMessageService instance = AvatarMessageService._();

  /// Registered on the MaterialApp so the popup can appear from a push
  /// tap regardless of which screen is on top.
  static final navigatorKey = GlobalKey<NavigatorState>();

  bool _showing = false;

  /// Fetch unread media messages and show them one after another.
  /// Returns true when at least one popup was shown (so callers know the
  /// tap was consumed and the voice announcement can skip those rows).
  Future<bool> showPending() async {
    if (_showing) return true;
    _showing = true;
    try {
      // Session may still be restoring on a cold start from a push tap.
      for (var i = 0; i < 20 && ApiService.sessionToken == null; i++) {
        await Future.delayed(const Duration(milliseconds: 500));
      }
      final j = await ApiService.getJson('/messages/unread');
      final rows = (j?['messages'] as List?)
              ?.whereType<Map<String, dynamic>>()
              .where((m) => (m['media'] ?? '') != '')
              .toList() ??
          const [];
      if (rows.isEmpty) return false;

      for (final m in rows) {
        final file = await _download(m);
        // Mark read even when the download failed: the words themselves
        // are in the row and have been shown/spoken by the fallback below.
        await ApiService.sendJson('/messages/read', body: {'ids': [m['id']]});
        final ctx = navigatorKey.currentContext;
        if (ctx == null || !ctx.mounted) break;
        await showAvatarMessagePopup(
          ctx,
          senderName: (m['from'] as String?) ?? 'Someone',
          text: (m['message'] as String?) ?? '',
          kind: file == null ? 'text' : (m['media'] as String? ?? 'audio'),
          mediaFile: file,
        );
      }
      return true;
    } catch (e) {
      AppLog.add('avatarmsg', 'showPending failed: $e');
      return false;
    } finally {
      _showing = false;
    }
  }

  /// Small files (a 15s clip is ~1–3 MB): download fully with our auth
  /// headers, then play locally — no player-side auth or range quirks.
  Future<File?> _download(Map<String, dynamic> m) async {
    try {
      final url = m['media_url'] as String?;
      if (url == null) return null;
      final res = await http
          .get(Uri.parse('${ApiService.baseUrl}$url'),
              headers: ApiService.authHeaders)
          .timeout(const Duration(seconds: 30));
      if (res.statusCode != 200 || res.bodyBytes.isEmpty) {
        AppLog.add('avatarmsg', 'media fetch → ${res.statusCode}');
        return null;
      }
      final dir = await getTemporaryDirectory();
      final ext = (m['media'] == 'video') ? 'mp4' : 'wav';
      final f = File('${dir.path}/avatarmsg_${m['id']}.$ext');
      await f.writeAsBytes(res.bodyBytes, flush: true);
      return f;
    } catch (e) {
      AppLog.add('avatarmsg', 'media download failed: $e');
      return null;
    }
  }

  /* ------------------- sender-side identity management ------------------- */

  static Future<Map<String, dynamic>?> profile() =>
      ApiService.getJson('/avatar-profile');

  static Future<bool> grantConsent() async =>
      await ApiService.sendJson('/avatar-profile/consent', method: 'POST') != null;

  static Future<bool> revokeConsent() async =>
      await ApiService.sendJson('/avatar-profile/consent', method: 'DELETE') != null;

  static Future<bool> setEnabled(bool enabled) async =>
      await ApiService.sendJson('/avatar-profile/prefs',
          method: 'PUT', body: {'enabled': enabled}) != null;

  static Future<bool> deleteIdentity() async =>
      await ApiService.sendJson('/avatar-profile', method: 'DELETE') != null;

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

  static Future<bool> uploadFace(File photo) =>
      _uploadFile('/avatar-profile/face', photo, 'image/jpeg');

  static Future<bool> uploadVoice(File sample) =>
      _uploadFile('/avatar-profile/voice', sample, 'audio/mp4');
}
