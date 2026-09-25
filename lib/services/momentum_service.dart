import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/momentum.dart';
import 'api_service.dart';
import 'auth_service.dart';
import 'habit_alarms.dart';
import 'notification_service.dart';

/// What the server answered: the HTTP status (0 = never reached it) and
/// its JSON body.
class MomentumReply {
  const MomentumReply(this.status, this.json);
  final int status;
  final Map<String, dynamic>? json;
  bool get ok => status >= 200 && status < 300 && json != null && json!['ok'] == true;
  String? get error => json?['error'] as String?;
}

/// Sends one request to /momentum{path}. Replaced in tests.
typedef MomentumTransport = Future<MomentumReply> Function(String method, String path,
    {Map<String, dynamic>? body});

/// Something worth a moment's celebration, played once by whichever
/// Momentum view is on screen when it happens.
class MomentumCelebration {
  const MomentumCelebration(this.seq, this.line, {this.milestone});
  final int seq;

  /// The short line under the glow ("All three done — a winning day.").
  final String line;
  final String? milestone;
}

/// ─────────────────────────────────────────────────────────────────────────
///  MOMENTUM — Today's 3, habits, focus and the streak (2026-09-25).
///
///  Owner: "plan and add some features that make much better and keeps
///  user motivated and productive". The server holds the truth (it survives
///  a reinstall); this keeps the last copy for an instant Home and offline
///  use, and makes every tap feel immediate:
///
///   * OPTIMISTIC. A tap changes the screen at once; the request follows.
///     If the server says no (or cannot be reached) the change is taken
///     back and [lastError] says why.
///   * ONE AT A TIME. Requests go out in the order they were made, so a
///     quick tick-untick can never land the other way round. What is shown
///     is the last answer from the server with the edits still in flight
///     laid over it.
///   * THE PHONE'S OWN DAY. Every request names the local date, so "today"
///     is never the server's idea of it.
/// ─────────────────────────────────────────────────────────────────────────
class MomentumService extends ChangeNotifier {
  MomentumService._() {
    AuthService.instance.onSignOut(reset);
  }
  static final MomentumService instance = MomentumService._();

  static const _cacheKey = 'momentum_cache_v1';
  static const _celebratedKey = 'momentum_celebrated_v1';

  /// How requests reach the server (tests swap in their own).
  static MomentumTransport transport = _http;

  /// The phone's clock (tests pin it).
  static DateTime Function() clock = DateTime.now;

  /// Puts the habits' daily reminders on the phone when a habit, its time
  /// or today's tick changed (tests record instead).
  static void Function(List<MomentumHabit> habits)? onHabitsChanged =
      (h) => unawaited(ReminderNotifications.instance.armHabits(h));
  String? _alarmSig;

  /// 'YYYY-MM-DD' for a local date.
  static String dayOf(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static String get today => dayOf(clock());
  static String get tomorrow => dayOf(clock().add(const Duration(days: 1)));

  MomentumSummary? _confirmed;
  MomentumSummary? _view;
  final List<_Edit> _pending = [];
  final List<Future<void> Function()> _jobs = [];
  bool _draining = false;
  DateTime? _fetchedAt;
  Timer? _auto;
  bool _fetching = false;
  Set<String>? _celebrated;
  int _celebrationSeq = 0;

  /// Bumped on sign-out: an answer to a request the previous account made
  /// must not repaint the next one's screen.
  int _generation = 0;

  /// What to show: the server's last word with pending edits on top.
  MomentumSummary? get summary => _view;

  /// There is something to show (from the cache or the server).
  bool get loaded => _view != null;

  /// Nothing to show and the last fetch failed.
  bool failed = false;

  /// Why the last change did not go through, in words for the user.
  String? lastError;

  /// The latest celebration. Views play it once, if they are on screen.
  final ValueNotifier<MomentumCelebration?> celebration = ValueNotifier(null);

  /// Loads the saved copy, fetches the day, and keeps "today" current.
  void start() {
    unawaited(_hydrate());
    unawaited(refresh());
    // The day can turn over with the app open: pick up the new one.
    _auto ??= Timer.periodic(const Duration(minutes: 5), (_) {
      final stale = _fetchedAt == null ||
          clock().difference(_fetchedAt!) > const Duration(minutes: 15);
      if (_view?.day != today || stale) unawaited(refresh());
    });
  }

  /// Puts a summary on screen as if the server had just sent it (tests,
  /// and the layout sweep's filled-in screens).
  @visibleForTesting
  void debugSeed(MomentumSummary? s) {
    _confirmed = s;
    _pending.clear();
    failed = false;
    _setView(s?.clone(), celebrate: false);
  }

  Future<void> _hydrate() async {
    if (_confirmed != null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_cacheKey);
      if (raw == null || _confirmed != null) return;
      final s = MomentumSummary.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      // Yesterday's list is not today's: a copy from another day waits
      // for the server rather than showing the wrong three.
      if (s.day != today) return;
      _confirmed = s;
      _recompute(celebrate: false);
    } catch (_) {}
  }

  /// Fetches today's summary (skipped when fresh, unless [force]).
  Future<void> refresh({bool force = false}) async {
    if (_fetching) return;
    final fresh = _fetchedAt != null &&
        clock().difference(_fetchedAt!) < const Duration(seconds: 20) &&
        _view?.day == today;
    if (fresh && !force) return;
    _fetching = true;
    final gen = _generation;
    try {
      await _queue(() async {
        final r = await transport('GET', '?day=$today');
        if (gen != _generation) return;
        if (r.ok) {
          _accept(r.json!);
        } else if (_confirmed == null) {
          failed = true;
          _recompute();
        }
      });
    } finally {
      _fetching = false;
    }
  }

  /// Forgets the signed-out account: its summary, the saved copy, the timer.
  Future<void> reset() async {
    _generation++;
    _auto?.cancel();
    _auto = null;
    _confirmed = null;
    _pending.clear();
    // A request still hanging for the last account must not hold up the
    // next one's.
    _jobs.clear();
    _draining = false;
    _fetchedAt = null;
    failed = false;
    lastError = null;
    _celebrated = null;
    // Their habit reminders stop ringing on this phone.
    if (_alarmSig != null) onHabitsChanged?.call(const []);
    _alarmSig = null;
    _setView(null, celebrate: false);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_cacheKey);
      await prefs.remove(_celebratedKey);
    } catch (_) {}
  }

  // ── Today's 3 ─────────────────────────────────────────────────────────

  static const maxPriorities = 3;
  int _tempId = -1;

  /// Adds one to today's list (three at most).
  Future<bool> addPriority(String title) {
    final t = _clean(title);
    final s = _view;
    if (t.isEmpty) return Future.value(false);
    if (s != null && s.priorities.length >= maxPriorities) {
      lastError = 'Today already has three.';
      return Future.value(false);
    }
    final temp = _tempId--;
    return _edit(
      'PUT',
      '/priorities',
      bodyOf: (s) => {
        'day': today,
        'items': [
          for (final p in s?.priorities ?? const <MomentumPriority>[])
            if (p.id > 0) {'id': p.id, 'title': p.title},
          {'title': t},
        ],
      },
      apply: (s) => s.priorities.add(MomentumPriority(id: temp, title: t, position: s.priorities.length)),
    );
  }

  Future<bool> togglePriority(int id) {
    final p = _find(id);
    if (p == null || id < 0) return Future.value(false);
    final done = !p.done;
    return _edit('PATCH', '/priorities/$id', body: {'done': done}, apply: (s) {
      for (final x in s.priorities) {
        if (x.id == id) x.done = done;
      }
      _touchToday(s, winDelta: done ? 1 : -1);
    });
  }

  Future<bool> renamePriority(int id, String title) {
    final t = _clean(title);
    if (t.isEmpty || id < 0) return Future.value(false);
    return _edit('PATCH', '/priorities/$id', body: {'title': t}, apply: (s) {
      for (final x in s.priorities) {
        if (x.id == id) x.title = t;
      }
    });
  }

  Future<bool> movePriorityToTomorrow(int id) {
    if (id < 0) return Future.value(false);
    return _edit('PATCH', '/priorities/$id',
        body: {'day': tomorrow}, apply: (s) => s.priorities.removeWhere((x) => x.id == id));
  }

  Future<bool> deletePriority(int id) {
    if (id < 0) return Future.value(false);
    return _edit('DELETE', '/priorities/$id', apply: (s) => s.priorities.removeWhere((x) => x.id == id));
  }

  // ── Habits ────────────────────────────────────────────────────────────

  static const maxHabits = 12;

  Future<bool> addHabit(String title, {String emoji = '', String? remindAt}) {
    final t = _clean(title);
    if (t.isEmpty) return Future.value(false);
    if ((_view?.habits.length ?? 0) >= maxHabits) {
      lastError = 'Twelve habits is the most — remove one first.';
      return Future.value(false);
    }
    final temp = _tempId--;
    return _edit('POST', '/habits',
        body: {'title': t, 'emoji': emoji, 'remindAt': remindAt ?? ''},
        apply: (s) => s.habits.add(MomentumHabit(id: temp, title: t, emoji: emoji, remindAt: remindAt)));
  }

  Future<bool> updateHabit(int id, {String? title, String? emoji, String? remindAt, bool clearReminder = false}) {
    if (id < 0) return Future.value(false);
    final body = <String, dynamic>{
      if (title != null) 'title': _clean(title),
      if (emoji != null) 'emoji': emoji,
      if (remindAt != null || clearReminder) 'remindAt': remindAt ?? '',
    };
    return _edit('PATCH', '/habits/$id', body: body, apply: (s) {
      for (final h in s.habits) {
        if (h.id != id) continue;
        if (title != null) h.title = _clean(title);
        if (emoji != null) h.emoji = emoji;
        if (remindAt != null || clearReminder) h.remindAt = remindAt;
      }
    });
  }

  Future<bool> deleteHabit(int id) {
    if (id < 0) return Future.value(false);
    return _edit('DELETE', '/habits/$id', apply: (s) => s.habits.removeWhere((h) => h.id == id));
  }

  /// Ticks a habit for today, or unticks it.
  Future<bool> toggleHabit(int id) {
    final h = _view?.habits.where((x) => x.id == id).firstOrNull;
    if (h == null || id < 0) return Future.value(false);
    final done = !h.doneToday;
    return _edit('PUT', '/habits/$id/check', body: {'day': today, 'done': done}, apply: (s) {
      for (final x in s.habits) {
        if (x.id != id) continue;
        x.doneToday = done;
        x.last7[6] = done;
        x.streak = done ? x.streak + 1 : (x.streak > 0 ? x.streak - 1 : 0);
      }
      _touchToday(s, habitDelta: done ? 1 : -1);
    });
  }

  // ── Focus ─────────────────────────────────────────────────────────────

  /// Starts a session on the server; its id, or null when offline.
  Future<int?> startFocus(int plannedMin, {String label = ''}) async {
    final r = await _send('POST', '/focus', {'plannedMin': plannedMin, if (label.isNotEmpty) 'label': label});
    return r.ok ? (r.json!['focusId'] as num?)?.toInt() : null;
  }

  /// Logs what a session did.
  Future<bool> finishFocus(int id, int actualMin, {required bool completed}) async {
    final r = await _send('PATCH', '/focus/$id', {'actualMin': actualMin, 'completed': completed});
    return r.ok;
  }

  // ── Plumbing ──────────────────────────────────────────────────────────

  static String _clean(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

  MomentumPriority? _find(int id) => _view?.priorities.where((p) => p.id == id).firstOrNull;

  /// A tick shows on today's row of the week and in the streak at once;
  /// the server's answer then replaces the guess with the real numbers.
  void _touchToday(MomentumSummary s, {int winDelta = 0, int habitDelta = 0}) {
    final d = s.week.where((x) => x.day == s.day).firstOrNull;
    if (d != null) {
      d.wins = (d.wins + winDelta).clamp(0, 999);
      d.habits = (d.habits + habitDelta).clamp(0, 999);
      d.active = d.wins > 0 || d.habits > 0 || d.focusMin >= 10;
    }
    final activeNow = s.priorities.any((p) => p.done) || s.habits.any((h) => h.doneToday) || s.todayMin >= 10;
    if (activeNow && !s.activeToday) {
      s.activeToday = true;
      s.streak += 1;
      if (s.streak > s.bestStreak) s.bestStreak = s.streak;
    }
  }

  /// Runs [job] after every job queued before it. The first one starts at
  /// once (no hop through a stored future, which would run in whatever
  /// zone created it).
  Future<void> _queue(Future<void> Function() job) {
    final done = Completer<void>();
    _jobs.add(() async {
      try {
        await job();
      } catch (_) {
        // A job reports its own failure; the line must keep moving.
      } finally {
        done.complete();
      }
    });
    if (!_draining) unawaited(_drain(_generation));
    return done.future;
  }

  Future<void> _drain(int gen) async {
    _draining = true;
    while (_jobs.isNotEmpty && gen == _generation) {
      await _jobs.removeAt(0)();
    }
    if (gen == _generation) _draining = false;
  }

  /// A request with no edit to show first (focus), in the same line.
  Future<MomentumReply> _send(String method, String path, Map<String, dynamic>? body) {
    final gen = _generation;
    final out = Completer<MomentumReply>();
    unawaited(_queue(() async {
      final r = await transport(method, '$path?day=$today', body: body);
      if (r.ok && gen == _generation) _accept(r.json!);
      out.complete(r);
    }));
    return out.future;
  }

  /// One optimistic edit: shown now, sent in turn, undone if refused.
  Future<bool> _edit(String method, String path,
      {Map<String, dynamic>? body,
      Map<String, dynamic> Function(MomentumSummary? s)? bodyOf,
      required void Function(MomentumSummary s) apply}) {
    final gen = _generation;
    final edit = _Edit(apply);
    _pending.add(edit);
    _recompute();
    final done = Completer<bool>();
    unawaited(_queue(() async {
      // Built when it is sent, from what the server last confirmed, so an
      // earlier add's real id is used rather than its stand-in.
      final r = await transport(method, '$path?day=$today', body: bodyOf != null ? bodyOf(_confirmed) : body);
      if (gen != _generation) {
        done.complete(false);
        return;
      }
      _pending.remove(edit);
      if (r.ok) {
        lastError = null;
        _accept(r.json!);
      } else {
        lastError = _friendly(r);
        _recompute(celebrate: false);
      }
      done.complete(r.ok);
    }));
    return done.future;
  }

  static String _friendly(MomentumReply r) {
    if (r.status == 0) return "Couldn't save — check your connection.";
    final e = r.error;
    if (e == null || e.isEmpty) return "Couldn't save that — please try again.";
    if (e.contains('already has')) return 'That day already has three.';
    return e[0].toUpperCase() + e.substring(1);
  }

  void _accept(Map<String, dynamic> json) {
    final MomentumSummary s;
    try {
      s = MomentumSummary.fromJson(json);
    } catch (_) {
      return;
    }
    _confirmed = s;
    failed = false;
    _fetchedAt = clock();
    _recompute();
    unawaited(_save(json));
    final sig = HabitAlarms.signature(s.habits, s.day);
    if (sig != _alarmSig) {
      _alarmSig = sig;
      onHabitsChanged?.call(s.habits);
    }
  }

  Future<void> _save(Map<String, dynamic> json) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final copy = Map<String, dynamic>.of(json)
        ..remove('focusId')
        ..remove('habitId');
      await prefs.setString(_cacheKey, jsonEncode(copy));
    } catch (_) {}
  }

  void _recompute({bool celebrate = true}) {
    final base = _confirmed?.clone();
    if (base != null) {
      for (final e in _pending) {
        e.apply(base);
      }
    }
    _setView(base, celebrate: celebrate);
  }

  void _setView(MomentumSummary? s, {required bool celebrate}) {
    _view = s;
    notifyListeners();
    if (s != null && celebrate) unawaited(_maybeCelebrate(s));
  }

  /// All three done, or a milestone reached: once each, ever. The first
  /// summary this phone sees only records the milestones already earned —
  /// a year of history is not a reason for fireworks on install.
  Future<void> _maybeCelebrate(MomentumSummary s) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final firstLook = _celebrated == null && prefs.getStringList(_celebratedKey) == null;
      final seen = _celebrated ??= (prefs.getStringList(_celebratedKey) ?? const <String>[]).toSet();
      final earned = s.milestones.where((m) => m.earned).toList();
      String? line;
      String? milestone;
      if (firstLook) {
        seen.addAll(earned.map((m) => 'ms:${m.id}'));
      } else {
        final fresh = earned.where((m) => !seen.contains('ms:${m.id}')).toList();
        if (fresh.isNotEmpty) {
          seen.addAll(fresh.map((m) => 'ms:${m.id}'));
          milestone = fresh.last.id;
          line = '${fresh.last.label} — well done.';
        }
      }
      final allKey = 'all:${s.day}';
      if (s.priorities.length == maxPriorities && s.allDone && !seen.contains(allKey)) {
        seen.add(allKey);
        line ??= 'All three done — a winning day.';
      }
      final list = seen.toList();
      await prefs.setStringList(_celebratedKey, list.length > 80 ? list.sublist(list.length - 80) : list);
      if (line != null) celebration.value = MomentumCelebration(++_celebrationSeq, line, milestone: milestone);
    } catch (_) {}
  }

  static final http.Client _client = http.Client();

  static Future<MomentumReply> _http(String method, String path, {Map<String, dynamic>? body}) async {
    try {
      final req = http.Request(method, Uri.parse('${ApiService.baseUrl}/momentum$path'))
        ..headers.addAll(ApiService.authHeaders);
      if (body != null) req.body = jsonEncode(body);
      final res = await http.Response.fromStream(
          await _client.send(req).timeout(const Duration(seconds: 12)));
      ApiService.noteAuthStatus(res.statusCode);
      Map<String, dynamic>? json;
      try {
        final d = jsonDecode(res.body);
        if (d is Map<String, dynamic>) json = d;
      } catch (_) {}
      return MomentumReply(res.statusCode, json);
    } catch (_) {
      return const MomentumReply(0, null);
    }
  }
}

class _Edit {
  _Edit(this.apply);
  final void Function(MomentumSummary s) apply;
}
