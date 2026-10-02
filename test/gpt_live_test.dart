import 'dart:async';
import 'dart:convert';

import 'package:firebase_ai/firebase_ai.dart' show FunctionResponse;
import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/ai/gpt_live.dart';
import 'package:myassistant/ai/live_voice.dart';

void main() {
  late StreamController<String> events;
  late List<Map<String, dynamic>> sent;
  late List<bool> mic;
  late List<bool> speaker;
  late bool disposed;
  late GptLiveSession session;
  late List<LiveIn> got;

  setUp(() {
    events = StreamController<String>();
    sent = [];
    mic = [];
    speaker = [];
    disposed = false;
    session = GptLiveSession(
      events.stream,
      (s) => sent.add(jsonDecode(s) as Map<String, dynamic>),
      () async => disposed = true,
      mic: mic.add,
      speaker: speaker.add,
      closeWait: const Duration(milliseconds: 200),
      tailMs: 10,
    );
    got = [];
    session.messages.listen(got.add);
  });

  void server(Map<String, Object?> e) => events.add(jsonEncode(e));
  Future<void> settle([int ms = 0]) => Future<void>.delayed(Duration(milliseconds: ms));
  List<LiveIn> real() => got.where((m) => m is! LiveInPing).toList();

  test('started, their words, her words, and her turn ends after her last word', () async {
    server({'type': 'session.started', 'session': {'id': 'live_1'}});
    await session.ready;
    server({'type': 'session.input_transcript.delta', 'delta': 'What time ', 'start_ms': 100, 'end_ms': 400});
    server({'type': 'session.input_transcript.delta', 'delta': 'is it?', 'start_ms': 400, 'end_ms': 700});
    server({'type': 'session.output_transcript.delta', 'delta': 'It is ', 'start_ms': 900, 'end_ms': 1000});
    server({'type': 'session.output_transcript.delta', 'delta': 'ten.', 'start_ms': 1000, 'end_ms': 0});
    await settle(60);
    final r = real();
    expect(r.first, isA<LiveInReady>());
    expect(r.whereType<LiveInContent>().map((c) => c.heard).whereType<String>().join(), 'What time is it?');
    expect(r.whereType<LiveInContent>().map((c) => c.said).whereType<String>().join(), 'It is ten.');
    expect(r.whereType<LiveInContent>().where((c) => c.turnComplete), hasLength(1));
  });

  test("the backend's function call reaches the engine; its answer goes back and asks to continue", () async {
    server({'type': 'session.started'});
    await session.ready;
    server({
      'type': 'response.event',
      'delegation_id': 'item_1',
      'event': {
        'type': 'response.output_item.done',
        'item': {'type': 'function_call', 'call_id': 'call_9', 'name': 'set_timer', 'arguments': '{"minutes":5}'}
      }
    });
    await settle();
    final call = real().whereType<LiveInToolCall>().single.calls.single;
    expect(call.name, 'set_timer');
    expect(call.args, {'minutes': 5});
    expect(call.id, 'call_9');
    session.sendToolResponses([const FunctionResponse('set_timer', {'ok': true}, id: 'call_9')]);
    expect(sent.map((e) => e['type']), ['response.item.create', 'response.create']);
    expect(sent.first['item'], {'type': 'function_call_output', 'call_id': 'call_9', 'output': '{"ok":true}'});
  });

  test('the backend working shows as working, through her "let me check", until her answer ends the turn', () async {
    server({'type': 'session.started'});
    await session.ready;
    server({'type': 'session.delegation.created', 'delegation': {'id': 'item_1', 'target': 'responses'}});
    server({'type': 'response.event', 'event': {'type': 'response.created'}});
    server({'type': 'session.output_transcript.delta', 'delta': 'Let me check.', 'end_ms': 0});
    server({'type': 'response.event', 'event': {'type': 'response.output_item.added', 'item': {'type': 'web_search_call'}}});
    await settle(40);
    final working = real().whereType<LiveInWorking>().toList();
    expect(working.first.tool, isNull);
    expect(working.last.tool, 'web_search');
    expect(real().whereType<LiveInContent>().where((c) => c.turnComplete), isEmpty, reason: 'still searching');
    server({'type': 'response.event', 'event': {'type': 'response.completed', 'response': {'output': [{'type': 'message'}]}}});
    server({'type': 'session.output_transcript.delta', 'delta': 'Narendra Modi.', 'end_ms': 0});
    await settle(40);
    expect(real().whereType<LiveInContent>().where((c) => c.turnComplete), hasLength(1));
  });

  test('the mic opens and closes on the track and tells GPT-Live; nothing is sent at startup', () async {
    server({'type': 'session.started'});
    await session.ready;
    expect(sent, isEmpty);
    session.setMicOpen(true);
    session.setMicOpen(false);
    expect(mic, [true, false]);
    expect(sent.map((e) => e['type']), ['session.input_audio.unmute', 'session.input_audio.mute']);
  });

  test('stop silences her until they speak again', () async {
    server({'type': 'session.started'});
    await session.ready;
    server({'type': 'session.output_transcript.delta', 'delta': 'A long story', 'end_ms': 99999});
    await settle();
    session.cancelReply();
    await settle();
    expect(speaker, [false]);
    expect(real().whereType<LiveInContent>().where((c) => c.turnComplete), hasLength(1));
    server({'type': 'session.input_transcript.delta', 'delta': 'thanks'});
    await settle();
    expect(speaker, [false, true]);
  });

  test('close waits for session.closed, then lets the call go', () async {
    server({'type': 'session.started'});
    await session.ready;
    final closing = session.close();
    await settle();
    expect(sent.last['type'], 'session.close');
    expect(disposed, isFalse, reason: 'audio and channel stay until the final event');
    server({'type': 'session.closed', 'reason': 'close_requested', 'usage': {'seconds': 12}});
    await closing;
    expect(disposed, isTrue);
  });

  test('no session.closed in time: finalization is incomplete, the call still goes', () async {
    server({'type': 'session.started'});
    await session.ready;
    await session.close();
    expect(disposed, isTrue);
  });
}
