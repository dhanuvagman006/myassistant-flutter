import 'dart:async';
import 'dart:math' as math;
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/log.dart';
import '../models/brief.dart';
import 'call_history.dart';
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

  /// True when what is on screen is older than the last attempt: a refresh
  /// failed after an earlier one worked (offline). Home says so, with the
  /// time of [updatedAt], instead of passing old news off as current.
  bool stale = false;

  /// When the brief on screen came from the server (kept with the saved
  /// copy, so a cold start offline can still say how old it is).
  DateTime? updatedAt;

  DateTime? _fetchedAt;
  Timer? _auto;
  bool _fetching = false;

  /// Another refresh was asked for while one was running (after a Done):
  /// the running one may have set off before the change, so one more runs.
  bool _again = false;

  /// Reminders and promises the user just acted on, and when. A refresh
  /// that set off BEFORE the action cannot bring them back (the card came
  /// back for a moment otherwise); one that set off after is the truth.
  final _gone = <String, DateTime>{};

  static const _cacheKey = 'brief_cache_v1';
  static const _cacheAtKey = 'brief_cache_at_v1';

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
      final at = prefs.getInt(_cacheAtKey);
      updatedAt = at == null ? null : DateTime.fromMillisecondsSinceEpoch(at);
      loaded = true;
      notifyListeners();
    } catch (e) {
      AppLog.add('brief', 'saved copy unreadable: $e');
    }
  }

  /// Refreshes if stale; forced refresh with [force].
  Future<void> refresh({bool force = false}) async {
    if (_fetching) {
      if (force) _again = true;
      return;
    }
    final fresh = _fetchedAt != null &&
        DateTime.now().difference(_fetchedAt!) < const Duration(minutes: 2);
    if (fresh && !force) return;
    _fetching = true;
    final started = DateTime.now();
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
      if (j == null && loaded && !stale) {
        stale = true;
        notifyListeners();
      }
      if (j != null) {
        final b = TodayBrief.fromJson(j);
        _gone.removeWhere((_, at) => started.isAfter(at));
        if (_gone.isNotEmpty) {
          b.agenda.removeWhere((a) => _gone.containsKey('r${a.id}'));
          b.tomorrow.removeWhere((a) => _gone.containsKey('r${a.id}'));
          b.promises.removeWhere((p) => _gone.containsKey('p${p.id}'));
        }
        brief = b;
        loaded = true;
        failed = false;
        stale = false;
        _fetchedAt = DateTime.now();
        updatedAt = _fetchedAt;
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
          await prefs.setInt(_cacheAtKey, _fetchedAt!.millisecondsSinceEpoch);
        } catch (e) {
          AppLog.add('brief', 'copy not saved: $e');
        }
      }
    } catch (e) {
      AppLog.add('brief', 'refresh failed: $e');
      // Keep showing the previous brief — a blip must not blank the home.
      if (!loaded) {
        failed = true;
        notifyListeners();
      } else if (!stale) {
        stale = true;
        notifyListeners();
      }
    } finally {
      _fetching = false;
      if (_again) {
        _again = false;
        unawaited(refresh(force: true));
      }
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
    stale = false;
    updatedAt = null;
    _fetchedAt = null;
    _gone.clear();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_cacheKey);
      await prefs.remove(_cacheAtKey);
    } catch (e) {
      AppLog.add('brief', 'saved copy not cleared: $e');
    }
    notifyListeners();
  }

  // ---------------- HOME'S BUTTONS (2026-09-29) ----------------
  //
  // AT ONCE, AND HONEST (2026-09-30; was "confirmed, not optimistic",
  // 2026-09-29, which the owner found laggy). The card leaves on the tap
  // and the request runs behind it; a failure puts the card back where it
  // was and says so (the caller offers Try again) — never swallowed, as
  // the old swipe-to-hide helpers did.

  /// Marks a reminder done. False when that could not be done.
  Future<bool> completeReminder(AgendaItem a) async {
    final id = a.id;
    if (id == null) return false;
    final back = _takeAway('r$id', a);
    final ok = await ApiService.sendJson('/reminders/$id',
            method: 'PATCH', body: {'done': true}) !=
        null;
    ok ? unawaited(refresh(force: true)) : back();
    return ok;
  }

  /// Moves a reminder to [to] (Home's "Later"). False when it could not.
  Future<bool> moveReminder(AgendaItem a, DateTime to) async {
    final id = a.id;
    if (id == null) return false;
    final back = _takeAway('r$id', a);
    final ok = await ApiService.sendJson('/reminders/$id',
            method: 'PATCH', body: {'dueAt': to.millisecondsSinceEpoch}) !=
        null;
    // Not gone — moved: the refresh brings it back at its new time.
    ok ? unawaited(refresh(force: true)) : back();
    return ok;
  }

  /// Marks a promise kept. False when that could not be done.
  Future<bool> completePromise(PromiseItem p) async {
    final id = p.id;
    if (id == null) return false;
    final at = brief.promises.indexOf(p);
    _gone['p$id'] = DateTime.now();
    if (at >= 0) brief.promises.removeAt(at);
    notifyListeners();
    final ok = await ApiService.sendJson('/commitments/$id/done') != null;
    if (ok) {
      unawaited(refresh(force: true));
    } else {
      _gone.remove('p$id');
      if (at >= 0) brief.promises.insert(math.min(at, brief.promises.length), p);
      notifyListeners();
    }
    return ok;
  }

  /// THE CARD GOES AT ONCE (owner, 2026-09-30: "some buttons are laggy,
  /// take so much time to respond"): a tap used to wait for the server
  /// before anything moved. Now the card leaves on the touch, the request
  /// runs behind it, and the returned undo puts it back exactly where it
  /// was if the server says no (the caller then offers Try again).
  VoidCallback _takeAway(String key, AgendaItem a) {
    final inAgenda = brief.agenda.indexOf(a);
    final inTomorrow = brief.tomorrow.indexOf(a);
    _gone[key] = DateTime.now();
    // Only where it is: an absent list is a const [] that throws on remove.
    if (inAgenda >= 0) brief.agenda.removeAt(inAgenda);
    if (inTomorrow >= 0) brief.tomorrow.removeAt(inTomorrow);
    notifyListeners();
    return () {
      _gone.remove(key);
      if (inAgenda >= 0) brief.agenda.insert(math.min(inAgenda, brief.agenda.length), a);
      if (inTomorrow >= 0) brief.tomorrow.insert(math.min(inTomorrow, brief.tomorrow.length), a);
      notifyListeners();
    };
  }

  // ---------------- PLAY MY MORNING (2026-09-30) ----------------

  /// The day as a spoken script (POST /brief/script), or null when it
  /// could not be had. [missed] are the phone's missed calls — the server
  /// never sees the call log — sent as names only (an unsaved number goes
  /// as '', never its digits).
  Future<BriefScript?> fetchScript({List<CallEntry> missed = const []}) async {
    final calls = [
      for (final g in CallHistory.group(missed).take(5))
        {'name': g.latest.name, 'count': g.count},
    ];
    final j = await ApiService.postJson(
      '/brief/script',
      {'missedCalls': calls},
      // The server may ask the model for the words: up to ~6 s, plus the
      // brief itself.
      timeout: const Duration(seconds: 20),
    );
    if (j == null) return null;
    final s = BriefScript.fromJson(j);
    return s.script.isEmpty ? null : s;
  }

  @visibleForTesting
  void debugShow(TodayBrief b, {bool failed = false, bool stale = false}) {
    brief = b;
    loaded = !failed;
    this.failed = failed;
    this.stale = stale;
    notifyListeners();
  }
}
