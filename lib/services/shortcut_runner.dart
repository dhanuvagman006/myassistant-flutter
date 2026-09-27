import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/shortcut.dart';

/// What the runner needs from the app (the engine in the app, fakes in
/// tests). Every action is an ordinary device action the engine already
/// performs and reports on — the runner only decides WHEN.
abstract class ShortcutPorts {
  /// Hand one device action (phone_control, open_url, automate…) to the
  /// engine's own handler.
  Future<void> perform(Map<String, dynamic> action);

  /// True when the phone may open another app while this one is in the
  /// background (the "use other apps" service is on).
  Future<bool> canLaunchFromBackground();

  /// "Office mode — tap to carry on": the next step waits for a tap,
  /// because Android will not let an app in the background open another.
  Future<void> notifyContinue(ShortcutRunDirective d, ShortcutEnvelope next);

  /// A step that never ran because the owner did not come back in time.
  Future<void> notifyUnfinished(String name, String label);

  Future<void> wait(Duration d);
}

/// ─────────────────────────────────────────────────────────────────────────
///  SHORTCUT RUNNER (build 120) — performs one `shortcut_run` directive in
///  the order the server fixed: in-app steps at once, then the chat
///  message (the owner taps Send and comes back), then the app that stays
///  open, then a phone task last.
///
///  Android only lets an app open another app while it is on screen, so
///  whatever is left after leaving the app is kept (10 minutes, across a
///  restart) and carried on when the owner comes back — or opened 1.5 s
///  apart when "use other apps" is on. A run already started is never
///  started twice (a resent directive).
/// ─────────────────────────────────────────────────────────────────────────
class ShortcutRunner {
  ShortcutRunner._();
  static final ShortcutRunner instance = ShortcutRunner._();

  static const tailKey = 'shortcut_run_tail_v1';
  static const tailTtl = Duration(minutes: 10);
  static const gap = Duration(milliseconds: 1500);

  /// The phone's clock (tests pin it).
  static DateTime Function() clock = DateTime.now;

  final Set<int> _started = {};

  /// Forget every started run (tests; sign-out).
  Future<void> reset() async {
    _started.clear();
    final p = await SharedPreferences.getInstance();
    await p.remove(tailKey);
  }

  /// Perform [d]. A run id already started is ignored.
  Future<void> run(ShortcutRunDirective d, ShortcutPorts ports) async {
    if (d.runId > 0 && !_started.add(d.runId)) return;
    if (_started.length > 200) _started.remove(_started.first);
    await _runFrom(d, 0, ports);
  }

  Future<void> _runFrom(ShortcutRunDirective d, int from, ShortcutPorts ports) async {
    var leftApp = false;
    for (var n = from; n < d.steps.length; n++) {
      final s = d.steps[n];
      if (!s.leavesApp) {
        await ports.perform(s.action);
        continue;
      }
      if (s.cls == 'app_task') {
        // The task engine takes the phone from here; it reports as today.
        await ports.perform(s.action);
        continue;
      }
      if (leftApp) {
        if (await ports.canLaunchFromBackground()) {
          await ports.wait(gap);
        } else {
          await _keep(d.tail(n));
          await ports.notifyContinue(d, s);
          return;
        }
      }
      await ports.perform(s.action);
      leftApp = true;
      if (s.waitReturn && n + 1 < d.steps.length) {
        // The owner taps Send there and comes back; the rest waits here.
        await _keep(d.tail(n + 1));
        return;
      }
    }
  }

  /// The app is back on screen (or was started): carry on with what was
  /// left, or say what never ran if the owner took too long.
  Future<void> resumePending(ShortcutPorts ports) async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(tailKey);
    if (raw == null) return;
    await p.remove(tailKey);
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final d = ShortcutRunDirective.fromJson((j['d'] as Map).cast<String, dynamic>());
      final until = (j['until'] as num?)?.toInt() ?? 0;
      if (d.steps.isEmpty) return;
      if (clock().millisecondsSinceEpoch > until) {
        await ports.notifyUnfinished(d.name, d.steps.first.label);
        return;
      }
      await _runFrom(d, 0, ports);
    } catch (_) {}
  }

  /// Is a tail waiting for the owner to come back?
  Future<bool> hasPending() async =>
      (await SharedPreferences.getInstance()).getString(tailKey) != null;

  Future<void> _keep(ShortcutRunDirective tail) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
        tailKey,
        jsonEncode({
          'd': tail.toJson(),
          'until': clock().add(tailTtl).millisecondsSinceEpoch,
        }));
  }
}
