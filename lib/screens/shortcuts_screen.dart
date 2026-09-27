import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../design/apple_kit.dart';
import '../design/neon_tokens.dart';
import '../features/assistant/state/assistant_engine.dart';
import '../models/shortcut.dart';
import '../services/app_feedback.dart';
import '../services/shortcut_runner.dart';
import '../services/shortcuts_service.dart';

/// HUB → SHORTCUTS (build 120): "office mode" — one word, several things.
///
/// Made by voice ("create a shortcut called office mode that puts my phone
/// on silent and gives me directions to office"); here they are listed,
/// run with one tap (with the same one question first when a step sends
/// something on his behalf), renamed and deleted. A phone task that just
/// finished can be saved as one.
class ShortcutsScreen extends StatefulWidget {
  const ShortcutsScreen({super.key, this.ports, this.lastTask});

  /// Where a Run's phone steps go (the engine; a fake in tests).
  final ShortcutPorts? ports;

  /// The last phone task that got there (the engine's; a fake in tests).
  final ValueListenable<({int runId, String goal})?>? lastTask;

  @override
  State<ShortcutsScreen> createState() => _ShortcutsScreenState();
}

class _ShortcutsScreenState extends State<ShortcutsScreen> {
  final _svc = ShortcutsService.instance;
  bool _running = false;
  final Set<int> _saved = {};

  ShortcutPorts get _ports => widget.ports ?? AssistantEngine.instance.shortcutPorts;
  ValueListenable<({int runId, String goal})?> get _lastTask =>
      widget.lastTask ?? AssistantEngine.instance.lastSavableTask;

  @override
  void initState() {
    super.initState();
    _svc.addListener(_changed);
    unawaited(_svc.load());
  }

  @override
  void dispose() {
    _svc.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _run(Shortcut s) async {
    if (_running) return;
    setState(() => _running = true);
    try {
      var reply = await _svc.run(s);
      if (reply.error != null) {
        _say(reply.error!);
        return;
      }
      if (reply.needsYes) {
        if (!mounted) return;
        final yes = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: Text(s.name),
            content: Text('${reply.confirm}?'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Not now')),
              FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Yes, go ahead')),
            ],
          ),
        );
        if (yes != true) {
          await _svc.decline(reply.runId);
          _say("Okay, I didn't run ${s.name}.");
          return;
        }
        reply = await _svc.approve(reply.runId);
        if (reply.error != null) {
          _say(reply.error!);
          return;
        }
      }
      if (reply.report.isNotEmpty) _say(reply.report, good: true);
      final d = reply.directive;
      if (d != null) await ShortcutRunner.instance.run(d, _ports);
      unawaited(_svc.refresh());
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  void _say(String line, {bool good = false}) {
    if (!mounted) return;
    AppFeedback.show(line, context: context, tone: good ? FeedbackTone.success : FeedbackTone.error);
  }

  Future<String?> _askName(String title, String initial) {
    final ctl = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctl,
          autofocus: true,
          maxLength: 40,
          decoration: const InputDecoration(hintText: 'Name'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, ctl.text.trim()), child: const Text('Save')),
        ],
      ),
    );
  }

  Future<void> _rename(Shortcut s) async {
    final name = await _askName('Rename', s.name);
    if (name == null || name.isEmpty || name == s.name) return;
    final err = await _svc.rename(s, name);
    _say(err ?? 'Renamed to “$name”.', good: err == null);
  }

  Future<void> _delete(Shortcut s) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Delete “${s.name}”?'),
        content: const Text('Saying its name will no longer do anything.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
        ],
      ),
    );
    if (yes != true) return;
    final ok = await _svc.delete(s);
    _say(ok ? 'Deleted “${s.name}”.' : "Couldn't delete that just now.", good: ok);
  }

  Future<void> _saveTask(({int runId, String goal}) t) async {
    final name = await _askName('Save as shortcut', ShortcutsScreenNames.suggest(t.goal));
    if (name == null || name.isEmpty) return;
    final err = await _svc.learn(runId: t.runId, name: name);
    if (err == null) setState(() => _saved.add(t.runId));
    _say(err ?? 'Saved “$name”. Say “${name.toLowerCase()}” next time — I stop before paying.',
        good: err == null);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Neon.bg,
      appBar: appleAppBar(context, 'Shortcuts'),
      body: SafeArea(
        child: ValueListenableBuilder<({int runId, String goal})?>(
          valueListenable: _lastTask,
          builder: (context, task, _) => _body(task),
        ),
      ),
    );
  }

  Widget _body(({int runId, String goal})? task) {
    final list = _svc.shortcuts;
    final canSave = task != null && !_saved.contains(task.runId);
    if (!_svc.loaded && !_svc.failed) {
      return const Center(child: CircularProgressIndicator());
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Text('One word does several things — say its name.',
              style: TextStyle(color: Neon.textLo, fontSize: NeonType.footnote, height: 1.3)),
        ),
        if (canSave) _saveCard(task),
        if (_svc.failed && list.isEmpty)
          _note("Couldn't load your shortcuts. Pull down to try again.")
        else if (list.isEmpty)
          _note('No shortcuts yet. Try saying: "Create a shortcut called office mode that puts my '
              'phone on silent and gives me directions to office."')
        else
          for (final s in list) _card(s),
        if (_svc.full)
          _note('You have ${_svc.maxShortcuts} shortcuts — remove one to add another.'),
      ],
    );
  }

  Widget _note(String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Text(text,
            textAlign: TextAlign.center,
            style: TextStyle(color: Neon.textLo, fontSize: NeonType.footnote, height: 1.4)),
      );

  Widget _saveCard(({int runId, String goal}) t) => Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: GroupedCard(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Your last phone task', style: NeonType.row.copyWith(color: Neon.textHi)),
                const SizedBox(height: 4),
                Text(t.goal,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: Neon.textLo, fontSize: NeonType.footnote, height: 1.3)),
                const SizedBox(height: 10),
                ApplePrimaryButton(
                  key: const Key('save_task_as_shortcut'),
                  label: 'Save as shortcut',
                  icon: Icons.bolt_rounded,
                  onPressed: () => _saveTask(t),
                ),
              ],
            ),
          ),
        ]),
      );

  Widget _card(Shortcut s) {
    final steps = s.steps.map((x) => x.label).join(' · ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GroupedCard(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(s.name, style: NeonType.row.copyWith(color: Neon.textHi)),
                    if (s.learned)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text('Learned from a task',
                            style: TextStyle(color: Neon.violet, fontSize: NeonType.footnote)),
                      ),
                    const SizedBox(height: 4),
                    Text(steps,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: Neon.textLo, fontSize: NeonType.footnote, height: 1.3)),
                    const SizedBox(height: 4),
                    Text('Say “${s.sayIt}”',
                        style: TextStyle(color: Neon.textDim, fontSize: NeonType.footnote)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                key: Key('run_${s.id}'),
                onPressed: _running ? null : () => _run(s),
                child: const Text('Run'),
              ),
              PopupMenuButton<String>(
                key: Key('menu_${s.id}'),
                icon: Icon(Icons.more_vert_rounded, color: Neon.textLo),
                onSelected: (v) => v == 'rename' ? _rename(s) : _delete(s),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'rename', child: Text('Rename')),
                  PopupMenuItem(value: 'delete', child: Text('Delete')),
                ],
              ),
            ],
          ),
        ),
      ]),
    );
  }
}

/// The name "Save as shortcut" suggests for a task.
class ShortcutsScreenNames {
  /// "Milk bread eggs" from "add milk, bread and eggs to my grocery cart".
  static String suggest(String goal) {
    const skip = {
      'add', 'to', 'my', 'the', 'a', 'an', 'and', 'in', 'on', 'for', 'of', 'from', 'with', 'me',
      'order', 'please', 'cart', 'find', 'open', 'get', 'book', 'buy', 'do', 'some', 'grocery',
    };
    final words = goal
        .toLowerCase()
        .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))
        .where((w) => w.length > 1 && !skip.contains(w))
        .take(3)
        .toList();
    if (words.isEmpty) return '';
    final s = words.join(' ');
    return s[0].toUpperCase() + s.substring(1);
  }
}
