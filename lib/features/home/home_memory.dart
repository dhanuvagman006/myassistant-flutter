import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/auth_service.dart';

/// What Home remembers on this phone: the cards put away with "Not now"
/// (until tomorrow — or until the thing changes, since a changed thing is
/// a new card id) and when Home was first opened, which decides the few
/// days a newcomer with nothing yet gets the "Ask me anything" card.
class HomeMemory extends ChangeNotifier {
  HomeMemory._() {
    AuthService.instance.onSignOut(reset);
  }
  static final HomeMemory instance = HomeMemory._();

  static const _kHidden = 'home_not_now_v1';
  static const _kFirstSeen = 'home_first_seen_v1';
  static const _kNews = 'home_news_on_v1';

  /// Headlines on Home (a card of two, when there is room). Off with the
  /// card's ✕ or You → Home; on by default.
  final ValueNotifier<bool> newsOn = ValueNotifier<bool>(true);

  /// How long someone counts as new.
  static const newFor = Duration(days: 3);

  final Map<String, int> _hidden = {}; // card id → hidden until (ms)
  DateTime? _firstSeen;
  Future<void>? _loading;

  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_kHidden);
      if (raw != null) {
        final m = jsonDecode(raw);
        if (m is Map) {
          for (final e in m.entries) {
            final until = e.value;
            if (until is num) _hidden['${e.key}'] = until.toInt();
          }
        }
      }
      newsOn.value = p.getBool(_kNews) ?? true;
      final seen = p.getInt(_kFirstSeen);
      if (seen == null) {
        _firstSeen = DateTime.now();
        await p.setInt(_kFirstSeen, _firstSeen!.millisecondsSinceEpoch);
      } else {
        _firstSeen = DateTime.fromMillisecondsSinceEpoch(seen);
      }
    } catch (_) {/* nothing hidden, not new: the plain Home */}
    notifyListeners();
  }

  /// The ids "Not now" still hides at [now].
  Set<String> hiddenAt(DateTime now) {
    final t = now.millisecondsSinceEpoch;
    return {for (final e in _hidden.entries) if (e.value > t) e.key};
  }

  bool isNew(DateTime now) {
    final seen = _firstSeen;
    return seen != null && now.difference(seen) < newFor;
  }

  /// "Not now": gone until tomorrow.
  Future<void> hide(String id, {DateTime? now}) async {
    final t = now ?? DateTime.now();
    final until = DateTime(t.year, t.month, t.day + 1);
    _hidden[id] = until.millisecondsSinceEpoch;
    _hidden.removeWhere((_, u) => u <= t.millisecondsSinceEpoch);
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_kHidden, jsonEncode(_hidden));
    } catch (_) {/* hidden for this run; shown again next launch */}
  }

  Future<void> setNewsOn(bool on) async {
    newsOn.value = on;
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_kNews, on);
    } catch (_) {/* for this run only */}
  }

  Future<void> reset() async {
    newsOn.value = true;
    _hidden.clear();
    _firstSeen = null;
    _loading = null;
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.remove(_kHidden);
      await p.remove(_kFirstSeen);
      await p.remove(_kNews);
    } catch (_) {}
  }

  @visibleForTesting
  void debugSet({Map<String, int> hidden = const {}, DateTime? firstSeen, bool newsOn = true}) {
    this.newsOn.value = newsOn;
    _hidden
      ..clear()
      ..addAll(hidden);
    _firstSeen = firstSeen;
    _loading = Future.value();
    notifyListeners();
  }
}
