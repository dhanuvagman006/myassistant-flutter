// THE FAST VOICE ON OPENAI REALTIME (2026-10-02): the socket's events
// become the engine's LiveIn messages, the mic's 16 kHz becomes 24 kHz on
// the way out, tool results go back as function_call_output, and the
// connector is chosen by the served provider.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:firebase_ai/firebase_ai.dart' show FunctionResponse;
import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/ai/live_voice.dart';
import 'package:myassistant/ai/openai_live.dart';

void main() {
  test('server events become LiveIn messages', () async {
    final frames = StreamController<dynamic>();
    final sent = <Map<String, dynamic>>[];
    final session = OpenAiLiveSession(frames.stream, (s) => sent.add(jsonDecode(s) as Map<String, dynamic>), () async {});
    final got = <LiveIn>[];
    final sub = session.messages.listen(got.add);
    frames
      ..add(jsonEncode({'type': 'session.created'}))
      // the owner opening a turn in silence is not an interruption
      ..add(jsonEncode({'type': 'input_audio_buffer.speech_started'}))
      ..add(jsonEncode({'type': 'response.created'}))
      ..add(jsonEncode({'type': 'input_audio_buffer.speech_started'}))
      ..add(jsonEncode({'type': 'conversation.item.input_audio_transcription.completed', 'transcript': 'set a timer'}))
      ..add(jsonEncode({'type': 'response.output_audio.delta', 'delta': base64Encode(List.filled(480, 1))}))
      ..add(jsonEncode({'type': 'response.output_audio_transcript.delta', 'delta': 'Sure, '}))
      ..add(jsonEncode({'type': 'response.function_call_arguments.done', 'name': 'set_timer', 'call_id': 'call_1', 'arguments': '{"minutes":5}'}))
      ..add(jsonEncode({'type': 'response.done'}));
    await session.ready;
    await Future<void>.delayed(Duration.zero);
    final real = got.where((m) => m is! LiveInPing).toList();
    expect(real[0], isA<LiveInReady>());
    // Speech while she answers is NOT an interruption (2026-10-02).
    expect(real.whereType<LiveInContent>().where((c) => c.interrupted), isEmpty);
    expect((real[1] as LiveInContent).heard, 'set a timer');
    final audio = (real[2] as LiveInContent).audio.single;
    expect(audio.$1.length, 480);
    expect(audio.$2, 24000);
    expect((real[3] as LiveInContent).said, 'Sure, ');
    final call = (real[4] as LiveInToolCall).calls.single;
    expect(call.name, 'set_timer');
    expect(call.args, {'minutes': 5});
    expect(call.id, 'call_1');
    expect((real[5] as LiveInContent).turnComplete, isTrue);
    await sub.cancel();
    await session.close();
  });

  test('parallel calls of one response reach the engine together, once it ends', () async {
    final frames = StreamController<dynamic>();
    final session = OpenAiLiveSession(frames.stream, (_) {}, () async {});
    final got = <LiveIn>[];
    final sub = session.messages.listen(got.add);
    frames
      ..add(jsonEncode({'type': 'session.created'}))
      ..add(jsonEncode({'type': 'response.function_call_arguments.done', 'name': 'get_weather', 'call_id': 'a', 'arguments': '{}'}))
      ..add(jsonEncode({'type': 'response.function_call_arguments.done', 'name': 'set_timer', 'call_id': 'b', 'arguments': '{"minutes":2}'}))
      ..add(jsonEncode({
        'type': 'response.done',
        'response': {
          'status': 'completed',
          'output': [
            {'type': 'function_call', 'call_id': 'a'},
            {'type': 'function_call', 'call_id': 'b'}
          ]
        }
      }));
    await session.ready;
    await Future<void>.delayed(Duration.zero);
    final calls = got.whereType<LiveInToolCall>().toList();
    expect(calls, hasLength(1));
    expect(calls.single.calls.map((c) => c.id), ['a', 'b']);
    expect(got.whereType<LiveInContent>().where((c) => c.turnComplete), isEmpty);
    await sub.cancel();
    await session.close();
  });

  test('what the phone sends: resampled audio, text turns, tool results', () async {
    final frames = StreamController<dynamic>();
    final sent = <Map<String, dynamic>>[];
    final session = OpenAiLiveSession(frames.stream, (s) => sent.add(jsonDecode(s) as Map<String, dynamic>), () async {});
    // 16 kHz: 160 samples (10 ms) → 240 samples at 24 kHz.
    final pcm = Uint8List(320);
    for (var i = 0; i < 160; i++) {
      ByteData.sublistView(pcm).setInt16(i * 2, i * 100 - 8000, Endian.little);
    }
    session.sendAudio(pcm);
    expect(sent.single['type'], 'input_audio_buffer.append');
    final up = base64Decode(sent.single['audio'] as String);
    expect(up.length, 480);
    final view = ByteData.sublistView(up);
    expect(view.getInt16(0, Endian.little), -8000);
    // the third output sample sits on input sample 2
    expect(view.getInt16(3 * 2, Endian.little), -8000 + 200);
    sent.clear();
    session.sendText('hello');
    expect(sent.map((e) => e['type']).toList(), ['conversation.item.create', 'response.create']);
    expect((sent[0]['item'] as Map)['role'], 'user');
    sent.clear();
    session.sendToolResponses([const FunctionResponse('set_timer', {'ok': true}, id: 'call_1')]);
    expect(sent.map((e) => e['type']).toList(), ['conversation.item.create', 'response.create']);
    final item = sent[0]['item'] as Map;
    expect(item['type'], 'function_call_output');
    expect(item['call_id'], 'call_1');
    expect(jsonDecode(item['output'] as String), {'ok': true});
    await session.close();
    await frames.close();
  });

  test('a response that ends in a tool call does not end her turn', () async {
    final frames = StreamController<dynamic>();
    final session = OpenAiLiveSession(frames.stream, (_) {}, () async {});
    final got = <LiveIn>[];
    final sub = session.messages.listen(got.add);
    frames
      ..add(jsonEncode({'type': 'session.created'}))
      ..add(jsonEncode({'type': 'response.function_call_arguments.done', 'name': 'web_search', 'call_id': 'c9', 'arguments': '{"query":"x"}'}))
      ..add(jsonEncode({
        'type': 'response.done',
        'response': {
          'status': 'completed',
          'output': [
            {'type': 'function_call', 'name': 'web_search', 'call_id': 'c9'}
          ]
        }
      }))
      ..add(jsonEncode({'type': 'response.output_audio_transcript.delta', 'delta': 'It is 8:45.'}))
      ..add(jsonEncode({
        'type': 'response.done',
        'response': {
          'status': 'completed',
          'output': [
            {'type': 'message'}
          ]
        }
      }));
    await session.ready;
    await Future<void>.delayed(Duration.zero);
    final real = got.where((m) => m is! LiveInPing && m is! LiveInReady).toList();
    expect(real[0], isA<LiveInToolCall>());
    expect((real[1] as LiveInContent).said, 'It is 8:45.');
    expect((real[2] as LiveInContent).turnComplete, isTrue);
    expect(real.length, 3, reason: 'only the spoken response completes the turn');
    await sub.cancel();
    await session.close();
  });

  test('the Interrupt button cancels the reply, and its cancelled end does not end the next turn', () async {
    final frames = StreamController<dynamic>();
    final sent = <Map<String, dynamic>>[];
    final session = OpenAiLiveSession(frames.stream, (s) => sent.add(jsonDecode(s) as Map<String, dynamic>), () async {});
    final got = <LiveIn>[];
    final sub = session.messages.listen(got.add);
    frames
      ..add(jsonEncode({'type': 'session.created'}))
      ..add(jsonEncode({'type': 'response.created'}))
      ..add(jsonEncode({'type': 'response.output_audio_transcript.delta', 'delta': 'There is no'}));
    await session.ready;
    await Future<void>.delayed(Duration.zero);
    session.cancelReply();
    expect(sent.single['type'], 'response.cancel');
    frames
      ..add(jsonEncode({'type': 'input_audio_buffer.speech_started'}))
      ..add(jsonEncode({'type': 'response.done', 'response': {'status': 'cancelled', 'output': []}}))
      ..add(jsonEncode({'type': 'conversation.item.input_audio_transcription.completed', 'transcript': 'مسٹر شنکر بھٹ'}))
      ..add(jsonEncode({'type': 'conversation.item.input_audio_transcription.completed', 'transcript': 'Mr. Shankar Bhat'}))
      ..add(jsonEncode({'type': 'response.created'}))
      ..add(jsonEncode({'type': 'response.output_audio_transcript.delta', 'delta': 'Shankar Bhat is a journalist.'}))
      ..add(jsonEncode({'type': 'response.done', 'response': {'status': 'completed', 'output': [{'type': 'message'}]}}));
    await session.ready;
    await Future<void>.delayed(Duration.zero);
    final real = got.where((m) => m is! LiveInPing && m is! LiveInReady).cast<LiveInContent>().toList();
    expect(real.where((c) => c.interrupted), isEmpty);
    expect(real[1].heard, 'Mr. Shankar Bhat');
    expect(real[2].said, 'Shankar Bhat is a journalist.');
    expect(real.where((c) => c.turnComplete).length, 1, reason: 'only the answered turn completes');
    expect(OpenAiLiveSession.plausible('ನಮಸ್ಕಾರ, how are you'), isTrue);
    expect(OpenAiLiveSession.plausible('नमस्ते'), isTrue);
    expect(OpenAiLiveSession.plausible('はい。'), isFalse);
    await sub.cancel();
    await session.close();
  });

  test('a socket that closes before the session is acknowledged fails fast', () async {
    final frames = StreamController<dynamic>();
    final session = OpenAiLiveSession(frames.stream, (_) {}, () async {});
    await frames.close();
    await expectLater(session.ready, throwsA(isA<StateError>()));
  });

  test('the served provider decides the connector', () async {
    final picked = <String>[];
    final sw = SwitchingLiveConnector(
      gemini: _Fake('gemini', picked),
      openai: _Fake('openai', picked),
      viaServer: () => picked.length.isOdd,
    );
    const setup = LiveSetup(model: 'm', voice: 'v', system: '');
    await sw.connect(setup);
    await sw.connect(setup);
    expect(picked, ['gemini', 'openai']);
  });
}

class _Fake implements LiveConnector {
  _Fake(this.name, this.picked);
  final String name;
  final List<String> picked;
  @override
  Future<LiveSessionPort> connect(LiveSetup setup, {String? resumeHandle}) async {
    picked.add(name);
    return OpenAiLiveSession(StreamController<dynamic>().stream, (_) {}, () async {});
  }
}
