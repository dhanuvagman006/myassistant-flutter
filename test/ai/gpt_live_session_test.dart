import 'dart:async';
import 'dart:convert';

import 'package:firebase_ai/firebase_ai.dart' show FunctionResponse;
import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/ai/gpt_live.dart';
import 'package:myassistant/ai/live_voice.dart';

/// A tool result reaches GPT-Live in the shape it accepts (2026-10-06,
/// production: a `delegation_id` on response.item.create was refused as an
/// unknown parameter, the result never arrived, and she said "one moment"
/// and never answered).
void main() {
  test('a tool result is sent without delegation_id, then the backend continues', () async {
    final incoming = StreamController<String>();
    final sent = <Map<String, dynamic>>[];
    final session = GptLiveSession(
      incoming.stream,
      (s) => sent.add(jsonDecode(s) as Map<String, dynamic>),
      () async {},
      closeWait: const Duration(milliseconds: 10),
    );
    final calls = <LiveInToolCall>[];
    final sub = session.messages.listen((m) {
      if (m is LiveInToolCall) calls.add(m);
    });
    void event(Map<String, Object?> e) => incoming.add(jsonEncode(e));

    event({'type': 'session.started', 'session': {'id': 'live_1'}});
    session.setMicOpen(true); // the conversation is open
    event({
      'type': 'session.delegation.created',
      'delegation': {'id': 'item_1', 'target': 'responses', 'response_id': 'resp_1'},
    });
    event({
      'type': 'response.event',
      'delegation_id': 'item_1',
      'event': {'type': 'response.created', 'response': {'id': 'resp_1'}},
    });
    event({
      'type': 'response.event',
      'delegation_id': 'item_1',
      'event': {
        'type': 'response.output_item.done',
        'response_id': 'resp_1',
        'item': {
          'type': 'function_call',
          'name': 'get_weather',
          'call_id': 'call_1',
          'arguments': '{"location":"Bengaluru"}',
        },
      },
    });
    event({
      'type': 'response.event',
      'delegation_id': 'item_1',
      'event': {'type': 'response.completed', 'response': {'id': 'resp_1'}},
    });
    await pumpEventQueue();

    expect(calls, hasLength(1));
    expect(calls.single.calls.single.name, 'get_weather');

    sent.clear();
    session.sendToolResponses([
      FunctionResponse('get_weather', {'ok': true, 'tempC': 27}, id: 'call_1'),
    ]);

    expect(sent.map((e) => e['type']), ['response.item.create', 'response.create']);
    final result = sent.first;
    expect(result.containsKey('delegation_id'), isFalse);
    expect(result['item'], {
      'type': 'function_call_output',
      'call_id': 'call_1',
      'output': jsonEncode({'ok': true, 'tempC': 27}),
    });

    await sub.cancel();
    await incoming.close();
  });

  test('nothing said or done before the conversation opens is acted on', () async {
    final incoming = StreamController<String>();
    final session = GptLiveSession(incoming.stream, (_) {}, () async {},
        closeWait: const Duration(milliseconds: 10));
    final got = <LiveIn>[];
    final sub = session.messages.listen(got.add);
    incoming.add(jsonEncode({'type': 'session.started', 'session': {'id': 'live_1'}}));
    incoming.add(jsonEncode({'type': 'session.input_transcript.delta', 'delta': 'phantom'}));
    incoming.add(jsonEncode({
      'type': 'session.delegation.created',
      'delegation': {'id': 'item_1', 'target': 'responses'},
    }));
    await pumpEventQueue();
    expect(got.whereType<LiveInContent>(), isEmpty);
    expect(got.whereType<LiveInWorking>(), isEmpty);
    await sub.cancel();
    await incoming.close();
  });
}
