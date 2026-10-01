import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/api_service.dart';
import 'calendar_models.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  WHAT THE CALENDAR SCREEN READS (2026-09-30).
///
///  * [month] — the user's own month (GET /brief/calendar?y=&m=): kept in
///    memory for the app run, one request in flight per month, so the grid
///    and "Coming up" share a fetch.
///  * [extras] — holidays, festivals, world days and global events
///    (GET /tools/calendar/extras?from=&to=). They change rarely, so they
///    are saved on the phone: the screen paints the saved copy at once and
///    asks the server only when it is older than [extrasFresh]. The last
///    good copy is kept when the network fails.
/// ─────────────────────────────────────────────────────────────────────────
class CalendarService {
  CalendarService._();

  /// Test seam: the GET behind both calls.
  @visibleForTesting
  static Future<Map<String, dynamic>?> Function(String path) getJson =
      (path) => ApiService.getJson(path, timeout: const Duration(seconds: 8));

  /// Test seam: DELETE /<collection>/<id>.
  @visibleForTesting
  static Future<bool> Function(String path) delete = (path) async =>
      await ApiService.sendJson(path, method: 'DELETE') != null;

  static const extrasFresh = Duration(hours: 12);
  static const _prefsKey = 'cal_extras_v1';
  static const _keep = 16; // saved windows, newest first

  // ── the user's own month ────────────────────────────────────────────
  static final Map<String, Map<int, List<CalendarEntry>>> _months = {};
  static final Map<String, Future<Map<int, List<CalendarEntry>>?>> _inflight =
      {};

  static String _mk(int y, int m) => '$y-$m';

  /// This run's copy of a month, if it was seen.
  static Map<int, List<CalendarEntry>>? cachedMonth(int y, int m) =>
      _months[_mk(y, m)];

  /// Drops a month so the next [month] asks the server.
  static void forget(int y, int m) => _months.remove(_mk(y, m));

  /// The month from the server; null when it could not be reached (the
  /// caller keeps what it shows).
  static Future<Map<int, List<CalendarEntry>>?> month(int y, int m) {
    final k = _mk(y, m);
    return _inflight[k] ??= () async {
      try {
        final j = await getJson('/brief/calendar?y=$y&m=$m');
        if (j == null) return null;
        final out = parseMonth(y, m, j);
        _months[k] = out;
        return out;
      } catch (_) {
        return null;
      } finally {
        unawaited(Future.microtask(() => _inflight.remove(k)));
      }
    }();
  }

  /// /brief/calendar's `days` map as entries, sorted by time.
  static Map<int, List<CalendarEntry>> parseMonth(
      int y, int m, Map<String, dynamic>? j) {
    final out = <int, List<CalendarEntry>>{};
    final raw = (j?['days'] as Map?) ?? const {};
    raw.forEach((k, v) {
      final day = int.tryParse('$k');
      if (day == null || day < 1 || day > 31 || v is! List) return;
      final list = v
          .whereType<Map>()
          .map((e) => CalendarEntry.fromBrief(y, m, day, e))
          .toList()
        ..sort((a, b) {
          final x = a.at, z = b.at;
          if (x == null && z == null) return 0;
          if (x == null) return 1;
          if (z == null) return -1;
          return x.compareTo(z);
        });
      out[day] = list;
    });
    return out;
  }

  /// Removes [e] on the server; true when it is gone.
  static Future<bool> remove(CalendarEntry e) async {
    if (!e.deletable) return false;
    try {
      final ok = await delete('/${e.del}/${e.id}');
      if (ok) forget(e.date.year, e.date.month);
      return ok;
    } catch (_) {
      return false;
    }
  }

  // ── the world's days ────────────────────────────────────────────────
  static final Map<String, ExtrasResult> _mem = {};

  static String _xk(DateTime from, DateTime to) =>
      '${calIso(from)}_${calIso(to)}';

  /// The saved copy for a window (memory, then the phone), or null.
  static Future<ExtrasResult?> savedExtras(DateTime from, DateTime to) async {
    final k = _xk(from, to);
    final hit = _mem[k];
    if (hit != null) return hit;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null) return null;
      final all = jsonDecode(raw) as Map<String, dynamic>;
      final one = all[k];
      if (one is! Map) return null;
      final at = DateTime.tryParse('${one['at']}');
      final items = _parseItems(one['items']);
      if (at == null) return null;
      final r = ExtrasResult(items, at, region: one['region'] as String?);
      _mem[k] = r;
      return r;
    } catch (_) {
      return null;
    }
  }

  /// The window from the server, saved on the phone; null on failure.
  static Future<ExtrasResult?> fetchExtras(DateTime from, DateTime to) async {
    final k = _xk(from, to);
    try {
      final j = await getJson(
          '/tools/calendar/extras?from=${calIso(from)}&to=${calIso(to)}');
      if (j == null || j['items'] is! List) return null;
      final r = ExtrasResult(_parseItems(j['items']), DateTime.now(),
          region: j['region'] as String?);
      _mem[k] = r;
      unawaited(_save(k, j['items'] as List, r));
      return r;
    } catch (_) {
      return null;
    }
  }

  /// Saved copy first ([onSaved]), then the server when the copy is
  /// missing or older than [extrasFresh]. Returns the best it has, and
  /// null only when there is neither.
  static Future<ExtrasResult?> extras(DateTime from, DateTime to,
      {void Function(ExtrasResult saved)? onSaved, bool force = false}) async {
    final saved = await savedExtras(from, to);
    if (saved != null) onSaved?.call(saved);
    if (!force &&
        saved != null &&
        DateTime.now().difference(saved.fetchedAt) < extrasFresh) {
      return saved;
    }
    return await fetchExtras(from, to) ?? saved;
  }

  static List<CalendarEntry> _parseItems(Object? v) => (v is List ? v : const [])
      .whereType<Map>()
      .map(CalendarEntry.fromExtra)
      .whereType<CalendarEntry>()
      .toList();

  static Future<void> _save(String k, List items, ExtrasResult r) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      Map<String, dynamic> all = {};
      final raw = prefs.getString(_prefsKey);
      if (raw != null) {
        try {
          all = Map<String, dynamic>.from(jsonDecode(raw) as Map);
        } catch (_) {}
      }
      all.remove(k);
      all[k] = {
        'at': r.fetchedAt.toIso8601String(),
        'region': r.region,
        'items': items,
      };
      // Newest last (insertion order): drop the oldest windows.
      while (all.length > _keep) {
        all.remove(all.keys.first);
      }
      await prefs.setString(_prefsKey, jsonEncode(all));
    } catch (_) {}
  }

  @visibleForTesting
  static void debugReset() {
    _months.clear();
    _inflight.clear();
    _mem.clear();
  }
}

class ExtrasResult {
  const ExtrasResult(this.items, this.fetchedAt, {this.region});
  final List<CalendarEntry> items;
  final DateTime fetchedAt;

  /// "IN-KL" or "IN": which state's holidays these are.
  final String? region;
}
