// The shortcut runner (build 120): the order the server fixed, the tail
// kept for the owner's return, the 1.5 s gap only when "use other apps" is
// on, a phone task last, expiry, and a resent directive ignored.
import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/models/shortcut.dart';
import 'package:myassistant/services/shortcut_runner.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakePorts implements ShortcutPorts {
  FakePorts({this.background = false});
  bool background;
  final performed = <String>[];
  final continues = <String>[];
  final unfinished = <String>[];
  final waits = <Duration>[];

  @override
  Future<void> perform(Map<String, dynamic> action) async =>
      performed.add('${action['type']}:${action['action'] ?? action['url'] ?? action['goal'] ?? ''}');

  @override
  Future<bool> canLaunchFromBackground() async => background;

  @override
  Future<void> notifyContinue(ShortcutRunDirective d, ShortcutEnvelope next) async =>
      continues.add(next.label);

  @override
  Future<void> notifyUnfinished(String name, String label) async => unfinished.add('$name: $label');

  @override
  Future<void> wait(Duration d) async => waits.add(d);
}

ShortcutEnvelope env(int i, String cls, Map<String, dynamic> action, {bool waitReturn = false}) =>
    ShortcutEnvelope(i: i, cls: cls, label: 'step $i', action: action, waitReturn: waitReturn);

ShortcutRunDirective directive(int runId, List<ShortcutEnvelope> steps) =>
    ShortcutRunDirective(runId: runId, shortcutId: 7, name: 'Office mode', steps: steps, leavesApp: true);

final silent = {'type': 'phone_control', 'action': 'ringer_silent'};
final torch = {'type': 'phone_control', 'action': 'flashlight_on'};
final chat = {'type': 'open_url', 'url': 'whatsapp://send?phone=1&text=hi'};
final maps = {'type': 'open_url', 'url': 'google.navigation:q=MG%20Road'};
final music = {'type': 'open_url', 'url': 'music://x'};
final task = {'type': 'automate', 'goal': 'add milk'};

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    ShortcutRunner.clock = DateTime.now;
    await ShortcutRunner.instance.reset();
  });

  test('in-app steps run at once, in order, and nothing is kept', () async {
    final p = FakePorts();
    await ShortcutRunner.instance.run(directive(1, [env(0, 'in_app', silent), env(1, 'in_app', torch)]), p);
    expect(p.performed, ['phone_control:ringer_silent', 'phone_control:flashlight_on']);
    expect(await ShortcutRunner.instance.hasPending(), isFalse);
  });

  test('the chat message waits for the owner to come back, then the rest carries on', () async {
    final p = FakePorts();
    await ShortcutRunner.instance.run(
        directive(2, [env(0, 'in_app', silent), env(1, 'hand_back', chat, waitReturn: true), env(2, 'stays', maps)]), p);
    expect(p.performed, ['phone_control:ringer_silent', 'open_url:${chat['url']}']);
    expect(await ShortcutRunner.instance.hasPending(), isTrue);
    await ShortcutRunner.instance.resumePending(p); // back in the app
    expect(p.performed.last, 'open_url:${maps['url']}');
    expect(await ShortcutRunner.instance.hasPending(), isFalse);
  });

  test('the tail survives a restart (it is kept on the phone)', () async {
    final p = FakePorts();
    await ShortcutRunner.instance.run(
        directive(3, [env(0, 'hand_back', chat, waitReturn: true), env(1, 'stays', maps)]), p);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(ShortcutRunner.tailKey), contains('google.navigation'));
    final fresh = FakePorts();
    await ShortcutRunner.instance.resumePending(fresh);
    expect(fresh.performed, ['open_url:${maps['url']}']);
  });

  test('a second app opens 1.5 s later only with "use other apps"; otherwise a tap carries on', () async {
    final on = FakePorts(background: true);
    await ShortcutRunner.instance.run(directive(4, [env(0, 'stays', maps), env(1, 'stays', music)]), on);
    expect(on.performed, ['open_url:${maps['url']}', 'open_url:music://x']);
    expect(on.waits, [ShortcutRunner.gap]);
    expect(on.continues, isEmpty);

    final off = FakePorts();
    await ShortcutRunner.instance.run(directive(5, [env(0, 'stays', maps), env(1, 'stays', music)]), off);
    expect(off.performed, ['open_url:${maps['url']}']);
    expect(off.continues, ['step 1']);
    await ShortcutRunner.instance.resumePending(off); // the tap
    expect(off.performed.last, 'open_url:music://x');
  });

  test('a phone task goes last, after the in-app steps', () async {
    final p = FakePorts();
    await ShortcutRunner.instance.run(directive(6, [env(0, 'in_app', torch), env(1, 'app_task', task)]), p);
    expect(p.performed, ['phone_control:flashlight_on', 'automate:add milk']);
  });

  test('a tail kept over 10 minutes is not run; the owner is told what never happened', () async {
    final p = FakePorts();
    final t0 = DateTime(2026, 9, 27, 9);
    ShortcutRunner.clock = () => t0;
    await ShortcutRunner.instance.run(
        directive(7, [env(0, 'hand_back', chat, waitReturn: true), env(1, 'stays', maps)]), p);
    ShortcutRunner.clock = () => t0.add(const Duration(minutes: 11));
    await ShortcutRunner.instance.resumePending(p);
    expect(p.performed, ['open_url:${chat['url']}']);
    expect(p.unfinished, ['Office mode: step 1']);
    expect(await ShortcutRunner.instance.hasPending(), isFalse);
  });

  test('a directive sent twice runs once', () async {
    final p = FakePorts();
    final d = directive(8, [env(0, 'in_app', silent)]);
    await ShortcutRunner.instance.run(d, p);
    await ShortcutRunner.instance.run(d, p);
    expect(p.performed, ['phone_control:ringer_silent']);
  });

  test('the directive and its tail round-trip', () {
    final d = ShortcutRunDirective.fromJson({
      'type': 'shortcut_run', 'run_id': 31, 'shortcut_id': 7, 'name': 'Office mode', 'leaves_app': true,
      'steps': [
        {'i': 0, 'class': 'in_app', 'label': 'Phone on silent', 'wait_return': false, 'action': silent},
        {'i': 1, 'class': 'hand_back', 'label': 'Chat', 'wait_return': true, 'action': chat},
      ],
    });
    expect(d.steps[1].waitReturn, isTrue);
    expect(d.steps[1].leavesApp, isTrue);
    expect(d.tail(1).steps.single.label, 'Chat');
    expect(ShortcutRunDirective.fromJson(d.toJson()).runId, 31);
  });
}
