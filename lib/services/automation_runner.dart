import 'dart:async';

import 'package:flutter/services.dart';

import '../core/log.dart';
import 'api_service.dart';

/// "DO IT FOR ME" — uses the phone for the owner (any app, several apps,
/// ordinary settings), one checked step at a time: look at the screen, ask
/// the server for ONE next action, do it, wait for the screen to settle,
/// check it changed, repeat. It stops at a
/// done, a hand-over (payment, a password, a message to send — always the
/// owner's), a question, or Stop on the bar the service draws.
///
/// The phone is the hands (HariAccessibilityService via "hari/automation"),
/// the server is the judgement (src/automation). Both refuse payment,
/// money, secrets and sending on their own, so neither has to be trusted.
class AutomationDirective {
  final int runId;
  final String goal;
  final String app;
  final String appName;
  final String pkg;
  final String startUrl;
  final bool web;
  /// The whole phone: any app except money apps, the installer and
  /// permission pop-ups (the phone enforces those).
  final bool anyApp;
  final List<String> allowed;
  final int maxSteps;
  final bool resume;
  /// The owner's words asked to install or download an app: only then may
  /// the hands press Install / Update in the app store.
  final bool mayInstall;
  /// The app they asked to install, when the server names it: then
  /// Install is pressed only on that app's own page, never on another
  /// app's (an ad in the results). Empty: [mayInstall] alone decides.
  final String installApp;
  /// A resumed run carries on the server's step count. Null when the
  /// server did not send one — then no count is sent at all for that run
  /// (the server's old behaviour), rather than a 0 that would make it
  /// throw away the steps already done.
  final int? startSeq;

  const AutomationDirective({
    required this.runId,
    required this.goal,
    this.app = '',
    this.appName = '',
    this.pkg = '',
    this.startUrl = '',
    this.web = false,
    this.anyApp = false,
    this.allowed = const [],
    this.maxSteps = 25,
    this.resume = false,
    this.mayInstall = false,
    this.installApp = '',
    this.startSeq,
  });

  static AutomationDirective? fromEvent(Map<String, dynamic> e) {
    final id = (e['run_id'] as num?)?.toInt();
    if (id == null || id <= 0) return null;
    return AutomationDirective(
      runId: id,
      goal: e['goal'] as String? ?? '',
      app: e['app'] as String? ?? '',
      appName: e['app_name'] as String? ?? '',
      pkg: e['pkg'] as String? ?? '',
      startUrl: e['start_url'] as String? ?? '',
      web: e['web'] == true,
      anyApp: e['any'] == true,
      allowed: ((e['allowed'] as List?) ?? const [])
          .map((x) => x.toString())
          .where((x) => x.isNotEmpty)
          .toList(),
      maxSteps: (e['max_steps'] as num?)?.toInt() ?? 25,
      resume: e['resume'] == true,
      mayInstall: e['may_install'] == true,
      installApp: e['install_app'] as String? ?? '',
      startSeq: (e['seq'] as num?)?.toInt(),
    );
  }
}

class AutomationOutcome {
  /// done | handoff | waiting | failed | stopped | blocked (the app itself
  /// keeps assistants out) | unconfirmed (claimed done, not seen on
  /// screen) | no_permission | busy
  final String status;
  final String report;
  final String question;
  final String handoffKind;
  final int steps;

  const AutomationOutcome(this.status, this.report,
      {this.question = '', this.handoffKind = '', this.steps = 0});

  static AutomationOutcome fromServer(Map<String, dynamic>? m,
      {String fallback = 'failed', String fallbackReport = ''}) {
    return AutomationOutcome(
      (m?['status'] as String?) ?? fallback,
      (m?['report'] as String?)?.trim().isNotEmpty == true
          ? (m!['report'] as String).trim()
          : fallbackReport,
      question: (m?['question'] as String?) ?? '',
      handoffKind: (m?['handoff_kind'] as String?) ?? '',
      steps: (m?['step'] as num?)?.toInt() ?? 0,
    );
  }
}

/// The phone's side, behind an interface so the loop is testable.
abstract class AutomationDevice {
  Future<({bool connected, bool enabled})> status();
  Future<Map<String, String>?> resolveApp(String name);
  Future<Map<String, dynamic>> launch({String pkg = '', String url = ''});
  /// False when the phone refuses to start (an app is installing).
  Future<bool> begin(List<String> allowed, String status,
      {bool any = false, bool mayInstall = false, String installApp = ''});
  Future<void> allow(String pkg);
  Future<void> say(String text);
  Future<Map<String, dynamic>?> snapshot();
  Future<Map<String, dynamic>> act(Map<String, dynamic> action);
  Future<void> settle({int quietMs = 450, int maxMs = 4000});
  Future<bool> stopRequested();
  /// The owner's turn: the bar shows [text] and Continue. Resolves to
  /// "continue", "stop" or "timeout". Reads nothing on the screen.
  Future<String> awaitOwner(String text);
  Future<void> end({String finalText = ''});
  Future<void> bringBack();
}

/// The server's side.
abstract class AutomationApi {
  /// [seq]: how many actions the phone has received and attempted in this
  /// run so far. A retry of the same request carries the same number.
  Future<Map<String, dynamic>?> step(
      int runId, Map<String, dynamic> screen, Map<String, dynamic>? last,
      {int? seq});
  Future<Map<String, dynamic>?> finish(int runId, String reason,
      {String kind = '', String detail = ''});
  /// The owner tapped Continue after their own step (sign-in, OTP…).
  Future<Map<String, dynamic>?> ownerDone(int runId);
}

class ChannelAutomationDevice implements AutomationDevice {
  static const _ch = MethodChannel('hari/automation');

  Map<String, dynamic> _map(Object? v) =>
      v is Map ? v.map((k, x) => MapEntry(k.toString(), x)) : <String, dynamic>{};

  @override
  Future<({bool connected, bool enabled})> status() async {
    try {
      final m = _map(await _ch.invokeMethod('status'));
      return (connected: m['connected'] == true, enabled: m['enabled'] == true);
    } catch (_) {
      return (connected: false, enabled: false);
    }
  }

  @override
  Future<Map<String, String>?> resolveApp(String name) async {
    try {
      final m = await _ch.invokeMethod('resolveApp', {'name': name});
      if (m is! Map) return null;
      return m.map((k, v) => MapEntry(k.toString(), v.toString()));
    } catch (_) {
      return null;
    }
  }

  @override
  Future<Map<String, dynamic>> launch({String pkg = '', String url = ''}) async {
    try {
      return _map(await _ch.invokeMethod('launch', {'pkg': pkg, 'url': url}));
    } catch (e) {
      return {'ok': false, 'error': 'channel'};
    }
  }

  @override
  Future<bool> begin(List<String> allowed, String status,
          {bool any = false, bool mayInstall = false, String installApp = ''}) async =>
      (await _ch.invokeMethod('begin', {
        'allowed': allowed,
        'status': status,
        'any': any,
        'may_install': mayInstall,
        'install_app': installApp,
      }).catchError((_) => false)) ==
      true;

  @override
  Future<void> allow(String pkg) =>
      _ch.invokeMethod('allow', {'pkg': pkg}).catchError((_) => null);

  @override
  Future<void> say(String text) =>
      _ch.invokeMethod('say', {'text': text}).catchError((_) => null);

  @override
  Future<Map<String, dynamic>?> snapshot() async {
    try {
      final m = await _ch.invokeMethod('snapshot');
      return m == null ? null : _map(m);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<Map<String, dynamic>> act(Map<String, dynamic> action) async {
    try {
      return _map(await _ch.invokeMethod('act', action));
    } catch (_) {
      return {'ok': false, 'error': 'channel'};
    }
  }

  @override
  Future<void> settle({int quietMs = 450, int maxMs = 4000}) => _ch
      .invokeMethod('settle', {'quietMs': quietMs, 'maxMs': maxMs})
      .timeout(Duration(milliseconds: maxMs + 1500))
      .catchError((_) => null);

  @override
  Future<bool> stopRequested() async =>
      (await _ch.invokeMethod('stopRequested').catchError((_) => false)) == true;

  /// Polls the bar's two buttons four times a second — a channel call, not
  /// a look at the screen. Ten minutes without an answer is "timeout".
  @override
  Future<String> awaitOwner(String text) async {
    final shown = await _ch.invokeMethod('ownerWait', {'text': text}).catchError((_) => false);
    if (shown != true) return 'stop';
    final until = DateTime.now().add(const Duration(minutes: 10));
    while (DateTime.now().isBefore(until)) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      final a = await _ch.invokeMethod('ownerAnswer').catchError((_) => 'stop');
      if (a == 'continue' || a == 'stop') return a as String;
    }
    return 'timeout';
  }

  @override
  Future<void> end({String finalText = ''}) =>
      _ch.invokeMethod('end', {'final': finalText}).catchError((_) => null);

  @override
  Future<void> bringBack() => _ch.invokeMethod('bringBack').catchError((_) => null);

  Future<bool> openSettings() async =>
      (await _ch.invokeMethod('openSettings').catchError((_) => false)) == true;

  Future<bool> openAppInfo() async =>
      (await _ch.invokeMethod('openAppInfo').catchError((_) => false)) == true;
}

class HttpAutomationApi implements AutomationApi {
  @override
  Future<Map<String, dynamic>?> step(
          int runId, Map<String, dynamic> screen, Map<String, dynamic>? last,
          {int? seq}) =>
      // A step is one model call. The server answers within ~26 s (its
      // planner has a hard 12 s limit); 30 s here, and the loop retries
      // once with the same seq, so a lost reply is never a second step.
      ApiService.postJson('/automation/$runId/step',
          {if (seq != null) 'seq': seq, 'screen': screen, 'last': last},
          timeout: const Duration(seconds: 30));

  @override
  Future<Map<String, dynamic>?> finish(int runId, String reason,
          {String kind = '', String detail = ''}) =>
      ApiService.postJson('/automation/$runId/finish',
          {'reason': reason, 'kind': kind, 'detail': detail});

  @override
  Future<Map<String, dynamic>?> ownerDone(int runId) =>
      ApiService.postJson('/automation/$runId/owner_done', const <String, dynamic>{});
}

class AutomationRunner {
  AutomationRunner({
    AutomationDevice? device,
    AutomationApi? api,
    this.ownPackage = 'com.myassistant.myassistant',
    this.startPoll = const Duration(milliseconds: 300),
    this.stopPoll = const Duration(milliseconds: 250),
  })  : device = device ?? ChannelAutomationDevice(),
        api = api ?? HttpAutomationApi();

  static final AutomationRunner instance = AutomationRunner();

  final AutomationDevice device;
  final AutomationApi api;
  final String ownPackage;

  /// How often to look while waiting for the opened app to come to the
  /// front (20 looks at most).
  final Duration startPoll;

  /// How often Stop is checked while the server thinks about a step.
  final Duration stopPoll;

  bool _busy = false;
  bool get busy => _busy;

  /// What the bar says while a step runs.
  static String statusLine(String app, Map<String, dynamic>? action) {
    final where = app.isEmpty ? '' : '$app · ';
    if (action == null) return '${where}getting started…';
    final what = (action['what'] as String? ?? '').trim();
    final short = what.length > 28 ? '${what.substring(0, 27)}…' : what;
    switch (action['type']) {
      case 'type':
        final t = (action['text'] as String? ?? '').trim();
        return '${where}typing “${t.length > 24 ? '${t.substring(0, 23)}…' : t}”';
      case 'tap_xy':
        final l = (action['label'] as String? ?? '').trim();
        return l.isEmpty ? '${where}tapping' : '${where}tapping “${l.length > 28 ? '${l.substring(0, 27)}…' : l}”';
      case 'tap':
        return short.isEmpty ? '${where}tapping' : '${where}tapping “$short”';
      case 'scroll':
        return '${where}looking further down';
      case 'swipe':
        return '${where}swiping';
      case 'long_press':
        return short.isEmpty ? '${where}pressing' : '${where}pressing “$short”';
      case 'open_app':
        return 'opening ${action['name'] ?? 'an app'}';
      case 'home':
        return 'going to the home screen';
      case 'notifications':
        return 'opening notifications';
      case 'quick_settings':
        return 'opening quick settings';
      case 'recents':
        return 'opening recent apps';
      case 'back':
        return '${where}going back';
      default:
        return '${where}waiting for the page';
    }
  }

  /// Did anything visible change? Text, ticks and selections, in order.
  static String signature(Map<String, dynamic> snap) {
    final nodes = (snap['nodes'] as List?) ?? const [];
    final b = StringBuffer(snap['pkg'] ?? '');
    // An app with little or no element list: the picture is the screen.
    if (nodes.length < 5 && snap['shot'] is String) {
      b.write('#${(snap['shot'] as String).hashCode}');
    }
    for (final n in nodes) {
      if (n is! Map) continue;
      b
        ..write('|')
        ..write(n['text'] ?? '')
        ..write('/')
        ..write(n['desc'] ?? '')
        ..write('/')
        ..write(n['label'] ?? '')
        ..write(n['checked'] == 1 ? '+c' : '')
        ..write(n['sel'] == 1 ? '+s' : '');
    }
    return b.toString();
  }

  Future<AutomationOutcome> _finish(int runId, String reason,
      {String kind = '', String detail = '', String fallback = ''}) async {
    final m = await api.finish(runId, reason, kind: kind, detail: detail);
    return AutomationOutcome.fromServer(m,
        fallback: switch (reason) {
          'stopped' => 'stopped',
          'blocked' => 'handoff',
          'blocked_by_app' => 'blocked',
          _ => 'failed',
        },
        fallbackReport: fallback);
  }

  /// INSTANT STOP. The step call is raced against the bar's Stop, checked
  /// every [stopPoll]: pressing Stop while the server thinks (up to half a
  /// minute) answers at once instead of after the reply. The late reply
  /// is ignored — the server's step count keeps it from counting twice.
  Future<({Map<String, dynamic>? resp, bool stopped})> _stepOrStop(int runId,
      Map<String, dynamic> screen, Map<String, dynamic>? last, int? seq) async {
    var settled = false;
    Future<bool> watchStop() async {
      while (!settled) {
        await Future<void>.delayed(stopPoll);
        if (settled) return false;
        if (await device.stopRequested()) return true;
      }
      return false;
    }

    try {
      return await Future.any<({Map<String, dynamic>? resp, bool stopped})>([
        api
            .step(runId, screen, last, seq: seq)
            .then((r) => (resp: r, stopped: false)),
        watchStop().then((s) => (resp: null, stopped: s)),
      ]);
    } finally {
      settled = true;
    }
  }

  static bool _locked(Map<String, dynamic>? m) =>
      m?['access'] is Map && (m!['access'] as Map)['locked'] == true;

  Future<AutomationOutcome> run(AutomationDirective d) async {
    if (_busy) {
      return const AutomationOutcome('busy',
          "I'm already doing another task on the phone — let me finish that first.");
    }
    _busy = true;
    var finalText = '';
    // The bar belongs to someone else (an install) when begin() refused:
    // it must not be touched on the way out.
    var leaveBar = false;
    try {
      final st = await device.status();
      if (!st.connected) {
        // The run stays open on the server: the setup screen continues it
        // as soon as the switch is on.
        return const AutomationOutcome('no_permission',
            'I need your one-time permission to use other apps for you.');
      }

      final app = d.web ? 'Browser' : (d.appName.isEmpty ? '' : d.app);
      final allowed = <String>{...d.allowed};
      var pkg = d.pkg;
      // No app to start in: the task starts from the home screen.
      final fromHome = !d.web && pkg.isEmpty && d.appName.isEmpty;
      if (!d.web && pkg.isEmpty && !fromHome) {
        final hit = await device.resolveApp(d.appName.isNotEmpty ? d.appName : d.app);
        if (hit == null || (hit['pkg'] ?? '').isEmpty) {
          final o = await _finish(d.runId, 'not_installed',
              fallback: "${d.app.isEmpty ? 'That app' : d.app} isn't installed on your phone.");
          finalText = o.report;
          return o;
        }
        pkg = hit['pkg']!;
        allowed.add(pkg);
      }

      final began = await device.begin(allowed.toList(), statusLine(app, null),
          any: d.anyApp, mayInstall: d.mayInstall, installApp: d.installApp);
      if (!began) {
        // An app is installing: the two would end each other.
        leaveBar = true;
        return await _finish(d.runId, 'error',
            detail: 'install_running',
            fallback: "I'm still installing an app — ask me again once that's done.");
      }
      final opened = fromHome
          ? await device.act({'type': 'home'})
          : await device.launch(pkg: pkg, url: d.resume ? '' : d.startUrl);
      if (opened['ok'] != true) {
        final o = await _finish(d.runId,
            opened['error'] == 'not_installed' ? 'not_installed' : 'error',
            detail: '${opened['error'] ?? 'could not open'}',
            fallback: "I couldn't open ${d.app.isEmpty ? 'the app' : d.app}.");
        finalText = o.report;
        return o;
      }
      // Apps take a moment to draw their first real screen.
      await device.settle(quietMs: 700, maxMs: 6000);

      Map<String, dynamic>? last;
      String? before;
      var firstLook = true;
      // Set once any other app has been in front. Before that, this app's
      // own screen is a slow start, not the owner coming back (seen
      // 2026-09-24: a run "stopped" 1.3 s in, before the app had opened).
      var seenOther = false;
      // THE STEP COUNT the server keeps in step with: every action received
      // and tried counts (a wait, a refused tap). A retried request carries
      // the same number, so a lost reply is never recorded twice.
      int? seq = d.resume ? d.startSeq : 0;
      // The phone's own guard refusing a tap is a failed step, not the end:
      // the server picks another. The second refusal hands over.
      var phoneVetoes = 0;
      for (var i = 0; i < d.maxSteps + 2; i++) {
        if (await device.stopRequested()) {
          final o = await _finish(d.runId, 'stopped', fallback: 'Stopped, as you asked.');
          finalText = 'Stopped.';
          return o;
        }

        final lookClock = Stopwatch()..start();
        var snap = await device.snapshot();
        for (var w = 0; w < 20 && !seenOther && snap?['pkg'] == ownPackage; w++) {
          await Future<void>.delayed(startPoll);
          snap = await device.snapshot();
        }
        if (!seenOther && snap?['pkg'] == ownPackage) {
          final o = await _finish(d.runId, 'error',
              detail: 'the app did not open',
              fallback: "I couldn't get ${d.app.isEmpty ? 'the app' : d.app} to open.");
          finalText = o.report;
          return o;
        }
        if (snap != null && (snap['pkg'] as String? ?? '').isNotEmpty) seenOther = true;
        // Patience before handing over: a splash screen or a slow first
        // draw is not a payment app or the owner switching away.
        bool usable(Map<String, dynamic>? m) =>
            m != null && (m['allowed'] == true || (!d.anyApp && allowed.contains(m['pkg'])));
        for (var tries = 0; tries < 3; tries++) {
          final fg = (snap?['pkg'] as String?) ?? '';
          if (usable(snap)) break;
          // The owner came back to the assistant: they have the phone.
          if (fg == ownPackage) break;
          // The phone locked: nothing to wait for; the server says so.
          if (_locked(snap)) break;
          // A web task runs in whichever browser took the link.
          if (d.web && firstLook && fg.isNotEmpty && fg != ownPackage) {
            await device.allow(fg);
            allowed.add(fg);
            snap = await device.snapshot();
            break;
          }
          await device.settle(quietMs: 500, maxMs: 2500);
          snap = await device.snapshot();
        }
        lookClock.stop();
        firstLook = false;
        if (snap == null) {
          final o = await _finish(d.runId, 'error',
              detail: 'screen unreadable', fallback: "I couldn't read the screen, so I stopped.");
          finalText = o.report;
          return o;
        }
        if (snap['pkg'] == ownPackage) {
          final o = await _finish(d.runId, 'returned',
              fallback: 'You came back to me, so I stopped there.');
          return o;
        }
        final block = (snap['block'] as String?) ?? '';
        // A PERMISSION POP-UP IS THE OWNER'S TURN, not the end of the run.
        // The phone never reads or touches it, so it goes to the server as
        // it is — the package alone, no elements, no picture — and a phone
        // that keeps count (seq) gets owner_step back: "allow it or not,
        // then tap Continue". Ending the run here made that answer
        // impossible. (Without a count, the old hand-over stays.)
        final ownerTurn = block == 'permission' && seq != null;
        // A locked phone goes to the server as it is (nothing was read):
        // it ends the run with one plain sentence.
        if (!usable(snap) && !_locked(snap) && !ownerTurn) {
          final AutomationOutcome o;
          if (block == 'no_root') {
            // The app gave the service no window at all, three looks in a
            // row: the app keeping assistants out — not "another screen
            // took over", which is what this used to be called.
            o = await _finish(d.runId, 'blocked_by_app',
                kind: 'no_access',
                fallback: "${d.app.isEmpty ? 'This app' : d.app} doesn't let assistants "
                    'read its screen, so I stopped rather than tap blind.');
          } else if (block.isNotEmpty && block != 'left_app') {
            o = await _finish(d.runId, 'blocked', kind: block);
          } else {
            o = await _finish(d.runId, 'left_app',
                fallback: 'Another screen took over, so I stopped there.');
          }
          finalText = o.report;
          return o;
        }
        if (snap['stop'] == true) {
          final o = await _finish(d.runId, 'stopped', fallback: 'Stopped, as you asked.');
          finalText = 'Stopped.';
          return o;
        }

        // VERIFY: did the last action change anything on screen?
        final now = signature(snap);
        if (last != null) last['changed'] = before == null || now != before;
        final access = snap['access'];
        final screen = <String, dynamic>{
          'pkg': snap['pkg'],
          'keyboard': snap['keyboard'] == true,
          'nodes': snap['nodes'] ?? const [],
          if (snap['shot'] is String) 'shot': snap['shot'],
          // What the phone could see: shot ok/black/failed…, tree
          // ok/empty/no_root, locked. A black picture is never sent.
          if (access is Map) 'access': Map<String, dynamic>.from(access),
        };
        final postClock = Stopwatch()..start();
        var call = await _stepOrStop(d.runId, screen, last, seq);
        if (!call.stopped && call.resp == null) {
          await Future<void>.delayed(const Duration(milliseconds: 1500));
          call = await _stepOrStop(d.runId, screen, last, seq);
        }
        postClock.stop();
        if (call.stopped) {
          final o = await _finish(d.runId, 'stopped', fallback: 'Stopped, as you asked.');
          finalText = 'Stopped.';
          return o;
        }
        final resp = call.resp;
        if (resp == null) {
          final o = await _finish(d.runId, 'error',
              detail: 'network',
              fallback: 'I lost the connection partway, so I stopped. Everything done so far is still on screen.');
          finalText = 'Connection lost — stopped.';
          return o;
        }

        final status = resp['status'] as String? ?? 'failed';
        if (status == 'continue') {
          final action = Map<String, dynamic>.from(resp['action'] as Map? ?? const {});
          await device.say(statusLine(app, action));
          final actClock = Stopwatch()..start();
          final r = await device.act(action);
          actClock.stop();
          if (r['stop'] == true) {
            final o = await _finish(d.runId, 'stopped', fallback: 'Stopped, as you asked.');
            finalText = 'Stopped.';
            return o;
          }
          // Received and tried: it counts, whether it worked or was refused.
          if (seq != null) seq++;
          if (r['blocked'] != null) {
            final kind = '${r['blocked']}';
            phoneVetoes++;
            _logStep(d.runId, seq, snap, lookClock, postClock, act: actClock, note: 'refused');
            if (phoneVetoes >= 2) {
              // 'refused' tells the server this was the phone's own
              // second refusal, not a never-act app coming to the front —
              // so the report names the step it stopped before.
              final o = await _finish(d.runId, 'blocked', kind: kind, detail: 'refused');
              finalText = o.report;
              return o;
            }
            last = {'ok': false, 'error': 'blocked:$kind', 'blocked': kind};
            before = now;
            continue;
          }
          final settleClock = Stopwatch()..start();
          await device.settle(
              quietMs: 450, maxMs: action['type'] == 'type' ? 2500 : 4000);
          settleClock.stop();
          _logStep(d.runId, seq, snap, lookClock, postClock,
              act: actClock, settle: settleClock);
          last = {
            'ok': r['ok'] == true,
            if (r['error'] != null) 'error': '${r['error']}',
            // How it went on the phone: a plain click or a finger, and
            // whether Enter was pressed or refused (then the planner taps
            // the screen's own search button instead).
            if (r['how'] != null) 'how': '${r['how']}',
            if (r['submitted'] is bool) 'submitted': r['submitted'],
            if (r['submit_refused'] == true) 'submit_refused': true,
          };
          before = now;
          continue;
        }

        _logStep(d.runId, seq, snap, lookClock, postClock, note: status);
        if (status == 'owner_step') {
          // THE OWNER'S TURN (sign-in, OTP, CAPTCHA, a permission): the bar
          // says what to do and Stop becomes Continue. Nothing is read or
          // touched meanwhile — they may be typing an OTP. On Continue the
          // same run carries on from where they left it: no relaunch, the
          // step count unchanged.
          final report = (resp['report'] as String? ?? '').trim();
          final answer = await device.awaitOwner(
              report.isNotEmpty ? report : 'Your turn — tap Continue when done.');
          if (answer == 'timeout') {
            final o = await _finish(d.runId, 'error',
                detail: 'owner_no_answer',
                fallback: "I waited a while for you to tap Continue, so I closed this task — "
                    "ask me again when you're ready.");
            finalText = o.report;
            return o;
          }
          if (answer != 'continue') {
            final o = await _finish(d.runId, 'stopped', fallback: 'Stopped, as you asked.');
            finalText = 'Stopped.';
            return o;
          }
          var ok = await api.ownerDone(d.runId);
          if (ok == null) {
            await Future<void>.delayed(const Duration(milliseconds: 1500));
            ok = await api.ownerDone(d.runId);
          }
          if (ok == null) {
            final o = await _finish(d.runId, 'error',
                detail: 'network',
                fallback: 'I lost the connection partway, so I stopped. Everything done so far is still on screen.');
            finalText = 'Connection lost — stopped.';
            return o;
          }
          // Nothing was attempted since: nothing to report on the next look.
          last = null;
          before = null;
          continue;
        }

        final o = AutomationOutcome.fromServer(resp,
            fallbackReport: status == 'done' ? 'Done.' : 'I stopped there.');
        finalText = o.status == 'waiting' ? 'I need to ask you something' : o.report;
        return o;
      }
      final o = await _finish(d.runId, 'error',
          detail: 'too many steps', fallback: 'This was taking too many steps, so I stopped.');
      finalText = o.report;
      return o;
    } finally {
      if (!leaveBar) await device.end(finalText: finalText);
      _busy = false;
    }
  }

  /// WHERE THE TIME GOES, per step — counts and times only, never what was
  /// on the screen: the whole look, the tree walk and picture inside it,
  /// the server's answer, the action and the settle.
  static void _logStep(int runId, int? seq, Map<String, dynamic> snap,
      Stopwatch look, Stopwatch post,
      {Stopwatch? act, Stopwatch? settle, String note = ''}) {
    final nodes = (snap['nodes'] as List?)?.length ?? 0;
    final shot = snap['access'] is Map ? '${(snap['access'] as Map)['shot'] ?? ''}' : '';
    AppLog.add(
        'auto',
        'step run=$runId seq=${seq ?? '-'} look_ms=${look.elapsedMilliseconds} '
            'tree_ms=${snap['look_ms'] ?? '-'} shot_ms=${snap['shot_ms'] ?? '-'} '
            'shot=$shot shot_kb=${snap['shot_kb'] ?? 0} nodes=$nodes '
            'post_ms=${post.elapsedMilliseconds} act_ms=${act?.elapsedMilliseconds ?? '-'} '
            'settle_ms=${settle?.elapsedMilliseconds ?? '-'}${note.isEmpty ? '' : ' $note'}');
  }
}
