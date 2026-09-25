/// MOMENTUM — the server's summary (GET /momentum), as the app reads it.
///
/// Owner, 2026-09-25: "plan and add some features that make much better
/// and keeps user motivated and productive". One summary drives the Home
/// card, the Momentum screen and the streak chip, so all three always say
/// the same thing. Mutable on purpose: optimistic edits are applied to a
/// copy ([clone]) and thrown away if the server says no.
library;

int _int(Object? v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;
bool _bool(Object? v) => v == true || v == 1 || v == 'true';
String _str(Object? v) => v == null ? '' : '$v';
List<Map<String, dynamic>> _maps(Object? v) =>
    (v is List ? v : const []).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();

class MomentumPriority {
  MomentumPriority({required this.id, required this.title, this.done = false, this.position = 0});

  /// Negative while it exists only on this phone (added, not yet saved).
  int id;
  String title;
  bool done;
  int position;

  factory MomentumPriority.fromJson(Map<String, dynamic> j) => MomentumPriority(
        id: _int(j['id']),
        title: _str(j['title']),
        done: _bool(j['done']),
        position: _int(j['position']),
      );

  Map<String, dynamic> toJson() => {'id': id, 'title': title, 'done': done, 'position': position};
}

class MomentumHabit {
  MomentumHabit({
    required this.id,
    required this.title,
    this.emoji = '',
    this.remindAt,
    this.doneToday = false,
    this.streak = 0,
    this.best = 0,
    List<bool>? last7,
  }) : last7 = last7 ?? List<bool>.filled(7, false);

  int id;
  String title;
  String emoji;

  /// Local 'HH:MM', or null for no reminder.
  String? remindAt;
  bool doneToday;
  int streak;
  int best;

  /// Oldest first, ending today.
  List<bool> last7;

  factory MomentumHabit.fromJson(Map<String, dynamic> j) {
    final raw = (j['last7'] is List ? j['last7'] as List : const []).map(_bool).toList();
    return MomentumHabit(
      id: _int(j['id']),
      title: _str(j['title']),
      emoji: _str(j['emoji']),
      remindAt: (j['remindAt'] is String && (j['remindAt'] as String).isNotEmpty)
          ? j['remindAt'] as String
          : null,
      doneToday: _bool(j['doneToday']),
      streak: _int(j['streak']),
      best: _int(j['best']),
      last7: raw.length == 7 ? raw : List<bool>.filled(7, false),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'emoji': emoji,
        'remindAt': remindAt,
        'doneToday': doneToday,
        'streak': streak,
        'best': best,
        'last7': last7,
      };
}

class MomentumDay {
  MomentumDay({
    required this.day,
    this.active = false,
    this.wins = 0,
    this.focusMin = 0,
    this.habits = 0,
    this.forgiven = false,
  });

  final String day;
  bool active;
  int wins;
  int focusMin;
  int habits;

  /// The one missed day this week that kept the streak alive.
  bool forgiven;

  factory MomentumDay.fromJson(Map<String, dynamic> j) => MomentumDay(
        day: _str(j['day']),
        active: _bool(j['active']),
        wins: _int(j['wins']),
        focusMin: _int(j['focusMin']),
        habits: _int(j['habits']),
        forgiven: _bool(j['forgiven']),
      );

  Map<String, dynamic> toJson() => {
        'day': day,
        'active': active,
        'wins': wins,
        'focusMin': focusMin,
        'habits': habits,
        'forgiven': forgiven,
      };
}

class MomentumMilestone {
  const MomentumMilestone({required this.id, required this.label, this.earned = false, this.earnedOn});
  final String id;
  final String label;
  final bool earned;
  final String? earnedOn;

  factory MomentumMilestone.fromJson(Map<String, dynamic> j) => MomentumMilestone(
        id: _str(j['id']),
        label: _str(j['label']),
        earned: _bool(j['earned']),
        earnedOn: j['earnedOn'] is String ? j['earnedOn'] as String : null,
      );

  Map<String, dynamic> toJson() => {'id': id, 'label': label, 'earned': earned, 'earnedOn': earnedOn};
}

class MomentumSummary {
  MomentumSummary({
    required this.day,
    List<MomentumPriority>? priorities,
    List<MomentumHabit>? habits,
    this.todayMin = 0,
    this.weekMin = 0,
    this.totalMin = 0,
    this.streak = 0,
    this.bestStreak = 0,
    this.activeToday = false,
    this.graceUsedThisWeek = false,
    List<MomentumDay>? week,
    this.weekWins = 0,
    this.weekFocusMin = 0,
    this.weekHabitsKept = 0,
    this.bestDay,
    List<MomentumMilestone>? milestones,
  })  : priorities = priorities ?? [],
        habits = habits ?? [],
        week = week ?? [],
        milestones = milestones ?? [];

  /// The local day this summary is about ('YYYY-MM-DD').
  final String day;
  List<MomentumPriority> priorities;
  List<MomentumHabit> habits;
  int todayMin;
  int weekMin;
  int totalMin;
  int streak;
  int bestStreak;
  bool activeToday;
  bool graceUsedThisWeek;

  /// Seven days, oldest first, ending [day].
  List<MomentumDay> week;
  int weekWins;
  int weekFocusMin;
  int weekHabitsKept;
  String? bestDay;
  List<MomentumMilestone> milestones;

  int get doneCount => priorities.where((p) => p.done).length;
  bool get allDone => priorities.isNotEmpty && priorities.every((p) => p.done);

  factory MomentumSummary.fromJson(Map<String, dynamic> j) {
    final focus = (j['focus'] is Map ? j['focus'] as Map : const {}).cast<String, dynamic>();
    final st = (j['streak'] is Map ? j['streak'] as Map : const {}).cast<String, dynamic>();
    final wk = (j['week'] is Map ? j['week'] as Map : const {}).cast<String, dynamic>();
    return MomentumSummary(
      day: _str(j['day']),
      priorities: _maps(j['priorities']).map(MomentumPriority.fromJson).toList()
        ..sort((a, b) => a.position.compareTo(b.position)),
      habits: _maps(j['habits']).map(MomentumHabit.fromJson).toList(),
      todayMin: _int(focus['todayMin']),
      weekMin: _int(focus['weekMin']),
      totalMin: _int(focus['totalMin']),
      streak: _int(st['current']),
      bestStreak: _int(st['best']),
      activeToday: _bool(st['activeToday']),
      graceUsedThisWeek: _bool(st['graceUsedThisWeek']),
      week: _maps(wk['days']).map(MomentumDay.fromJson).toList(),
      weekWins: _int(wk['wins']),
      weekFocusMin: _int(wk['focusMin']),
      weekHabitsKept: _int(wk['habitsKept']),
      bestDay: wk['bestDay'] is String ? wk['bestDay'] as String : null,
      milestones: _maps(j['milestones']).map(MomentumMilestone.fromJson).toList(),
    );
  }

  Map<String, dynamic> toJson() => {
        'ok': true,
        'day': day,
        'priorities': [for (final p in priorities) p.toJson()],
        'habits': [for (final h in habits) h.toJson()],
        'focus': {'todayMin': todayMin, 'weekMin': weekMin, 'totalMin': totalMin},
        'streak': {
          'current': streak,
          'best': bestStreak,
          'activeToday': activeToday,
          'graceUsedThisWeek': graceUsedThisWeek,
        },
        'week': {
          'days': [for (final d in week) d.toJson()],
          'wins': weekWins,
          'focusMin': weekFocusMin,
          'habitsKept': weekHabitsKept,
          'bestDay': bestDay,
        },
        'milestones': [for (final m in milestones) m.toJson()],
      };

  /// A deep copy, for an optimistic edit that may have to be undone.
  MomentumSummary clone() => MomentumSummary.fromJson(toJson());
}
