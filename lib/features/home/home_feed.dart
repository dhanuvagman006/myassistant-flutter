import 'dart:math' as math;

import '../../models/brief.dart';
import '../../services/call_history.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  HOME: WHAT NEEDS YOU NOW (2026-09-29, the owner's approved proposal).
///
///  Home was a calendar with a greeting. It now answers one question —
///  "what is relevant to me right now?" — with at most ONE Now card, TWO
///  smaller Also cards and THREE lines of the day, chosen by plain rules
///  over what the phone already has: the brief (GET /brief, refreshed
///  every five minutes and saved) and the missed calls. No model call: it
///  is instant, works offline from the saved brief, cannot invent a card,
///  and the same day always gives the same screen. Every card says why it
///  is there and has a button that really does something.
///
///  Order, most urgent first (lower [HomeCard.score]):
///    100  a meeting starting within the hour, or started minutes ago
///    200  a reminder due within the hour
///    300  a call missed in the last two hours
///    380  a birthday today
///    400  a promise overdue · 420 due today · 430 a bill due today
///    450  a reminder missed in the last three hours
///    500  a meeting in one to two hours
///    600  an unread message from someone's assistant
///    700  an older missed call
///    ─── [nowLimit]: below it the first card is Now; above, "all clear" ──
///    800  a birthday tomorrow (from 5 pm) · 820 a bill due tomorrow
///    850  a promise due tomorrow · 900 the first promise with no date
///  Ties keep the order above. Nothing appears twice: what is a card is
///  not also a line of the day.
/// ─────────────────────────────────────────────────────────────────────────

/// What a card is about: its icon, its words and its buttons.
enum HomeCardKind {
  meeting,
  reminder,
  promise,
  missedCall,
  message,
  birthday,
  payment,
  getStarted,
}

class HomeCard {
  const HomeCard({
    required this.id,
    required this.kind,
    required this.title,
    required this.reason,
    required this.score,
    this.detail,
    this.at,
    this.item,
    this.promise,
    this.call,
    this.person,
  });

  /// The same while the thing it shows is unchanged. A reminder moved to
  /// another time is a new card, so "Not now" on the old one does not
  /// hide it.
  final String id;
  final HomeCardKind kind;
  final String title;

  /// Why it is on Home, in plain words: "In 25 min", "Due today".
  final String reason;

  /// A second line when there is one: "At 3:00 pm", "You promised Ravi".
  final String? detail;

  /// Lower comes first (see the table at the top of this file).
  final int score;
  final DateTime? at;

  /// The reminder or meeting behind the card.
  final AgendaItem? item;
  final PromiseItem? promise;
  final CallEntry? call;

  /// Whose birthday it is, or who is waiting on a promise.
  final String? person;
}

/// One line of the day: "6:30 pm  Pick up medicines".
class HomeLine {
  const HomeLine({required this.id, required this.time, required this.item});
  final String id;
  final String time; // "6:30 pm", or "Anytime" for an undated reminder
  final AgendaItem item;
}

/// A quick action: a request handed to the assistant.
class HomeAsk {
  const HomeAsk(this.label, this.request);
  final String label;
  final String request;
}

class HomeFeed {
  const HomeFeed({
    this.now,
    this.also = const [],
    this.dayLabel = 'Today',
    this.day = const [],
    this.asks = const [],
  });

  /// The one thing that matters most right now; null: all clear.
  final HomeCard? now;
  final List<HomeCard> also;

  /// 'Today', or 'Tomorrow' once nothing is left today (from 5 pm).
  final String dayLabel;
  final List<HomeLine> day;
  final List<HomeAsk> asks;

  bool get allClear => now == null;
}

class HomeRanker {
  HomeRanker._();

  /// A card scoring below this is about today and can be the Now card.
  static const nowLimit = 800;
  static const maxAlso = 2;
  static const maxDay = 3;

  /// For someone in their first days with nothing to show yet.
  static const getStarted = HomeCard(
    id: 'get-started',
    kind: HomeCardKind.getStarted,
    title: 'Ask me anything',
    reason: 'Start here',
    detail: 'Try: “Remind me to call Amma at 6”',
    score: 790,
  );

  static HomeFeed rank({
    required TodayBrief brief,
    required DateTime now,
    List<CallEntry> missed = const [],
    Set<String> hidden = const {},
    bool newUser = false,
  }) {
    final found = <HomeCard>[
      ..._agenda(brief.agenda, now),
      ..._calls(missed, now),
      ..._dates(brief.dates, now),
      ..._promises(brief.promises, now),
      ..._messages(brief.messages),
    ].where((c) => !hidden.contains(c.id)).toList();
    // List.sort is not stable: ties fall back to the order found.
    final order = {for (var i = 0; i < found.length; i++) found[i].id: i};
    found.sort((a, b) {
      final s = a.score.compareTo(b.score);
      return s != 0 ? s : order[a.id]!.compareTo(order[b.id]!);
    });
    if (found.isEmpty && newUser && !hidden.contains(getStarted.id)) {
      found.add(getStarted);
    }
    final first = found.isEmpty ? null : found.first;
    final nowCard = first != null && first.score < nowLimit ? first : null;
    final also =
        found.skip(nowCard == null ? 0 : 1).take(maxAlso).toList();
    final shown = {if (nowCard != null) nowCard.id, for (final c in also) c.id};
    final (label, day) = _day(brief, now, shown);
    return HomeFeed(
      now: nowCard,
      also: also,
      dayLabel: label,
      day: day,
      asks: _asks([if (nowCard != null) nowCard, ...also], now),
    );
  }

  // ── sources ──────────────────────────────────────────────────────────

  static String agendaId(AgendaItem a) =>
      '${a.kind}:${a.id ?? a.title}@${a.atMs ?? 0}';

  static Iterable<HomeCard> _agenda(List<AgendaItem> agenda, DateTime now) sync* {
    for (final a in agenda) {
      final ms = a.atMs;
      if (ms == null) continue; // undated: a line of the day, not a card
      final at = DateTime.fromMillisecondsSinceEpoch(ms);
      final m = at.difference(now).inMinutes; // negative: in the past
      if (a.kind == 'meeting') {
        if (m >= -15 && m <= 60) {
          yield HomeCard(
            id: agendaId(a),
            kind: HomeCardKind.meeting,
            title: a.title,
            reason: m <= 0 ? 'Now' : 'In ${_mins(m)}',
            detail: 'At ${CallHistory.clock(at)}',
            score: 100 + math.max(m, 0),
            at: at,
            item: a,
          );
        } else if (m > 60 && m <= 120) {
          yield HomeCard(
            id: agendaId(a),
            kind: HomeCardKind.meeting,
            title: a.title,
            reason: 'At ${CallHistory.clock(at)}',
            score: 500 + m,
            at: at,
            item: a,
          );
        }
      } else if (m >= 0 && m <= 60) {
        yield HomeCard(
          id: agendaId(a),
          kind: HomeCardKind.reminder,
          title: a.title,
          reason: m == 0 ? 'Now' : 'In ${_mins(m)}',
          detail: 'At ${CallHistory.clock(at)}',
          score: 200 + m,
          at: at,
          item: a,
        );
      } else if (m < 0 && m >= -180) {
        // Rung and not ticked off. Older than three hours it was most
        // likely dealt with and simply never ticked: Reminders keeps it,
        // Home does not nag about it.
        yield HomeCard(
          id: agendaId(a),
          kind: HomeCardKind.reminder,
          title: a.title,
          reason: 'Was due ${CallHistory.clock(at)}',
          score: 450 + (-m) ~/ 10,
          at: at,
          item: a,
        );
      }
    }
  }

  static Iterable<HomeCard> _calls(List<CallEntry> missed, DateTime now) sync* {
    for (final g in CallHistory.group(missed)) {
      final c = g.latest;
      final age = math.max(0, now.difference(c.at).inMinutes);
      final when = age <= 1
          ? 'Just now'
          : age < 60
              ? '$age min ago'
              : _cap(CallHistory.when(c.at, now).replaceFirst(RegExp(r'^at '), 'Today at '));
      yield HomeCard(
        id: 'call:${c.dialable.isEmpty ? c.label : c.dialable}@${c.at.millisecondsSinceEpoch}',
        kind: HomeCardKind.missedCall,
        title: c.label,
        reason: when,
        detail: g.count > 1 ? '${g.count} missed calls' : 'Missed call',
        score: age <= 120 ? 300 + age ~/ 2 : 700,
        at: c.at,
        call: c,
      );
    }
  }

  static Iterable<HomeCard> _dates(List<DateItem> dates, DateTime now) sync* {
    for (final d in dates) {
      final today = d.when == 'today';
      final day = DateTime(now.year, now.month, now.day + (today ? 0 : 1));
      final key = '${day.year}-${day.month}-${day.day}';
      if (d.kind == 'birthday') {
        // Tomorrow's shows in the evening: time to plan the wish, not a
        // whole day of a card that cannot be acted on yet.
        if (!today && now.hour < 17) continue;
        yield HomeCard(
          id: 'date:${d.title}@$key',
          kind: HomeCardKind.birthday,
          title: d.title,
          reason: today ? 'Today' : 'Tomorrow',
          score: today ? 380 : 800,
          person: d.person,
        );
      } else if (d.kind == 'payment') {
        yield HomeCard(
          id: 'date:${d.title}@$key',
          kind: HomeCardKind.payment,
          title: d.title,
          reason: today ? 'Due today' : 'Due tomorrow',
          score: today ? 430 : 820,
        );
      }
    }
  }

  static Iterable<HomeCard> _promises(List<PromiseItem> promises, DateTime now) sync* {
    var undated = false;
    for (final p in promises) {
      final who = p.owedTo;
      // The server writes "To Ravi: …" into the text; the card says who
      // on its own line.
      final prefix = who == null ? null : 'To $who: ';
      final title = prefix != null && p.text.startsWith(prefix)
          ? p.text.substring(prefix.length)
          : p.text;
      final ms = p.dueAtMs;
      int score;
      String when;
      if (ms != null) {
        final due = DateTime.fromMillisecondsSinceEpoch(ms);
        final days = _daysBetween(now, due);
        if (due.isBefore(now)) {
          score = 400;
          when = 'Overdue';
        } else if (days == 0) {
          score = 420;
          when = 'Due today';
        } else if (days == 1) {
          score = 850;
          when = 'Due tomorrow';
        } else {
          continue; // later this week: the calendar has it
        }
      } else {
        // An older server sends the label only; no label, no deadline.
        switch (p.dueLabel) {
          case 'overdue':
            score = 400;
            when = 'Overdue';
          case 'due today':
            score = 420;
            when = 'Due today';
          case 'due tomorrow':
            score = 850;
            when = 'Due tomorrow';
          case null:
            if (undated) continue; // one is a reminder; six are a list
            undated = true;
            score = 900;
            when = 'No date set';
          default:
            continue;
        }
      }
      yield HomeCard(
        id: 'promise:${p.id ?? p.text}@${ms ?? p.dueLabel}',
        kind: HomeCardKind.promise,
        title: title,
        reason: when,
        detail: who == null ? 'You promised this' : 'You promised $who',
        score: score,
        promise: p,
        person: who,
      );
    }
  }

  static Iterable<HomeCard> _messages(List<BriefMessage> messages) sync* {
    if (messages.isEmpty) return;
    final m = messages.first;
    final named = m.from.trim().isNotEmpty && m.from != 'Someone';
    yield HomeCard(
      id: 'message:${m.from}:${m.text.length}:${m.text.substring(0, math.min(24, m.text.length))}',
      kind: HomeCardKind.message,
      title: named ? 'Message from ${m.from}' : 'A message for you',
      reason: messages.length > 1 ? '${messages.length} waiting' : 'Waiting',
      detail: m.text,
      score: 600,
    );
  }

  // ── the day ──────────────────────────────────────────────────────────

  static (String, List<HomeLine>) _day(TodayBrief b, DateTime now, Set<String> shown) {
    HomeLine line(AgendaItem a) => HomeLine(
          id: agendaId(a),
          time: a.atMs == null
              ? 'Anytime'
              : CallHistory.clock(DateTime.fromMillisecondsSinceEpoch(a.atMs!)),
          item: a,
        );
    final since = now.subtract(const Duration(minutes: 10));
    final upcoming = [
      for (final a in b.agenda)
        if (a.atMs != null &&
            DateTime.fromMillisecondsSinceEpoch(a.atMs!).isAfter(since))
          a,
    ];
    final left = [for (final a in upcoming) if (!shown.contains(agendaId(a))) a];
    final tomorrow = [for (final a in b.tomorrow) if (!shown.contains(agendaId(a))) a];
    if (upcoming.isEmpty && now.hour >= 17 && tomorrow.isNotEmpty) {
      return ('Tomorrow', [for (final a in tomorrow.take(maxDay)) line(a)]);
    }
    final anytime = [for (final a in b.agenda) if (a.atMs == null) a];
    return ('Today', [for (final a in [...left, ...anytime].take(maxDay)) line(a)]);
  }

  // ── quick actions ────────────────────────────────────────────────────

  /// One that follows the cards (help with a promise on screen), then the
  /// ones that fit the hour. A card whose own button already asks the same
  /// thing (Prepare, Send wishes, Hear it) adds no chip.
  static List<HomeAsk> _asks(List<HomeCard> cards, DateTime now) {
    final out = <HomeAsk>[];
    for (final c in cards) {
      if (c.kind == HomeCardKind.promise) {
        out.add(HomeAsk(
          'Help with my promise',
          'Help me with something I promised${c.person == null ? '' : ' ${c.person}'}: '
              '"${c.title}". Draft what I need, and ask me before sending anything.',
        ));
        break;
      }
    }
    for (final a in _hourly(now)) {
      if (out.length == 3) break;
      out.add(a);
    }
    return out;
  }

  static List<HomeAsk> _hourly(DateTime now) {
    final h = now.hour;
    if (h < 12) {
      return const [
        HomeAsk('Brief me for today', 'Give me my brief for today.'),
        HomeAsk('What is on my calendar?', 'What is on my calendar today?'),
        HomeAsk('Remind me tonight', 'Remind me tonight at 8 to plan tomorrow.'),
      ];
    }
    if (h < 17) {
      return const [
        HomeAsk('What did I promise?', 'What have I promised anyone recently?'),
        HomeAsk('Any mail worth reading?', 'Any important mail I should know about?'),
        HomeAsk('Track an expense', 'I spent money today — note it for me.'),
      ];
    }
    return const [
      HomeAsk('Summarise my day', 'Summarise what happened today for me.'),
      HomeAsk('What is tomorrow like?', 'What does my day tomorrow look like?'),
      HomeAsk('Write an email', 'I want to send an email — ask me the details.'),
    ];
  }

  // ── words ────────────────────────────────────────────────────────────

  /// Calendar days from [from] to [to] (0 = the same day).
  static int _daysBetween(DateTime from, DateTime to) =>
      DateTime.utc(to.year, to.month, to.day)
          .difference(DateTime.utc(from.year, from.month, from.day))
          .inDays;

  static String _mins(int m) => m >= 60 ? '1 hr' : '$m min';

  static String _cap(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
}
