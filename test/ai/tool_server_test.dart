import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:myassistant/ai/tool_server.dart';
import 'package:myassistant/ai/types.dart';

class _Server {
  final requests = <http.Request>[];
  final statuses = <int>[];
  int status = 200;
  Object? body = const {'ok': true};
  bool down = false;

  ToolServer build() => ToolServer(
        client: MockClient((r) async {
          requests.add(r);
          if (down) throw http.ClientException('no route to host');
          return http.Response(body is String ? body as String : jsonEncode(body), status,
              headers: {'content-type': 'application/json'});
        }),
        baseUrl: () => 'https://api.test',
        headers: () => {'Authorization': 'Bearer tok', 'X-App-Build': '123'},
        onStatus: statuses.add,
      );

  Map<String, dynamic> get sent => jsonDecode(requests.last.body) as Map<String, dynamic>;
}

void main() {
  late _Server s;
  setUp(() => s = _Server());

  group('/ai/context', () {
    test('sends the turn and the phone, reads the whole context', () async {
      s.body = {
        'sessionId': 's1',
        'turnId': 't1',
        'route': {'shortcut': null},
        'system': 'You are Hari.',
        'nano': 'Be brief. [[CLOUD]] when…',
        'tools': [
          {
            'name': 'set_reminder',
            'description': 'Sets one.',
            'parameters': {'type': 'object', 'properties': {}},
          },
          {'description': 'nameless: dropped'},
        ],
        'history': [
          {'role': 'user', 'text': 'hi'},
          {'role': 'model', 'text': 'Hello!'},
          {'role': 'user', 'text': ''},
        ],
      };
      final ctx = await s.build().context(
        text: 'remind me',
        mode: 'voice',
        sessionId: 's0',
        attachments: const [AiAttachment(kind: 'image', mimeType: 'image/jpeg')],
        untrusted: true,
        shared: true,
        device: const {
          'lat': 9.93,
          'lng': 76.26,
          'caps': {'granted': ['calendar'], 'denied': []},
        },
      );
      final r = s.requests.single;
      expect(r.method, 'POST');
      expect(r.url.toString(), 'https://api.test/ai/context');
      expect(r.headers['Authorization'], 'Bearer tok');
      expect(r.headers['Content-Type'], startsWith('application/json'));
      final b = s.sent;
      expect(b['text'], 'remind me');
      expect(b['mode'], 'voice');
      expect(b['sessionId'], 's0');
      expect(b['platform'], 'android');
      expect(b['tz'], isA<int>());
      expect(b['build'], isA<int>());
      expect(b['lat'], 9.93);
      expect(b['caps'], {'granted': ['calendar'], 'denied': []});
      expect(b['attachments'], [
        {'kind': 'image', 'mime': 'image/jpeg'},
      ]);
      expect(b['untrusted'], isTrue);
      expect(b['shared'], isTrue);
      expect(b.containsKey('expressive'), isFalse, reason: 'asked for only when it will be spoken');

      expect(ctx!.sessionId, 's1');
      expect(ctx.turnId, 't1');
      expect(ctx.shortcut, isNull);
      expect(ctx.system, 'You are Hari.');
      expect(ctx.tools.single.name, 'set_reminder');
      expect(ctx.tools.single.parameters['type'], 'object');
      expect(ctx.history, const [ChatTurn('user', 'hi'), ChatTurn('model', 'Hello!')]);
      expect(ctx.fromServer, isTrue);
    });

    test("the server's shortcut; nothing on failure", () async {
      s.body = {'sessionId': 's', 'turnId': 't', 'route': {'shortcut': 'Office Mode'}};
      expect((await s.build().context(text: 'office mode', mode: 'chat'))!.shortcut, 'Office Mode');
      s.status = 500;
      expect(await s.build().context(text: 'x', mode: 'chat'), isNull);
      s.down = true;
      expect(await s.build().context(text: 'x', mode: 'chat'), isNull);
    });
  });

  group('/ai/tool', () {
    test('a call with its approval token; the result as the model reads it', () async {
      s.body = {
        'ok': true,
        'result': {'reminderId': 7},
        'speak': 'Reminder set.',
        'deviceAction': {'type': 'open_camera'},
      };
      final res = await s.build().tool(
        sessionId: 's1',
        turnId: 't1',
        name: 'set_reminder',
        args: const {'text': 'call amma'},
        userText: 'yes',
        approvalToken: 'appr.ok',
      );
      expect(s.requests.single.url.path, '/ai/tool');
      expect(s.sent, {
        'sessionId': 's1',
        'turnId': 't1',
        'name': 'set_reminder',
        'args': {'text': 'call amma'},
        'userText': 'yes',
        'approvalToken': 'appr.ok',
      });
      expect(res.ok, isTrue);
      expect(res.speak, 'Reminder set.');
      expect(res.deviceAction, {'type': 'open_camera'});
      expect(res.toFunctionResponse(), {'reminderId': 7, 'ok': true});
    });

    test('needs confirmation: summary and token kept, the model told', () async {
      s.body = {
        'ok': false,
        'result': {},
        'needsConfirmation': true,
        'summary': "Send 'hi' to Amma",
        'approvalToken': 'hmac.123',
      };
      final res = await s.build().tool(
          sessionId: 's', turnId: 't', name: 'send_message', args: const {}, userText: 'x');
      expect(s.sent.containsKey('approvalToken'), isFalse);
      expect(res.needsConfirmation, isTrue);
      expect(res.summary, "Send 'hi' to Amma");
      expect(res.approvalToken, 'hmac.123');
      expect(res.toFunctionResponse(), {
        'ok': false,
        'needsConfirmation': true,
        'summary': "Send 'hi' to Amma",
      });
    });

    test('refusals and failures come back as ok == false with the reason', () async {
      s
        ..status = 400
        ..body = {'error': 'unknown tool'};
      var res = await s.build().tool(
          sessionId: 's', turnId: 't', name: 'nope', args: const {}, userText: 'x');
      expect([res.ok, res.error, res.status], [false, 'unknown tool', 400]);
      expect(res.toFunctionResponse(), {'ok': false, 'error': 'unknown tool'});
      expect(s.statuses, [400]);

      s
        ..status = 502
        ..body = '<html>bad gateway</html>';
      res = await s.build().tool(
          sessionId: 's', turnId: 't', name: 'x', args: const {}, userText: 'x');
      expect([res.ok, res.status], [false, 502]);

      s.down = true;
      res = await s.build().tool(
          sessionId: 's', turnId: 't', name: 'x', args: const {}, userText: 'x');
      expect([res.ok, res.status], [false, 0]);
      expect(res.error, contains('could not be reached'));
    });

    test('a 401 is reported so the session check can run', () async {
      s
        ..status = 401
        ..body = {'error': 'unauthorized'};
      await s.build().tool(sessionId: 's', turnId: 't', name: 'x', args: const {}, userText: 'x');
      expect(s.statuses, [401]);
    });
  });

  group('/ai/turn', () {
    test('records the turn and returns the claim-checked reply', () async {
      s.body = {'ok': true, 'reply': "I couldn't set that reminder.", 'corrected': true};
      final receipt = await s.build().recordTurn(
        sessionId: 's1',
        turnId: 't1',
        user: 'remind me',
        reply: "I've set it.",
        engine: 'nano',
        tools: const [
          {'name': 'set_reminder', 'ok': false},
        ],
        latencyMs: 812,
        mode: 'voice',
      );
      expect(s.requests.single.url.path, '/ai/turn');
      expect(s.sent, {
        'sessionId': 's1',
        'turnId': 't1',
        'user': 'remind me',
        'reply': "I've set it.",
        'engine': 'nano',
        'tools': [
          {'name': 'set_reminder', 'ok': false},
        ],
        'latencyMs': 812,
        'mode': 'voice',
      });
      expect(receipt!.reply, "I couldn't set that reminder.");
      expect(receipt.corrected, isTrue);
    });

    test('an empty corrected reply keeps ours; a failure is null', () async {
      s.body = {'ok': true, 'reply': '', 'corrected': false};
      final r = await s.build().recordTurn(
          sessionId: 's', turnId: 't', user: 'u', reply: 'Mine.', engine: 'cloud',
          tools: const [], latencyMs: 1, mode: 'chat');
      expect(r!.reply, 'Mine.');
      s.status = 503;
      expect(
          await s.build().recordTurn(
              sessionId: 's', turnId: 't', user: 'u', reply: 'Mine.', engine: 'cloud',
              tools: const [], latencyMs: 1, mode: 'chat'),
          isNull);
    });

    test('"" with corrected: the model chose to stay silent — nothing to say', () async {
      s.body = {'ok': true, 'reply': '', 'corrected': true};
      final r = await s.build().recordTurn(
          sessionId: 's', turnId: 't', user: 'u', reply: 'Mine.', engine: 'cloud',
          tools: const [], latencyMs: 1, mode: 'voice');
      expect(r!.reply, '');
      expect(r.corrected, isTrue);
    });
  });

  group('/ai/firebase-token and /ai/config', () {
    test('the custom token, or null when Firebase is unavailable', () async {
      s.body = {'token': 'custom.jwt', 'uid': 'u42'};
      final t = await s.build().firebaseToken();
      expect(s.requests.single.url.path, '/ai/firebase-token');
      expect(s.requests.single.method, 'POST');
      expect([t!.token, t.uid], ['custom.jwt', 'u42']);
      s
        ..status = 503
        ..body = {'error': 'firebase unavailable'};
      expect(await s.build().firebaseToken(), isNull);
    });

    test('GET /ai/config', () async {
      s.body = {'nano': {'enabled': true}};
      final j = await s.build().config();
      expect(s.requests.single.method, 'GET');
      expect(s.requests.single.url.toString(), 'https://api.test/ai/config?build=0',
          reason: 'the build decides the voice this phone can play');
      expect(j, {'nano': {'enabled': true}});
      s.status = 404;
      expect(await s.build().config(), isNull);
    });
  });
}
