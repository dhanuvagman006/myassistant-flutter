import '../models/momentum.dart';

/// One habit reminder to put on the phone's alarm clock.
class HabitAlarm {
  const HabitAlarm(this.id, this.at, this.title, this.body);
  final int id;
  final DateTime at;
  final String title;
  final String body;
}

/// ─────────────────────────────────────────────────────────────────────────
///  HABIT REMINDERS (Momentum, 2026-09-25) — which local notifications a
///  habit's daily time becomes. Pure, so the rules are testable:
///
///   * one reminder a day for the next [days] days, not one repeating
///     alarm: a habit already ticked today is not reminded about today,
///     and a repeating alarm cannot skip a day;
///   * a week ahead, so a phone left alone for days still reminds — every
///     sync (each brief refresh) re-arms the whole week;
///   * ids from their own range ([base] up), clear of reminder ids (the
///     server's small serial numbers) and of the focus timer's two.
/// ─────────────────────────────────────────────────────────────────────────
abstract final class HabitAlarms {
  static const int base = 0x40000000;
  static const int days = 7;

  static int idFor(int habitId, int dayOffset) => base + habitId * 8 + dayOffset;

  static bool isHabitAlarm(int id) => id >= base;

  static List<HabitAlarm> plan(List<MomentumHabit> habits, DateTime now) {
    final out = <HabitAlarm>[];
    for (final h in habits) {
      final t = _time(h.remindAt);
      if (t == null || h.id <= 0) continue;
      for (var k = 0; k < days; k++) {
        final d = DateTime(now.year, now.month, now.day + k, t.$1, t.$2);
        if (!d.isAfter(now)) continue;
        if (k == 0 && h.doneToday) continue;
        final name = h.emoji.isEmpty ? h.title : '${h.emoji} ${h.title}';
        out.add(HabitAlarm(idFor(h.id, k), d, name, 'A small tick keeps it going.'));
      }
    }
    return out;
  }

  static (int, int)? _time(String? hhmm) {
    final m = RegExp(r'^(\d{2}):(\d{2})$').firstMatch(hhmm ?? '');
    if (m == null) return null;
    final h = int.parse(m.group(1)!), min = int.parse(m.group(2)!);
    if (h > 23 || min > 59) return null;
    return (h, min);
  }

  /// A stable fingerprint of what the alarms depend on: re-arm only when
  /// it changes.
  static String signature(List<MomentumHabit> habits, String day) => [
        day,
        for (final h in habits)
          if (h.remindAt != null) '${h.id}@${h.remindAt}${h.doneToday ? '+' : ''}${h.emoji}${h.title}',
      ].join('|');
}
