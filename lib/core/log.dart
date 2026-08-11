import 'package:flutter/foundation.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  AppLog — the app's single in-memory log.
///
///  Every layer (API, SSE stream, voice, engine) writes one-line entries
///  here. The Diagnostics screen shows the tail live, so "it's not
///  working" becomes "look, the POST to /assistant/session returned a
///  connection refused at 6:21:14" — debuggable on a phone, no adb.
///
///  Ring buffer, capped: zero growth, zero files, nothing sensitive
///  persisted. Also mirrors to debugPrint in debug builds.
/// ─────────────────────────────────────────────────────────────────────────
class AppLog {
  AppLog._();
  static const int _cap = 200;

  static final List<String> _lines = [];

  /// Bumps whenever a line is added — the Diagnostics screen listens.
  static final ValueNotifier<int> revision = ValueNotifier(0);

  static void add(String tag, String message) {
    final t = DateTime.now();
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    final ss = t.second.toString().padLeft(2, '0');
    final line = '$hh:$mm:$ss [$tag] $message';
    _lines.add(line);
    if (_lines.length > _cap) _lines.removeAt(0);
    revision.value++;
    if (kDebugMode) debugPrint(line);
  }

  /// Newest last. Copy — callers can't mutate the buffer.
  static List<String> tail([int n = _cap]) =>
      List.unmodifiable(_lines.length <= n
          ? _lines
          : _lines.sublist(_lines.length - n));

  static void clear() {
    _lines.clear();
    revision.value++;
  }
}
