/// Result of a /vision call (Group B).
class VisionResult {
  final String answer;
  final VisionAction? action;
  const VisionResult({required this.answer, this.action});

  factory VisionResult.fromJson(Map<String, dynamic> j) => VisionResult(
        answer: (j['answer'] ?? '').toString(),
        action: j['action'] is Map<String, dynamic>
            ? VisionAction.fromJson(j['action'] as Map<String, dynamic>)
            : null,
      );
}

/// B4 — a suggested next step extracted from a screenshot, awaiting the
/// user's one-tap approval (currently: calendar/reminder entries).
class VisionAction {
  final String type; // 'calendar'
  final String title;
  final DateTime? start;
  final DateTime? end;
  final String? location;

  const VisionAction({
    required this.type,
    required this.title,
    this.start,
    this.end,
    this.location,
  });

  /// A calendar event we can act on: it has a start, and it is still ahead.
  bool isUpcoming([DateTime? now]) =>
      type == 'calendar' &&
      start != null &&
      start!.isAfter(now ?? DateTime.now());

  /// Minutes from start to end, or an hour when the image gave no end.
  int get durationMin {
    final s = start, e = end;
    if (s == null || e == null || !e.isAfter(s)) return 60;
    return e.difference(s).inMinutes.clamp(15, 24 * 60);
  }

  /// "Sun 4 Oct, 11:00 AM" — the year only when it is not this one (or
  /// always, [withYear], for the model).
  String whenLabel({DateTime? now, bool withYear = false}) {
    final s = start;
    if (s == null) return '';
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final h = s.hour % 12 == 0 ? 12 : s.hour % 12;
    final m = s.minute.toString().padLeft(2, '0');
    final year =
        !withYear && s.year == (now ?? DateTime.now()).year ? '' : ' ${s.year}';
    return '${days[s.weekday - 1]} ${s.day} ${months[s.month - 1]}$year, '
        '$h:$m ${s.hour < 12 ? 'AM' : 'PM'}';
  }

  static VisionAction? fromJson(Map<String, dynamic> j) {
    final title = (j['title'] ?? '').toString();
    if (title.isEmpty) return null;
    return VisionAction(
      type: (j['type'] ?? 'calendar').toString(),
      title: title,
      start: DateTime.tryParse((j['startIso'] ?? '').toString())?.toLocal(),
      end: DateTime.tryParse((j['endIso'] ?? '').toString())?.toLocal(),
      location: j['location']?.toString(),
    );
  }
}
