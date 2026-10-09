import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/log.dart';
import 'api_service.dart';
import 'auth_service.dart';
import 'call_history.dart';

/// One check's answer.
class CheckResult {
  const CheckResult(this.name, this.ok, this.detail);
  final String name;

  /// true pass, false fail, null "just information".
  final bool? ok;
  final String detail;

  Map<String, Object?> toJson() => {'name': name, 'ok': ok, 'detail': detail};
}

/// ─────────────────────────────────────────────────────────────────────────
///  SELF-CHECK (2026-10-09). Owner: "run a check … automatically on users
///  phone … so that we can get exactly what went wrong instead of us
///  guessing".
///
///  Runs a fixed list of checks on the phone — the app and device, the
///  server and the sign-in, the clock, the permissions — and sends them
///  with the app's recent log to the server (POST /diagnostics), where the
///  admin panel shows them per user. It runs:
///    * when the admin asks for it (GET /diagnostics/pending, on launch
///      and whenever the app comes back to the front);
///    * by itself after something went wrong (a voice answer that never
///      came), at most once every 30 minutes;
///    * from the Diagnostics screen's button.
///  Never asks for anything, never shows anything.
/// ─────────────────────────────────────────────────────────────────────────
class SelfCheck {
  SelfCheck._();
  static final SelfCheck instance = SelfCheck._();

  bool _running = false;
  DateTime _lastAuto = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastPoll = DateTime.fromMillisecondsSinceEpoch(0);

  static const _autoGap = Duration(minutes: 30);

  /// The admin asked for a check: run it. Cheap; at most once a minute.
  Future<void> runIfRequested() async {
    if (!AuthService.instance.isSignedIn) return;
    if (DateTime.now().difference(_lastPoll) < const Duration(minutes: 1)) return;
    _lastPoll = DateTime.now();
    await _sendUnsent();
    final r = await ApiService.getJson('/diagnostics/pending');
    if (r?['run'] == true) await run('admin');
  }

  /// Something went wrong: send a check, unless one went recently.
  void afterProblem(String what) {
    if (!AuthService.instance.isSignedIn) return;
    if (DateTime.now().difference(_lastAuto) < _autoGap) return;
    _lastAuto = DateTime.now();
    // A moment later, so the log holds what happened right after.
    Timer(const Duration(seconds: 4), () => unawaited(run('auto: $what')));
  }

  /// Runs every check and sends the report. True when the server got it.
  Future<bool> run(String trigger) async {
    if (_running) return false;
    _running = true;
    try {
      final checks = await collect();
      final ok = await _send(trigger, checks);
      AppLog.add('selfcheck', '$trigger: ${checks.where((c) => c.ok == false).length} failed, sent=$ok');
      return ok;
    } catch (e) {
      AppLog.add('selfcheck', '$trigger failed: $e');
      return false;
    } finally {
      _running = false;
    }
  }

  Future<List<CheckResult>> collect() async {
    final out = <CheckResult>[];
    Future<void> guard(String name, Future<CheckResult> Function() f) async {
      try {
        out.add(await f().timeout(const Duration(seconds: 12)));
      } catch (e) {
        out.add(CheckResult(name, false, 'check failed: $e'));
      }
    }

    await guard('app', () async {
      final p = await PackageInfo.fromPlatform();
      return CheckResult('app', null, '${p.version}+${p.buildNumber} (${p.packageName})');
    });
    await guard('device', () async {
      if (!Platform.isAndroid) return CheckResult('device', null, Platform.operatingSystem);
      final a = await DeviceInfoPlugin().androidInfo;
      return CheckResult('device', null,
          '${a.manufacturer} ${a.model}, Android ${a.version.release} (SDK ${a.version.sdkInt})');
    });
    await guard('server', () async {
      final sw = Stopwatch()..start();
      try {
        final r = await http
            .get(Uri.parse('${ApiService.baseUrl}/health'))
            .timeout(const Duration(seconds: 10));
        final ms = sw.elapsedMilliseconds;
        var skew = '';
        try {
          final ts = (jsonDecode(r.body) as Map)['ts'];
          if (ts is num) {
            final d = (DateTime.now().millisecondsSinceEpoch - ts.toInt() - ms ~/ 2) ~/ 1000;
            skew = ', phone clock ${d >= 0 ? '+' : ''}$d s vs server';
            if (d.abs() > 120) {
              out.add(CheckResult('clock', false, 'phone clock is off by $d s'));
            }
          }
        } catch (_) {}
        return CheckResult('server', r.statusCode == 200,
            '${ApiService.baseUrl} → ${r.statusCode} in $ms ms$skew');
      } catch (e) {
        return CheckResult('server', false,
            '${ApiService.baseUrl} unreachable after ${sw.elapsedMilliseconds} ms: $e');
      }
    });
    await guard('sign-in', () async {
      final me = await ApiService.getJson('/me', timeout: const Duration(seconds: 10));
      return CheckResult('sign-in', me != null,
          me != null ? 'signed in as #${me['id'] ?? me['user']?['id'] ?? '?'}' : '/me did not answer (token refused or no network)');
    });
    Future<void> perm(String name, Permission p) => guard(name, () async {
          final s = await p.status;
          return CheckResult(name, s.isGranted, s.name);
        });
    await perm('microphone', Permission.microphone);
    await perm('notifications', Permission.notification);
    await perm('contacts', Permission.contacts);
    await perm('battery: unrestricted', Permission.ignoreBatteryOptimizations);
    await guard('phone + call log', () async {
      final p = await CallHistory.permissions();
      if (p == null) return const CheckResult('phone + call log', null, 'unknown');
      return CheckResult('phone + call log', p['phoneState'] == true,
          p.entries.map((e) => '${e.key} ${e.value ? 'on' : 'off'}').join(', '));
    });
    return out;
  }

  static const _kUnsent = 'selfcheck_unsent';

  Future<bool> _send(String trigger, List<CheckResult> checks) async {
    final body = {
      'trigger': trigger,
      'at': DateTime.now().millisecondsSinceEpoch,
      'checks': [for (final c in checks) c.toJson()],
      'log': AppLog.tail().join('\n'),
    };
    final r = await ApiService.sendJson('/diagnostics', body: body);
    final ok = r?['ok'] == true;
    if (!ok) {
      // The server could not be reached — often the very problem. The
      // report waits on the phone and goes with the next check.
      try {
        final p = await SharedPreferences.getInstance();
        await p.setString(_kUnsent, jsonEncode(body));
      } catch (_) {}
    }
    return ok;
  }

  Future<void> _sendUnsent() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_kUnsent);
      if (raw == null) return;
      final body = jsonDecode(raw);
      if (body is! Map) return;
      final r = await ApiService.sendJson('/diagnostics', body: {...body, 'late': true});
      if (r?['ok'] == true) await p.remove(_kUnsent);
    } catch (_) {}
  }
}
