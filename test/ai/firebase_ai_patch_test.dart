// OUR COPY OF firebase_ai (third_party/README.md), 2026-09-30. Upstream,
// a Live message the SDK does not know (gemini-3.8-live sends voiceActivity
// and empty keep-alives, ~30 a turn) became a stream error, which ENDED
// receive() — and the tool call or turn complete that came right behind it
// in the same socket read was lost. The model then waited for good on a tool
// answer, and the client's S24 Ultra sat on "Listening".
import 'dart:async';
import 'dart:convert';

import 'package:firebase_ai/firebase_ai.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class _Sink implements WebSocketSink {
  final sent = <Object?>[];

  @override
  void add(Object? data) => sent.add(data);

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Socket implements WebSocketChannel {
  /// What the server sends. Synchronous: one add is one frame of a single
  /// socket read, delivered at once.
  final incoming = StreamController<Object?>(sync: true);
  final _sink = _Sink();

  @override
  Stream<Object?> get stream => incoming.stream;

  @override
  WebSocketSink get sink => _sink;

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  Future<void> get ready => Future.value();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('a message it does not know is skipped, and what came behind it arrives', () async {
    final ws = _Socket();
    final session = LiveSession.forTesting(ws);
    var frames = 0;
    session.onFrame = () => frames++;
    final got = <LiveServerMessage>[];
    final errors = <Object>[];
    session.receive().listen((r) => got.add(r.message), onError: errors.add);
    await Future<void>.delayed(Duration.zero);

    // One socket read: a voiceActivity, a keep-alive, a tool call, the end.
    ws.incoming
      ..add(jsonEncode({
        'voiceActivity': {'voiceActivityType': 'ACTIVITY_START'}
      }))
      ..add(jsonEncode({}))
      ..add(jsonEncode({
        'toolCall': {
          'functionCalls': [
            {'name': 'get_time', 'args': <String, Object?>{}, 'id': 'c1'}
          ]
        }
      }))
      ..add(jsonEncode({
        'serverContent': {'turnComplete': true}
      }));
    await Future<void>.delayed(Duration.zero);

    expect(errors, isEmpty, reason: 'an unknown message is not an error');
    expect(got.whereType<LiveServerToolCall>().single.functionCalls!.single.id, 'c1',
        reason: 'the tool call behind it was not lost');
    expect(got.whereType<LiveServerContent>().single.turnComplete, isTrue);
    expect(frames, 4, reason: 'every frame is a sign of life, understood or not');
    await session.close();
  });

  test('a known kind that fails to parse is still an error, never dropped silently',
      () async {
    final ws = _Socket();
    final session = LiveSession.forTesting(ws);
    final errors = <Object>[];
    session.receive().listen((_) {}, onError: errors.add);
    await Future<void>.delayed(Duration.zero);
    ws.incoming.add(jsonEncode({
      'toolCall': {
        'functionCalls': [
          {'args': <String, Object?>{}, 'id': 'c1'} // no name
        ]
      }
    }));
    await Future<void>.delayed(Duration.zero);
    expect(errors, hasLength(1));
    await session.close();
  });
}
