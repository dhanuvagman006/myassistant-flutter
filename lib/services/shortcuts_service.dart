import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/shortcut.dart';
import 'api_service.dart';
import 'auth_service.dart';

/// What the server answered: the HTTP status (0 = never reached it) and
/// its JSON body.
class ShortcutsReply {
  const ShortcutsReply(this.status, this.json);
  final int status;
  final Map<String, dynamic>? json;
  bool get ok => status >= 200 && status < 300 && json != null && json!['ok'] == true;
  String? get error => json?['error'] as String?;
  Map<String, dynamic> get data => ((json?['data'] as Map?) ?? const {}).cast<String, dynamic>();
}

/// Sends one request to /shortcuts{path}. Replaced in tests.
typedef ShortcutsTransport = Future<ShortcutsReply> Function(String method, String path,
    {Map<String, dynamic>? body});

/// The answer to a Run tap: a directive to perform, a question to ask
/// first (confirm), or an error line.
class ShortcutRunReply {
  const ShortcutRunReply({this.runId = 0, this.status = '', this.report = '', this.confirm, this.directive, this.error});
  final int runId;
  final String status;
  final String report;
  final String? confirm;
  final ShortcutRunDirective? directive;
  final String? error;
  bool get needsYes => confirm != null;
}

/// ─────────────────────────────────────────────────────────────────────────
///  SHORTCUTS — the Hub list and its Run, Rename and Delete (build 120).
///  The server holds the truth; the last list is kept for an instant Hub
///  and cleared on sign-out.
/// ─────────────────────────────────────────────────────────────────────────
class ShortcutsService extends ChangeNotifier {
  ShortcutsService._() {
    AuthService.instance.onSignOut(reset);
  }
  static final ShortcutsService instance = ShortcutsService._();

  static const cacheKey = 'shortcuts_cache_v1';

  /// How requests reach the server (tests swap in their own).
  static ShortcutsTransport transport = _http;

  List<Shortcut> _list = const [];
  bool loaded = false;
  bool failed = false;
  int maxShortcuts = 50;
  int _generation = 0;

  List<Shortcut> get shortcuts => _list;

  /// Shows [list] as if the server had sent it (tests and screenshots).
  @visibleForTesting
  void debugSeed(List<Shortcut> list) {
    _list = list;
    loaded = true;
    failed = false;
    notifyListeners();
  }
  bool get full => _list.length >= maxShortcuts;

  /// The saved copy first, then the server.
  Future<void> load() async {
    if (!loaded) {
      try {
        final p = await SharedPreferences.getInstance();
        final raw = p.getString(cacheKey);
        if (raw != null) {
          _list = (jsonDecode(raw) as List)
              .whereType<Map>()
              .map((m) => Shortcut.fromJson(m.cast<String, dynamic>()))
              .toList();
          loaded = true;
          notifyListeners();
        }
      } catch (_) {}
    }
    await refresh();
  }

  Future<void> refresh() async {
    final gen = _generation;
    final r = await transport('GET', '');
    if (gen != _generation) return;
    if (!r.ok) {
      failed = !loaded;
      notifyListeners();
      return;
    }
    _list = ((r.json!['shortcuts'] as List?) ?? const [])
        .whereType<Map>()
        .map((m) => Shortcut.fromJson(m.cast<String, dynamic>()))
        .toList();
    maxShortcuts = ((r.json!['limits'] as Map?)?['max_shortcuts'] as num?)?.toInt() ?? 50;
    loaded = true;
    failed = false;
    notifyListeners();
    unawaited(_save());
  }

  Future<void> _save() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(cacheKey, jsonEncode(_list.map((s) => s.toJson()).toList()));
    } catch (_) {}
  }

  /// Rename. Null on success, else a plain line for the user.
  Future<String?> rename(Shortcut s, String name) async {
    final r = await transport('PATCH', '/${s.id}', body: {'version': s.version, 'name': name.trim()});
    if (r.ok) {
      await refresh();
      return null;
    }
    if (r.status == 409) await refresh();
    return lineFor(r.error, r.data);
  }

  /// Delete (the screen's own dialog is the confirmation).
  Future<bool> delete(Shortcut s) async {
    final before = _list;
    _list = _list.where((x) => x.id != s.id).toList();
    notifyListeners();
    final r = await transport('DELETE', '/${s.id}');
    if (!r.ok && r.status != 404) {
      _list = before;
      notifyListeners();
      return false;
    }
    unawaited(_save());
    return true;
  }

  Future<ShortcutRunReply> run(Shortcut s) async =>
      _runReply(await transport('POST', '/${s.id}/run', body: {'surface': 'screen'}));

  Future<ShortcutRunReply> approve(int runId) async =>
      _runReply(await transport('POST', '/runs/$runId/approve'));

  Future<void> decline(int runId) async {
    await transport('POST', '/runs/$runId/decline');
  }

  ShortcutRunReply _runReply(ShortcutsReply r) {
    if (!r.ok) {
      return ShortcutRunReply(
          error: r.status == 410 ? 'That was a while ago — tap Run again.' : lineFor(r.error, r.data));
    }
    final run = ((r.json!['run'] as Map?) ?? const {}).cast<String, dynamic>();
    final confirm = (run['confirm'] as Map?)?['summary'] as String?;
    final d = r.json!['directive'] as Map?;
    return ShortcutRunReply(
      runId: (run['id'] as num?)?.toInt() ?? 0,
      status: (run['status'] ?? '').toString(),
      report: (run['report'] ?? '').toString(),
      confirm: confirm,
      directive: d == null ? null : ShortcutRunDirective.fromJson(d.cast<String, dynamic>()),
    );
  }

  /// A server error code as a plain line.
  static String lineFor(String? code, [Map<String, dynamic> data = const {}]) {
    switch (code) {
      case 'name_taken':
        return 'That name is already used.';
      case 'reserved_name':
        return "That name is one of my own commands — try another.";
      case 'bad_name':
        return 'A name is 2 to 40 letters.';
      case 'too_many_shortcuts':
        return 'You have 50 shortcuts — remove one to add another.';
      case 'needs_detail':
        return (data['question'] as String?) ?? 'That step needs one more detail.';
      case 'step_not_allowed':
        return (data['why'] as String?) ?? "That can't be part of a shortcut.";
      case 'stale':
        return 'It changed a moment ago — try again.';
      case 'app_too_old':
        return 'This needs the latest app update.';
      case 'daily_limit':
        return "That's enough shortcut runs for today.";
      case 'last_task_not_finished':
        return "That task didn't finish, so there's nothing to save yet.";
      case 'already_a_shortcut':
        return 'That task is already a shortcut.';
      case 'nothing_to_save':
      case 'too_old':
        return 'Do the task once more, then save it.';
      case 'money_app':
        return "Tasks in money apps can't be saved.";
      default:
        return "Couldn't do that just now — try again.";
    }
  }

  Future<void> reset() async {
    _generation++;
    _list = const [];
    loaded = false;
    failed = false;
    try {
      final p = await SharedPreferences.getInstance();
      await p.remove(cacheKey);
    } catch (_) {}
    notifyListeners();
  }

  static final http.Client _client = http.Client();
  static Future<ShortcutsReply> _http(String method, String path, {Map<String, dynamic>? body}) async {
    try {
      final req = http.Request(method, Uri.parse('${ApiService.baseUrl}/shortcuts$path'))
        ..headers.addAll(ApiService.authHeaders);
      if (body != null) req.body = jsonEncode(body);
      final res = await http.Response.fromStream(
          await _client.send(req).timeout(const Duration(seconds: 25)));
      ApiService.noteAuthStatus(res.statusCode);
      Map<String, dynamic>? json;
      try {
        final d = jsonDecode(res.body);
        if (d is Map<String, dynamic>) json = d;
      } catch (_) {}
      return ShortcutsReply(res.statusCode, json);
    } catch (_) {
      return const ShortcutsReply(0, null);
    }
  }
}
