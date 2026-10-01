import 'package:flutter/material.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  ONE THING ON THE CALENDAR (2026-09-30, owner: "in the calendar screen I
///  need much more information, not just a calendar — holidays, upcoming
///  events, maybe global events"). The user's own things come from
///  GET /brief/calendar (meeting, reminder, promise, payment, income,
///  birthday, anniversary, class); the world's from GET /tools/calendar/extras (holiday,
///  festival, event, world_day). One shape, so the grid, the day's agenda
///  and "Coming up" read them all the same way.
/// ─────────────────────────────────────────────────────────────────────────
class CalendarEntry {
  const CalendarEntry({
    required this.date,
    required this.kind,
    required this.title,
    this.end,
    this.at,
    this.endAt,
    this.note,
    this.tentative = false,
    this.bank = false,
    this.del,
    this.id,
  });

  /// The day (local midnight).
  final DateTime date;

  /// The last day of a multi-day event (the Asian Games), else null.
  final DateTime? end;

  /// meeting | reminder | promise | payment | income | birthday |
  /// anniversary | class | holiday | festival | event | world_day
  final String kind;
  final String title;

  /// The time, when the item has one (a 10:30 meeting).
  final DateTime? at;

  /// When it finishes, for a thing with a length (a 9:00 – 9:50 class).
  /// Not [end], which is the last DAY of a multi-day event.
  final DateTime? endAt;
  final String? note;

  /// The date may move (a moon-sighted Eid, a list not yet notified).
  final bool tentative;

  /// Banks are closed (Kerala).
  final bool bank;

  /// REST collection + id to delete it ("reminders", "commitments",
  /// "finance"); null for things we do not own.
  final String? del;
  final int? id;

  static const worldKinds = {'holiday', 'festival', 'event', 'world_day'};

  /// Something from the world (a holiday, a UN day), not the user's own.
  bool get isWorld => worldKinds.contains(kind);
  bool get deletable => del != null && id != null;

  /// Covers [day] (a multi-day event covers every day of its span).
  bool covers(DateTime day) {
    final d = DateUtils.dateOnly(day);
    final e = end;
    if (e == null) return DateUtils.isSameDay(date, d);
    return !d.isBefore(date) && !d.isAfter(e);
  }

  /// A row of /brief/calendar's `days` map, for [year]-[month]-[day].
  static CalendarEntry fromBrief(int year, int month, int day, Map j) {
    final at = (j['at'] as num?)?.toInt();
    // A class (2026-09-30, students): `end` is the finish in epoch ms.
    // Older shapes have none, and a finish before the start is ignored.
    final endMs = (j['end'] as num?)?.toInt();
    final hasAt = at != null && at > 0;
    return CalendarEntry(
      date: DateTime(year, month, day),
      kind: (j['kind'] as String?) ?? 'reminder',
      title: (j['title'] as String?) ?? '',
      at: hasAt ? DateTime.fromMillisecondsSinceEpoch(at) : null,
      endAt: hasAt && endMs != null && endMs > at
          ? DateTime.fromMillisecondsSinceEpoch(endMs)
          : null,
      del: j['del'] as String?,
      id: (j['id'] as num?)?.toInt(),
    );
  }

  /// An item of /tools/calendar/extras; null when it is malformed.
  static CalendarEntry? fromExtra(Map j) {
    final d = _day(j['date']);
    final title = (j['title'] as String?)?.trim() ?? '';
    final kind = j['kind'] as String?;
    if (d == null || title.isEmpty || !worldKinds.contains(kind)) return null;
    final e = _day(j['end']);
    return CalendarEntry(
      date: d,
      end: e != null && e.isAfter(d) ? e : null,
      kind: kind!,
      title: title,
      note: (j['note'] as String?)?.trim().isEmpty ?? true
          ? null
          : (j['note'] as String).trim(),
      tentative: j['tentative'] == true,
      bank: j['bank'] == true,
    );
  }

  static DateTime? _day(Object? v) {
    if (v is! String || v.length != 10) return null;
    final p = DateTime.tryParse(v);
    return p == null ? null : DateTime(p.year, p.month, p.day);
  }
}

/// THE WORDS AND SIGNS FOR A KIND. Colour is [calendarTone] (in
/// month_calendar.dart), so a dot on the grid and a row in a list agree.
IconData calendarKindIcon(String kind) => switch (kind) {
      'meeting' => Icons.event_rounded,
      'payment' => Icons.currency_rupee_rounded,
      'income' => Icons.south_west_rounded,
      'promise' => Icons.handshake_rounded,
      'birthday' => Icons.cake_rounded,
      'anniversary' => Icons.favorite_rounded,
      'class' => Icons.school_rounded,
      'holiday' => Icons.beach_access_rounded,
      'festival' => Icons.celebration_rounded,
      'event' => Icons.emoji_events_rounded,
      'world_day' => Icons.public_rounded,
      _ => Icons.alarm_rounded,
    };

String calendarKindLabel(String kind) => switch (kind) {
      'meeting' => 'Meeting',
      'payment' => 'Payment',
      'income' => 'Income',
      'promise' => 'Promise',
      'birthday' => 'Birthday',
      'anniversary' => 'Anniversary',
      'class' => 'Class',
      'holiday' => 'Holiday',
      'festival' => 'Festival',
      'event' => 'Event',
      'world_day' => 'World day',
      _ => 'Reminder',
    };

// ── dates, said the way a person says them ─────────────────────────────
const calMonths = [
  'January', 'February', 'March', 'April', 'May', 'June', 'July',
  'August', 'September', 'October', 'November', 'December'
];
const calMonthsShort = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
];
const calWeekdays = [
  'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday',
  'Sunday'
];
const calWeekdaysShort = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// "Friday, 2 October".
String calDayLong(DateTime d) =>
    '${calWeekdays[d.weekday - 1]}, ${d.day} ${calMonths[d.month - 1]}';

/// "Fri 2 Oct".
String calDayShort(DateTime d) =>
    '${calWeekdaysShort[d.weekday - 1]} ${d.day} ${calMonthsShort[d.month - 1]}';

/// "19 Sep – 4 Oct".
String calSpan(DateTime a, DateTime b) =>
    '${a.day} ${calMonthsShort[a.month - 1]} – ${b.day} ${calMonthsShort[b.month - 1]}';

/// "Today", "Tomorrow", "In 5 days", "In 3 weeks".
String calRelative(DateTime day, DateTime today) {
  final n = DateUtils.dateOnly(day).difference(DateUtils.dateOnly(today)).inDays;
  if (n < 0) return n == -1 ? 'Yesterday' : '${-n} days ago';
  if (n == 0) return 'Today';
  if (n == 1) return 'Tomorrow';
  if (n < 14) return 'In $n days';
  return 'In ${(n / 7).round()} weeks';
}

/// "9:00 – 9:50 am" (one am/pm when both halves share it), else
/// "10:30 am"; "9:00 am – 12:10 pm" when they differ.
String calTimeRange(DateTime a, DateTime? b) {
  if (b == null) return calTime(a);
  if ((a.hour < 12) == (b.hour < 12)) {
    final h = a.hour % 12 == 0 ? 12 : a.hour % 12;
    return '$h:${a.minute.toString().padLeft(2, '0')} – ${calTime(b)}';
  }
  return '${calTime(a)} – ${calTime(b)}';
}

/// "10:30 am".
String calTime(DateTime t) {
  final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
  final m = t.minute.toString().padLeft(2, '0');
  return '$h:$m ${t.hour < 12 ? 'am' : 'pm'}';
}

String calIso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
