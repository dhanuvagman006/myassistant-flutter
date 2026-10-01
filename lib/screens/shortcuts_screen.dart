import 'dart:async';

import 'package:flutter/material.dart';

import '../design/apple_kit.dart';
import '../design/neon_tokens.dart';
import '../design/neon_widgets.dart';
import '../features/assistant/state/assistant_engine.dart';
import '../models/shortcut.dart';
import '../services/app_feedback.dart';
import '../services/shortcut_runner.dart';
import '../services/shortcuts_service.dart';
import '../design/motion.dart';

/// HUB → SHORTCUTS (build 120): "office mode" — one word, several things.
///
/// Made by voice ("create a shortcut called office mode that puts my phone
/// on silent and gives me directions to office"); here they are listed,
/// run with one tap (with the same one question first when a step sends
/// something on his behalf), renamed and deleted.
class ShortcutsScreen extends StatefulWidget {
  const ShortcutsScreen({super.key, this.ports});

  /// Where a Run's phone steps go (the engine; a fake in tests).
  final ShortcutPorts? ports;

  @override
  State<ShortcutsScreen> createState() => _ShortcutsScreenState();
}

class _ShortcutsScreenState extends State<ShortcutsScreen> {
  final _svc = ShortcutsService.instance;
  bool _running = false;

  ShortcutPorts get _ports =>
      widget.ports ?? AssistantEngine.instance.shortcutPorts;

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
        final yes = await showAppDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: Text(s.name),
            content: Text('${reply.confirm}?'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(c, false),
                  child: const Text('Not now')),
              FilledButton(
                  onPressed: () => Navigator.pop(c, true),
                  child: const Text('Yes, go ahead')),
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
    AppFeedback.show(line,
        context: context,
        tone: good ? FeedbackTone.success : FeedbackTone.error);
  }

  Future<String?> _askName(String title, String initial) {
    final ctl = TextEditingController(text: initial);
    return showAppDialog<String>(
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
          TextButton(
              onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(c, ctl.text.trim()),
              child: const Text('Save')),
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
    final yes = await showAppDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Delete “${s.name}”?'),
        content: const Text('Saying its name will no longer do anything.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Keep')),
          FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (yes != true) return;
    final ok = await _svc.delete(s);
    _say(ok ? 'Deleted “${s.name}”.' : "Couldn't delete that just now.",
        good: ok);
  }

  @override
  Widget build(BuildContext context) {
    return NeonScaffold(
      appBar: appleAppBar(context, 'Shortcuts'),
      body: SafeArea(child: StateSwitch.of(_body())),
    );
  }

  Widget _body() {
    final list = _svc.shortcuts;
    if (!_svc.loaded && !_svc.failed) {
      return const NeonLoader.page(semanticLabel: 'Loading your shortcuts');
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Text('One word does several things — say its name.',
              style: TextStyle(
                  color: Neon.textLo,
                  fontSize: NeonType.footnote,
                  height: 1.3)),
        ),
        // It said "pull down to try again" on a page that cannot be
        // pulled: a real button now.
        if (_svc.failed && list.isEmpty)
          NeonErrorState(
            message: "Couldn't load your shortcuts",
            onRetry: () {
              // The spinner while it asks again.
              setState(() => _svc.failed = false);
              unawaited(_svc.refresh());
            },
          )
        else if (list.isEmpty)
          const NeonEmptyState(
            icon: Icons.bolt_rounded,
            title: 'No shortcuts yet',
            body: 'Try saying: "Create a shortcut called office mode that '
                'puts my phone on silent and gives me directions to '
                'office."',
          )
        else
          for (final s in list) _card(s),
        if (_svc.full)
          _note(
              'You have ${_svc.maxShortcuts} shortcuts — remove one to add another.'),
      ],
    );
  }

  Widget _note(String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Text(text,
            textAlign: TextAlign.center,
            style: TextStyle(
                color: Neon.textLo, fontSize: NeonType.footnote, height: 1.4)),
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
                    Text(s.name,
                        style: NeonType.row.copyWith(color: Neon.textHi)),
                    const SizedBox(height: 4),
                    Text(steps,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: Neon.textLo,
                            fontSize: NeonType.footnote,
                            height: 1.3)),
                    const SizedBox(height: 4),
                    Text('Say “${s.sayIt}”',
                        style: TextStyle(
                            color: Neon.textLo, fontSize: NeonType.footnote)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // A lit pill, not a filled button (2026-09-30): a page of
              // shortcuts is a page of Runs, and a column of glowing
              // primaries has no focus. Magenta-to-orange: something to do.
              NeonPill(
                key: Key('run_${s.id}'),
                label: 'Run',
                icon: Icons.play_arrow_rounded,
                tone: NeonTone.action,
                onPressed: _running ? null : () => _run(s),
              ),
              PopupMenuButton<String>(
                popUpAnimationStyle: appMenuAnimation(context),
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
