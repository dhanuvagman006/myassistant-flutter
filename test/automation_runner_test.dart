// "Do it for me": the phone's loop — look, act, verify, report — against a
// fake phone and a fake server. The rules pinned here: every action is
// followed by a fresh look, whether the screen changed is reported back,
// and payment / Stop / another app taking over end the run with a report.
import 'package:flutter_test/flutter_test.dart';
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
  Future<bool> begin(List<String> allowed, String status, {bool any = false}) async {
    this.allowed = allowed;
    this.any = any;
    log.add('begin:${allowed.join(",")}');
    return true;
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

  @override
  Future<void> settle({int quietMs = 450, int maxMs = 4000}) async => log.add('settle');
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
  FakeApi(this.replies);
  final List<Map<String, dynamic>?> replies;
  final steps = <({Map<String, dynamic> screen, Map<String, dynamic>? last})>[];
  final finishes = <String>[];

  @override
  Future<Map<String, dynamic>?> step(
      int runId, Map<String, dynamic> screen, Map<String, dynamic>? last) async {
    steps.add((screen: screen, last: last == null ? null : Map.of(last)));
    return replies.isEmpty ? null : replies.removeAt(0);
  }

  @override
  Future<Map<String, dynamic>?> finish(int runId, String reason,
      {String kind = '', String detail = ''}) async {
    finishes.add(kind.isEmpty ? reason : '$reason:$kind');
    return {
      'status': reason == 'stopped' ? 'stopped' : (reason == 'blocked' || reason == 'left_app' ? 'handoff' : 'failed'),
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
    // Every action is followed by settling and a fresh look.
    final seq = dev.log.where((l) => l.startsWith('act') || l == 'settle' || l == 'look').toList();
    expect(seq.take(5), ['settle', 'look', 'act:type', 'settle', 'look']);
    expect(dev.log.first, 'begin:$sw');
    expect(dev.log[1], 'launch:$sw|');
    expect(dev.log.last, 'end');
    expect(dev.finalText, contains('ready to pay'), reason: 'the bar says how it ended');
    expect(dev.log.where((l) => l.startsWith('say:')).first, 'say:Swiggy · typing “veg biryani”');
  });

  test('the phone refusing a payment tap ends the run as a hand-over', () async {
    final dev = FakeDevice(screens: [screen(sw, ['Pay ₹312'])])
      ..onAct = (_) => {'ok': false, 'error': 'blocked', 'blocked': 'payment'};
    final api = FakeApi([
      {'status': 'continue', 'action': {'type': 'tap', 'id': 0}},
    ]);
    final out = await AutomationRunner(device: dev, api: api).run(swiggy());
    expect(out.status, 'handoff');
    expect(api.finishes, ['blocked:payment']);
    expect(dev.log.last, 'end');
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
    final dev = FakeDevice(screens: [screen('com.myassistant.myassistant', ['Home'])]);
    final api = FakeApi([]);
    await AutomationRunner(device: dev, api: api).run(swiggy());
    expect(api.finishes, ['returned']);
    expect(api.steps, isEmpty);
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
