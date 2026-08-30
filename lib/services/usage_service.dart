import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/log.dart';
import 'api_service.dart';

/// SCREEN-TIME REPORTING — the on-device half of usage tracking.
///
/// Android's UsageStatsManager is behind a special permission the user must
/// grant by hand (Settings → Special app access → Usage access), so this
/// service is a quiet opportunist: on every app start it checks whether the
/// permission has appeared, and if so pushes the last two days of per-app
/// foreground minutes to the backend. The AGENT reads from the backend, not
/// the device — that way "how much did I use YouTube" works identically in
/// live and classic voice, and the morning brief can carry a screen-time
/// line without waking the phone.
class UsageService {
  UsageService._();
  static final UsageService instance = UsageService._();

  static const _ch = MethodChannel('hari/usage');
  bool _syncing = false;

  Future<bool> hasPermission() async {
    try {
      return await _ch.invokeMethod<bool>('hasPermission') ?? false;
    } catch (_) {
      return false; // iOS or channel missing — feature silently absent
    }
  }

  /// Opens the Usage access settings screen (the only way to grant).
  Future<void> openSettings() async {
    try {
      await _ch.invokeMethod('openSettings');
    } catch (_) {}
  }

  /// Push today + yesterday to the backend, at most once per hour.
  /// Yesterday is included on every sync because "today" was incomplete
  /// when it was last uploaded — the final upsert fixes the totals.
  Future<void> syncIfPermitted() async {
    if (_syncing) return;
    _syncing = true;
    try {
      if (!await hasPermission()) return;
      final prefs = await SharedPreferences.getInstance();
      final last = prefs.getInt('usage_synced_at') ?? 0;
      if (DateTime.now().millisecondsSinceEpoch - last < 3600_000) return;

      final days = <Map<String, dynamic>>[];
      for (var ago = 0; ago <= 1; ago++) {
        final raw = await _ch.invokeMethod<List<dynamic>>(
            'getDayUsage', {'daysAgo': ago});
        final apps = [
          for (final e in (raw ?? const []).whereType<Map>())
            {
              'package': e['package'],
              'name': e['name'],
              'minutes': e['minutes'],
            }
        ];
        if (apps.isEmpty) continue;
        final d = DateTime.now().subtract(Duration(days: ago));
        days.add({
          'date':
              '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}',
          'apps': apps,
        });
      }
      if (days.isEmpty) return;
      final r = await ApiService.sendJson('/usage', body: {'days': days});
      if (r != null) {
        await prefs.setInt(
            'usage_synced_at', DateTime.now().millisecondsSinceEpoch);
        AppLog.add('usage', 'synced ${days.length} day(s) of screen time');
      }
    } catch (e) {
      AppLog.add('usage', 'sync failed: $e');
    } finally {
      _syncing = false;
    }
  }
}
