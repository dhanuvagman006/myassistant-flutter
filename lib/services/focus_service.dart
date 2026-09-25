import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_service.dart';
import 'momentum_service.dart';
import 'notification_service.dart';

/// THE COUNTDOWN'S ARITHMETIC — pure, so it can be tested, persisted and
/// restored after the app is killed. Time is measured from when it
/// started, minus the time spent paused: nothing counts seconds, so a
/// phone asleep for twenty minutes wakes to the right number.
@immutable
class FocusClock {
  const FocusClock({
    required this.startedAt,
    required this.plannedMin,
    this.extraMin = 0,
    this.pausedTotal = Duration.zero,
    this.pausedAt,
  });

  final DateTime startedAt;
  final int plannedMin;

  /// Added with "+5 min".
  final int extraMin;
  final Duration pausedTotal;

  /// Non-null while paused.
  final DateTime? pausedAt;

  bool get paused => pausedAt != null;
  Duration get total => Duration(minutes: plannedMin + extraMin);

  Duration elapsed(DateTime now) {
    final e = (pausedAt ?? now).difference(startedAt) - pausedTotal;
    if (e.isNegative) return Duration.zero;
    return e > total ? total : e;
  }

  Duration remaining(DateTime now) => total - elapsed(now);
  bool isDone(DateTime now) => remaining(now) <= Duration.zero;

  /// When it ends if it keeps running from [now].
  DateTime endsAt(DateTime now) => now.add(remaining(now));

  /// 0 → 1 over the whole session.
  double progress(DateTime now) =>
      total.inMilliseconds == 0 ? 1 : elapsed(now).inMilliseconds / total.inMilliseconds;

  /// Whole minutes done (what gets logged).
  int minutesDone(DateTime now) => elapsed(now).inSeconds ~/ 60;

  FocusClock pause(DateTime now) => paused
      ? this
      : FocusClock(
          startedAt: startedAt,
          plannedMin: plannedMin,
          extraMin: extraMin,
          pausedTotal: pausedTotal,
          pausedAt: now);

  FocusClock resume(DateTime now) => !paused
      ? this
      : FocusClock(
          startedAt: startedAt,
          plannedMin: plannedMin,
          extraMin: extraMin,
          pausedTotal: pausedTotal + now.difference(pausedAt!));

  FocusClock plus(int minutes) => FocusClock(
      startedAt: startedAt,
      plannedMin: plannedMin,
      extraMin: extraMin + minutes,
      pausedTotal: pausedTotal,
      pausedAt: pausedAt);

  Map<String, dynamic> toJson() => {
        'startedAt': startedAt.millisecondsSinceEpoch,
        'plannedMin': plannedMin,
        'extraMin': extraMin,
        'pausedMs': pausedTotal.inMilliseconds,
        'pausedAt': pausedAt?.millisecondsSinceEpoch,
      };

  factory FocusClock.fromJson(Map<String, dynamic> j) => FocusClock(
        startedAt: DateTime.fromMillisecondsSinceEpoch((j['startedAt'] as num).toInt()),
        plannedMin: (j['plannedMin'] as num).toInt(),
        extraMin: (j['extraMin'] as num?)?.toInt() ?? 0,
        pausedTotal: Duration(milliseconds: (j['pausedMs'] as num?)?.toInt() ?? 0),
        pausedAt: j['pausedAt'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch((j['pausedAt'] as num).toInt()),
      );
}

enum FocusKind { focus, rest }

/// One session: a focus (logged) or the short break after it (not).
class FocusSession {
  FocusSession({
    required this.kind,
    required this.clock,
    this.label = '',
    this.serverId,
    this.done = false,
    this.completed = false,
    this.minutes = 0,
    this.logged = false,
  });

  final FocusKind kind;
  FocusClock clock;
  final String label;

  /// The server's id for it, once it knows about it.
  int? serverId;

  /// Finished: ran out, or ended by the owner.
  bool done;

  /// Ran its whole length.
  bool completed;

  /// Minutes done, once finished.
  int minutes;

  /// The minutes reached the server.
  bool logged;

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'clock': clock.toJson(),
        'label': label,
        'serverId': serverId,
        'done': done,
        'completed': completed,
        'minutes': minutes,
        'logged': logged,
      };

  factory FocusSession.fromJson(Map<String, dynamic> j) => FocusSession(
        kind: j['kind'] == 'rest' ? FocusKind.rest : FocusKind.focus,
        clock: FocusClock.fromJson((j['clock'] as Map).cast<String, dynamic>()),
        label: (j['label'] ?? '').toString(),
        serverId: (j['serverId'] as num?)?.toInt(),
        done: j['done'] == true,
        completed: j['completed'] == true,
        minutes: (j['minutes'] as num?)?.toInt() ?? 0,
        logged: j['logged'] == true,
      );
}

/// What the notification shade shows for a session (tests record it).
abstract class FocusAlerts {
  /// The countdown in the shade, and the alert at [endsAt].
  Future<void> show({required DateTime endsAt, required String label, required bool rest});

  /// Both gone (paused, ended early).
  Future<void> cancel();

  /// It ran out: the countdown goes, the alert that is ringing stays.
  Future<void> finished();
}

class _ShadeAlerts implements FocusAlerts {
  const _ShadeAlerts();
  @override
  Future<void> show({required DateTime endsAt, required String label, required bool rest}) =>
      ReminderNotifications.instance.showFocus(endsAt: endsAt, label: label, rest: rest);
  @override
  Future<void> cancel() => ReminderNotifications.instance.cancelFocus();
  @override
  Future<void> finished() => ReminderNotifications.instance.cancelFocus(keepAlert: true);
}

/// ─────────────────────────────────────────────────────────────────────────
///  FOCUS — the session behind the Focus screen (2026-09-25, Momentum).
///
///  "Start a 25-minute focus on the report": a calm countdown that keeps
///  going with the screen off or the app killed (the session is saved
///  after every change and read back at launch), shows in the notification
///  shade, rings "Focus done — take 5?" at the end, and logs the minutes
///  actually done — a session ended early still counts what it ran.
/// ─────────────────────────────────────────────────────────────────────────
class FocusService extends ChangeNotifier {
  FocusService._() {
    AuthService.instance.onSignOut(reset);
  }
  static final FocusService instance = FocusService._();

  static const _key = 'focus_session_v1';
  static const breakMin = 5;

  /// The phone's clock (tests pin it).
  static DateTime Function() clock = DateTime.now;

  /// The notification shade (tests record instead).
  static FocusAlerts alerts = const _ShadeAlerts();

  FocusSession? session;
  bool _restored = false;

  /// Puts a session in place as if it had been read back at launch (tests,
  /// and the layout sweep's running timer).
  @visibleForTesting
  void debugSeed(FocusSession? s) {
    session = s;
    _restored = true;
    notifyListeners();
  }

  /// A session is counting (running or paused).
  bool get active => session != null && !session!.done;
  bool get running => active && !session!.clock.paused;

  /// Reads a session saved before the app was closed. A focus that ran out
  /// while the app was away is finished and logged as done in full.
  Future<void> restore({bool force = false}) async {
    if (_restored && !force) return;
    _restored = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      session = raw == null ? null : FocusSession.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      session = null;
    }
    notifyListeners();
    final s = session;
    if (s == null) return;
    if (!s.done && s.clock.isDone(clock())) {
      await _finish(completed: true);
    } else if (s.done && !s.logged) {
      await _log();
    }
  }

  /// Starts a focus of [minutes] — or, when one is already counting, keeps
  /// that one (a second "start focus" must not throw away the first).
  Future<void> start(int minutes, {String label = '', FocusKind kind = FocusKind.focus}) async {
    await restore();
    if (active) return;
    // The server logs 5 to 180 minutes; a break is its own short thing.
    final m = kind == FocusKind.focus ? minutes.clamp(5, 180) : minutes.clamp(1, 60);
    session = FocusSession(
      kind: kind,
      clock: FocusClock(startedAt: clock(), plannedMin: m),
      label: label.trim(),
    );
    await _save();
    notifyListeners();
    await _arm();
    if (kind == FocusKind.focus) {
      final s = session!;
      final id = await MomentumService.instance.startFocus(m, label: s.label);
      if (identical(session, s) && id != null) {
        s.serverId = id;
        await _save();
      }
    }
  }

  /// The five-minute break "take 5?" offers.
  Future<void> startBreak() async {
    session = null;
    await start(breakMin, kind: FocusKind.rest);
  }

  Future<void> pause() async {
    final s = session;
    if (s == null || s.done || s.clock.paused) return;
    s.clock = s.clock.pause(clock());
    await _save();
    notifyListeners();
    await _quietly(alerts.cancel);
  }

  Future<void> resume() async {
    final s = session;
    if (s == null || s.done || !s.clock.paused) return;
    s.clock = s.clock.resume(clock());
    await _save();
    notifyListeners();
    await _arm();
  }

  Future<void> addMinutes(int m) async {
    final s = session;
    if (s == null || s.done) return;
    // A session never runs past four hours, "+5" or not.
    if (s.clock.total.inMinutes + m > 240) return;
    s.clock = s.clock.plus(m);
    await _save();
    notifyListeners();
    if (!s.clock.paused) await _arm();
  }

  /// Ended by the owner: logs what was done.
  Future<void> end() => _finish(completed: false);

  /// Called by the Focus screen each second while it is up and running.
  Future<void> tick() async {
    final s = session;
    if (s != null && !s.done && !s.clock.paused && s.clock.isDone(clock())) {
      await _finish(completed: true);
    }
  }

  /// Puts away a finished session.
  Future<void> dismiss() async {
    if (session == null || active) return;
    session = null;
    await _save();
    notifyListeners();
  }

  /// Sign-out: nothing of theirs stays counting on the phone.
  Future<void> reset() async {
    session = null;
    _restored = false;
    await _save();
    notifyListeners();
    await _quietly(alerts.cancel);
  }

  /// After the notification shade was cleared (ReminderNotifications.sync
  /// cancels everything), put the countdown back.
  Future<void> rearm() async {
    if (running) await _arm();
  }

  /// The shade is a courtesy: a phone that refuses a notification must
  /// not stop the timer.
  static Future<void> _quietly(Future<void> Function() f) async {
    try {
      await f();
    } catch (_) {}
  }

  Future<void> _arm() async {
    final s = session;
    if (s == null || s.done || s.clock.paused) return;
    try {
      await alerts.show(
          endsAt: s.clock.endsAt(clock()), label: s.label, rest: s.kind == FocusKind.rest);
    } catch (_) {}
  }

  Future<void> _finish({required bool completed}) async {
    final s = session;
    if (s == null || s.done) return;
    final now = clock();
    s.done = true;
    s.completed = completed;
    s.minutes = completed ? s.clock.total.inMinutes : s.clock.minutesDone(now);
    s.logged = s.kind == FocusKind.rest; // a break is not logged
    await _save();
    notifyListeners();
    // Ended early: the "done" alert must not ring later. Ran out: it is
    // ringing now, and only the countdown goes.
    try {
      await (completed ? alerts.finished() : alerts.cancel());
    } catch (_) {}
    await _log();
  }

  Future<void> _log() async {
    final s = session;
    if (s == null || !s.done || s.logged || s.kind != FocusKind.focus) return;
    final m = MomentumService.instance;
    var id = s.serverId;
    id ??= await m.startFocus(s.clock.plannedMin.clamp(5, 180), label: s.label);
    if (id == null) return; // offline: tried again at the next launch
    s.serverId = id;
    final ok = await m.finishFocus(id, s.minutes.clamp(0, 300), completed: s.completed);
    if (ok && identical(session, s)) {
      s.logged = true;
      await _save();
      notifyListeners();
    }
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final s = session;
      if (s == null) {
        await prefs.remove(_key);
      } else {
        await prefs.setString(_key, jsonEncode(s.toJson()));
      }
    } catch (_) {}
  }
}
