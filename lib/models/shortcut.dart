/// Shortcuts (build 120): "office mode" — one word, several things.
///
/// The server owns the steps, their order and their labels (the labels
/// never name a company); the phone shows them and performs the ones it is
/// sent as one `shortcut_run` directive. Shapes: the backend's
/// tests/fixtures/shortcuts/contract.json (a copy is in test/fixtures).
library;

int _int(Object? v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}') ?? 0;

class ShortcutStep {
  const ShortcutStep({
    required this.i,
    required this.tool,
    required this.label,
    this.said,
    this.cls = '',
    this.icon = 'bolt',
  });

  final int i;
  final String tool;
  final String label;
  final String? said;
  final String cls;
  final String icon;

  factory ShortcutStep.fromJson(Map<String, dynamic> j) => ShortcutStep(
        i: _int(j['i']),
        tool: (j['tool'] ?? '').toString(),
        label: (j['label'] ?? '').toString(),
        said: j['said'] as String?,
        cls: (j['class'] ?? '').toString(),
        icon: (j['icon'] ?? 'bolt').toString(),
      );

  Map<String, dynamic> toJson() =>
      {'i': i, 'tool': tool, 'label': label, 'said': said, 'class': cls, 'icon': icon};
}

class Shortcut {
  const Shortcut({
    required this.id,
    required this.name,
    this.otherNames = const [],
    this.version = 1,
    this.steps = const [],
    this.learned = false,
    this.runCount = 0,
    this.lastRunAt = 0,
  });

  final int id;
  final String name;
  final List<String> otherNames;
  final int version;
  final List<ShortcutStep> steps;
  final bool learned;
  final int runCount;
  final int lastRunAt;

  /// What to say to run it: the name as it is shown, in lower case.
  String get sayIt => name.toLowerCase();

  factory Shortcut.fromJson(Map<String, dynamic> j) => Shortcut(
        id: _int(j['id']),
        name: (j['name'] ?? '').toString(),
        otherNames: ((j['other_names'] as List?) ?? const []).map((e) => '$e').toList(),
        version: _int(j['version']),
        steps: ((j['steps'] as List?) ?? const [])
            .whereType<Map>()
            .map((m) => ShortcutStep.fromJson(m.cast<String, dynamic>()))
            .toList(),
        learned: j['learned'] == true,
        runCount: _int(j['run_count']),
        lastRunAt: _int(j['last_run_at']),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'other_names': otherNames,
        'version': version,
        'steps': steps.map((s) => s.toJson()).toList(),
        'learned': learned,
        'run_count': runCount,
        'last_run_at': lastRunAt,
      };
}

/// One step of a `shortcut_run` directive: the device action it carries
/// is an ordinary one the engine already knows (phone_control, open_url…).
class ShortcutEnvelope {
  const ShortcutEnvelope({
    required this.i,
    required this.cls,
    required this.label,
    required this.action,
    this.waitReturn = false,
  });

  final int i;

  /// in_app | hand_back | stays | app_task
  final String cls;
  final String label;
  final bool waitReturn;
  final Map<String, dynamic> action;

  bool get leavesApp => cls != 'in_app';

  factory ShortcutEnvelope.fromJson(Map<String, dynamic> j) => ShortcutEnvelope(
        i: _int(j['i']),
        cls: (j['class'] ?? '').toString(),
        label: (j['label'] ?? '').toString(),
        waitReturn: j['wait_return'] == true,
        action: ((j['action'] as Map?) ?? const {}).cast<String, dynamic>(),
      );

  Map<String, dynamic> toJson() =>
      {'i': i, 'class': cls, 'label': label, 'wait_return': waitReturn, 'action': action};
}

class ShortcutRunDirective {
  const ShortcutRunDirective({
    required this.runId,
    required this.shortcutId,
    required this.name,
    required this.steps,
    this.leavesApp = false,
  });

  final int runId;
  final int shortcutId;
  final String name;
  final bool leavesApp;
  final List<ShortcutEnvelope> steps;

  factory ShortcutRunDirective.fromJson(Map<String, dynamic> j) => ShortcutRunDirective(
        runId: _int(j['run_id']),
        shortcutId: _int(j['shortcut_id']),
        name: (j['name'] ?? '').toString(),
        leavesApp: j['leaves_app'] == true,
        steps: ((j['steps'] as List?) ?? const [])
            .whereType<Map>()
            .map((m) => ShortcutEnvelope.fromJson(m.cast<String, dynamic>()))
            .toList(),
      );

  Map<String, dynamic> toJson() => {
        'type': 'shortcut_run',
        'run_id': runId,
        'shortcut_id': shortcutId,
        'name': name,
        'leaves_app': leavesApp,
        'steps': steps.map((s) => s.toJson()).toList(),
      };

  /// The same run from step [from] on (the tail left after leaving the app).
  ShortcutRunDirective tail(int from) => ShortcutRunDirective(
        runId: runId,
        shortcutId: shortcutId,
        name: name,
        leavesApp: leavesApp,
        steps: steps.sublist(from.clamp(0, steps.length)),
      );
}
