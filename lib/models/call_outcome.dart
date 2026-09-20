/// ONE CALL THE ASSISTANT MADE FOR THE USER, and what came of it.
///
/// Backed by the server's task_outcomes rows (kind = agent_call). The
/// result line is what the assistant says out loud; [transcript] is the
/// conversation itself, so "what exactly did he say?" is answerable days
/// later instead of only in the moment it happened.
class CallOutcome {
  final int id;
  final String contact; // who was called
  final String detail; // the one-line result, e.g. what they said
  final String status; // dialing | connected | completed | no_answer | failed…
  final String reason; // why it failed, when it did
  final String transcript; // "assistant: …\nuser: …"
  final int createdAt;
  final int updatedAt;

  const CallOutcome({
    required this.id,
    required this.contact,
    required this.detail,
    required this.status,
    required this.reason,
    required this.transcript,
    required this.createdAt,
    required this.updatedAt,
  });

  bool get inProgress =>
      status == 'requested' || status == 'dialing' || status == 'connected';
  bool get answered => status == 'completed' || status == 'connected';
  bool get missed => status == 'no_answer';

  /// Just the other person's lines, in order — the part the user asked
  /// for ("let the user know what they have responded").
  List<String> get theirLines => transcript
      .split('\n')
      .where((l) => RegExp(r'^\s*user\s*:', caseSensitive: false).hasMatch(l))
      .map((l) => l.replaceFirst(RegExp(r'^\s*user\s*:', caseSensitive: false), '').trim())
      .where((l) => l.length > 1)
      .toList(growable: false);

  /// Every turn as (whoSpoke, whatTheySaid), for the expanded view.
  List<({bool them, String text})> get exchange {
    final out = <({bool them, String text})>[];
    for (final line in transcript.split('\n')) {
      final m = RegExp(r'^\s*(assistant|user)\s*:(.*)$', caseSensitive: false)
          .firstMatch(line);
      if (m == null) continue;
      final text = (m.group(2) ?? '').trim();
      if (text.isEmpty) continue;
      out.add((them: m.group(1)!.toLowerCase() == 'user', text: text));
    }
    return out;
  }

  factory CallOutcome.fromJson(Map<String, dynamic> j) => CallOutcome(
        id: (j['id'] as num?)?.toInt() ?? 0,
        contact: (j['target'] ?? '').toString(),
        detail: (j['detail'] ?? '').toString(),
        status: (j['status'] ?? '').toString(),
        reason: (j['reason'] ?? '').toString(),
        transcript: (j['transcript'] ?? '').toString(),
        createdAt: (j['createdAt'] as num?)?.toInt() ?? 0,
        updatedAt: (j['updatedAt'] as num?)?.toInt() ?? 0,
      );

  static List<CallOutcome> listFromJson(dynamic j) {
    if (j is! List) return const [];
    return j
        .whereType<Map>()
        .map((m) => CallOutcome.fromJson(m.cast<String, dynamic>()))
        .where((c) => c.id > 0)
        .toList(growable: false);
  }
}
