/// One reminder, mirroring the backend's /reminders rows. Created by
/// voice ("remind me to…") or the Today screen; local notifications are
/// scheduled from this list.
class Reminder {
  final int id;
  final String text;
  final DateTime? dueAt; // null = undated note-to-self
  final bool done;

  /// 'alarm' rings like a clock through silent mode and takes over a
  /// locked screen; 'gentle' is an ordinary notification. Only the user
  /// asking to be woken produces 'alarm'.
  final String ring;

  const Reminder(
      {required this.id,
      required this.text,
      this.dueAt,
      required this.done,
      this.ring = 'gentle'});

  bool get isAlarm => ring == 'alarm';

  factory Reminder.fromJson(Map<String, dynamic> j) => Reminder(
        id: j['id'] as int,
        text: (j['text'] as String?) ?? '',
        dueAt: j['dueAt'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch((j['dueAt'] as num).toInt()),
        done: (j['done'] as bool?) ?? false,
        ring: (j['ring'] ?? 'gentle').toString(),
      );
}
