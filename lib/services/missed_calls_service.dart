import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/log.dart';
import 'call_history.dart';

/// MISSED CALLS, WITHOUT BEING ASKED.
///
/// Owner, 2026-09-24: "it should report when we have any missed calls".
/// When the app comes forward or a voice session starts, the phone reads
/// the calls missed since it last looked (the first time: the last 12
/// hours). They sit on a small card on Home with a Call back button
/// ([pending]) until the owner dismisses it or deals with them — a later
/// call to or from the same number clears that caller by itself — and the
/// next greeting mentions them ONCE ([takeMention]).
///
/// It only ever CHECKS the permission. Asking happens when the owner asks
/// about calls; a dialog on opening the app is exactly what he does not
/// want.
class MissedCallsService {
  MissedCallsService._();
  static final MissedCallsService instance = MissedCallsService._();

  /// Newest first. Drives the Missed calls card.
  final ValueNotifier<List<CallEntry>> pending =
      ValueNotifier<List<CallEntry>>(const []);

  /// How far back the very first check looks.
  static const firstLook = Duration(hours: 12);

  /// A call rings for up to a minute and is logged when it ENDS, stamped
  /// with when it STARTED — a check during the ringing would otherwise
  /// step past it forever.
  static const overlap = Duration(minutes: 2);

  /// Card entries older than this are old news.
  static const keepFor = Duration(hours: 48);

  static const _kChecked = 'missed_calls_checked_at';
  static const _kPending = 'missed_calls_pending';
  static const _kMentioned = 'missed_calls_mentioned_upto';
  static const _kDismissed = 'missed_calls_dismissed_upto';

  bool _loaded = false;
  DateTime? _checkedAt;
  int _mentionedUpTo = 0; // ms: calls at or before this were mentioned
  int _dismissedUpTo = 0; // ms: calls at or before this were dismissed
  DateTime _lastRun = DateTime.fromMillisecondsSinceEpoch(0);
  Future<void>? _running;

  Future<void> _load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final p = await SharedPreferences.getInstance();
      final c = p.getInt(_kChecked);
      if (c != null) _checkedAt = DateTime.fromMillisecondsSinceEpoch(c);
      _mentionedUpTo = p.getInt(_kMentioned) ?? 0;
      _dismissedUpTo = p.getInt(_kDismissed) ?? 0;
      final raw = p.getString(_kPending);
      if (raw != null && raw.isNotEmpty) {
        final list = jsonDecode(raw);
        if (list is List) {
          pending.value = [
            for (final m in list)
              if (m is Map) CallEntry.fromMap(m),
          ];
        }
      }
    } catch (_) {/* a fresh start is a fine fallback */}
  }

  Future<void> _save() async {
    try {
      final p = await SharedPreferences.getInstance();
      if (_checkedAt != null) {
        await p.setInt(_kChecked, _checkedAt!.millisecondsSinceEpoch);
      }
      await p.setInt(_kMentioned, _mentionedUpTo);
      await p.setInt(_kDismissed, _dismissedUpTo);
      await p.setString(_kPending,
          jsonEncode([for (final c in pending.value) c.toJson()]));
    } catch (_) {}
  }

  /// Looks at the call history. Cheap, never asks, never throws; calls
  /// close together share one read.
  Future<void> check({bool force = false}) {
    final running = _running;
    if (running != null) return running;
    if (!force &&
        DateTime.now().difference(_lastRun) < const Duration(seconds: 20)) {
      return Future.value();
    }
    final f = _check().catchError((Object e) {
      AppLog.add('calls', 'missed-call check failed: $e');
    }).whenComplete(() => _running = null);
    _running = f;
    return f;
  }

  Future<void> _check() async {
    if (!Platform.isAndroid) return;
    await _load();
    _lastRun = DateTime.now();
    if (!await CallHistory.canRead()) return;
    final now = DateTime.now();
    final checkedAt = _checkedAt ?? now.subtract(firstLook);
    // Far enough back to also see what happened AFTER each card entry —
    // a call back clears it.
    var since = checkedAt.subtract(overlap);
    for (final c in pending.value) {
      if (c.at.isBefore(since)) since = c.at;
    }
    final rows =
        await CallHistory.recent(filter: 'all', since: since, limit: 200);
    final next = merge(
      pending: pending.value,
      recent: rows,
      checkedAt: checkedAt,
      dismissedUpTo: _dismissedUpTo,
      now: now,
    );
    _checkedAt = now;
    final added = next.where((c) => !pending.value.any((p) => _same(p, c)));
    if (added.isNotEmpty) {
      AppLog.add('calls', '${added.length} new missed call(s)');
    }
    pending.value = next;
    await _save();
  }

  static bool _same(CallEntry a, CallEntry b) =>
      a.caller == b.caller && a.at == b.at;

  /// The card's next contents (pure — tested). [recent] is newest first.
  ///
  /// * a missed call after the last check joins the card (unless it was
  ///   already there or dismissed);
  /// * a caller the owner has since spoken to — a later answered call
  ///   either way — leaves it;
  /// * anything older than [keepFor] leaves it.
  @visibleForTesting
  static List<CallEntry> merge({
    required List<CallEntry> pending,
    required List<CallEntry> recent,
    required DateTime checkedAt,
    required int dismissedUpTo,
    required DateTime now,
  }) {
    final from = checkedAt.subtract(overlap);
    final out = <CallEntry>[...pending];
    for (final c in recent) {
      if (c.type != 'missed') continue;
      if (!c.at.isAfter(from)) continue;
      if (c.at.millisecondsSinceEpoch <= dismissedUpTo) continue;
      if (out.any((p) => _same(p, c))) continue;
      out.add(c);
    }
    bool dealtWith(CallEntry m) => recent.any((r) =>
        r.caller == m.caller &&
        r.at.isAfter(m.at) &&
        (r.type == 'incoming' || r.type == 'outgoing'));
    final cutoff = now.subtract(keepFor);
    final kept = out
        .where((c) => c.at.isAfter(cutoff) && !dealtWith(c))
        .toList()
      ..sort((a, b) => b.at.compareTo(a.at));
    return kept.length > 20 ? kept.sublist(0, 20) : kept;
  }

  /// Card entries the greeting has not mentioned yet.
  List<CallEntry> get unmentioned => [
        for (final c in pending.value)
          if (c.at.millisecondsSinceEpoch > _mentionedUpTo) c,
      ];

  bool get hasUnmentioned => unmentioned.isNotEmpty;

  /// The greeting's one mention, or null when there is nothing new. Once
  /// taken, those calls are never mentioned again.
  String? takeMention({
    required String honorific,
    required bool hello,
    DateTime? now,
  }) {
    final list = unmentioned;
    if (list.isEmpty) return null;
    final line = CallHistory.greetingMention(list,
        honorific: honorific, hello: hello, now: now ?? DateTime.now());
    markMentioned(list);
    return line;
  }

  /// The owner has heard about these (the greeting, or an answer to "any
  /// missed calls?") — no greeting repeats them.
  void markMentioned(Iterable<CallEntry> calls) {
    var upTo = _mentionedUpTo;
    for (final c in calls) {
      upTo = math.max(upTo, c.at.millisecondsSinceEpoch);
    }
    if (upTo == _mentionedUpTo) return;
    _mentionedUpTo = upTo;
    unawaited(_save());
  }

  /// The card's ✕.
  void dismiss() {
    for (final c in pending.value) {
      _dismissedUpTo = math.max(_dismissedUpTo, c.at.millisecondsSinceEpoch);
    }
    markMentioned(pending.value);
    pending.value = const [];
    unawaited(_save());
  }

  /// Called back (or otherwise handled): that caller leaves the card.
  void remove(CallEntry c) {
    _dismissedUpTo = math.max(_dismissedUpTo, c.at.millisecondsSinceEpoch);
    pending.value = [
      for (final p in pending.value)
        if (p.caller != c.caller) p,
    ];
    unawaited(_save());
  }

  /// Tests start clean.
  @visibleForTesting
  void debugReset() {
    _loaded = true;
    _checkedAt = null;
    _mentionedUpTo = 0;
    _dismissedUpTo = 0;
    _lastRun = DateTime.fromMillisecondsSinceEpoch(0);
    _running = null;
    pending.value = const [];
  }
}
