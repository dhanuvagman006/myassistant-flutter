import 'dart:async';

import 'package:flutter/services.dart';

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
    );
  }
}

class AutomationOutcome {
  /// done | handoff | waiting | failed | stopped | no_permission | busy
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
  Future<bool> begin(List<String> allowed, String status, {bool any = false});
  Future<void> allow(String pkg);
  Future<void> say(String text);
  Future<Map<String, dynamic>?> snapshot();
  Future<Map<String, dynamic>> act(Map<String, dynamic> action);
  Future<void> settle({int quietMs = 450, int maxMs = 4000});
  Future<bool> stopRequested();
  Future<void> end({String finalText = ''});
  Future<void> bringBack();
}

/// The server's side.
abstract class AutomationApi {
  Future<Map<String, dynamic>?> step(
      int runId, Map<String, dynamic> screen, Map<String, dynamic>? last);
  Future<Map<String, dynamic>?> finish(int runId, String reason,
      {String kind = '', String detail = ''});
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
  Future<bool> begin(List<String> allowed, String status, {bool any = false}) async =>
      (await _ch.invokeMethod('begin', {'allowed': allowed, 'status': status, 'any': any})
          .catchError((_) => false)) ==
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
          int runId, Map<String, dynamic> screen, Map<String, dynamic>? last) =>
      // A step is one model call; give it room, the phone is waiting anyway.
      ApiService.postJson('/automation/$runId/step', {'screen': screen, 'last': last},
          timeout: const Duration(seconds: 40));

  @override
  Future<Map<String, dynamic>?> finish(int runId, String reason,
          {String kind = '', String detail = ''}) =>
      ApiService.postJson('/automation/$runId/finish',
          {'reason': reason, 'kind': kind, 'detail': detail});
}

class AutomationRunner {
  AutomationRunner({
    AutomationDevice? device,
    AutomationApi? api,
    this.ownPackage = 'com.myassistant.myassistant',
    this.startPoll = const Duration(milliseconds: 300),
  })  : device = device ?? ChannelAutomationDevice(),
        api = api ?? HttpAutomationApi();

  static final AutomationRunner instance = AutomationRunner();

  final AutomationDevice device;
  final AutomationApi api;
  final String ownPackage;

  /// How often to look while waiting for the opened app to come to the
  /// front (20 looks at most).
  final Duration startPoll;

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
        fallback: reason == 'stopped' ? 'stopped' : (reason == 'blocked' ? 'handoff' : 'failed'),
        fallbackReport: fallback);
  }

  Future<AutomationOutcome> run(AutomationDirective d) async {
    if (_busy) {
      return const AutomationOutcome('busy',
          "I'm already doing another task on the phone — let me finish that first.");
    }
    _busy = true;
    var finalText = '';
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

      await device.begin(allowed.toList(), statusLine(app, null), any: d.anyApp);
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
      for (var i = 0; i < d.maxSteps + 2; i++) {
        if (await device.stopRequested()) {
          final o = await _finish(d.runId, 'stopped', fallback: 'Stopped, as you asked.');
          finalText = 'Stopped.';
          return o;
        }

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
        if (!usable(snap)) {
          final block = (snap['block'] as String?) ?? '';
          final o = block.isNotEmpty && block != 'left_app'
              ? await _finish(d.runId, 'blocked', kind: block)
              : await _finish(d.runId, 'left_app',
                  fallback: 'Another screen took over, so I stopped there.');
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
        final screen = {
          'pkg': snap['pkg'],
          'keyboard': snap['keyboard'] == true,
          'nodes': snap['nodes'] ?? const [],
          if (snap['shot'] is String) 'shot': snap['shot'],
        };
        var resp = await api.step(d.runId, screen, last);
        if (resp == null) {
          await Future<void>.delayed(const Duration(milliseconds: 1500));
          resp = await api.step(d.runId, screen, last);
        }
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
          final r = await device.act(action);
          if (r['blocked'] != null) {
            final o = await _finish(d.runId, 'blocked', kind: '${r['blocked']}');
            finalText = o.report;
            return o;
          }
          if (r['stop'] == true) {
            final o = await _finish(d.runId, 'stopped', fallback: 'Stopped, as you asked.');
            finalText = 'Stopped.';
            return o;
          }
          await device.settle(
              quietMs: 450, maxMs: action['type'] == 'type' ? 2500 : 4000);
          last = {
            'ok': r['ok'] == true,
            if (r['error'] != null) 'error': '${r['error']}',
          };
          before = now;
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
      await device.end(finalText: finalText);
      _busy = false;
    }
  }
}
