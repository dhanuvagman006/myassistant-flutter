import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/brief.dart';
import 'notification_service.dart';
import 'api_service.dart';
import 'auth_service.dart';

/// Fetches and caches the home screen's "Today" brief (GET /brief).
///
/// One aggregate request instead of five — the dashboard renders whatever
/// the last good fetch returned, refreshes quietly in the background, and
/// NEVER blocks or breaks the live conversation (errors keep the old data).
class BriefService extends ChangeNotifier {
  BriefService._() {
    AuthService.instance.onSignOut(reset);
  }
  static final BriefService instance = BriefService._();

  TodayBrief brief = const TodayBrief();
  bool loaded = false;

  /// True when there is nothing to show AND the last fetch failed — the
  /// first launch with no network. Without it Home spun forever: a failed
  /// fetch never set [loaded], and nothing offered to try again.
  bool failed = false;
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
    if (failed) {
      failed = false; // show the spinner while this attempt runs
      notifyListeners();
    }
    try {
      final j = await ApiService.getJson('/brief');
      if (j == null && !loaded) {
        failed = true;
        notifyListeners();
      }
      if (j != null) {
        brief = TodayBrief.fromJson(j);
        loaded = true;
        failed = false;
        _fetchedAt = DateTime.now();
        notifyListeners();
        // Re-arm the LOCAL alarms for every open reminder. This service
        // existed fully built with ZERO callers — "remind me at 5"
        // created rows that never rang on any device. The brief refresh
        // already fires after every turn and on resume, so this keeps
        // the phone's alarms in step with the server at no extra cost.
        unawaited(ReminderNotifications.instance.sync());
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(_cacheKey, jsonEncode(j));
        } catch (_) {}
      }
    } catch (_) {
      // Keep showing the previous brief — a blip must not blank the home.
      if (!loaded) {
        failed = true;
        notifyListeners();
      }
    } finally {
      _fetching = false;
    }
  }

  /// Forgets everything about the signed-out account: the in-memory brief,
  /// the saved copy that repaints Home on the next launch, and the refresh
  /// timer (which kept polling /brief with no one signed in). The next
  /// sign-in's HomeShell calls [start] again.
  Future<void> reset() async {
    _auto?.cancel();
    _auto = null;
    brief = const TodayBrief();
    loaded = false;
    failed = false;
    _fetchedAt = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_cacheKey);
    } catch (_) {}
    notifyListeners();
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
    // Wrapped like deleteReminder below, which always had this. Without it
    // a failed write threw out of an optimistic gesture nobody is awaiting,
    // so the card was already gone and the error had nowhere to surface.
    // The next refresh reconciles the row either way.
    try {
      if (kind == 'done') {
        await ApiService.sendJson('/commitments/${p.id}/done');
      } else {
        await ApiService.sendJson('/commitments/${p.id}', method: 'DELETE');
      }
    } catch (_) {}
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

  // ---------------- UNDOABLE versions (Home's swipe + Undo) ----------------
  //
  // A swipe used to delete for good the instant it finished — one stray
  // thumb on the agenda and a reminder was gone. These split the gesture:
  // the card leaves the screen at once, the server is only told when the
  // Undo window closes, and Undo puts the card back where it was.

  /// Takes the reminder off the screen; returns where it was, for [restoreReminder].
  int hideReminder(AgendaItem a) {
    final i = brief.agenda.indexOf(a);
    brief.agenda.remove(a);
    notifyListeners();
    return i;
  }

  void restoreReminder(AgendaItem a, int index) {
    if (brief.agenda.contains(a)) return;
    brief.agenda.insert(index.clamp(0, brief.agenda.length), a);
    notifyListeners();
  }

  Future<void> commitReminderDelete(AgendaItem a) async {
    if (a.id == null) return;
    try {
      await ApiService.deleteReminder(a.id!);
    } catch (_) {}
  }

  int hidePromise(PromiseItem p) {
    final i = brief.promises.indexOf(p);
    brief.promises.remove(p);
    notifyListeners();
    return i;
  }

  void restorePromise(PromiseItem p, int index) {
    if (brief.promises.contains(p)) return;
    brief.promises.insert(index.clamp(0, brief.promises.length), p);
    notifyListeners();
  }

  /// [done] true = "I kept it", false = "never mind".
  Future<void> commitPromise(PromiseItem p, {required bool done}) async {
    if (p.id == null) return;
    try {
      if (done) {
        await ApiService.sendJson('/commitments/${p.id}/done');
      } else {
        await ApiService.sendJson('/commitments/${p.id}', method: 'DELETE');
      }
    } catch (_) {}
  }
}
