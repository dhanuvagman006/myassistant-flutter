import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_service.dart';

/// One JSON request: `GET`, `PUT` or `DELETE` to [path]. Null on failure.
typedef JsonTransport = Future<Map<String, dynamic>?> Function(
    String method, String path, [Object? body]);

Future<Map<String, dynamic>?> apiTransport(String method, String path,
    [Object? body]) {
  if (method == 'GET') return ApiService.getJson(path, timeout: const Duration(seconds: 10));
  return ApiService.sendJson(path, method: method, body: body);
}

/// ─────────────────────────────────────────────────────────────────────────
///  "HELP IMPROVE THE ASSISTANT" (build 120).
///
///  Off until the user says yes. When on, the team may listen to recordings
///  of their voice chats and read their conversations, only to fix
///  mistakes. When off, recordings are not kept and chats stay private.
///  The server decides and enforces; this is the switch and the one-time
///  question. `ask` is true until they answer the card.
/// ─────────────────────────────────────────────────────────────────────────
class PrivacyPrefsService extends ChangeNotifier {
  PrivacyPrefsService._();
  static final PrivacyPrefsService instance = PrivacyPrefsService._();

  /// The wording the user was shown. The server stores it with the choice.
  static const noticeVersion = 'help-improve-v1';
  static const _prefsKey = 'help_improve_v1';

  @visibleForTesting
  static JsonTransport transport = apiTransport;

  /// true on, false off, null not asked yet.
  bool? helpImprove;
  bool ask = false;
  int recordingDays = 14;
  bool loaded = false;

  bool get isOn => helpImprove == true;

  Future<void> load() async {
    // The last known answer paints the switch at once.
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.containsKey(_prefsKey)) {
        helpImprove = prefs.getBool(_prefsKey);
        notifyListeners();
      }
    } catch (_) {}
    final r = await transport('GET', '/privacy/prefs');
    if (r == null) return;
    final v = r['helpImprove'];
    helpImprove = v is bool ? v : null;
    ask = r['ask'] == true;
    final keeps = r['keeps'];
    if (keeps is Map && keeps['recordingDays'] is num) {
      recordingDays = (keeps['recordingDays'] as num).toInt();
    }
    loaded = true;
    await _cache();
    notifyListeners();
  }

  /// Saves the choice. [source] is `ask_card` or `settings`. The caller
  /// shows the notice (turning on) or the confirmation (turning off) first.
  /// Returns false when the server did not take it.
  Future<bool> set(bool on, {required String source}) async {
    final r = await transport('PUT', '/privacy/prefs', {
      'helpImprove': on,
      'source': source,
      'noticeVersion': noticeVersion,
    });
    if (r == null) return false;
    helpImprove = r['helpImprove'] is bool ? r['helpImprove'] as bool : on;
    ask = false;
    await _cache();
    notifyListeners();
    return true;
  }

  Future<void> _cache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (helpImprove == null) {
        await prefs.remove(_prefsKey);
      } else {
        await prefs.setBool(_prefsKey, helpImprove!);
      }
    } catch (_) {}
  }

  @visibleForTesting
  void resetForTest() {
    helpImprove = null;
    ask = false;
    recordingDays = 14;
    loaded = false;
  }
}
