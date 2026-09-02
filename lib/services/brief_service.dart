import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  static const _cacheKey = 'brief_cache_v1';

  /// Starts periodic refresh (call once from the home screen).
  void start() {
    _hydrate(); // paint the LAST brief instantly; the fetch replaces it
    refresh();
    _auto ??= Timer.periodic(const Duration(minutes: 5), (_) => refresh());
  }

  /// Cold-start speed: the home screen shows yesterday's last-good brief
  /// in one frame instead of a skeleton while the network round-trips.
  Future<void> _hydrate() async {
    if (loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final s = prefs.getString(_cacheKey);
      if (s == null || loaded) return; // a fast fetch may have won the race
      brief = TodayBrief.fromJson(jsonDecode(s) as Map<String, dynamic>);
      loaded = true;
      notifyListeners();
    } catch (_) {}
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
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(_cacheKey, jsonEncode(j));
        } catch (_) {}
      }
    } catch (_) {
      // Keep showing the previous brief — a blip must not blank the home.
    } finally {
      _fetching = false;
    }
  }

  /// Promise actions are OPTIMISTIC: the card leaves the screen the moment
  /// the user acts (that instant feedback is the whole point of a swipe),
  /// and the server call follows. A failed call is reconciled by the next
  /// periodic refresh rather than by resurrecting the card mid-gesture.
  Future<void> completePromise(PromiseItem p) => _promiseAction(p, 'done');
  Future<void> dismissPromise(PromiseItem p) => _promiseAction(p, 'delete');

  Future<void> _promiseAction(PromiseItem p, String kind) async {
    brief.promises.remove(p);
    notifyListeners();
    if (p.id == null) return; // pre-upgrade payload — refresh will resync
    if (kind == 'done') {
      await ApiService.sendJson('/commitments/${p.id}/done');
    } else {
      await ApiService.sendJson('/commitments/${p.id}', method: 'DELETE');
    }
  }

  /// Same optimistic treatment for reminder rows on the agenda.
  Future<void> deleteReminder(AgendaItem a) async {
    brief.agenda.remove(a);
    notifyListeners();
    if (a.id == null) return;
    try {
      await ApiService.deleteReminder(a.id!);
    } catch (_) {}
  }
}
