import 'package:flutter/services.dart';

/// One row of the phone's call history (CallLogBridge.kt, "hari/calls").
class CallEntry {
  const CallEntry({
    required this.name,
    required this.number,
    required this.type,
    required this.at,
    this.durationSec = 0,
  });

  /// Contact name, or '' for a number that is not saved.
  final String name;

  /// As the phone logged it; '' for a withheld number.
  final String number;

  /// missed | incoming | outgoing | rejected | blocked
  final String type;
  final DateTime at;
  final int durationSec;

  factory CallEntry.fromMap(Map m) => CallEntry(
        name: (m['name'] ?? '').toString().trim(),
        number: (m['number'] ?? '').toString().trim(),
        type: (m['type'] ?? '').toString(),
        at: DateTime.fromMillisecondsSinceEpoch(
            (m['at'] as num?)?.toInt() ?? 0),
        durationSec: (m['durationSec'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'number': number,
        'type': type,
        'at': at.millisecondsSinceEpoch,
        'durationSec': durationSec,
      };

  /// The same caller whatever way the number was written: the last ten
  /// digits, else the name, else "private".
  String get caller {
    final d = number.replaceAll(RegExp(r'\D'), '');
    if (d.length >= 3) return d.length > 10 ? d.substring(d.length - 10) : d;
    if (name.isNotEmpty) return 'name:${name.toLowerCase()}';
    return 'private';
  }

  /// How the assistant names the caller in its one line.
  String get label => name.isNotEmpty
      ? name
      : number.isNotEmpty
          ? CallHistory.formatNumber(number)
          : 'a private number';

  /// How the greeting names them: a first name, or the number's tail.
  String get shortLabel {
    if (name.isNotEmpty) return CallHistory.shortName(name);
    final d = number.replaceAll(RegExp(r'\D'), '');
    if (d.length >= 4) return 'a number ending ${d.substring(d.length - 4)}';
    return 'a private number';
  }

  /// The number to dial back ('' when withheld).
  String get dialable => number.replaceAll(RegExp(r'[^\d+]'), '');
}

/// The phone's call history: read on the phone, told to the assistant as
/// ONE short line, never dumped.
///
/// Owner, 2026-09-24: "the calls should be connected — it should report
/// when we have any missed calls, or any info if user asks about calls".
/// Before this the assistant could only guess, and once told a client
/// "you haven't missed any calls" about a phone it could not see.
class CallHistory {
  CallHistory._();

  static const _ch = MethodChannel('hari/calls');

  /// At most this many people in one line; the rest are counted.
  static const maxEntries = 5;

  /// The exact runtime permissions, one by one. Null when the phone side
  /// cannot answer (not Android, an old build). See CallLogBridge.kt for
  /// why permission_handler's Permission.phone is no longer exact.
  static Future<Map<String, bool>?> permissions() async {
    try {
      final r = await _ch.invokeMethod<Map<Object?, Object?>>('permissions');
      if (r == null) return null;
      return {for (final e in r.entries) e.key.toString(): e.value == true};
    } catch (_) {
      return null;
    }
  }

  /// Can the call history be read right now? Never asks.
  static Future<bool> canRead() async =>
      (await permissions())?['callLog'] == true;

  /// Shows Android's dialog. "granted" | "denied" | "blocked" (Android
  /// will not ask again) | "busy" | "unavailable".
  static Future<String> requestCallLog() async {
    try {
      return await _ch.invokeMethod<String>('requestCallLog') ?? 'denied';
    } catch (_) {
      return 'unavailable';
    }
  }

  /// Newest first. Throws [PlatformException] with code `no_permission`
  /// when call history is off.
  static Future<List<CallEntry>> recent({
    String filter = 'all',
    String person = '',
    required DateTime since,
    int limit = 100,
  }) async {
    final r = await _ch.invokeMethod<List<Object?>>('recent', {
      'filter': filter,
      'person': person,
      'sinceMs': since.millisecondsSinceEpoch,
      'limit': limit,
    });
    return [
      for (final m in r ?? const [])
        if (m is Map) CallEntry.fromMap(m),
    ];
  }

  // ---------------- wording (pure, tested) ----------------

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];

  /// "3:10 pm" in the owner's local time.
  static String clock(DateTime t) {
    final l = t.toLocal();
    final h = l.hour % 12 == 0 ? 12 : l.hour % 12;
    final m = l.minute.toString().padLeft(2, '0');
    return '$h:$m ${l.hour < 12 ? 'am' : 'pm'}';
  }

  /// "at 3:10 pm" today, "yesterday at 3:10 pm", "on 22 Sep at 3:10 pm".
  static String when(DateTime at, DateTime now) {
    final a = at.toLocal();
    final n = now.toLocal();
    // Calendar days, not 24-hour blocks: 11 pm yesterday is "yesterday".
    final days = DateTime.utc(n.year, n.month, n.day)
        .difference(DateTime.utc(a.year, a.month, a.day))
        .inDays;
    if (days <= 0) return 'at ${clock(a)}';
    if (days == 1) return 'yesterday at ${clock(a)}';
    return 'on ${a.day} ${_months[a.month - 1]} at ${clock(a)}';
  }

  /// "the last 24 hours", "the last 3 days".
  static String span(int hours) {
    if (hours <= 1) return 'the last hour';
    if (hours < 48) return 'the last $hours hours';
    return 'the last ${(hours / 24).round()} days';
  }

  /// "+919876545678" -> "+91 98765 45678", "9876545678" -> "98765 45678".
  static String formatNumber(String raw) {
    final plus = raw.trim().startsWith('+');
    final d = raw.replaceAll(RegExp(r'\D'), '');
    if (d.length < 10) return raw.trim();
    final local = d.substring(d.length - 10);
    final cc = d.substring(0, d.length - 10);
    final grouped = '${local.substring(0, 5)} ${local.substring(5)}';
    if (cc.isEmpty) return grouped;
    return '${plus ? '+' : ''}$cc $grouped';
  }

  /// "Ravi Kumar" -> "Ravi", "Dr Shah Mehta" -> "Dr Shah".
  static String shortName(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return name.trim();
    const titles = {
      'dr', 'dr.', 'mr', 'mr.', 'mrs', 'mrs.', 'ms', 'ms.', 'prof', 'prof.',
      'smt', 'smt.', 'shri', 'sri',
    };
    if (parts.length > 1 && titles.contains(parts.first.toLowerCase())) {
      return '${parts[0]} ${parts[1]}';
    }
    return parts.first;
  }

  /// Newest call per caller (and per type when [byType]), with how many
  /// calls it stands for. [calls] must be newest first.
  static List<CallGroup> group(List<CallEntry> calls, {bool byType = false}) {
    final out = <String, CallGroup>{};
    for (final c in calls) {
      final key = byType ? '${c.caller}|${c.type}' : c.caller;
      final g = out[key];
      if (g == null) {
        out[key] = CallGroup(c);
      } else {
        g.count++;
      }
    }
    return out.values.toList();
  }

  /// THE ONE LINE the assistant gets back for a `call_log` device action:
  /// counts, names and local times, at most [maxEntries] people — e.g.
  /// "[SYSTEM] Missed calls in the last 24 hours: Ravi Kumar at 3:10 pm
  /// (2 times), +91 98765 45678 at 5:02 pm. Say this in one or two short
  /// sentences and offer to call back."
  static String summaryLine({
    required List<CallEntry> calls,
    required String filter,
    String person = '',
    required int sinceHours,
    required DateTime now,
    int maxPeople = maxEntries,
  }) {
    final who = person.trim();
    final cap = maxPeople.clamp(1, maxEntries);
    final kind = switch (filter) {
      'missed' => 'missed calls',
      'incoming' => 'incoming calls',
      'outgoing' => 'outgoing calls',
      _ => 'calls',
    };
    final prep = who.isEmpty
        ? ''
        : switch (filter) {
            'outgoing' => ' to $who',
            'all' => ' with $who',
            _ => ' from $who',
          };
    final range = span(sinceHours);
    if (calls.isEmpty) {
      return '[SYSTEM] The phone\'s call history shows no $kind$prep in '
          '$range. Say that in one short sentence — do not guess any calls.';
    }
    // The type is worth saying only where the list mixes them.
    final showType = filter == 'all' || filter == 'incoming';
    final groups = group(calls, byType: showType);
    final parts = <String>[];
    for (final g in groups.take(cap)) {
      final c = g.latest;
      final tags = <String>[
        if (showType && !(filter == 'incoming' && c.type == 'incoming'))
          c.type,
        if (g.count > 1) '${g.count} times',
        if ((c.type == 'incoming' || c.type == 'outgoing') &&
            c.durationSec >= 60)
          '${(c.durationSec / 60).round()} min',
      ];
      parts.add('${c.label} ${when(c.at, now)}'
          '${tags.isEmpty ? '' : ' (${tags.join(', ')})'}');
    }
    var more = 0;
    for (final g in groups.skip(cap)) {
      more += g.count;
    }
    final head = '${kind[0].toUpperCase()}${kind.substring(1)}$prep';
    final anyMissed = calls.any((c) => c.type == 'missed');
    return '[SYSTEM] $head in $range: ${parts.join(', ')}'
        '${more > 0 ? ', and $more more call${more == 1 ? '' : 's'}' : ''}. '
        '${anyMissed ? 'Say this in one or two short sentences and offer to call back.' : 'Say this in one or two short sentences.'}';
  }

  /// What the greeting says ONCE about calls missed since the owner last
  /// heard about them: "Hello Sir! You missed 2 calls — Ravi at 3:10 pm."
  /// [hello] false (greeted a moment ago): "Sir, you missed 2 calls — …".
  static String greetingMention(
    List<CallEntry> missed, {
    required String honorific,
    required bool hello,
    required DateTime now,
  }) {
    final sorted = [...missed]..sort((a, b) => b.at.compareTo(a.at));
    final groups = group(sorted);
    final n = sorted.length;
    final who = [
      for (final g in groups.take(2)) '${g.latest.shortLabel} ${when(g.latest.at, now)}',
    ];
    final others = groups.length - who.length;
    final list = switch (who.length) {
      0 => '',
      1 => others > 0
          ? '${who[0]} and $others other${others == 1 ? '' : 's'}'
          : who[0],
      _ => others > 0
          ? '${who[0]}, ${who[1]} and $others other${others == 1 ? '' : 's'}'
          : '${who[0]} and ${who[1]}',
    };
    final count = n == 1 ? 'a call' : '$n calls';
    final opener = hello ? 'Hello $honorific! You' : '$honorific, you';
    return '$opener missed $count — $list.';
  }
}

/// One caller's newest call and how many calls it stands for.
class CallGroup {
  CallGroup(this.latest);
  final CallEntry latest;
  int count = 1;
}
