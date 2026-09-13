/// One commitment in the schedule panel — a meeting, an appointment, a
/// client or patient recall, or a time-bound reminder.
class ScheduleItem {
  final String kind; // meeting | appointment | patient | client | reminder | …
  final String title;
  final String who;
  final String where;
  final String time; // "10:30 am" or "All day", already localised server-side
  final String note;
  final String source; // calendar | booking | recall | reminder
  final int at; // epoch ms

  const ScheduleItem({
    required this.kind,
    required this.title,
    this.who = '',
    this.where = '',
    this.time = '',
    this.note = '',
    this.source = '',
    this.at = 0,
  });

  factory ScheduleItem.fromJson(Map<String, dynamic> j) => ScheduleItem(
        kind: (j['kind'] as String?) ?? '',
        title: (j['title'] as String?) ?? '',
        who: (j['who'] as String?) ?? '',
        where: (j['where'] as String?) ?? '',
        time: (j['time'] as String?) ?? '',
        note: (j['note'] as String?) ?? '',
        source: (j['source'] as String?) ?? '',
        at: (j['at'] as num?)?.toInt() ?? 0,
      );
}
