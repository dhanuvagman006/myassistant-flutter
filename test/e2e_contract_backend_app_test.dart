// BACKEND <-> APP CONTRACT (2026-09-27).
//
// The server and the phone are two repos that ship on different days. Every
// directive the server sends the phone, every endpoint the phone calls, every
// method the Dart side asks Android for, and every build gate between them is
// checked here against the OTHER side's real source — so a rename, a new
// directive without a handler, or a gate that lets an old build be told to do
// something it cannot, fails a test instead of a user.
//
// The backend half reads ../myassistant-backend. Those tests are skipped (not
// failed) on a machine that only has this repo checked out.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/features/assistant/state/assistant_engine.dart';
import 'package:myassistant/services/automation_runner.dart';

final String _app = Directory.current.path;
final String _be = '${Directory.current.parent.path}/myassistant-backend';
final bool _haveBackend = File('$_be/src/tools/builtins.js').existsSync();
final Object? _needsBackend =
    _haveBackend ? null : 'the backend repo is not checked out next to this one';

/// Both repos mix CRLF and LF files; every scan below works on LF.
String _read(String path) => File(path).readAsStringSync().replaceAll('\r\n', '\n');
String _beSrc(String rel) => _read('$_be/$rel');
String _appSrc(String rel) => _read('$_app/$rel');

/// The `case '…'` labels between two markers of a Dart source.
Set<String> _cases(String src, String from, String to) {
  final start = src.indexOf(from);
  expect(start, greaterThanOrEqualTo(0), reason: 'marker not found: $from');
  final end = src.indexOf(to, start + from.length);
  expect(end, greaterThan(start), reason: 'end marker not found: $to');
  return RegExp(r"case\s+'([a-z_]+)'")
      .allMatches(src.substring(start, end))
      .map((m) => m.group(1)!)
      .toSet();
}

/// Everything the phone's event dispatcher (both voice paths) acts on.
Set<String> _engineCases() => _cases(
    _appSrc('lib/features/assistant/state/assistant_engine.dart'),
    'void _onEvent(Map<String, dynamic> e) {',
    'Future<void> _analyzeCamera(');

/// The live socket's own wire protocol (not device actions).
Set<String> _liveProtocolCases() => _cases(_appSrc('lib/services/live_service.dart'),
    'void _onFrame(dynamic frame) {', '// ---------------- playback');

/// The app build this checkout produces (pubspec `version: x.y.z+BUILD`).
int _appBuild() => int.parse(RegExp(r'^version:\s*[\d.]+\+(\d+)', multiLine: true)
    .firstMatch(_appSrc('pubspec.yaml'))!
    .group(1)!);

/// JS source between `start` and the first `end` after it.
String _slice(String src, String start, String end) {
  final i = src.indexOf(start);
  expect(i, greaterThanOrEqualTo(0), reason: 'not found in backend: $start');
  final j = src.indexOf(end, i + start.length);
  expect(j, greaterThan(i), reason: 'no "$end" after $start');
  return src.substring(i, j);
}

Set<String> _quoted(String s) =>
    RegExp(r'"([a-z_]+)"').allMatches(s).map((m) => m.group(1)!).toSet();

/// Every source the backend builds phone-bound directives in: the tools,
/// the classic voice loop's event stream and the live socket.
const _directiveSources = [
  'src/tools/builtins.js',
  'src/tools/knowledge.js',
  'src/posters/tools.js',
  'src/momentum/tools.js',
  'src/automation/service.js',
  'src/assistant/routes.js',
  'src/live/proxy.js',
];

/// `type:` literals in those files that are not phone directives: JSON-schema
/// types in tool declarations, the automation step action "wait" (a reply to
/// POST /automation/:id/step, handled by the runner, not the engine), and
/// "location", which travels the other way (the phone's own live frame —
/// checked in the test below).
const _notDirectives = {
  'object', 'string', 'number', 'integer', 'boolean', 'array', 'wait', 'location'
};

/// Directives the phone deliberately ignores, and why that is safe.
const _serverOnly = {
  // The server follows the business call itself and streams call_status.
  'fulfillment_call': 'server-followed call',
  'scheduling_call': 'server-followed call',
  // Classic path only; the same outcome is spoken as assistant_message.
  'task_update': 'narrated by assistant_message',
  // Avatar-room readiness; the room itself is LiveKit's (avatar_service).
  'avatar': 'informational',
  // Its tools are hidden while no build handles it (checked below).
  'interpreter_mode': 'tools hidden',
};

class _Call {
  const _Call(this.method, this.appFile, this.appNeedle, this.mount, this.mountNeedle,
      this.beFile, this.sub);
  final String method; // get | post | put | patch | delete
  final String appFile; // where the phone makes the call
  final String appNeedle; // the exact path text in that file
  final String mount; // server.js prefix
  final String mountNeedle; // what server.js mounts there
  final String beFile; // the router file
  final String sub; // the route inside it, as written in JS
  @override
  String toString() => '${method.toUpperCase()} $mount$sub ($appFile)';
}

const _asst = 'lib/core/network/assistant_api.dart';
const _auto = 'lib/services/automation_runner.dart';
const _post = 'lib/features/poster/poster_service.dart';
const _mom = 'lib/services/momentum_service.dart';
const _avm = 'lib/services/avatar_message_service.dart';
const _api = 'lib/services/api_service.dart';
const _eng = 'lib/features/assistant/state/assistant_engine.dart';

/// The calls the working features make (voice loop, Do it for me, photo
/// cards, Momentum, video notes, documents, vision, meetings, call notes,
/// reminders, the brief, news, quick tasks).
const _calls = <_Call>[
  // Classic voice loop (SSE) — session + every sub-post the app sends.
  _Call('post', _asst, "/assistant/session'", '/assistant', 'assistantRoutes',
      'src/assistant/routes.js', '/session'),
  _Call('post', _asst, "/assistant/\$sid/audio'", '/assistant', 'assistantRoutes',
      'src/assistant/routes.js', '/:sid/audio'),
  _Call('post', _asst, "_post('message'", '/assistant', 'assistantRoutes',
      'src/assistant/routes.js', '/:sid/message'),
  _Call('post', _asst, "_post('contacts'", '/assistant', 'assistantRoutes',
      'src/assistant/routes.js', '/:sid/contacts'),
  _Call('post', _asst, "_post('choose'", '/assistant', 'assistantRoutes',
      'src/assistant/routes.js', '/:sid/choose'),
  _Call('post', _asst, "_post('confirm'", '/assistant', 'assistantRoutes',
      'src/assistant/routes.js', '/:sid/confirm'),
  _Call('post', _asst, "_post('call_result'", '/assistant', 'assistantRoutes',
      'src/assistant/routes.js', '/:sid/call_result'),
  _Call('post', _asst, "_post('device_result'", '/assistant', 'assistantRoutes',
      'src/assistant/routes.js', '/:sid/device_result'),
  _Call('post', _asst, "_post('capabilities'", '/assistant', 'assistantRoutes',
      'src/assistant/routes.js', '/:sid/capabilities'),
  _Call('post', _asst, "_post('cancel'", '/assistant', 'assistantRoutes',
      'src/assistant/routes.js', '/:sid/cancel'),
  // Do it for me.
  _Call('post', _auto, "'/automation/\$runId/step'", '/automation',
      'require("./automation/routes")', 'src/automation/routes.js', r'/:id(\\d+)/step'),
  _Call('post', _auto, "'/automation/\$runId/finish'", '/automation',
      'require("./automation/routes")', 'src/automation/routes.js', r'/:id(\\d+)/finish'),
  _Call('post', _auto, "'/automation/\$runId/owner_done'", '/automation',
      'require("./automation/routes")', 'src/automation/routes.js', r'/:id(\\d+)/owner_done'),
  // Photo cards (build 119).
  _Call('post', _post, "'\$_base/photos'", '/posters', 'require("./routes/posters")',
      'src/routes/posters.js', '/photos'),
  _Call('post', _post, "'\$_base/photos/from-document'", '/posters',
      'require("./routes/posters")', 'src/routes/posters.js', '/photos/from-document'),
  _Call('get', _post, "'\$_base/photos/\$photoId/file?v=", '/posters',
      'require("./routes/posters")', 'src/routes/posters.js', '/photos/:id/file'),
  _Call('post', _post, "'\$_base/photos/\$photoId/colour'", '/posters',
      'require("./routes/posters")', 'src/routes/posters.js', '/photos/:id/colour'),
  _Call('post', _post, "'\$_base/photos/\$photoId/keep'", '/posters',
      'require("./routes/posters")', 'src/routes/posters.js', '/photos/:id/keep'),
  _Call('post', _post, '.post(Uri.parse(_base)', '/posters', 'require("./routes/posters")',
      'src/routes/posters.js', '/'),
  _Call('get', _post, "'\$_base/latest'", '/posters', 'require("./routes/posters")',
      'src/routes/posters.js', '/latest'),
  _Call('patch', _post, ".patch(Uri.parse('\$_base/\$id')", '/posters',
      'require("./routes/posters")', 'src/routes/posters.js', '/:id'),
  _Call('post', _post, "'\$_base/\$id/final'", '/posters', 'require("./routes/posters")',
      'src/routes/posters.js', '/:id/final'),
  _Call('delete', _post, ".delete(Uri.parse('\$_base/\$id')", '/posters',
      'require("./routes/posters")', 'src/routes/posters.js', '/:id'),
  // Momentum.
  _Call('put', _mom, "'/priorities',", '/momentum', 'require("./momentum/routes")',
      'src/momentum/routes.js', '/priorities'),
  _Call('patch', _mom, "_edit('PATCH', '/priorities/\$id'", '/momentum',
      'require("./momentum/routes")', 'src/momentum/routes.js', '/priorities/:id'),
  _Call('post', _mom, "_edit('POST', '/habits'", '/momentum', 'require("./momentum/routes")',
      'src/momentum/routes.js', '/habits'),
  _Call('put', _mom, "_edit('PUT', '/habits/\$id/check'", '/momentum',
      'require("./momentum/routes")', 'src/momentum/routes.js', '/habits/:id/check'),
  _Call('post', _mom, "_send('POST', '/focus'", '/momentum', 'require("./momentum/routes")',
      'src/momentum/routes.js', '/focus'),
  _Call('patch', _mom, "_send('PATCH', '/focus/\$id'", '/momentum',
      'require("./momentum/routes")', 'src/momentum/routes.js', '/focus/:id'),
  // Video notes and messages from the circle.
  _Call('get', _avm, "'/messages/unread'", '/messages', 'require("./routes/messages")',
      'src/routes/messages.js', '/unread'),
  _Call('post', _avm, "'/messages/read'", '/messages', 'require("./routes/messages")',
      'src/routes/messages.js', '/read'),
  _Call('post', _avm, "/avatar-profile/video'", '/avatar-profile',
      'require("./routes/avatarProfile")', 'src/routes/avatarProfile.js', '/video'),
  _Call('post', _avm, "'/avatar-profile/consent'", '/avatar-profile',
      'require("./routes/avatarProfile")', 'src/routes/avatarProfile.js', '/consent'),
  _Call('put', _avm, "'/avatar-profile/prefs'", '/avatar-profile',
      'require("./routes/avatarProfile")', 'src/routes/avatarProfile.js', '/prefs'),
  // Documents, camera, speech.
  _Call('post', _api, "'\$baseUrl/docs'", '/docs', 'require("./routes/docs")',
      'src/routes/docs.js', '/'),
  _Call('get', _api, "'\$baseUrl/docs/\$id/file'", '/docs', 'require("./routes/docs")',
      'src/routes/docs.js', '/:id/file'),
  _Call('get', 'lib/services/share_intake_service.dart', "/understanding'", '/docs',
      'require("./routes/docs")', 'src/routes/docs.js', r'/:id(\\d+)/understanding'),
  _Call('post', _eng, "'\${ApiService.baseUrl}/vision'", '/vision',
      'require("./routes/vision")', 'src/routes/vision.js', '/'),
  _Call('post', _api, "'\$baseUrl/stt'", '/stt', 'sttRoute', 'src/routes/stt.js', '/'),
  _Call('post', _api, "'\$baseUrl/tts'", '/tts', 'ttsRoute', 'src/routes/tts.js', '/'),
  _Call('post', 'lib/screens/business_card_flow.dart', '/clients/scan-card', '/clients',
      'require("./routes/clients")', 'src/routes/clients.js', '/scan-card'),
  // Meetings and call notes.
  _Call('post', 'lib/services/meetings_service.dart', '/meetings/record', '/meetings',
      'require("./meetings/routes")', 'src/meetings/routes.js', '/record'),
  _Call('get', 'lib/services/meetings_service.dart', '/meetings/\$id/pdf', '/meetings',
      'require("./meetings/routes")', 'src/meetings/routes.js', r'/:id(\\d+)/pdf'),
  _Call('post', 'lib/services/call_recording_watcher.dart', '/calls/upload', '/calls',
      'require("./routes/calls")', 'src/routes/calls.js', '/upload'),
  _Call('get', 'lib/services/call_notes_service.dart', "'/calls/recent'", '/calls',
      'require("./routes/calls")', 'src/routes/calls.js', '/recent'),
  // Reminders, the brief, promises, news, outcomes, quick tasks, contacts.
  _Call('post', _api, "'\$baseUrl/reminders'", '/reminders', 'require("./reminders/routes")',
      'src/reminders/routes.js', '/'),
  _Call('patch', _api, "'\$baseUrl/reminders/\$id'", '/reminders',
      'require("./reminders/routes")', 'src/reminders/routes.js', '/:id'),
  _Call('get', 'lib/services/brief_service.dart', "'/brief'", '/brief',
      'require("./routes/brief")', 'src/routes/brief.js', '/'),
  _Call('post', 'lib/services/brief_service.dart', "'/commitments/\${p.id}/done'",
      '/commitments', 'require("./routes/commitments")', 'src/routes/commitments.js',
      '/:id/done'),
  _Call('get', 'lib/services/news_feed.dart', '/news/feed', '/news', 'require("./routes/news")',
      'src/routes/news.js', '/feed'),
  _Call('post', _eng, "'/outcomes'", '/outcomes', 'require("./routes/outcomes")',
      'src/routes/outcomes.js', '/'),
  _Call('post', _api, "'\$baseUrl/tasks/quick'", '/tasks', 'require("./routes/tasks")',
      'src/routes/tasks.js', '/quick'),
  _Call('get', _eng, "'/contacts/resolve?name=", '/contacts', 'require("./routes/contacts")',
      'src/routes/contacts.js', '/resolve'),
  _Call('post', 'lib/services/contacts_sync_service.dart', "'/contacts/sync'", '/contacts',
      'require("./routes/contacts")', 'src/routes/contacts.js', '/sync'),
];

/// Every `"name" ->` label in the Kotlin handler block of [channel].
Set<String> _kotlinMethods(String channel) {
  final dir = Directory('$_app/android/app/src/main/kotlin');
  final out = <String>{};
  for (final f in dir.listSync(recursive: true).whereType<File>()) {
    if (!f.path.endsWith('.kt')) continue;
    final src = _read(f.path);
    final marks = RegExp(r'(?:Method|Event)Channel\([^")]*"([a-z_/]+)"').allMatches(src).toList();
    for (var i = 0; i < marks.length; i++) {
      if (marks[i].group(1) != channel) continue;
      final end = i + 1 < marks.length ? marks[i + 1].start : src.length;
      final block = src.substring(marks[i].start, end);
      for (final m in RegExp(r'^\s*("[A-Za-z_]+"(?:\s*,\s*"[A-Za-z_]+")*)\s*->', multiLine: true)
          .allMatches(block)) {
        out.addAll(RegExp(r'"([A-Za-z_]+)"').allMatches(m.group(1)!).map((x) => x.group(1)!));
      }
    }
  }
  return out;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('server -> phone directives', () {
    test('every directive the server can send has a handler on the phone', () {
      final sent = <String, String>{};
      for (final f in _directiveSources) {
        for (final m in RegExp(r'type:\s*"([a-z_]+)"').allMatches(_beSrc(f))) {
          sent.putIfAbsent(m.group(1)!, () => f);
        }
      }
      sent.removeWhere((k, _) => _notDirectives.contains(k));
      expect(sent.length, greaterThan(40), reason: 'the scan found the directives');
      final handled = {..._engineCases(), ..._liveProtocolCases()};
      final orphans = [
        for (final e in sent.entries)
          if (!handled.contains(e.key) && !_serverOnly.containsKey(e.key)) '${e.key} (${e.value})'
      ];
      expect(orphans, isEmpty,
          reason: 'the server sends these, and neither AssistantEngine._onEvent nor '
              'LiveService._onFrame handles them — the assistant would announce '
              'something the phone never does');
      // The ignore-list must not hide something the phone now handles, or
      // go stale after the server stops sending it.
      for (final k in _serverOnly.keys) {
        expect(sent.containsKey(k), isTrue, reason: '$k is no longer sent; drop it');
      }
      // "location" is phone -> server: the app sends it, the proxy reads it.
      expect(_appSrc('lib/services/live_service.dart'), contains("'type': 'location'"));
      expect(_beSrc('src/live/proxy.js'), contains('m.type === "location"'));
    }, skip: _needsBackend);

    test('interpreter_mode has no handler, so both of its tools stay hidden', () {
      expect(_engineCases(), isNot(contains('interpreter_mode')));
      final src = _beSrc('src/tools/builtins.js');
      for (final name in ['start_interpreter_mode', 'stop_interpreter_mode']) {
        final head = _slice(src, 'name: "$name"', 'async execute');
        expect(head, contains('available: () => false'),
            reason: '$name would say interpreter mode is on while the phone ignores it');
      }
    }, skip: _needsBackend);

    testWidgets('every screen the server can open by voice opens on the phone', (t) async {
      final src = _beSrc('src/tools/builtins.js');
      final tool = _slice(src, 'name: "open_app_screen"', 'registry.register({');
      final screens = {
        ..._quoted(_slice(tool, 'const ALLOWED = [', '];')),
        // Other tools open screens directly (record_meeting, save flows,
        // send_video_note).
        ...RegExp(r'screen:\s*"([a-z_]+)"').allMatches(src).map((m) => m.group(1)!),
      };
      expect(screens, containsAll(['documents', 'meeting_recorder', 'avatar_identity']));
      const tabs = {'home', 'hub', 'chat', 'settings'};
      final missing = [
        for (final s in screens)
          if (!tabs.contains(s) && !AssistantEngine.instance.canOpenAppScreen(s)) s
      ];
      expect(missing, isEmpty,
          reason: 'open_app_screen targets with no screen builder report "not available"');
    }, skip: _needsBackend != null);

    test('the four tab names map to the shell\'s real tab order', () {
      final engine = _appSrc('lib/features/assistant/state/assistant_engine.dart');
      expect(engine, contains("const tabs = {'home': 0, 'hub': 1, 'chat': 2, 'settings': 3};"));
      final shell = _appSrc('lib/shell/home_shell.dart');
      final stack = _slice(shell, 'IndexedStack(', ']');
      final order = ['HomeDashboard()', 'HubScreen()', 'ChatScreen()', 'AssistantSettingsScreen()']
          .map(stack.indexOf)
          .toList();
      expect(order.every((i) => i >= 0), isTrue, reason: 'all four tabs are in the stack');
      expect([...order]..sort(), order, reason: 'home, hub, chat, settings — in that order');
    });

    test('every phone_control action is a case on the phone; go_home/app_info go as intents',
        () {
      final src = _beSrc('src/tools/builtins.js');
      final tool = _slice(src, 'name: "phone_control"', 'registry.register({');
      final actions = _quoted(_slice(tool, 'enum: [', ']'));
      expect(actions, containsAll(['flashlight_on', 'battery', 'open_settings']));
      // These two never reach the phone as phone_control.
      expect(tool, contains('args.action === "go_home"'));
      expect(tool, contains('args.action === "app_info"'));
      final onPhone = _cases(_appSrc('lib/features/assistant/state/assistant_engine.dart'),
          'Future<void> _handlePhoneControl(', 'default:');
      final missing = actions.difference({'go_home', 'app_info'}).difference(onPhone);
      expect(missing, isEmpty, reason: 'unhandled controls are reported as failures');
      // The open_settings panels the server offers all exist natively.
      final panels = _quoted(_slice(tool.substring(tool.indexOf('panel: {')), 'enum: [', ']'));
      expect(panels, containsAll(['wifi', 'bluetooth', 'settings']));
      final kotlin = _read('$_app/android/app/src/main/kotlin/com/myassistant/myassistant/'
          'DeviceControl.kt');
      final openPanel = _slice(kotlin, 'fun openPanel(', 'return try');
      for (final p in panels.difference({'settings'})) {
        expect(openPanel, contains('"$p" ->'), reason: 'panel $p falls to plain Settings');
      }
    }, skip: _needsBackend);

    test('the automate directive the server builds is read field for field', () {
      final body = _slice(_beSrc('src/automation/service.js'), 'function directive(r', '\n}\n');
      final keys = RegExp(r'^\s{4}([a-z_]+)\s*[:,]', multiLine: true)
          .allMatches(body)
          .map((m) => m.group(1)!)
          .toSet()
        ..remove('type');
      expect(keys, containsAll(['run_id', 'goal', 'pkg', 'allowed', 'resume', 'seq']));
      final reader = _slice(_appSrc('lib/services/automation_runner.dart'),
          'static AutomationDirective? fromEvent(', '\n  }\n');
      final unread = [for (final k in keys) if (!reader.contains("e['$k']")) k];
      expect(unread, isEmpty, reason: 'fields the server sends that the phone drops');
    }, skip: _needsBackend);

    test('a server-shaped automate directive parses completely', () {
      final d = AutomationDirective.fromEvent({
        'type': 'automate',
        'run_id': 42,
        'goal': 'order a masala dosa',
        'app': 'Swiggy',
        'app_name': 'swiggy',
        'category': 'food',
        'named': true,
        'no_install': false,
        'pkg': 'in.swiggy.android',
        'start_url': '',
        'web': false,
        'any': true,
        'allowed': ['in.swiggy.android'],
        'max_steps': 30,
        'resume': false,
        'may_install': true,
        'install_app': 'Swiggy',
        'seq': 3,
      })!;
      expect(d.runId, 42);
      expect(d.pkg, 'in.swiggy.android');
      expect(d.anyApp, isTrue);
      expect(d.allowed, ['in.swiggy.android']);
      expect(d.maxSteps, 30);
      expect(d.mayInstall, isTrue);
      expect(d.installApp, 'Swiggy');
      expect(d.startSeq, 3);
      expect(d.category, 'food');
      expect(d.named, isTrue);
      expect(d.noInstall, isFalse);
      // A server that could not create the run sends no id: nothing starts.
      expect(AutomationDirective.fromEvent({'type': 'automate'}), isNull);
    });
  });

  group('build gates', () {
    test('no server gate asks for a build newer than this app', () {
      final build = _appBuild();
      final gates = <String, int>{};
      for (final f in ['src/tools/builtins.js', 'src/posters/tools.js', 'src/momentum/tools.js']) {
        for (final m in RegExp(r'minAppBuild:\s*(\d+)').allMatches(_beSrc(f))) {
          gates['$f@${m.start}'] = int.parse(m.group(1)!);
        }
      }
      int constant(String file, String name) => int.parse(
          RegExp('const $name = (\\d+);').firstMatch(_beSrc(file))!.group(1)!);
      gates['POSTER_MIN_BUILD'] = constant('src/posters/tools.js', 'POSTER_MIN_BUILD');
      gates['VIDEO_NOTE_MIN_BUILD'] = constant('src/tools/builtins.js', 'VIDEO_NOTE_MIN_BUILD');
      gates['momentum APP_BUILD'] = constant('src/momentum/tools.js', 'APP_BUILD');
      final tooNew = {
        for (final e in gates.entries)
          if (e.value > build) e.key: e.value
      };
      expect(tooNew, isEmpty, reason: 'this build ($build) would be told to update');
    }, skip: _needsBackend);

    test('photo cards are gated to the build that handles poster_* (119, not released 118)',
        () {
      final gate = int.parse(RegExp(r'const POSTER_MIN_BUILD = (\d+);')
          .firstMatch(_beSrc('src/posters/tools.js'))!
          .group(1)!);
      expect(_engineCases(),
          containsAll(['poster_pick_photo', 'poster_show', 'poster_share', 'poster_sign']));
      // Build 118 is what users have, and it has no poster_* handler.
      expect(gate, greaterThanOrEqualTo(119));
      expect(gate, lessThanOrEqualTo(_appBuild()));
      // Every poster tool carries the gate (the declaration filter) …
      final tools = _beSrc('src/posters/tools.js');
      final registered = 'registry.register('.allMatches(tools).length;
      expect('minAppBuild: POSTER_MIN_BUILD'.allMatches(tools).length, registered,
          reason: 'a poster tool without the gate is offered to build 118');
      // … and an old phone that still reaches one gets an honest refusal.
      expect(tools, contains('b > 0 && b < POSTER_MIN_BUILD'));
    }, skip: _needsBackend);

    test('the video-note screen is only opened for builds that have it', () {
      final src = _beSrc('src/tools/builtins.js');
      expect(src, contains('screen === "avatar_identity" && build < VIDEO_NOTE_MIN_BUILD'));
      expect(src, contains('Number(ctx.appBuild) >= VIDEO_NOTE_MIN_BUILD'));
    }, skip: _needsBackend);
  });

  group('phone -> server endpoints', () {
    test('every endpoint the working features call is mounted with that method', () {
      final server = _beSrc('src/server.js');
      final problems = <String>[];
      for (final c in _calls) {
        if (!_appSrc(c.appFile).contains(c.appNeedle)) {
          problems.add('$c: the app no longer contains ${c.appNeedle}');
          continue;
        }
        final mounted = RegExp('app\\.use\\(\\s*"${RegExp.escape(c.mount)}"([^;]*)\\);')
            .allMatches(server)
            .any((m) => m.group(1)!.contains(c.mountNeedle));
        if (!mounted) problems.add('$c: server.js does not mount ${c.mountNeedle} at ${c.mount}');
        final route = RegExp('router\\.${c.method}\\(\\s*"${RegExp.escape(c.sub)}"');
        if (!route.hasMatch(_beSrc(c.beFile))) {
          problems.add('$c: ${c.beFile} has no router.${c.method}("${c.sub}")');
        }
      }
      expect(problems, isEmpty);
    }, skip: _needsBackend);

    test('the SSE stream route is public (token in the URL), the rest behind auth', () {
      final server = _beSrc('src/server.js');
      expect(server, contains('app.get("/assistant/stream/:sid", assistantRoutes.streamHandler)'));
      expect(_appSrc(_asst), contains("/assistant/stream/\$_sessionId?token=\$_streamToken"));
    }, skip: _needsBackend);

    test('the photo-card contract fixture is the same file on both sides', () {
      final ours = _read('$_app/test/fixtures/poster_contract.json');
      final theirs = _beSrc('tests/fixtures/posters/contract.json');
      expect(ours, theirs, reason: 'copy tests/fixtures/posters/contract.json across');
    }, skip: _needsBackend);
  });

  group('pushes', () {
    test('every push kind the phone reacts to is one the server sends, with its fields', () {
      final pushSrc = _appSrc('lib/services/push_service.dart');
      for (final k in ['agent_message', 'scheduled_call', 'momentum', 'app_update']) {
        expect(pushSrc, contains("m.data['kind'] == '$k'"));
      }
      // Video notes open their popup on avatar '1'.
      expect(_beSrc('src/videonotes/service.js'), contains('{ kind: "agent_message", avatar: "1" }'));
      expect(pushSrc, contains("m.data['avatar'] == '1'"));
      // A scheduled call dials the name it carries.
      expect(_beSrc('src/infra/handlers.js'), contains('{ kind: "scheduled_call", name, message }'));
      expect(pushSrc, contains("m.data['name']"));
      expect(_beSrc('src/momentum/nudges.js'), contains('kind: "momentum"'));
      expect(_beSrc('src/routes/appUpdate.js'), contains('kind: "app_update"'));
      // The inbox the popup reads: media + a document URL the RECIPIENT owns.
      final inbox = _beSrc('src/routes/messages.js');
      expect(inbox, contains('media_url: `/docs/'));
      expect(_beSrc('src/videonotes/service.js'),
          contains('docs.createDocumentFromStream(to.id'));
      expect(_appSrc(_avm), contains("m['media_url']"));
    }, skip: _needsBackend);
  });

  group('Dart <-> Android', () {
    test('every platform method the Dart side calls exists on that channel natively', () {
      final problems = <String>[];
      final seenChannels = <String>{};
      var checked = 0;
      final lib = Directory('$_app/lib');
      for (final f in lib.listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith('.dart')) continue;
        final src = f.readAsStringSync();
        final channels = RegExp(r"MethodChannel\('(hari/[a-z_/]+)'")
            .allMatches(src)
            .map((m) => m.group(1)!)
            .toSet();
        if (channels.isEmpty) continue;
        seenChannels.addAll(channels);
        final native = {for (final c in channels) ..._kotlinMethods(c)};
        expect(native, isNotEmpty, reason: 'no native handler for $channels');
        final called = {
          ...RegExp(r"invoke(?:Method|ListMethod|MapMethod)(?:<[^(]*>)?\(\s*'([A-Za-z_]+)'")
              .allMatches(src)
              .map((m) => m.group(1)!),
          // DeviceControlService funnels through _call<T>('name', …).
          ...RegExp(r"_call<[^>]*>\(\s*'([A-Za-z_]+)'").allMatches(src).map((m) => m.group(1)!),
        };
        for (final m in called) {
          checked++;
          if (!native.contains(m)) {
            problems.add('${f.path.substring(_app.length + 1)}: $m on $channels');
          }
        }
      }
      // The scan really covered the app's channels (not a vacuous pass).
      expect(seenChannels.length, greaterThanOrEqualTo(11));
      expect(checked, greaterThanOrEqualTo(50));
      expect(problems, isEmpty, reason: 'MissingPluginException/notImplemented on the phone');
    });

    test('the task-voice event stream is registered natively', () {
      expect(_appSrc('lib/services/task_voice.dart'), contains("EventChannel('hari/task_voice/events'"));
      final kt = _read('$_app/android/app/src/main/kotlin/com/myassistant/myassistant/'
          'TaskVoiceBridge.kt');
      expect(kt, contains('"hari/task_voice/events"'));
    });

    test('the manifest declares every component and permission the features use', () {
      final m = _appSrc('android/app/src/main/AndroidManifest.xml');
      for (final s in [
        // Do it for me: the accessibility service, bindable only by the system.
        'android:name=".HariAccessibilityService"',
        'android.permission.BIND_ACCESSIBILITY_SERVICE',
        '@xml/hari_automation',
        // Talk while it works: a microphone foreground service.
        'android:name=".TaskVoiceService"',
        'android:foregroundServiceType="microphone"',
        'android.permission.FOREGROUND_SERVICE_MICROPHONE',
        // Widget, self-update, gift-card sharing.
        'android:name=".TaskWidgetProvider"',
        'android:name=".InstallResultReceiver"',
        'android:name=".PosterFileProvider"',
        r'android:authorities="${applicationId}.posters"',
        // Local reminders actually ring.
        'com.dexterous.flutterlocalnotifications.ScheduledNotificationReceiver',
        // Permissions behind voice tools.
        'com.android.alarm.permission.SET_ALARM',
        'android.permission.SEND_SMS',
        'android.permission.CALL_PHONE',
        'android.permission.READ_CALL_LOG',
        'android.permission.READ_CONTACTS',
        'android.permission.RECORD_AUDIO',
        'android.permission.CAMERA',
        'android.permission.WRITE_CALENDAR',
        'android.permission.PACKAGE_USAGE_STATS',
        'android.permission.REQUEST_DELETE_PACKAGES',
        'android.permission.REQUEST_INSTALL_PACKAGES',
        'android.permission.POST_NOTIFICATIONS',
        'android.permission.SCHEDULE_EXACT_ALARM',
        // Clock intents are visible to the app.
        'android.intent.action.SET_ALARM',
        'android.intent.action.SET_TIMER',
        'android.intent.action.DISMISS_ALARM',
        'android.intent.action.SHOW_ALARMS',
        // FCM banners use the channel the app creates.
        'com.google.firebase.messaging.default_notification_channel_id',
      ]) {
        expect(m, contains(s), reason: 'AndroidManifest.xml lacks $s');
      }
      expect(m, contains('android:value="hari_default"'));
      expect(_appSrc('lib/services/notification_service.dart'), contains("'hari_default'"));
      expect(
          _read('$_app/android/app/src/main/kotlin/com/myassistant/myassistant/'
              'PosterShareBridge.kt'),
          contains('ctx.packageName + ".posters"'));
    });
  });
}
