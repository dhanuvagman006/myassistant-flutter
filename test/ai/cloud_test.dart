import 'dart:async';
import 'dart:typed_data';

import 'package:firebase_ai/firebase_ai.dart';
// Grounding metadata has no public constructor export; the tests build it.
// ignore: implementation_imports
import 'package:firebase_ai/src/api.dart' show GroundingMetadata, SearchEntryPoint;
import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/ai/cloud.dart';
import 'package:myassistant/ai/types.dart';

import 'fakes.dart';

const _tool = AiToolSpec(
  name: 'set_reminder',
  description: 'Sets a reminder.',
  parameters: {
    'type': 'object',
    'properties': {
      'text': {'type': 'string'},
    },
    'required': ['text'],
  },
);

CloudRequest _req({
  String text = 'remind me to call amma at 5',
  List<ChatTurn> history = const [],
  List<AiAttachment> attachments = const [],
  List<AiToolSpec> tools = const [_tool],
  int maxToolRounds = 6,
  Duration roundTimeout = const Duration(seconds: 30),
  Duration? firstTimeout,
}) =>
    CloudRequest(
      model: 'gemini-test',
      text: text,
      system: 'You are Hari.',
      history: history,
      attachments: attachments,
      tools: tools,
      maxToolRounds: maxToolRounds,
      roundTimeout: roundTimeout,
      firstTimeout: firstTimeout,
    );

String _texts(List<CloudEvent> events) =>
    [for (final e in events) if (e is CloudTextDelta) e.text].join();

void main() {
  group('buildContents', () {
    test('history as alternating turns, starting with the user, then this turn', () {
      final c = CloudEngine.buildContents(
        const [
          ChatTurn('model', 'Hello! (greeting before the user spoke)'),
          ChatTurn('user', 'hi'),
          ChatTurn('user', 'are you there?'),
          ChatTurn('model', 'Yes.'),
          ChatTurn('user', 'thanks'),
        ],
        'what is 2+2',
        const [],
      );
      expect([for (final x in c) x.role], ['user', 'model', 'user']);
      expect((c[0].parts.single as TextPart).text, 'hi\nare you there?');
      // A history ending with the user merges into this turn.
      expect([for (final p in c.last.parts) (p as TextPart).text], ['thanks', 'what is 2+2']);
    });

    test('attachments go in as inline data, before the words', () {
      final img = Uint8List.fromList([1, 2, 3]);
      final c = CloudEngine.buildContents(const [], 'what is this', [
        AiAttachment(kind: 'image', mimeType: 'image/jpeg', bytes: img),
        const AiAttachment(kind: 'pdf', mimeType: 'application/pdf'), // no bytes: skipped
        AiAttachment(kind: 'pdf', mimeType: 'application/pdf', bytes: Uint8List(2)),
      ]);
      final parts = c.single.parts;
      expect(parts.length, 3);
      expect((parts[0] as InlineDataPart).mimeType, 'image/jpeg');
      expect((parts[0] as InlineDataPart).bytes, img);
      expect((parts[1] as InlineDataPart).mimeType, 'application/pdf');
      expect((parts[2] as TextPart).text, 'what is this');
    });
  });

  group('turn', () {
    test('streams text; system, model and declared tools reach the request', () async {
      final model = FakeModel([
        [textChunk('Two '), textChunk('plus two is four.')],
      ]);
      final events = await CloudEngine(model)
          .turn(_req(text: 'what is 2+2'), runTool: (_, __) async => fail('no tools'))
          .toList();
      expect(_texts(events), 'Two plus two is four.');
      final done = events.last as CloudFinished;
      expect(done.text, 'Two plus two is four.');
      expect(done.toolRounds, 0);
      final r = model.requests.single;
      expect(r.model, 'gemini-test');
      expect(r.system, 'You are Hari.');
      expect(r.toolConfig, isNull);
      final tools = r.tools!.single.toJson();
      expect((tools['functionDeclarations'] as List).single['name'], 'set_reminder');
    });

    test('the function-calling loop: runner called, responses returned by id', () async {
      const call = FunctionCall('set_reminder', {'text': 'call amma'}, id: 'call-1');
      final model = FakeModel([
        [partsChunk([const TextPart('Setting it. '), call])],
        [textChunk('Done — reminder set for 5 pm.')],
      ]);
      final ran = <(String, Map<String, Object?>)>[];
      final events = await CloudEngine(model).turn(_req(), runTool: (name, args) async {
        ran.add((name, args));
        return {'ok': true, 'id': 42};
      }).toList();

      expect(ran.single.$1, 'set_reminder');
      expect(ran.single.$2, {'text': 'call amma'});
      expect(events.whereType<CloudToolStarted>().single.name, 'set_reminder');
      final done = events.last as CloudFinished;
      expect(done.text, 'Setting it. Done — reminder set for 5 pm.');
      expect(done.toolRounds, 1);

      final second = model.requests[1].contents;
      // user turn, the model's own content (unchanged: thought signatures
      // ride on it), then the function response.
      expect(second.length, 3);
      expect(second[1].role, 'model');
      expect(identical(second[1].parts[1], call), isTrue);
      final response = second[2].parts.single as FunctionResponse;
      expect(second[2].role, 'user');
      expect(response.name, 'set_reminder');
      expect(response.id, 'call-1');
      expect(response.response, {'ok': true, 'id': 42});
    });

    test('several calls in one round run in order; thoughts are not shown', () async {
      final model = FakeModel([
        [
          partsChunk([
            const TextPart('let me think', isThought: true),
            const FunctionCall('a', {}),
            const FunctionCall('b', {'x': 1}),
          ]),
        ],
        [textChunk('Both done.')],
      ]);
      final order = <String>[];
      final events = await CloudEngine(model).turn(_req(), runTool: (name, _) async {
        order.add(name);
        return {'ok': true};
      }).toList();
      expect(order, ['a', 'b']);
      expect(_texts(events), 'Both done.');
      expect([for (final p in model.requests[1].contents.last.parts) (p as FunctionResponse).name],
          ['a', 'b']);
    });

    test('after maxToolRounds the model must answer in words', () async {
      Object again(_) => [partsChunk([const FunctionCall('set_reminder', {'text': 'x'})])];
      final model = FakeModel([again, again, again]);
      var runs = 0;
      final events = await CloudEngine(model)
          .turn(_req(maxToolRounds: 2), runTool: (_, __) async {
        runs++;
        return {'ok': true};
      }).toList();
      expect(runs, 2);
      expect(model.requests.length, 3);
      expect(model.requests[0].toolConfig, isNull);
      expect(model.requests[2].toolConfig!.toJson(), {
        'functionCallingConfig': {'mode': 'NONE'},
      });
      final done = events.last as CloudFinished;
      expect(done.hitToolLimit, isTrue);
    });

    test('no tools declared: calls are never run', () async {
      final model = FakeModel([
        [partsChunk([const FunctionCall('x', {})])],
      ]);
      final events = await CloudEngine(model)
          .turn(_req(tools: const []), runTool: (_, __) async => fail('no tools'))
          .toList();
      expect(model.requests.single.tools, isNull);
      expect((events.last as CloudFinished).text, '');
    });

    test('nothing back within the first wait fails early; a steady stream does not', () async {
      final slow = FakeModel([
        [textChunk('slow')],
      ])
        ..delay = const Duration(milliseconds: 200);
      await expectLater(
        CloudEngine(slow)
            .turn(_req(firstTimeout: const Duration(milliseconds: 50)), runTool: (_, __) async => {})
            .toList(),
        throwsA(isA<TimeoutException>()),
      );
      final steady = FakeModel([
        [textChunk('one '), textChunk('two '), textChunk('three')],
      ])
        ..delay = const Duration(milliseconds: 30);
      final events = await CloudEngine(steady)
          .turn(_req(firstTimeout: const Duration(milliseconds: 50)), runTool: (_, __) async => {})
          .toList();
      expect(_texts(events), 'one two three', reason: 'the wait is for the first words only');
    });

    test('a round that takes too long fails with a TimeoutException', () async {
      final model = FakeModel([
        [textChunk('slow')],
      ])
        ..delay = const Duration(milliseconds: 200);
      await expectLater(
        CloudEngine(model)
            .turn(_req(roundTimeout: const Duration(milliseconds: 50)),
                runTool: (_, __) async => {})
            .toList(),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('a blocked answer is an error the brain can word', () async {
      final model = FakeModel([
        [textChunk('', finish: FinishReason.safety)],
      ]);
      await expectLater(
        CloudEngine(model).turn(_req(), runTool: (_, __) async => {}).toList(),
        throwsA(isA<CloudBlockedException>()),
      );
      final blockedPrompt = FakeModel([
        [GenerateContentResponse(const [], PromptFeedback(BlockReason.safety, null, const []))],
      ]);
      await expectLater(
        CloudEngine(blockedPrompt).turn(_req(), runTool: (_, __) async => {}).toList(),
        throwsA(isA<CloudBlockedException>()),
      );
    });
  });

  group('search', () {
    test('grounded in Google Search, no function tools, links kept once', () async {
      GroundingMetadata grounding(List<(String, String)> pages) => GroundingMetadata(
            groundingChunks: [
              for (final (uri, title) in pages)
                GroundingChunk(web: WebGroundingChunk(uri: uri, title: title)),
            ],
            groundingSupports: const [],
            webSearchQueries: const ['who won'],
            searchEntryPoint: SearchEntryPoint(renderedContent: '<div>chips</div>'),
          );
      final model = FakeModel([
        [
          textChunk('India won '),
          textChunk('by 6 wickets.', grounding: grounding([
            ('https://a.example/1', 'A'),
            ('https://b.example/2', 'B'),
          ])),
          textChunk('', grounding: grounding([('https://a.example/1', 'A')])),
        ],
      ]);
      final events = await CloudEngine(model).search(_req(text: 'who won today')).toList();
      final done = events.last as CloudFinished;
      expect(done.text, 'India won by 6 wickets.');
      expect(done.sources.map((s) => s.uri), ['https://a.example/1', 'https://b.example/2']);
      expect(done.sources.first.title, 'A');
      expect(done.searchSuggestionsHtml, '<div>chips</div>');
      final tools = model.requests.single.tools!;
      expect(tools.single.toJson(), {'googleSearch': {}});
    });
  });
}
