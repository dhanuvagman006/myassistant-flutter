import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/brief.dart';
import 'api_service.dart';

/// Fetches and caches the home screen's "Today" brief (GET /brief).
///
/// One aggregate request instead of five — the dashboard renders whatever
/// the last good fetch returned, refreshes quietly in the background, and
/// NEVER blocks or breaks the live conversation (errors keep the old data).
class BriefService extends ChangeNotifier {
  BriefService._();
  static final BriefService instance = BriefService._();

  TodayBrief brief = const TodayBrief();
  bool loaded = false;
  DateTime? _fetchedAt;
  Timer? _auto;
  bool _fetching = false;

  /// Starts periodic refresh (call once from the home screen).
  void start() {
    refresh();
    _auto ??= Timer.periodic(const Duration(minutes: 5), (_) => refresh());
  }

  /// Refreshes if stale; forced refresh with [force].
  Future<void> refresh({bool force = false}) async {
    if (_fetching) return;
    final fresh = _fetchedAt != null &&
        DateTime.now().difference(_fetchedAt!) < const Duration(minutes: 2);
    if (fresh && !force) return;
    _fetching = true;
    try {
      final j = await ApiService.getJson('/brief');
      if (j != null) {
        brief = TodayBrief.fromJson(j);
        loaded = true;
        _fetchedAt = DateTime.now();
        notifyListeners();
      }
    } catch (_) {
      // Keep showing the previous brief — a blip must not blank the home.
    } finally {
      _fetching = false;
    }
  }
}
