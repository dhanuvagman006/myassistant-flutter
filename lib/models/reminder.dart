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

  /// 'call' — the assistant phones the user at dueAt; 'notify' — a push.
  /// The server has sent this all along; showing it means the user learns
  /// which reminders will ring their phone before it rings.
  final String deliver;

  const Reminder(
      {required this.id,
      required this.text,
      this.dueAt,
      required this.done,
      this.ring = 'gentle',
      this.deliver = 'notify'});

  bool get isAlarm => ring == 'alarm';
  bool get calls => deliver == 'call';

  factory Reminder.fromJson(Map<String, dynamic> j) => Reminder(
        id: j['id'] as int,
        text: (j['text'] as String?) ?? '',
        dueAt: j['dueAt'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch((j['dueAt'] as num).toInt()),
        done: (j['done'] as bool?) ?? false,
        ring: (j['ring'] ?? 'gentle').toString(),
        deliver: (j['deliver'] ?? 'notify').toString(),
      );
}
