// "Do it for me": the phone's loop — look, act, verify, report — against a
// fake phone and a fake server. The rules pinned here: every action is
// followed by a fresh look, whether the screen changed is reported back,
// every step carries the phone's action count (seq), a refused tap is a
// failed step (the second one hands over), Stop answers at once even while
// the server thinks, the owner's turn reads nothing until Continue, and
// payment / Stop / another app taking over end the run with a report.
// Phase B: the first look waits for the app (not a fixed delay), each action
// waits for its own effect with its own budget, a picture-only screen's
// "changed" comes from a brightness grid, clocks ticking are not changes,
// and the upload leaves out empty keys.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/features/assistant/state/assistant_engine.dart';
import 'package:myassistant/services/automation_runner.dart';

class FakeDevice implements AutomationDevice {
  FakeDevice({this.connected = true, List<Map<String, dynamic>>? screens})
      : screens = screens ?? [];

  bool connected;
  final List<Map<String, dynamic>> screens;
  final log = <String>[];
  final acts = <Map<String, dynamic>>[];
  Map<String, dynamic> Function(Map<String, dynamic>)? onAct;
  bool stop = false;
  Map<String, String>? resolved;
  List<String> allowed = [];
  bool any = false;
  bool mayInstall = false;
  String installApp = '';
  bool beginResult = true;
  /// The owner's answer on the bar; the test completes it.
  Completer<String>? owner;
  String finalText = '';
  int _i = 0;

  @override
  Future<({bool connected, bool enabled})> status() async =>
      (connected: connected, enabled: connected);
  @override
  Future<Map<String, String>?> resolveApp(String name) async {
    log.add('resolve:$name');
    return resolved;
  }

  @override
  Future<Map<String, dynamic>> launch({String pkg = '', String url = ''}) async {
    log.add('launch:$pkg|$url');
    return {'ok': true};
  }

  @override
  Future<bool> begin(List<String> allowed, String status,
      {bool any = false, bool mayInstall = false, String installApp = ''}) async {
    this.allowed = allowed;
    this.any = any;
    this.mayInstall = mayInstall;
    this.installApp = installApp;
    log.add('begin:${allowed.join(",")}');
    return beginResult;
  }

  @override
  Future<String> awaitOwner(String text) async {
    log.add('owner:$text');
    return (owner ??= Completer<String>()).future;
  }

  @override
  Future<void> allow(String pkg) async {
    allowed.add(pkg);
    log.add('allow:$pkg');
  }

  @override
  Future<void> say(String text) async => log.add('say:$text');
  @override
  Future<Map<String, dynamic>?> snapshot() async {
    log.add('look');
    if (screens.isEmpty) return null;
    final s = screens[_i < screens.length ? _i : screens.length - 1];
    _i++;
    // Like the service: allowed unless the screen says otherwise.
    return {
      ...s,
      'allowed': s.containsKey('allowed')
          ? s['allowed']
          : (any || allowed.contains(s['pkg'])),
    };
  }

  @override
  Future<Map<String, dynamic>> act(Map<String, dynamic> action) async {
    log.add('act:${action['type']}');
    acts.add(action);
    return onAct?.call(action) ?? {'ok': true};
  }

  /// Every settle asked for, with its budget.
  final settles = <({int quiet, int max, int expect, int min})>[];
  String settleReason = 'quiet';

  @override
  Future<Map<String, dynamic>?> settle(
      {int quietMs = 450, int maxMs = 4000, int expectMs = 0, int minMs = 250}) async {
    settles.add((quiet: quietMs, max: maxMs, expect: expectMs, min: minMs));
    log.add('settle');
    return {'ms': 10, 'reason': settleReason};
  }

  @override
  Future<Map<String, dynamic>?> waitForApp(String pkg, {int maxMs = 5000}) async {
    log.add('wait:$pkg');
    return {'ok': true, 'reason': 'drawn', 'ms': 5, 'pkg': pkg};
  }

  @override
  Future<bool> stopRequested() async => stop;
  @override
  Future<void> end({String finalText = ''}) async {
    this.finalText = finalText;
    log.add('end');
  }

  @override
  Future<void> bringBack() async => log.add('bringBack');
}

class FakeApi implements AutomationApi {
  FakeApi(this.replies, {this.delay = Duration.zero});
  final List<Map<String, dynamic>?> replies;
  /// How long the "server" thinks about each step.
  final Duration delay;
  final steps = <({Map<String, dynamic> screen, Map<String, dynamic>? last, int? seq})>[];
  final finishes = <String>[];
  final log = <String>[];
  int ownerDones = 0;

  @override
  Future<Map<String, dynamic>?> step(
      int runId, Map<String, dynamic> screen, Map<String, dynamic>? last,
      {int? seq}) async {
    steps.add((screen: screen, last: last == null ? null : Map.of(last), seq: seq));
    log.add('step:${seq ?? '-'}');
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    return replies.isEmpty ? null : replies.removeAt(0);
  }

  @override
  Future<Map<String, dynamic>?> ownerDone(int runId) async {
    ownerDones++;
    log.add('owner_done');
    return {'ok': true};
  }

  @override
  Future<Map<String, dynamic>?> finish(int runId, String reason,
      {String kind = '', String detail = ''}) async {
    finishes.add(kind.isEmpty ? reason : '$reason:$kind');
    log.add('finish:$reason');
    return {
      'status': switch (reason) {
        'stopped' => 'stopped',
        'blocked' || 'left_app' => 'handoff',
        'blocked_by_app' => 'blocked',
        _ => 'failed',
      },
      'report': 'server report for $reason',
      'handoff_kind': kind,
    };
  }
}

const sw = 'in.swiggy.android';
Map<String, dynamic> screen(String pkg, List<String> texts) => {
      'pkg': pkg,
      'keyboard': false,
      'nodes': [
        for (var i = 0; i < texts.length; i++)
          {'id': i, 'text': texts[i], 'click': 1}
      ],
    };

AutomationDirective swiggy({String pkg = sw}) => AutomationDirective(
      runId: 7,
      goal: 'Book veg biryani from a 4-star restaurant',
      app: 'Swiggy',
      appName: 'swiggy',
      pkg: pkg,
      allowed: pkg.isEmpty ? const [] : [pkg],
    );

void main() {
  test('look → act → look again, reporting whether each step changed the screen', () async {
    final dev = FakeDevice(screens: [
      screen(sw, ['Search']),
      screen(sw, ['Search', 'Paradise 4.4']),
      screen(sw, ['Search', 'Paradise 4.4']), // tap did nothing visible
      screen(sw, ['Veg Biryani x1', 'Proceed to Pay']),
    ]);
    final api = FakeApi([
      {'status': 'continue', 'action': {'type': 'type', 'id': 0, 'text': 'veg biryani', 'submit': true}},
      {'status': 'continue', 'action': {'type': 'tap', 'id': 1, 'what': 'Paradise 4.4'}},
      {'status': 'continue', 'action': {'type': 'tap', 'id': 1}},
      {'status': 'handoff', 'handoff_kind': 'payment', 'report': 'Veg biryani from Paradise (4.4★) is in your cart — ready to pay.'},
    ]);
    final out = await AutomationRunner(device: dev, api: api).run(swiggy());

    expect(out.status, 'handoff');
    expect(out.report, contains('ready to pay'));
    expect(api.steps.length, 4);
    expect(api.steps[0].last, isNull);
    expect(api.steps[1].last, {'ok': true, 'changed': true});
    expect(api.steps[2].last, {'ok': true, 'changed': false});
    expect(api.steps[3].last, {'ok': true, 'changed': true});
    // The first look waits for the app itself; every action is followed by
    // settling and a fresh look.
    final seq = dev.log
        .where((l) => l.startsWith('act') || l.startsWith('wait:') || l == 'settle' || l == 'look')
        .toList();
    expect(seq.take(5), ['wait:$sw', 'look', 'act:type', 'settle', 'look']);
    expect(dev.log.first, 'begin:$sw');
    expect(dev.log[1], 'launch:$sw|');
    expect(dev.log.last, 'end');
    expect(dev.finalText, contains('ready to pay'), reason: 'the bar says how it ended');
    expect(dev.log.where((l) => l.startsWith('say:')).first, 'say:Swiggy · typing “veg biryani”');
  });

  test('a tap the phone refuses is a failed step: the loop goes on, the second refusal hands over', () async {
    final dev = FakeDevice(screens: [screen(sw, ['Pay ₹312', 'Menu'])])
      ..onAct = (a) => a['id'] == 0
          ? {'ok': false, 'error': 'blocked', 'blocked': 'payment'}
          : {'ok': true};
    final api = FakeApi([
      {'status': 'continue', 'action': {'type': 'tap', 'id': 0}},
      {'status': 'continue', 'action': {'type': 'tap', 'id': 1}},
      {'status': 'continue', 'action': {'type': 'tap', 'id': 0}},
    ]);
    final out = await AutomationRunner(device: dev, api: api).run(swiggy());
    expect(out.status, 'handoff');
    expect(api.finishes, ['blocked:payment'], reason: 'only after the second refusal');
    expect(api.steps.length, 3);
    // The server hears about the refusal as the last step's result…
    expect(api.steps[1].last,
        {'ok': false, 'error': 'blocked:payment', 'blocked': 'payment', 'changed': false});
    // …and a refused tap still counts as an action tried.
    expect(api.steps.map((s) => s.seq), [0, 1, 2]);
    expect(dev.log.last, 'end');
  });

  test('every step carries the action count; a retry after a lost reply carries the same one', () async {
    final dev = FakeDevice(screens: [
      screen(sw, ['Search']),
      screen(sw, ['Search', 'Biryani']),
      screen(sw, ['Biryani']),
    ]);
    final api = FakeApi([
      {'status': 'continue', 'action': {'type': 'wait'}},
      null, // the reply to seq 1 is lost…
      {'status': 'continue', 'action': {'type': 'tap', 'id': 1}}, // …the retry gets it
      {'status': 'done', 'report': 'ok'},
    ]);
    final out = await AutomationRunner(device: dev, api: api).run(swiggy());
    expect(out.status, 'done');
    expect(api.steps.map((s) => s.seq), [0, 1, 1, 2]);
    expect(api.steps[2].last, api.steps[1].last, reason: 'the retry is the same request');
  });

  test('a resumed run carries on the server\'s count, or sends none when it has none', () async {
    final resumed = AutomationDirective.fromEvent({
      'type': 'automate', 'run_id': 4, 'goal': 'g', 'pkg': sw, 'allowed': [sw],
      'resume': true, 'seq': 6, 'may_install': true, 'install_app': 'Swiggy',
    })!;
    expect(resumed.startSeq, 6);
    expect(resumed.mayInstall, isTrue);
    expect(resumed.installApp, 'Swiggy');
    final dev = FakeDevice(screens: [screen(sw, ['Search'])]);
    final api = FakeApi([
      {'status': 'done', 'report': 'ok'},
    ]);
    await AutomationRunner(device: dev, api: api).run(resumed);
    expect(api.steps.single.seq, 6);
    expect(dev.mayInstall, isTrue, reason: 'may_install reaches the phone');
    expect(dev.installApp, 'Swiggy', reason: 'so Install is pressed only on its own page');

    final api2 = FakeApi([
      {'status': 'done', 'report': 'ok'},
    ]);
    await AutomationRunner(device: FakeDevice(screens: [screen(sw, ['Search'])]), api: api2)
        .run(const AutomationDirective(runId: 4, goal: 'g', pkg: sw, allowed: [sw], resume: true));
    expect(api2.steps.single.seq, isNull, reason: 'no count beats a 0 that trims real steps');
  });

  test('Stop while the server thinks answers at once, not after the reply', () async {
    final dev = FakeDevice(screens: [screen(sw, ['Search'])]);
    final api = FakeApi([
      {'status': 'continue', 'action': {'type': 'tap', 'id': 0}},
    ], delay: const Duration(seconds: 5));
    final clock = Stopwatch()..start();
    Timer(const Duration(milliseconds: 100), () => dev.stop = true);
    final out = await AutomationRunner(
            device: dev, api: api, stopPoll: const Duration(milliseconds: 50))
        .run(swiggy());
    clock.stop();
    expect(out.status, 'stopped');
    expect(clock.elapsedMilliseconds, lessThan(500));
    expect(api.finishes, ['stopped']);
    expect(dev.acts, isEmpty, reason: 'the late reply is never acted on');
  });

  test("the owner's turn: Continue carries on in place, nothing is read while waiting", () async {
    final dev = FakeDevice(screens: [
      screen(sw, ['Enter OTP']),
      screen(sw, ['Veg Biryani', 'ADD']),
    ]);
    final api = FakeApi([
      {'status': 'owner_step', 'kind': 'credential',
        'report': 'Swiggy needs you to sign in or enter the OTP. Do that, then tap Continue on the bar.'},
      {'status': 'done', 'report': 'Added.'},
    ]);
    final run = AutomationRunner(device: dev, api: api).run(swiggy());
    while (!dev.log.any((l) => l.startsWith('owner:'))) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    final looks = dev.log.where((l) => l == 'look').length;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(dev.log.where((l) => l == 'look').length, looks, reason: 'no look while the owner types');
    expect(api.ownerDones, 0);
    dev.owner!.complete('continue');
    final out = await run;
    expect(out.status, 'done');
    expect(api.ownerDones, 1);
    expect(api.log, ['step:0', 'owner_done', 'step:0'], reason: 'no action was tried meanwhile');
    expect(api.steps[1].last, isNull);
    expect(dev.log.where((l) => l.startsWith('launch')).length, 1, reason: 'no relaunch');
    expect(dev.log.firstWhere((l) => l.startsWith('owner:')), contains('tap Continue'));
  });

  test("a permission pop-up is the owner's turn: sent unread, Continue carries on", () async {
    const perm = 'com.google.android.permissioncontroller';
    final dev = FakeDevice(screens: [
      // The phone never reads a permission pop-up: package only.
      {'pkg': perm, 'allowed': false, 'block': 'permission', 'keyboard': false, 'nodes': [],
        'access': {'tree': 'empty', 'locked': false, 'shot': 'none'}},
      {'pkg': perm, 'allowed': false, 'block': 'permission', 'keyboard': false, 'nodes': [],
        'access': {'tree': 'empty', 'locked': false, 'shot': 'none'}},
      {'pkg': perm, 'allowed': false, 'block': 'permission', 'keyboard': false, 'nodes': [],
        'access': {'tree': 'empty', 'locked': false, 'shot': 'none'}},
      {'pkg': perm, 'allowed': false, 'block': 'permission', 'keyboard': false, 'nodes': [],
        'access': {'tree': 'empty', 'locked': false, 'shot': 'none'}},
      screen(sw, ['Detect my location']),
    ])
      ..owner = (Completer<String>()..complete('continue'));
    final api = FakeApi([
      {'status': 'owner_step', 'kind': 'permission',
        'report': 'Swiggy is asking for a permission. Answer it, then tap Continue on the bar.'},
      {'status': 'done', 'report': 'Done.'},
    ]);
    final out = await AutomationRunner(device: dev, api: api).run(swiggy());
    expect(out.status, 'done');
    expect(api.finishes, isEmpty, reason: 'not ended as a hand-over');
    expect(api.steps.first.screen['pkg'], perm);
    expect(api.steps.first.screen['nodes'], isEmpty);
    expect(api.steps.first.screen.containsKey('shot'), isFalse);
    expect(api.log, ['step:0', 'owner_done', 'step:0']);
    expect(dev.log.where((l) => l.startsWith('owner:')).single, contains('tap Continue'));
    expect(dev.acts, isEmpty, reason: 'nothing is tapped on the pop-up');
  });

  test('a permission pop-up on a run without a step count hands over as before', () async {
    final dev = FakeDevice(screens: [
      {'pkg': 'com.android.permissioncontroller', 'allowed': false, 'block': 'permission',
        'nodes': [], 'access': {'tree': 'empty', 'locked': false, 'shot': 'none'}},
    ]);
    final api = FakeApi([]);
    final out = await AutomationRunner(device: dev, api: api).run(const AutomationDirective(
        runId: 4, goal: 'g', pkg: sw, allowed: [sw], resume: true));
    expect(out.status, 'handoff');
    expect(api.finishes, ['blocked:permission']);
    expect(api.steps, isEmpty);
  });

  test("Stop on the owner's turn stops the run", () async {
    final dev = FakeDevice(screens: [screen(sw, ['Sign in'])])
      ..owner = (Completer<String>()..complete('stop'));
    final api = FakeApi([
      {'status': 'owner_step', 'kind': 'credential', 'report': 'Your turn.'},
    ]);
    final out = await AutomationRunner(device: dev, api: api).run(swiggy());
    expect(out.status, 'stopped');
    expect(api.finishes, ['stopped']);
    expect(api.ownerDones, 0);
  });

  test('blocked and unconfirmed endings come back as they are', () async {
    for (final s in ['blocked', 'unconfirmed']) {
      final dev = FakeDevice(screens: [screen(sw, [])]);
      final api = FakeApi([
        {'status': s, 'report': 'report for $s', 'handoff_kind': s == 'blocked' ? 'secure_screen' : ''},
      ]);
      final out = await AutomationRunner(device: dev, api: api).run(swiggy());
      expect(out.status, s);
      expect(dev.finalText, 'report for $s');
    }
    expect(AssistantEngine.automationTitles['blocked'], "Can't do this one here");
    expect(AssistantEngine.automationTitles['unconfirmed'], 'Please check');
  });

  test('what the phone could see goes with the screen; a black picture is not sent', () async {
    final dev = FakeDevice(screens: [
      {
        ...screen(sw, []),
        'access': {'shot': 'black', 'tree': 'empty', 'locked': false},
        'look_ms': 40, 'shot_ms': 520,
      },
    ]);
    final api = FakeApi([
      {'status': 'blocked', 'report': 'Swiggy hides its screen from assistants for security.'},
    ]);
    await AutomationRunner(device: dev, api: api).run(swiggy());
    final sent = api.steps.single.screen;
    expect(sent['access'], {'shot': 'black', 'tree': 'empty', 'locked': false});
    expect(sent.containsKey('shot'), isFalse);
    expect(sent.containsKey('look_ms'), isFalse, reason: 'timings stay on the phone');
  });

  test('a black first look (a dark splash?) that the server answers with a wait is looked at again', () async {
    Map<String, dynamic> black() => {
          ...screen(sw, []),
          'access': {'shot': 'black', 'tree': 'empty', 'locked': false},
        };
    final dev = FakeDevice(screens: [black(), black()]);
    final api = FakeApi([
      {'status': 'continue', 'action': {'type': 'wait'}, 'expect': 'the screen to load'},
      {'status': 'blocked', 'handoff_kind': 'secure_screen',
        'report': 'Swiggy hides its screen from assistants for security.'},
    ]);
    final out = await AutomationRunner(device: dev, api: api).run(swiggy());
    expect(out.status, 'blocked');
    expect(api.steps.length, 2, reason: 'the second look is what confirms it');
    expect(api.steps[1].screen['access'], containsPair('shot', 'black'));
    expect(api.steps[1].last, {'ok': true, 'changed': false});
    expect(api.steps.map((s) => s.seq), [0, 1]);
  });

  test('an app that gives no window at all is "blocks assistants", not "another screen took over"', () async {
    final dev = FakeDevice(screens: [
      {'pkg': '', 'allowed': false, 'block': 'no_root', 'nodes': [],
        'access': {'tree': 'no_root', 'locked': false, 'shot': 'none'}},
    ]);
    final api = FakeApi([]);
    final out = await AutomationRunner(device: dev, api: api).run(swiggy());
    expect(api.finishes, ['blocked_by_app:no_access']);
    expect(out.status, 'blocked');
    expect(dev.log.where((l) => l == 'look').length, 4, reason: 'the same patience first');
  });

  test('a locked phone goes to the server as it is, unread', () async {
    final dev = FakeDevice(screens: [
      {'pkg': 'com.android.systemui', 'allowed': false, 'block': 'locked', 'nodes': [],
        'access': {'tree': 'empty', 'locked': true, 'shot': 'none'}},
    ]);
    final api = FakeApi([
      {'status': 'failed', 'report': 'Your phone locked partway, so I stopped. Unlock it and ask me again.'},
    ]);
    final out = await AutomationRunner(device: dev, api: api).run(swiggy());
    expect(out.report, contains('locked partway'));
    expect(api.steps.single.screen['access'], containsPair('locked', true));
    expect(api.steps.single.screen['nodes'], isEmpty);
    expect(dev.log.where((l) => l == 'look').length, 1, reason: 'nothing to wait for');
  });

  test('how the typing went goes back to the server', () async {
    final dev = FakeDevice(screens: [
      screen('com.whatsapp', ['Message']),
      screen('com.whatsapp', ['Message', 'hi']),
    ])
      ..onAct = (_) => {'ok': true, 'verified': true, 'submitted': false, 'submit_refused': true};
    final api = FakeApi([
      {'status': 'continue', 'action': {'type': 'type', 'id': 0, 'text': 'hi', 'submit': true}},
      {'status': 'handoff', 'report': 'The message is written — tap Send when you are happy with it.'},
    ]);
    await AutomationRunner(device: dev, api: api).run(swiggy(pkg: 'com.whatsapp'));
    expect(api.steps[1].last,
        {'ok': true, 'submitted': false, 'submit_refused': true, 'changed': true});
  });

  test('while an app installs, a task does not start — and leaves the install bar alone', () async {
    final dev = FakeDevice(screens: [screen(sw, ['Search'])])..beginResult = false;
    final api = FakeApi([]);
    final out = await AutomationRunner(device: dev, api: api).run(swiggy());
    expect(out.status, 'failed');
    expect(api.finishes, ['error']);
    expect(api.steps, isEmpty);
    expect(dev.log.where((l) => l.startsWith('launch')), isEmpty);
    expect(dev.log, isNot(contains('end')), reason: 'the bar is the install\'s');
  });

  test('Stop on the bar ends the run before the next step', () async {
    final dev = FakeDevice(screens: [screen(sw, ['Search'])])..stop = true;
    final api = FakeApi([]);
    final out = await AutomationRunner(device: dev, api: api).run(swiggy());
    expect(out.status, 'stopped');
    expect(api.steps, isEmpty);
    expect(api.finishes, ['stopped']);
  });

  test('a money app in front hands over as payment, never acts in it', () async {
    final dev = FakeDevice(screens: [
      {...screen('com.phonepe.app', ['Enter UPI PIN']), 'allowed': false, 'block': 'payment'}
    ]);
    final api = FakeApi([]);
    final out = await AutomationRunner(device: dev, api: api)
        .run(const AutomationDirective(runId: 12, goal: 'x', anyApp: true));
    expect(out.status, 'handoff');
    expect(api.finishes, ['blocked:payment']);
    expect(dev.acts.where((a) => a['type'] != 'home'), isEmpty);
  });

  test('the owner coming back to the assistant ends the run', () async {
    final dev = FakeDevice(screens: [
      screen(sw, ['Search']),
      screen('com.myassistant.myassistant', ['Home']),
    ]);
    final api = FakeApi([
      {'status': 'continue', 'action': {'type': 'tap', 'id': 0}},
    ]);
    await AutomationRunner(device: dev, api: api).run(swiggy());
    expect(api.finishes, ['returned']);
    expect(api.steps.length, 1);
  });

  test('a slow app start is waited for — our own screen first is not "coming back"', () async {
    final dev = FakeDevice(screens: [
      screen('com.myassistant.myassistant', ['Home']),
      screen('com.myassistant.myassistant', ['Home']),
      screen(sw, ['Search']),
    ]);
    final api = FakeApi([
      {'status': 'done', 'report': 'ok'},
    ]);
    final out = await AutomationRunner(device: dev, api: api, startPoll: Duration.zero).run(swiggy());
    expect(out.status, 'done');
    expect(api.finishes, isEmpty);
    expect(api.steps.single.screen['pkg'], sw);
  });

  test('an app that never comes to the front is reported, not called "you came back"', () async {
    final dev = FakeDevice(screens: [screen('com.myassistant.myassistant', ['Home'])]);
    final api = FakeApi([]);
    final out = await AutomationRunner(device: dev, api: api, startPoll: Duration.zero).run(swiggy());
    expect(out.status, 'failed');
    expect(api.finishes, ['error']);
  });

  test('a task with no app starts from the home screen and may open any app', () async {
    final dev = FakeDevice(screens: [
      screen('com.sec.android.app.launcher', ['Phone', 'Settings']),
      screen('com.android.settings', ['Connections', 'Bluetooth']),
    ]);
    final api = FakeApi([
      {'status': 'continue', 'action': {'type': 'open_app', 'name': 'Settings'}},
      {'status': 'done', 'report': 'Bluetooth is on.'},
    ]);
    final out = await AutomationRunner(device: dev, api: api).run(
        const AutomationDirective(runId: 13, goal: 'turn on bluetooth', anyApp: true));
    expect(out.status, 'done');
    expect(dev.acts.first, {'type': 'home'});
    expect(dev.acts[1], {'type': 'open_app', 'name': 'Settings'});
    expect(dev.log.where((l) => l.startsWith('launch')), isEmpty);
    expect(dev.log.where((l) => l.startsWith('say:')).first, 'say:opening Settings');
  });

  test('another app in front (after patience) stops the run, never acts in it', () async {
    final dev = FakeDevice(screens: [screen('com.instagram.android', ['Reels'])]);
    final api = FakeApi([]);
    final out = await AutomationRunner(device: dev, api: api).run(swiggy());
    expect(out.status, 'handoff');
    expect(api.finishes, ['left_app']);
    expect(dev.acts, isEmpty);
    expect(dev.log.where((l) => l == 'look').length, 4, reason: 'looked again three times first');
  });

  test('without the permission nothing starts — the setup screen takes over', () async {
    final dev = FakeDevice(connected: false);
    final api = FakeApi([]);
    final out = await AutomationRunner(device: dev, api: api).run(swiggy());
    expect(out.status, 'no_permission');
    expect(api.steps, isEmpty);
    expect(api.finishes, isEmpty, reason: 'the run stays open to continue after setup');
    expect(dev.log, ['end']);
  });

  test('an app known only by name is found on the phone, and a missing one is reported', () async {
    final dev = FakeDevice(screens: [screen('com.notebook.store', ['Cart (1)'])])
      ..resolved = {'pkg': 'com.notebook.store', 'label': 'Notebook Store'};
    final api = FakeApi([
      {'status': 'handoff', 'report': 'The notebook is in your cart.'},
    ]);
    final out = await AutomationRunner(device: dev, api: api)
        .run(const AutomationDirective(runId: 9, goal: 'x', app: 'Notebook Store', appName: 'notebook store'));
    expect(out.status, 'handoff');
    expect(dev.log.first, 'resolve:notebook store');
    expect(dev.allowed, ['com.notebook.store']);

    final dev2 = FakeDevice();
    final api2 = FakeApi([]);
    final missing = await AutomationRunner(device: dev2, api: api2)
        .run(const AutomationDirective(runId: 10, goal: 'x', app: 'Nowhere', appName: 'nowhere'));
    expect(missing.status, 'failed');
    expect(api2.finishes, ['not_installed']);
  });

  test('a web form runs in whichever browser took the link', () async {
    final dev = FakeDevice(screens: [
      screen('com.sec.android.app.sbrowser', ['Customer name']),
    ]);
    final api = FakeApi([
      {'status': 'done', 'report': 'Filled and submitted — confirmed.'},
    ]);
    final out = await AutomationRunner(device: dev, api: api).run(const AutomationDirective(
        runId: 11, goal: 'fill the form', web: true,
        startUrl: 'https://httpbin.org/forms/post', allowed: ['com.android.chrome']));
    expect(out.status, 'done');
    expect(dev.log, contains('allow:com.sec.android.app.sbrowser'));
    expect(dev.log[1], 'launch:|https://httpbin.org/forms/post');
  });

  test('a question comes back as waiting, with the question', () async {
    final dev = FakeDevice(screens: [screen(sw, ['Book a table'])]);
    final api = FakeApi([
      {'status': 'waiting', 'question': 'For how many people?', 'report': 'For how many people?'},
    ]);
    final out = await AutomationRunner(device: dev, api: api).run(swiggy());
    expect(out.status, 'waiting');
    expect(out.question, 'For how many people?');
  });

  test('the server unreachable twice stops honestly', () async {
    final dev = FakeDevice(screens: [screen(sw, ['Search'])]);
    final api = FakeApi([null, null]);
    final out = await AutomationRunner(device: dev, api: api).run(swiggy());
    expect(out.status, 'failed');
    expect(api.steps.length, 2, reason: 'one retry');
    expect(api.finishes, ['error']);
  });

  test('one task at a time', () async {
    final dev = FakeDevice(screens: [screen(sw, ['Search'])]);
    final api = FakeApi([
      {'status': 'done', 'report': 'ok'},
    ]);
    final runner = AutomationRunner(device: dev, api: api);
    final first = runner.run(swiggy());
    final second = await runner.run(swiggy());
    expect(second.status, 'busy');
    expect((await first).status, 'done');
    expect(runner.busy, isFalse);
  });

  test('the screenshot goes to the planner with the screen', () async {
    final dev = FakeDevice(screens: [
      {...screen(sw, []), 'shot': 'QUJD'},
    ]);
    final api = FakeApi([
      {'status': 'done', 'report': 'ok'},
    ]);
    await AutomationRunner(device: dev, api: api).run(swiggy());
    expect(api.steps.single.screen['shot'], 'QUJD');
    expect(AutomationRunner.statusLine('Swiggy', {'type': 'tap_xy', 'label': 'Food tab'}),
        'Swiggy · tapping “Food tab”');
    // With no element list, a new picture counts as the screen changing.
    expect(AutomationRunner.signature({'pkg': sw, 'nodes': [], 'shot': 'A'}) ==
        AutomationRunner.signature({'pkg': sw, 'nodes': [], 'shot': 'B'}), isFalse);
  });

  // ---- Faster, surer steps (phase B, 2026-09-24) ----

  String grid(int Function(int i) cell) =>
      base64Encode(Uint8List.fromList(List<int>.generate(24 * 48, cell)));

  test('a picture-only screen changes when its brightness grid does — not for a pixel or two', () {
    final a = grid((i) => (i * 7) % 200);
    expect(AutomationRunner.gridChanged(a, a), isFalse, reason: 'identical');
    // One cell (a blinking cursor) is not a change.
    final one = grid((i) => i == 100 ? 255 : (i * 7) % 200);
    expect(AutomationRunner.gridChanged(a, one), isFalse);
    // Differences of 10 levels or less (JPEG noise, a dimmed bar) are not either.
    final dim = grid((i) => (i * 7) % 200 + 8);
    expect(AutomationRunner.gridChanged(a, dim), isFalse);
    // 3% of the cells (a cart bar appearing) is.
    final bar = grid((i) => i >= 1152 - 35 ? 255 : (i * 7) % 200);
    expect(AutomationRunner.gridChanged(a, bar), isTrue);
    expect(AutomationRunner.gridChanged(a, 'not base64!'), isTrue);
  });

  test('a clock or a countdown ticking is not the screen changing; a cart count is', () {
    Map<String, dynamic> s(List<String> t) => screen(sw, t);
    bool changed(List<String> a, List<String> b) =>
        AutomationRunner.changedBetween(s(a), s(b));
    expect(changed(['12:03', 'Search'], ['12:04', 'Search']), isFalse);
    expect(changed(['Arrives by 3:05 pm'], ['Arrives by 3:06 pm']), isFalse);
    expect(changed(['Paradise · 30 mins'], ['Paradise · 35 mins']), isFalse);
    expect(changed(['Resend OTP in 45 s'], ['Resend OTP in 44 s']), isFalse);
    expect(changed(['View Cart · 1 item'], ['View Cart · 2 items']), isTrue);
    expect(changed(['ADD'], ['−  1  +']), isTrue);
  });

  test('in a picture-only app "changed" comes from the grid, not the picture\'s bytes', () {
    final g = grid((i) => (i * 3) % 180);
    Map<String, dynamic> look(String shot, String grid) =>
        {...screen(sw, []), 'shot': shot, 'grid': grid};
    // A new picture (the status bar clock) with the same grid: unchanged.
    expect(AutomationRunner.changedBetween(look('AAAA', g), look('BBBB', g)), isFalse);
    final moved = grid((i) => i < 200 ? 250 : (i * 3) % 180);
    expect(AutomationRunner.changedBetween(look('AAAA', g), look('BBBB', moved)), isTrue);
    // Another app in front is a change whatever the grid says.
    expect(AutomationRunner.changedBetween(
        look('AAAA', g), {...screen('com.other', []), 'shot': 'AAAA', 'grid': g}), isTrue);
  });

  test('a tap_xy that did nothing in a picture-only app is reported unchanged to the server', () async {
    final g = grid((i) => (i * 5) % 220);
    final dev = FakeDevice(screens: [
      {...screen(sw, []), 'shot': 'QUFB', 'grid': g},
      {...screen(sw, []), 'shot': 'QkJC', 'grid': g}, // only the clock moved
    ]);
    final api = FakeApi([
      {'status': 'continue', 'action': {'type': 'tap_xy', 'x': 500, 'y': 900, 'label': 'ADD'}},
      {'status': 'handoff', 'report': 'I could not confirm it was added.'},
    ]);
    await AutomationRunner(device: dev, api: api).run(swiggy());
    expect(api.steps[1].last, {'ok': true, 'changed': false});
    expect(api.steps[1].screen.containsKey('grid'), isFalse, reason: 'the grid stays on the phone');
  });

  test('each action waits for its own effect, with its own budget', () {
    final tap = AutomationRunner.settleFor({'type': 'tap', 'id': 3});
    expect((tap.expect, tap.max), (1200, 2500));
    final typed = AutomationRunner.settleFor({'type': 'type', 'id': 1, 'text': 'x'});
    expect(typed.max, 800, reason: 'typing without Enter shows at once');
    final searched = AutomationRunner.settleFor({'type': 'type', 'id': 1, 'text': 'x', 'submit': true});
    expect(searched.expect, 2500, reason: 'results take a moment to load');
    final wait = AutomationRunner.settleFor({'type': 'wait'});
    expect(wait.min, greaterThanOrEqualTo(1000), reason: 'a wait really waits');
    expect(AutomationRunner.settleFor({'type': 'scroll'}).expect, 800);
    for (final t in ['tap', 'tap_xy', 'type', 'wait', 'scroll', 'back', 'open_app', 'home']) {
      final b = AutomationRunner.settleFor({'type': t});
      expect(b.expect, greaterThan(0), reason: '$t waits for an effect after the action');
      expect(b.max, lessThanOrEqualTo(5000), reason: '$t never waits longer than 5 s');
    }
  });

  test('the loop asks the phone for those budgets after every action', () async {
    final dev = FakeDevice(screens: [
      screen(sw, ['Search']),
      screen(sw, ['Search', 'Biryani']),
      screen(sw, ['Biryani', 'ADD']),
    ]);
    final api = FakeApi([
      {'status': 'continue', 'action': {'type': 'type', 'id': 0, 'text': 'biryani', 'submit': true}},
      {'status': 'continue', 'action': {'type': 'tap', 'id': 1}},
      {'status': 'done', 'report': 'ok'},
    ]);
    await AutomationRunner(device: dev, api: api).run(swiggy());
    expect(dev.settles.map((s) => s.expect), [2500, 1200]);
    expect(dev.settles.map((s) => s.max), [4000, 2500]);
  });

  test('the first look waits for the app itself — no fixed delay before the first step', () async {
    final dev = FakeDevice(screens: [screen(sw, ['Search'])]);
    final api = FakeApi([
      {'status': 'done', 'report': 'ok'},
    ]);
    final clock = Stopwatch()..start();
    await AutomationRunner(device: dev, api: api).run(swiggy());
    clock.stop();
    expect(dev.log.where((l) => l.startsWith('wait:')).toList(), ['wait:$sw']);
    expect(dev.settles, isEmpty, reason: 'no fixed settle before the first look');
    expect(clock.elapsedMilliseconds, lessThan(700));
    // A task from the home screen (or the browser) waits for any app but this one.
    final dev2 = FakeDevice(screens: [screen('com.sec.android.app.launcher', ['Phone'])]);
    await AutomationRunner(device: dev2, api: FakeApi([{'status': 'done', 'report': 'ok'}]))
        .run(const AutomationDirective(runId: 13, goal: 'g', anyApp: true));
    expect(dev2.log.where((l) => l.startsWith('wait:')).toList(), ['wait:']);
  });

  test('the upload leaves out empty keys — the server reads them as their defaults', () {
    final compact = AutomationRunner.compactNodes([
      {'id': 0, 'up': -1, 'cls': 'TextView', 'text': 'Veg Biryani', 'desc': '', 'hint': '', 'rid': '',
        'label': '', 'click': 0, 'edit': 0, 'scroll': 0, 'check': 0, 'checked': 0, 'sel': 0, 'pwd': 0,
        'en': 1, 'b': [10, 20, 500, 60]},
      {'id': 1, 'up': 0, 'cls': 'Button', 'text': 'ADD', 'desc': '', 'hint': '', 'rid': 'add',
        'label': '', 'click': 1, 'edit': 0, 'scroll': 0, 'check': 0, 'checked': 0, 'sel': 0, 'pwd': 0,
        'en': 0, 'b': [800, 20, 950, 60]},
    ]);
    expect(compact[0], {'id': 0, 'cls': 'TextView', 'text': 'Veg Biryani', 'b': [10, 20, 500, 60]});
    expect(compact[1], {'id': 1, 'up': 0, 'cls': 'Button', 'text': 'ADD', 'rid': 'add', 'click': 1,
      'en': 0, 'b': [800, 20, 950, 60]});

    // 160 realistic elements: well under 25 KB, and much smaller than before.
    final nodes = [
      for (var i = 0; i < 160; i++)
        {'id': i, 'up': i % 4 == 0 ? -1 : i - 1, 'cls': i % 4 == 0 ? 'ViewGroup' : 'TextView',
          'text': i % 4 == 0 ? '' : 'Dish number $i · ₹${100 + i}', 'desc': '', 'hint': '', 'rid': '',
          'label': i % 4 == 0 ? 'Dish number $i · ₹${100 + i} · 4.${i % 10} · 30 mins' : '',
          'click': i % 4 == 0 ? 1 : 0, 'edit': 0, 'scroll': 0, 'check': 0, 'checked': 0, 'sel': 0,
          'pwd': 0, 'en': 1, 'b': [0, i * 6, 1000, i * 6 + 5]},
    ];
    final full = jsonEncode(nodes).length;
    final small = jsonEncode(AutomationRunner.compactNodes(nodes)).length;
    expect(small, lessThanOrEqualTo(25000));
    expect(small, lessThan(full * 0.7));
  });

  test('the screen goes to the server compacted', () async {
    final dev = FakeDevice(screens: [
      {'pkg': sw, 'keyboard': false, 'nodes': [
        {'id': 0, 'up': -1, 'text': 'Search', 'desc': '', 'click': 1, 'edit': 0, 'en': 1, 'b': [0, 0, 10, 10]},
      ]},
    ]);
    final api = FakeApi([
      {'status': 'done', 'report': 'ok'},
    ]);
    await AutomationRunner(device: dev, api: api).run(swiggy());
    expect(api.steps.single.screen['nodes'], [
      {'id': 0, 'text': 'Search', 'click': 1, 'b': [0, 0, 10, 10]},
    ]);
  });

  test('offline, the assistant retries less and less often, down to once a minute', () {
    expect([1, 2, 3, 4, 5, 9].map((n) => AssistantEngine.reconnectDelay(n).inSeconds).toList(),
        [4, 8, 16, 32, 60, 60]);
  });

  test('the bar describes each step in a few words', () {
    expect(AutomationRunner.statusLine('Swiggy', null), 'Swiggy · getting started…');
    expect(AutomationRunner.statusLine('Swiggy', {'type': 'tap', 'what': 'ADD'}), 'Swiggy · tapping “ADD”');
    expect(AutomationRunner.statusLine('', {'type': 'scroll'}), 'looking further down');
    expect(AutomationDirective.fromEvent({'type': 'automate'}), isNull);
    final d = AutomationDirective.fromEvent({
      'type': 'automate', 'run_id': 3, 'goal': 'g', 'pkg': sw, 'allowed': [sw], 'web': false,
    })!;
    expect(d.allowed, [sw]);
  });
}
