import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:firebase_ai/firebase_ai.dart';
// ignore: implementation_imports
import 'package:firebase_ai/src/api.dart' show GroundingMetadata;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:myassistant/ai/brain.dart';
import 'package:myassistant/ai/cloud.dart';
import 'package:myassistant/ai/config.dart';
import 'package:myassistant/ai/model_port.dart';
import 'package:myassistant/ai/speech.dart';
import 'package:myassistant/ai/tool_server.dart';
import 'package:myassistant/ai/types.dart';

import 'fakes.dart';

/// The backend's /ai/* routes, scripted.
class _Server extends ToolServer {
  _Server() : super(client: MockClient((_) async => http.Response('', 500)));

  AiContext? ctx = const AiContext(
    sessionId: 's1',
    turnId: 't1',
    system: 'SYSTEM',
    tools: [
      AiToolSpec(name: 'open_camera', description: 'Opens the camera.'),
      AiToolSpec(name: 'send_message', description: 'Sends a message.', parameters: {
        'type': 'object',
        'properties': {
          'to': {'type': 'string'},
          'text': {'type': 'string'},
        },
        'required': ['to', 'text'],
      }),
    ],
    history: [ChatTurn('user', 'earlier question'), ChatTurn('model', 'earlier answer')],
  );
  final contexts = <Map<String, Object?>>[];
  final tools = <Map<String, Object?>>[];
  final turns = <Map<String, Object?>>[];
  AiToolResult Function(String name, Map<String, Object?> args, String? token) onTool =
      (_, __, ___) => const AiToolResult(ok: true, result: {'done': true});
  AiTurnReceipt? Function(String reply)? onTurn;

  @override
  Future<AiContext?> context({
    required String text,
    required String mode,
    String? sessionId,
    List<AiAttachment> attachments = const [],
    bool untrusted = false,
    bool shared = false,
    bool expressive = false,
    Map<String, Object?> device = const {},
    Duration timeout = const Duration(seconds: 8),
  }) async {
    contexts.add({
      'text': text,
      'mode': mode,
      'sessionId': sessionId,
      'attachments': [for (final a in attachments) a.toJson()],
      'device': device,
      'untrusted': untrusted,
      'shared': shared,
      'expressive': expressive,
    });
    return ctx;
  }

  @override
  Future<AiToolResult> tool({
    required String sessionId,
    required String turnId,
    required String name,
    required Map<String, Object?> args,
    required String userText,
    String? approvalToken,
    Duration timeout = const Duration(seconds: 25),
  }) async {
    tools.add({
      'name': name,
      'args': args,
      'userText': userText,
      'token': approvalToken,
      'sid': sessionId,
      'tid': turnId,
    });
    return onTool(name, args, approvalToken);
  }

  @override
  Future<AiTurnReceipt?> recordTurn({
    required String sessionId,
    required String turnId,
    required String user,
    required String reply,
    required String engine,
    required List<Map<String, Object?>> tools,
    required int latencyMs,
    required String mode,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    turns.add({
      'user': user,
      'reply': reply,
      'engine': engine,
      'tools': tools,
      'mode': mode,
      'sid': sessionId,
      'tid': turnId,
    });
    return onTurn == null ? AiTurnReceipt(reply: reply) : onTurn!(reply);
  }
}

const _configJson = {
  'models': {'cloud': 'cloud-model', 'tts': 'tts-model'},
  'routing': {
    'toolWords': ['open', 'send', 'message', 'remind'],
    'freshWords': ['today', 'who won'],
    'shortcutNames': ['Office Mode'],
  },
  'limits': {'maxToolRounds': 6},
};

class _Harness {
  _Harness({BrainTimeouts? timeouts}) {
    brain = AssistantBrain(
      server: server,
      configs: AiConfigStore(
        fetch: () async => _configJson,
      ),
      cloud: CloudEngine(cloudModel),
      speech: SpeechEngine(port: ttsModel, config: () => const AiConfig()),
      sink: sink,
      timeouts: timeouts ?? const BrainTimeouts(),
      deviceContext: () async => {
        'caps': {'granted': ['camera'], 'denied': []},
      },
    );
  }

  final server = _Server();
  final cloudModel = FakeModel();
  final ttsModel = FakeModel();
  final sink = RecordingSink();
  late final AssistantBrain brain;

  /// Runs a turn; device actions are answered by [onDevice].
  Future<List<BrainEvent>> turn(
    String text, {
    BrainMode mode = BrainMode.chat,
    AiAttachment? image,
    List<AiAttachment> attachments = const [],
    DeviceOutcome Function(Map<String, dynamic> action)? onDevice,
  }) async {
    final events = <BrainEvent>[];
    await for (final e
        in brain.turn(text: text, mode: mode, image: image, attachments: attachments)) {
      events.add(e);
      if (e is BrainDeviceAction) {
        e.respond(onDevice?.call(e.action) ?? const DeviceOutcome.ok());
      }
    }
    return events;
  }
}

T _one<T>(List<BrainEvent> events) => events.whereType<T>().single;

List<AiRoute> _routes(List<BrainEvent> events) =>
    [for (final e in events.whereType<BrainRouteChosen>()) e.route];

void main() {
  group('a turn', () {
    test('an everyday turn: the cloud answers, recorded, with the history', () async {
      final h = _Harness();
      h.cloudModel.script.add([textChunk('Why did the '), textChunk('scarecrow win? He was outstanding.')]);
      final events = await h.turn('tell me a joke');

      expect(_routes(events), [AiRoute.cloud]);
      final done = _one<BrainFinalText>(events);
      expect(done.text, 'Why did the scarecrow win? He was outstanding.');
      expect(done.route, AiRoute.cloud);
      expect(events.whereType<BrainPartialText>().map((e) => e.text),
          ['Why did the', 'Why did the scarecrow win? He was outstanding.']);
      final asked = h.cloudModel.requests.single;
      expect(asked.system, 'SYSTEM');
      expect(asked.model, 'cloud-model');
      expect(h.server.turns.single['engine'], 'cloud');
      expect(h.server.turns.single['reply'], done.text);
      expect(h.server.contexts.single['mode'], 'chat');
      expect(h.server.contexts.single['device'], {
        'caps': {'granted': ['camera'], 'denied': []},
      });
      expect(h.brain.sessionId, 's1');
      expect(h.brain.history.last, ChatTurn('model', done.text));
    });

    test('a photo goes to the cloud as bytes', () async {
      final dir = await Directory.systemTemp.createTemp('brain_photo');
      final f = File('${dir.path}/p.jpg')..writeAsBytesSync([9, 9, 9]);
      final h = _Harness();
      h.cloudModel.script.add([textChunk('A cup of tea.')]);
      final events = await h.turn('',
          image: AiAttachment(kind: 'image', mimeType: 'image/jpeg', path: f.path));
      expect(_one<BrainFinalText>(events).text, 'A cup of tea.');
      final parts = h.cloudModel.requests.single.contents.last.parts;
      expect((parts.first as InlineDataPart).bytes, [9, 9, 9]);
      expect((parts.last as TextPart).text, 'What is in this picture?');
      expect(h.server.contexts.single['attachments'], [
        {'kind': 'image', 'mime': 'image/jpeg'},
      ]);
      await dir.delete(recursive: true);
    });
  });

  group('cloud with tools', () {
    test("a device action is the engine's; its outcome goes back to the model", () async {
      final h = _Harness();
      h.server.onTool = (name, args, _) => const AiToolResult(
            ok: true,
            result: {'opened': 'camera'},
            deviceAction: {'type': 'open_camera'},
          );
      h.cloudModel.script
        ..add([
          partsChunk([const FunctionCall('open_camera', {}, id: 'c1')]),
        ])
        ..add([textChunk('The camera is open.')]);
      final actions = <Map<String, dynamic>>[];
      final events = await h.turn('open the camera', onDevice: (a) {
        actions.add(a);
        return const DeviceOutcome.ok('camera on screen');
      });

      expect(_routes(events), [AiRoute.cloud]);
      expect(_one<BrainToolCall>(events).name, 'open_camera');
      expect(actions, [
        {'type': 'open_camera'},
      ]);
      expect(h.server.tools.single['name'], 'open_camera');
      expect(h.server.tools.single['userText'], 'open the camera');
      final response = h.cloudModel.requests[1].contents.last.parts.single as FunctionResponse;
      expect(response.id, 'c1');
      expect(response.response, {
        'opened': 'camera',
        'ok': true,
        'device': {'ok': true, 'detail': 'camera on screen'},
      });
      expect(_one<BrainFinalText>(events).text, 'The camera is open.');
      expect(h.server.turns.single['tools'], [
        {'name': 'open_camera', 'ok': true, 'outcome': 'ok'},
      ]);
    });

    test('an unanswered device action times out as a failure the model hears', () async {
      final h = _Harness(
          timeouts: const BrainTimeouts(deviceAction: Duration(milliseconds: 30)));
      h.server.onTool = (_, __, ___) =>
          const AiToolResult(ok: true, deviceAction: {'type': 'open_camera'});
      h.cloudModel.script
        ..add([
          partsChunk([const FunctionCall('open_camera', {})]),
        ])
        ..add([textChunk("I couldn't open it.")]);
      final events = <BrainEvent>[];
      await for (final e in h.brain.turn(text: 'open the camera')) {
        events.add(e); // never answered
      }
      final response = h.cloudModel.requests[1].contents.last.parts.single as FunctionResponse;
      expect(response.response['device'], {'ok': false, 'detail': 'The phone did not answer.'});
      expect(_one<BrainFinalText>(events).text, "I couldn't open it.");
    });

    test('confirmation: asked in one turn, the token rides only on a later yes', () async {
      final h = _Harness();
      const args = {'to': 'Amma', 'text': 'hi'};
      h.server.onTool = (name, a, token) => token == 'hmac.1'
          ? const AiToolResult(ok: true, result: {'sent': true})
          : const AiToolResult(
              ok: false,
              needsConfirmation: true,
              summary: "Send 'hi' to Amma",
              approvalToken: 'hmac.1',
            );
      h.cloudModel.script
        // Turn 1: the model tries twice in the same turn; no token either time.
        ..add([
          partsChunk([const FunctionCall('send_message', args)]),
        ])
        ..add([
          partsChunk([const FunctionCall('send_message', args)]),
        ])
        ..add([textChunk("Shall I send 'hi' to Amma?")])
        // Turn 2 ("yes"): the retry carries the token.
        ..add([
          partsChunk([const FunctionCall('send_message', args)]),
        ])
        ..add([textChunk('Sent.')]);

      final first = await h.turn('send hi to amma');
      final ask = first.whereType<BrainNeedsConfirmation>().first;
      expect(ask.summary, "Send 'hi' to Amma");
      expect(ask.approvalToken, 'hmac.1');
      expect(h.server.tools.map((t) => t['token']), [null, null]);
      final told = h.cloudModel.requests[1].contents.last.parts.single as FunctionResponse;
      expect(told.response, {'ok': false, 'needsConfirmation': true, 'summary': "Send 'hi' to Amma"});

      final second = await h.turn('yes');
      expect(second.whereType<BrainRouteChosen>().first.reason, 'pending_confirmation');
      expect(h.server.tools.last['token'], 'hmac.1');
      expect(_one<BrainFinalText>(second).text, 'Sent.');
    });

    test('a "no" never carries the token', () async {
      final h = _Harness();
      const args = {'to': 'Amma', 'text': 'hi'};
      h.server.onTool = (_, __, token) => AiToolResult(
            ok: false,
            needsConfirmation: token == null,
            summary: 'Send it',
            approvalToken: 'hmac.2',
          );
      h.cloudModel.script
        ..add([
          partsChunk([const FunctionCall('send_message', args)]),
        ])
        ..add([textChunk('Shall I?')])
        ..add([
          partsChunk([const FunctionCall('send_message', args)]),
        ])
        ..add([textChunk('Okay, not sending it.')]);
      await h.turn('send hi to amma');
      await h.turn('no, wait');
      expect(h.server.tools.map((t) => t['token']), [null, null]);
    });

    test('attachments go to the cloud as bytes', () async {
      final h = _Harness();
      h.cloudModel.script.add([textChunk('It is a lease agreement.')]);
      final events = await h.turn('what is this document', attachments: [
        AiAttachment(
            kind: 'pdf', mimeType: 'application/pdf', bytes: Uint8List.fromList([37, 80])),
      ]);
      expect(events.whereType<BrainRouteChosen>().single.reason, 'attachments');
      final parts = h.cloudModel.requests.single.contents.last.parts;
      expect((parts.first as InlineDataPart).mimeType, 'application/pdf');
    });
  });

  group('other routes', () {
    test("a shortcut runs with no model, in the server's words", () async {
      final h = _Harness();
      h.server.ctx = const AiContext(sessionId: 's1', turnId: 't2', shortcut: 'Office Mode');
      h.server.onTool = (name, args, _) => const AiToolResult(
            ok: true,
            speak: 'Office mode is on.',
            deviceAction: {'type': 'set_ringer', 'mode': 'vibrate'},
          );
      final actions = <Map<String, dynamic>>[];
      final events = await h.turn('office mode', onDevice: (a) {
        actions.add(a);
        return const DeviceOutcome.ok();
      });
      expect(_routes(events), [AiRoute.shortcut]);
      expect(h.server.tools.single['name'], 'run_shortcut');
      expect(h.server.tools.single['args'], {'name': 'Office Mode'});
      expect(actions.single['type'], 'set_ringer');
      expect(_one<BrainFinalText>(events).text, 'Office mode is on.');
      expect(h.cloudModel.requests, isEmpty);
      expect(h.server.turns.single['engine'], 'shortcut');
    });

    test('a shortcut that needs a yes asks for it; one that fails says so', () async {
      final h = _Harness();
      h.server.ctx = const AiContext(sessionId: 's1', turnId: 't2', shortcut: 'Office Mode');
      h.server.onTool = (_, __, ___) => const AiToolResult(
          ok: false, needsConfirmation: true, summary: 'Turn on office mode', approvalToken: 'a');
      expect(_one<BrainFinalText>(await h.turn('office mode')).text, 'Turn on office mode?');
      h.server.onTool = (_, __, ___) => const AiToolResult.failed('no such shortcut');
      expect(_one<BrainFinalText>(await h.turn('office mode')).text,
          "I couldn't run Office Mode: no such shortcut.");
    });

    test('fresh facts: Google Search grounding, with the pages', () async {
      final h = _Harness();
      h.cloudModel.script.add([
        textChunk('India won.',
            grounding: GroundingMetadata(
              groundingChunks: [
                GroundingChunk(
                    web: WebGroundingChunk(uri: 'https://news.example/1', title: 'News')),
              ],
              groundingSupports: const [],
              webSearchQueries: const [],
            )),
      ]);
      final events = await h.turn('who won the match today');
      expect(_routes(events), [AiRoute.search]);
      final done = _one<BrainFinalText>(events);
      expect(done.text, 'India won.');
      expect(done.sources.single.uri, 'https://news.example/1');
      expect(h.cloudModel.requests.single.tools!.single.toJson(), {'googleSearch': {}});
    });

    test("the server's claim-checked reply is the one used", () async {
      final h = _Harness();
      h.cloudModel.script.add([textChunk('Sure, noted.')]);
      h.server.onTurn =
          (_) => const AiTurnReceipt(reply: "I can't save notes yet.", corrected: true);
      final done = _one<BrainFinalText>(await h.turn('tell me a joke'));
      expect(done.text, "I can't save notes yet.");
      expect(done.corrected, isTrue);
      expect(h.brain.history.last.text, "I can't save notes yet.");
    });

    test('the server unreachable: the cloud answers without tools or memory', () async {
      final h = _Harness();
      h.server.ctx = null;
      h.cloudModel.script.add([textChunk("I can't reach your services right now.")]);
      final events = await h.turn('remind me at 5');
      final r = h.cloudModel.requests.single;
      expect(r.system, AssistantBrain.standInSystem(BrainMode.chat));
      expect(r.tools, isNull);
      expect(h.server.turns, isEmpty, reason: 'nothing to record against');
      expect(_one<BrainFinalText>(events).text, "I can't reach your services right now.");
    });
  });

  group('a model in trouble', () {
    test('it fails before saying anything: the fallback answers', () async {
      final h = _Harness();
      h.cloudModel.script
        ..add(ServerException('The model is overloaded. Please try again later.'))
        ..add([textChunk('Here is your answer.')]);
      final events = await h.turn('tell me a joke');
      expect(_one<BrainFinalText>(events).text, 'Here is your answer.');
      expect(events.whereType<BrainError>(), isEmpty);
      final asked = h.cloudModel.requests;
      expect(asked.map((r) => r.model), ['cloud-model', 'gemini-flash-lite-latest']);
      // 2026-09-30: a plain conversation turn thinks minimally.
      expect(asked[0].generationConfig!.toJson()['thinkingConfig'], {'thinkingLevel': 'MINIMAL'},
          reason: 'a conversation turn thinks as little as it can');
      expect(asked[1].generationConfig, isNull, reason: 'the fallback is there to be quick');
    });

    test('thinking and length: tool routes keep the configured level; a voice reply is capped',
        () {
      const config = AiConfig(models: AiModels(cloud: 'cloud-model', thinking: 'low'));
      Map<String, dynamic>? json(GenerationConfig? g) =>
          g?.toJson().cast<String, dynamic>();
      expect(json(AssistantBrain.thinkingFor(config, 'cloud-model'))!['thinkingConfig'],
          {'thinkingLevel': 'LOW'});
      final talk = json(
          AssistantBrain.thinkingFor(config, 'cloud-model', conversation: true, voice: true))!;
      expect(talk['thinkingConfig'], {'thinkingLevel': 'MINIMAL'});
      expect(talk['maxOutputTokens'], AssistantBrain.voiceReplyTokens);
      expect(json(AssistantBrain.thinkingFor(config, 'cloud-model', voice: true))!['maxOutputTokens'],
          AssistantBrain.voiceToolReplyTokens);
      expect(json(AssistantBrain.thinkingFor(config, 'other', voice: true)),
          {'maxOutputTokens': AssistantBrain.voiceToolReplyTokens},
          reason: 'the fallback thinks not at all, but a spoken reply is still capped');
      const flash38 = AiConfig(models: AiModels(cloud: 'gemini-3.8-flash', thinking: 'low'));
      expect(
          json(AssistantBrain.thinkingFor(flash38, 'gemini-3.8-flash', conversation: true))![
              'thinkingConfig'],
          {'thinkingLevel': 'LOW'},
          reason: '3.8 Flash cannot think "minimal"');
    });

    test('it has not started within the wait: the fallback answers', () async {
      final h = _Harness(timeouts: const BrainTimeouts(cloudFirst: Duration(milliseconds: 50)));
      h.cloudModel.delay = const Duration(milliseconds: 300);
      h.cloudModel.script
        ..add([textChunk('Too late.')])
        ..add((ModelRequest r) {
          h.cloudModel.delay = Duration.zero;
          return [textChunk('In time.')];
        });
      final events = await h.turn('tell me a joke');
      expect(_one<BrainFinalText>(events).text, 'In time.');
    });

    test('once a tool has run, nothing is done twice: the failure is said', () async {
      final h = _Harness();
      h.server.onTool = (name, args, _) =>
          const AiToolResult(ok: true, result: {}, deviceAction: {'type': 'open_camera'});
      h.cloudModel.script
        ..add([
          partsChunk([const FunctionCall('open_camera', {}, id: 'c1')]),
        ])
        ..add(ServerException('500'));
      final events = await h.turn('open the camera');
      expect(_one<BrainError>(events).code, 'server');
      expect(h.cloudModel.requests.length, 2, reason: 'no third call to a fallback');
    });
  });

  group('how a reply sounds', () {
    test('the tone and expressions are heard, never shown or remembered', () async {
      final h = _Harness();
      h.cloudModel.script.add([
        textChunk('<tone: bright and sunny> Good news! <chuck'),
        textChunk('les> Your order is on its way.'),
      ]);
      h.ttsModel.script.add(audioResponse([7, 7]));
      final events = await h.turn('where is my order', mode: BrainMode.voice);
      expect(h.server.contexts.single['expressive'], isTrue, reason: 'it will be spoken');
      for (final p in events.whereType<BrainPartialText>()) {
        expect(p.text, isNot(contains('<')), reason: 'no mark on screen, even half-streamed');
      }
      expect(_one<BrainFinalText>(events).text, 'Good news! Your order is on its way.');
      expect(h.server.turns.single['reply'], 'Good news! Your order is on its way.');
      final said = (h.ttsModel.requests.single.contents.single.parts.single as TextPart).text;
      expect(said, 'Good news! <chuckles> Your order is on its way.',
          reason: 'the expression is performed; no lead-in to be read aloud');
      expect(h.sink.played, [Uint8List.fromList([7, 7])]);
    });

    test('no tone from the model: the default one; a typed turn asks for no marks', () async {
      final h = _Harness();
      h.cloudModel.script.add([textChunk('It is sunny and warm right now.')]);
      h.ttsModel.script.add(audioResponse([1]));
      await h.turn('talk to me', mode: BrainMode.voice);
      final said = (h.ttsModel.requests.single.contents.single.parts.single as TextPart).text;
      expect(said, 'It is sunny and warm right now.');

      final typed = _Harness();
      typed.cloudModel.script.add([textChunk('Sure.')]);
      await typed.turn('tell me a joke');
      expect(typed.server.contexts.single['expressive'], isFalse);
    });
  });

  group('voice', () {
    test('the reply is spoken sentence by sentence into the sink', () async {
      final h = _Harness();
      h.cloudModel.script.add([textChunk('The first sentence is here. The second one follows it.')]);
      h.ttsModel.script
        ..add(audioResponse([1, 1]))
        ..add(audioResponse([2, 2]));
      final events = await h.turn('talk to me', mode: BrainMode.voice);
      final spoken = events.whereType<BrainSpokenAudio>().toList();
      expect(spoken.map((s) => s.sentence),
          ['The first sentence is here.', 'The second one follows it.']);
      expect(h.sink.played, [
        Uint8List.fromList([1, 1]),
        Uint8List.fromList([2, 2]),
      ]);
      // The final text comes before the audio.
      expect(events.indexWhere((e) => e is BrainFinalText),
          lessThan(events.indexWhere((e) => e is BrainSpokenAudio)));
      expect(h.server.contexts.single['mode'], 'voice');
      expect(h.server.turns.single['mode'], 'voice');
    });

    test('the first sentence goes to the voice the moment its full stop is written', () async {
      // 2026-09-30 (voice audit): it used to wait for the next sentence.
      final h = _Harness();
      final rest = Completer<void>();
      Stream<GenerateContentResponse> reply() async* {
        yield textChunk('Sure, I can help you with that.');
        await rest.future;
        yield textChunk(' Here is the rest of it.');
      }

      h.cloudModel.script.add(reply());
      h.ttsModel.script
        ..add(audioResponse([1, 1]))
        ..add(audioResponse([2, 2]));
      final turn = h.turn('talk to me', mode: BrainMode.voice);
      for (var i = 0; i < 200 && h.ttsModel.requests.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(h.ttsModel.requests, hasLength(1),
          reason: 'asked for before the rest of the reply was written');
      rest.complete();
      final events = await turn;
      expect(events.whereType<BrainSpokenAudio>().map((s) => s.sentence),
          ['Sure, I can help you with that.', 'Here is the rest of it.']);
    });

    test('speech that cannot be made is a non-fatal error after the reply', () async {
      final h = _Harness();
      h.cloudModel.script.add([textChunk('Just one sentence to say.')]);
      h.ttsModel.script
        ..add(Exception('tts down'))
        ..add(Exception('tts down'));
      final events = await h.turn('talk to me', mode: BrainMode.voice);
      expect(_one<BrainFinalText>(events).text, 'Just one sentence to say.');
      final err = _one<BrainError>(events);
      expect([err.code, err.fatal], ['tts', false]);
    });
  });

  group('cancel and errors', () {
    test('barge-in: the turn stops, no reply, the sink is stopped', () async {
      final h = _Harness();
      h.cloudModel
        ..delay = const Duration(milliseconds: 200)
        ..script.add([textChunk('too late')]);
      final events = <BrainEvent>[];
      final done = Completer<void>();
      h.brain.turn(text: 'tell me a long story').listen(events.add, onDone: done.complete);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(h.brain.busy, isTrue);
      await h.brain.cancel();
      await done.future;
      expect(events.whereType<BrainFinalText>(), isEmpty);
      expect(h.sink.stops, 1);
      expect(h.server.turns, isEmpty);
      expect(h.brain.busy, isFalse);
    });

    test('a new turn cancels the one still running', () async {
      final h = _Harness();
      h.cloudModel
        ..delay = const Duration(milliseconds: 100)
        ..script.add([textChunk('first')])
        ..script.add([textChunk('second')]);
      final first = <BrainEvent>[];
      final firstDone = Completer<void>();
      h.brain.turn(text: 'one').listen(first.add, onDone: firstDone.complete);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final second = await h.turn('two');
      await firstDone.future;
      expect(first.whereType<BrainFinalText>(), isEmpty);
      expect(_one<BrainFinalText>(second).text, 'second');
    });

    test('failures become plain words', () async {
      for (final (error, code, fallsBack) in <(Object, String, bool)>[
        (QuotaExceeded('quota'), 'quota', true),
        (const SocketException('no network'), 'offline', false),
        (ServerException('500'), 'server', true),
        (StateError('bug'), 'failed', false),
      ]) {
        final h = _Harness();
        h.cloudModel.script.add(error);
        // The fallback model is tried first where another model may help.
        if (fallsBack) h.cloudModel.script.add(error);
        final events = await h.turn('tell me a joke');
        final e = _one<BrainError>(events);
        expect([e.code, e.fatal], [code, true], reason: '$error');
        expect(events.whereType<BrainFinalText>(), isEmpty);
      }
      expect(BrainError.from(TimeoutException('x')).code, 'timeout');
      expect(AssistantBrain.fallbackHelps(ServerException('App Check token is invalid')), isFalse);
      expect(AssistantBrain.fallbackHelps(TimeoutException('x')), isTrue);
      expect(AssistantBrain.fallbackHelps(const SocketException('x')), isFalse);
      expect(BrainError.from(const CloudBlockedException('SAFETY')).code, 'blocked');
      expect(BrainError.from(ServiceApiNotEnabled('off')).code, 'not_enabled');
    });

    test('reset forgets the conversation and the session', () async {
      final h = _Harness();
      h.cloudModel.script.add([textChunk('Here is one.')]);
      await h.turn('tell me a joke');
      expect(h.brain.history, isNotEmpty);
      h.brain.reset();
      expect(h.brain.history, isEmpty);
      expect(h.brain.sessionId, isNull);
    });
  });

  group('prepare', () {
    test('fetches the config before the first turn', () async {
      var fetched = 0;
      final brain = AssistantBrain(
        server: _Server(),
        configs: AiConfigStore(fetch: () async {
          fetched++;
          return _configJson;
        }),
        cloud: CloudEngine(FakeModel()),
      );
      await brain.prepare();
      expect(fetched, 1);
    });
  });

  group("the tool server's rules", () {
    const args = {'to': 'Amma', 'text': 'hi'};

    test('a lost session (404 unknown session): renewed, the call retried ONCE', () async {
      final h = _Harness();
      final renewed = AiContext(
        sessionId: 's2',
        turnId: 't2',
        system: 'SYSTEM',
        tools: h.server.ctx!.tools,
      );
      var n = 0;
      h.server.onTool = (name, a, token) {
        n++;
        if (n == 1) {
          // A deploy forgot the session; /ai/context now starts a new one.
          h.server.ctx = renewed;
          return const AiToolResult.failed('unknown session', status: 404);
        }
        return const AiToolResult(ok: true, result: {'sent': true});
      };
      h.cloudModel.script
        ..add([
          partsChunk([const FunctionCall('send_message', args)]),
        ])
        ..add([textChunk('Sent.')]);
      final events = await h.turn('send hi to amma');
      expect(h.server.contexts.length, 2, reason: '/ai/context again, for this turn');
      expect([for (final t in h.server.tools) '${t['sid']}/${t['tid']}'], ['s1/t1', 's2/t2']);
      expect(h.brain.sessionId, 's2');
      expect(_one<BrainFinalText>(events).text, 'Sent.');
      expect(h.server.turns.single['sid'], 's2', reason: 'recorded in the new session');
      expect(h.server.turns.single['tools'], [
        {'name': 'send_message', 'ok': true},
      ]);
    });

    test('a session lost again is not chased: the model hears the failure', () async {
      final h = _Harness();
      h.server.onTool = (_, __, ___) => const AiToolResult.failed('unknown session', status: 404);
      h.cloudModel.script
        ..add([
          partsChunk([const FunctionCall('send_message', args)]),
        ])
        ..add([textChunk("I couldn't send it.")]);
      await h.turn('send hi to amma');
      expect(h.server.tools.length, 2, reason: 'one retry, never a loop');
    });

    test('a refused approval is a new question, never a success', () async {
      final h = _Harness();
      final devices = <Map<String, dynamic>>[];
      h.server.onTool = (name, a, token) => token == null
          ? const AiToolResult(
              ok: false, needsConfirmation: true, summary: 'Send it', approvalToken: 'tok.1')
          // Expired: nothing ran; a fresh token for a fresh question.
          : const AiToolResult(
              ok: false,
              needsConfirmation: true,
              summary: 'Send it',
              approvalToken: 'tok.2',
              error: 'approval not accepted: expired',
              deviceAction: {'type': 'send_sms'},
            );
      h.cloudModel.script
        ..add([
          partsChunk([const FunctionCall('send_message', args)]),
        ])
        ..add([textChunk('Shall I send it?')])
        ..add([
          partsChunk([const FunctionCall('send_message', args)]),
        ])
        ..add([textChunk('That approval expired. Shall I send it now?')]);
      await h.turn('send hi to amma');
      final second = await h.turn('yes', onDevice: (a) {
        devices.add(a);
        return const DeviceOutcome.ok();
      });
      expect(h.server.tools.map((t) => t['token']), [null, 'tok.1']);
      expect(devices, isEmpty, reason: 'nothing ran, so nothing is done on the phone');
      expect(second.whereType<BrainNeedsConfirmation>().single.approvalToken, 'tok.2');
      expect(h.server.turns.last['tools'], [
        {'name': 'send_message', 'ok': false},
      ]);
    });

    test('a "no" uses the approval up: a later "yes" does not carry it', () async {
      final h = _Harness();
      h.server.onTool = (_, __, ___) => const AiToolResult(
          ok: false, needsConfirmation: true, summary: 'Send it', approvalToken: 'tok.9');
      h.cloudModel.script
        ..add([
          partsChunk([const FunctionCall('send_message', args)]),
        ])
        ..add([textChunk('Shall I?')])
        ..add([textChunk('Okay, I will not.')])
        ..add([
          partsChunk([const FunctionCall('send_message', args)]),
        ])
        ..add([textChunk('Shall I?')]);
      await h.turn('send hi to amma');
      await h.turn('no');
      await h.turn('yes');
      expect(h.server.tools.map((t) => t['token']), [null, null]);
    });

    test('a turn the model stayed silent on: nothing shown, said or remembered', () async {
      final h = _Harness();
      h.server.onTurn = (_) => const AiTurnReceipt(reply: '', corrected: true);
      h.cloudModel.script.add([textChunk('')]);
      final events = await h.turn('and then the match went to penalties', mode: BrainMode.voice);
      final fin = _one<BrainFinalText>(events);
      expect(fin.text, '');
      expect(fin.corrected, isTrue);
      expect(h.ttsModel.requests, isEmpty, reason: 'nothing is spoken');
      expect(h.sink.played, isEmpty);
      expect(h.brain.history.map((t) => t.role), ['user']);
    });

    test('speak: a typed (chat) turn can still be answered out loud', () async {
      final h = _Harness();
      h.cloudModel.script.add([textChunk('Hello to you too, how can I help?')]);
      h.ttsModel.script.add(audioResponse([1, 2, 3, 4]));
      await for (final _ in h.brain.turn(text: 'hello there', speak: true)) {}
      expect(h.server.turns.single['mode'], 'chat');
      expect(h.sink.played, isNotEmpty);
    });
  });

  group('local tools', () {
    LocalTool nextStep(List<LocalToolCall> calls,
            {LocalToolResult result = const LocalToolResult(result: {'step': 3}),
            bool Function()? available}) =>
        LocalTool(
          spec: const AiToolSpec(
            name: 'next_step',
            description: 'Moves the recipe on.',
            parameters: {
              'type': 'object',
              'properties': {
                'by': {'type': 'integer'},
              },
            },
          ),
          available: available,
          handler: (call) async {
            calls.add(call);
            return result;
          },
        );

    test('declared beside the server tools, run in the app, never POST /ai/tool', () async {
      final h = _Harness();
      final calls = <LocalToolCall>[];
      h.brain.localTools.register(nextStep(calls));
      h.cloudModel.script
        ..add([
          partsChunk([const FunctionCall('next_step', {'by': 1}, id: 'l1')]),
        ])
        ..add([textChunk('Step three: fold in the flour.')]);
      final events = await h.turn('go on');
      expect(events.whereType<BrainRouteChosen>().first.route, AiRoute.cloud);
      final declared = h.cloudModel.requests.first.tools!.single.toJson();
      expect([for (final d in declared['functionDeclarations'] as List) d['name']],
          ['open_camera', 'send_message', 'next_step']);
      expect(h.server.tools, isEmpty);
      expect(calls.single.args, {'by': 1});
      expect(calls.single.userText, 'go on');
      final response = h.cloudModel.requests[1].contents.last.parts.single as FunctionResponse;
      expect(response.id, 'l1');
      expect(response.response, {'step': 3, 'ok': true});
      expect(h.server.turns.single['tools'], [
        {'name': 'next_step', 'ok': true, 'local': true},
      ]);
    });

    test("its device action is the engine's, and its outcome goes back", () async {
      final h = _Harness();
      final calls = <LocalToolCall>[];
      h.brain.localTools.register(nextStep(calls,
          result: const LocalToolResult(
              result: {'step': 4}, deviceAction: {'type': 'start_focus', 'minutes': 5})));
      h.cloudModel.script
        ..add([
          partsChunk([const FunctionCall('next_step', {})]),
        ])
        ..add([textChunk('Timer on.')]);
      final actions = <Map<String, dynamic>>[];
      await h.turn('next', onDevice: (a) {
        actions.add(a);
        return const DeviceOutcome.ok('timer started');
      });
      expect(actions, [
        {'type': 'start_focus', 'minutes': 5},
      ]);
      final response = h.cloudModel.requests[1].contents.last.parts.single as FunctionResponse;
      expect(response.response['device'], {'ok': true, 'detail': 'timer started'});
    });

    test('a server tool of the same name wins; one not available is not offered', () async {
      final h = _Harness();
      final calls = <LocalToolCall>[];
      h.brain.localTools.register(LocalTool(
        spec: const AiToolSpec(name: 'open_camera'),
        handler: (call) async {
          calls.add(call);
          return const LocalToolResult();
        },
      ));
      h.brain.localTools.register(nextStep(calls, available: () => false));
      h.cloudModel.script
        ..add([
          partsChunk([const FunctionCall('open_camera', {})]),
        ])
        ..add([textChunk('Open.')]);
      await h.turn('open the camera');
      final declared = h.cloudModel.requests.first.tools!.single.toJson();
      expect([for (final d in declared['functionDeclarations'] as List) d['name']],
          ['open_camera', 'send_message']);
      expect(calls, isEmpty);
      expect(h.server.tools.single['name'], 'open_camera');
    });

    test('a handler that fails, throws or is too slow is a failure the model hears', () async {
      final registry = LocalToolRegistry();
      final remove = registry.register(LocalTool(
        spec: const AiToolSpec(name: 'boom'),
        handler: (call) async => throw StateError('no oven'),
      ));
      registry.register(LocalTool(
        spec: const AiToolSpec(name: 'slow'),
        handler: (call) => Completer<LocalToolResult>().future,
      ));
      const call = LocalToolCall(name: 'boom', args: {}, userText: 'x');
      final boom = await registry.run(call);
      expect(boom.ok, isFalse);
      expect(boom.toFunctionResponse()['error'], contains('no oven'));
      final slow = await registry.run(const LocalToolCall(name: 'slow', args: {}, userText: 'x'),
          timeout: const Duration(milliseconds: 20));
      expect(slow.toFunctionResponse(), {'ok': false, 'error': 'That took too long on the phone.'});
      remove();
      expect((await registry.run(call)).error, 'That tool is not available right now.');
    });
  });
}
