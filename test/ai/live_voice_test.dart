// THE FAST VOICE (2026-09-30): Gemini Live through Firebase AI Logic, with
// a scripted session, a scripted tool server, the real brain for the tools
// (the same /ai/tool and approvals as the cascade), a player that plays
// into nothing and a microphone fed by hand.
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:firebase_ai/firebase_ai.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:myassistant/ai/brain.dart';
import 'package:myassistant/ai/cloud.dart';
import 'package:myassistant/ai/live_voice.dart';
import 'package:myassistant/ai/tool_server.dart';
import 'package:myassistant/ai/types.dart';
import 'package:myassistant/services/audio/mic_stream.dart';
import 'package:myassistant/services/audio/pcm_player.dart';

import 'fakes.dart';

class _Session implements LiveSessionPort {
  final inbox = StreamController<LiveIn>();
  final audio = <Uint8List>[];
  final texts = <String>[];
  final toolResponses = <List<FunctionResponse>>[];
  var closed = false;

  @override
  Stream<LiveIn> get messages => inbox.stream;

  @override
  void sendAudio(Uint8List pcm16) => audio.add(pcm16);

  @override
  void sendText(String text) => texts.add(text);

  @override
  void sendToolResponses(List<FunctionResponse> responses) => toolResponses.add(responses);

  @override
  Future<void> close() async {
    closed = true;
    if (!inbox.isClosed) await inbox.close();
  }
}

class _Connector implements LiveConnector {
  final setups = <LiveSetup>[];
  final handles = <String?>[];
  final sessions = <_Session>[];

  /// 'ok' (setupComplete at once), 'fail' (throws), 'hang' (never ready),
  /// 'flaky' (ready, then closed at once).
  String mode = 'ok';

  @override
  Future<LiveSessionPort> connect(LiveSetup setup, {String? resumeHandle}) async {
    setups.add(setup);
    handles.add(resumeHandle);
    if (mode == 'fail') throw StateError('no socket');
    final s = _Session();
    sessions.add(s);
    if (mode == 'ok' || mode == 'flaky') {
      scheduleMicrotask(() => s.inbox.add(const LiveInReady()));
    }
    if (mode == 'flaky') scheduleMicrotask(() => s.inbox.close());
    return s;
  }
}

class _Server extends ToolServer {
  _Server() : super(client: MockClient((_) async => http.Response('', 500)));

  AiContext? ctx = const AiContext(
    sessionId: 's1',
    turnId: 't1',
    system: 'LIVE SYSTEM',
    tools: [
      AiToolSpec(name: 'send_message', description: 'Sends a message.', parameters: {
        'type': 'object',
        'properties': {
          'to': {'type': 'string'},
          'text': {'type': 'string'},
        },
        'required': ['to', 'text'],
      }),
      AiToolSpec(name: 'get_calendar', description: 'Reads the calendar.'),
    ],
    history: [ChatTurn('user', 'earlier question'), ChatTurn('model', 'earlier answer')],
  );
  final contexts = <Map<String, Object?>>[];
  final opened = <String?>[];
  final tools = <Map<String, Object?>>[];
  final records = <Map<String, Object?>>[];
  var nextTurn = 2;
  AiToolResult Function(String name, Map<String, Object?> args, String? token) onTool =
      (_, __, ___) => const AiToolResult(ok: true, result: {'events': 2});

  /// Set: every tool call waits on it (a tool that never comes back).
  Completer<void>? hang;

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
    contexts.add({'text': text, 'mode': mode, 'expressive': expressive, 'device': device});
    return ctx;
  }

  @override
  Future<AiContext?> openLiveTurn({
    required String? sessionId,
    Map<String, Object?> device = const {},
    Duration timeout = const Duration(seconds: 8),
  }) async {
    opened.add(sessionId);
    return AiContext(sessionId: sessionId, turnId: 't${nextTurn++}');
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
    final h = hang;
    if (h != null) await h.future;
    return onTool(name, args, approvalToken);
  }

  @override
  Future<AiTurnReceipt?> recordLiveTurn({
    required String sessionId,
    required String turnId,
    required String user,
    required String reply,
    required List<Map<String, Object?>> tools,
    required Map<String, int> latency,
    int? cutOffAfter,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    records.add({
      'sid': sessionId,
      'tid': turnId,
      'user': user,
      'reply': reply,
      'tools': tools,
      'latency': latency,
      'cutOffAfter': cutOffAfter,
    });
    return AiTurnReceipt(reply: reply);
  }
}

class _Mic extends MicStream {
  void Function(Uint8List pcm, double? level)? onFrame;
  void Function(String why)? onLost;
  int? bufferBytes;
  var starts = 0;
  var stops = 0;

  /// false: the next starts fail (a microphone that will not open).
  var opens = true;

  @override
  Future<bool> start(void Function(Uint8List pcm, double? level) onFrame,
      {int? bufferBytes, void Function(String why)? onLost}) async {
    starts++;
    if (!opens) return false;
    this.onFrame = onFrame;
    this.onLost = onLost;
    this.bufferBytes = bufferBytes;
    return true;
  }

  @override
  Future<void> stop() async {
    stops++;
    onFrame = null;
  }
}

/// [ms] of her voice: PCM16 @24 kHz.
Uint8List voice(int ms, {int amp = 6000}) {
  final n = 24 * ms;
  final b = ByteData(n * 2);
  for (var i = 0; i < n; i++) {
    b.setInt16(i * 2, (amp * math.sin(2 * math.pi * 180 * i / 24000)).round(), Endian.little);
  }
  return b.buffer.asUint8List();
}

/// One 40 ms microphone frame whose bytes are all [fill].
Uint8List frame([int fill = 1]) => Uint8List(1280)..fillRange(0, 1280, fill);

/// Lets the events (delivered asynchronously) arrive.
Future<void> pump() => Future<void>.delayed(Duration.zero);

Future<void> until(bool Function() ok, {String what = 'the condition'}) async {
  for (var i = 0; i < 300; i++) {
    if (ok()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('timed out waiting for $what');
}

class _Rig {
  _Rig({LiveTimeouts? timeouts, bool fakeClock = false})
      : player = PcmPlayer(
            output: _out, clockUs: fakeClock ? () => _clock : null) {
    brain = AssistantBrain(
      server: server,
      configs: configs,
      cloud: CloudEngine(FakeModel()),
      deviceContext: () async => const {},
    );
    live = LiveVoice(
      connector: connector,
      server: server,
      brain: brain,
      player: player,
      mic: mic,
      configs: configs,
      timeouts: timeouts ??
          const LiveTimeouts(
            connect: Duration(milliseconds: 300),
            firstReply: Duration(milliseconds: 300),
            afterTool: Duration(milliseconds: 300),
          ),
      enabled: () => true,
    );
    live.events.listen(events.add);
  }

  static final _out = SilentOutput();
  static int _clock = 0;

  /// Moves the fake clock (a rig made with fakeClock).
  void advance(int ms) => _clock += ms * 1000;

  final server = _Server();
  final connector = _Connector();
  SilentOutput get out => _out;
  final PcmPlayer player;
  final mic = _Mic();
  final configs = AiConfigStore(
    fetch: () async => {
      'models': {'cloud': 'cloud-model'},
      'live': {'model': 'gemini-3.8-live', 'voice': 'Sulafat', 'silenceMs': 500},
    },
  );
  late final AssistantBrain brain;
  late final LiveVoice live;
  final events = <LiveEvent>[];

  _Session get session => connector.sessions.last;

  /// The owner says something: [ms] of speech, then 800 ms of quiet.
  void speak({int ms = 400}) {
    for (var i = 0; i < ms ~/ 40; i++) {
      live.debugFrame(frame(), 0.6);
    }
    for (var i = 0; i < 20; i++) {
      live.debugFrame(frame(0), 0.005);
    }
  }

  List<Type> get kinds => [for (final e in events) e.runtimeType];
}

void main() {
  setUp(() => BargeInWatch.detector.forget());

  group('the session', () {
    test('opened with the Live instruction, the tools as BLOCKING, the VAD settings', () async {
      final r = _Rig();
      expect(await r.live.start(), isTrue);
      expect(r.server.contexts.single['mode'], 'live');
      expect(r.server.contexts.single['text'], '');
      expect(r.server.contexts.single['expressive'], isFalse, reason: 'never expressive marks');
      final setup = r.connector.setups.single;
      expect(setup.model, 'gemini-3.8-live');
      expect(setup.voice, 'Sulafat');
      expect(setup.system, startsWith('LIVE SYSTEM'));
      expect(setup.system, contains('The owner: earlier question'));
      final decl = setup.sdkTools!.single.toJson()['functionDeclarations'] as List;
      expect([for (final d in decl) (d as Map)['behavior']], ['BLOCKING', 'BLOCKING'],
          reason: 'the model waits for the answer, or it goes silent after a tool');
      expect((decl.first as Map)['name'], 'send_message');
      final vad = setup.generationConfig;
      expect(vad.realtimeInputConfig!.toJson()['automatic_activity_detection'], {
        'start_of_speech_sensitivity': 'START_SENSITIVITY_LOW',
        'end_of_speech_sensitivity': 'END_SENSITIVITY_HIGH',
        'prefix_padding_ms': 100,
        'silence_duration_ms': 500,
      });
      expect(r.mic.bufferBytes, MicStream.liveChunkBytes, reason: '40 ms reads');
      await r.live.stop();
    });

    test('the microphone goes to Live in 40 ms chunks', () async {
      final r = _Rig();
      await r.live.start();
      r.mic.onFrame!(Uint8List(1280 * 3), 0.01);
      expect(r.session.audio.map((a) => a.length), [1280, 1280, 1280]);
      await r.live.stop();
    });

    // Measured 2026-09-30: with a TV talking in the room Live's own
    // end-of-turn never fired. This phone's VAD closes the turn for it.
    test('a TV on: once he stops, Live hears silence; when he carries on, nothing is lost',
        () async {
      final r = _Rig();
      await r.live.start();
      for (var i = 0; i < 10; i++) {
        r.live.debugFrame(frame(), 0.6);
      }
      final before = r.session.audio.length;
      for (var i = 0; i < 30; i++) {
        r.live.debugFrame(frame(2), 0.03); // the TV, well under his voice
      }
      final tv = r.session.audio.sublist(before);
      expect(tv.first.every((b) => b == 2), isTrue, reason: 'the room goes on until he stops');
      expect(tv.last.every((b) => b == 0), isTrue, reason: 'then silence closes the turn');
      await pump();
      expect(r.kinds, contains(LiveThinking));
      final mark = r.session.audio.length;
      for (var i = 0; i < 5; i++) {
        r.live.debugFrame(frame(3), 0.6); // he carries on (onset after 200 ms)
      }
      final resumed = r.session.audio.sublist(mark);
      expect(resumed.take(4).every((f) => f.every((b) => b == 0)), isTrue);
      expect(resumed[4].every((b) => b == 2), isTrue, reason: 'the held-back moments first');
      expect(resumed.last.every((b) => b == 3), isTrue);
      expect(resumed.where((f) => f.every((b) => b == 3)).length, 5,
          reason: 'every frame of his carrying on reaches Live');
      await r.live.stop();
    });

    test('cannot connect, or not ready in time: false, so the cascade answers', () async {
      final r = _Rig()..connector.mode = 'fail';
      expect(await r.live.start(), isFalse);
      final h = _Rig()..connector.mode = 'hang';
      final t0 = DateTime.now();
      expect(await h.live.start(), isFalse);
      expect(DateTime.now().difference(t0), lessThan(const Duration(seconds: 2)));
      expect(h.connector.sessions.single.closed, isTrue);
      final off = _Rig()..server.ctx = null;
      expect(await off.live.start(), isFalse, reason: 'no instruction from the server');
      expect(off.connector.setups, isEmpty);
    });

    test('off in the config: never connects', () async {
      final r = _Rig();
      final off = LiveVoice(
        connector: r.connector,
        server: r.server,
        brain: r.brain,
        player: r.player,
        mic: r.mic,
        configs: AiConfigStore(fetch: () async => {
          'live': {'on': false},
        }),
        enabled: () => true,
      );
      expect(await off.start(), isFalse);
      expect(r.connector.setups, isEmpty);
    });
  });

  group('a turn', () {
    test('LISTENING -> THINKING -> RESPONDING -> SPEAKING -> DONE, recorded with its latency',
        () async {
      final r = _Rig();
      await r.live.start();
      r.speak();
      r.live.debugIn(const LiveInContent(heard: "What's on my calendar"));
      r.live.debugIn(const LiveInContent(heard: ' tomorrow?'));
      await pump();
      expect(r.kinds, contains(LiveThinking));
      r.live.debugIn(const LiveInToolCall([
        FunctionCall('get_calendar', {'day': 'tomorrow'}, id: 'call-1'),
      ]));
      await until(() => r.session.toolResponses.isNotEmpty, what: 'the tool response');
      final resp = r.session.toolResponses.single.single;
      expect(resp.id, 'call-1', reason: 'answered with the call id');
      expect(resp.name, 'get_calendar');
      expect(resp.response, {'events': 2, 'ok': true});
      expect(r.server.tools.single['userText'], "What's on my calendar tomorrow?");
      expect(r.server.tools.single['tid'], 't1');
      r.live.debugIn(LiveInContent(audio: [(voice(40), 24000)], said: 'Two things tomorrow.'));
      expect(r.player.playing, isTrue);
      r.live.debugIn(const LiveInContent(turnComplete: true));
      await until(() => r.events.whereType<LiveTurnDone>().isNotEmpty, what: 'DONE');
      final order = [
        for (final e in r.events)
          if (e is LiveThinking ||
              e is LiveSpeaking ||
              e is LiveTurnDone ||
              (e is LiveBrain && e.event is BrainToolCall))
            e is LiveBrain ? 'responding' : e.runtimeType.toString(),
      ];
      expect(order, ['LiveThinking', 'responding', 'LiveSpeaking', 'LiveTurnDone']);
      final done = r.events.whereType<LiveTurnDone>().single;
      expect(done.user, "What's on my calendar tomorrow?");
      expect(done.reply, 'Two things tomorrow.');
      expect(done.latency.keys, containsAll(['endToFirstAudio', 'endToPlay', 'tool']));
      await until(() => r.server.records.isNotEmpty, what: 'the record');
      final rec = r.server.records.single;
      expect(rec['tid'], 't1');
      expect(rec['reply'], 'Two things tomorrow.');
      expect((rec['tools'] as List).single, {'name': 'get_calendar', 'ok': true});
      expect(rec['cutOffAfter'], isNull);
      await until(() => r.server.opened.isNotEmpty, what: 'the next turn opened ahead');
      await r.live.stop();
    });

    test('approvals: asked in one turn, the token rides only on a later yes', () async {
      final r = _Rig();
      const args = {'to': 'Amma', 'text': 'hi'};
      r.server.onTool = (name, a, token) => token == 'hmac.1'
          ? const AiToolResult(ok: true, result: {'sent': true})
          : const AiToolResult(
              ok: false,
              needsConfirmation: true,
              summary: "Send 'hi' to Amma",
              approvalToken: 'hmac.1',
            );
      await r.live.start();
      r.live.debugIn(const LiveInContent(heard: 'Send hi to Amma'));
      r.live.debugIn(const LiveInToolCall([FunctionCall('send_message', args, id: 'a')]));
      await until(() => r.session.toolResponses.length == 1);
      await pump();
      expect(r.events.whereType<LiveBrain>().map((e) => e.event).whereType<BrainNeedsConfirmation>(),
          hasLength(1));
      expect(r.session.toolResponses.single.single.response['needsConfirmation'], isTrue);
      r.live.debugIn(LiveInContent(audio: [(voice(40), 24000)], said: "Shall I send 'hi' to Amma?"));
      r.live.debugIn(const LiveInContent(turnComplete: true));
      await until(() => r.events.whereType<LiveTurnDone>().length == 1);

      r.live.debugIn(const LiveInContent(heard: 'Yes.'));
      r.live.debugIn(const LiveInToolCall([FunctionCall('send_message', args, id: 'b')]));
      await until(() => r.session.toolResponses.length == 2);
      expect(r.server.tools.map((t) => t['token']), [null, 'hmac.1']);
      expect(r.server.tools.last['tid'], isNot(r.server.tools.first['tid']),
          reason: 'every Live turn is its own server turn');
      expect(r.session.toolResponses.last.single.id, 'b');
      await r.live.stop();
    });

    test('a call the model cancels is not answered', () async {
      final r = _Rig();
      await r.live.start();
      r.live.debugIn(const LiveInContent(heard: 'check my calendar'));
      r.live.debugIn(const LiveInToolCancel(['x']));
      r.live.debugIn(const LiveInToolCall([
        FunctionCall('get_calendar', {}, id: 'x'),
        FunctionCall('get_calendar', {}, id: 'y'),
      ]));
      await until(() => r.session.toolResponses.isNotEmpty);
      expect(r.session.toolResponses.single.map((f) => f.id), ['y']);
      await r.live.stop();
    });
  });

  group('talking over her', () {
    test("Live's 'interrupted': the player is flushed, the cut is recorded", () async {
      final r = _Rig();
      await r.live.start();
      r.live.debugIn(const LiveInContent(heard: 'Tell me a long story'));
      r.live.debugIn(LiveInContent(audio: [(voice(3000), 24000)], said: 'Once upon a time there was a king.'));
      expect(r.player.playing, isTrue);
      final stops = r.out.stops;
      r.live.debugIn(const LiveInContent(interrupted: true));
      await pump();
      expect(r.player.playing, isFalse, reason: 'never talks over the owner');
      expect(r.out.stops, greaterThan(stops));
      final done = r.events.whereType<LiveTurnDone>().single;
      expect(done.interrupted, isTrue);
      expect(r.events.whereType<LiveInterrupted>(), hasLength(1));
      await until(() => r.server.records.isNotEmpty);
      expect(r.server.records.single['cutOffAfter'], isA<int>());
      await r.live.stop();
    });

    test('her echo reaches Live as silence; a real interruption stops her HERE and sends the pre-roll',
        () async {
    // The voice interruption this pins is off in the app since 2026-10-02
    // (an Interrupt button instead); the mechanism is kept and tested.
    LiveVoice.autoBargeIn = true;
    addTearDown(() => LiveVoice.autoBargeIn = false);
      final r = _Rig(fakeClock: true);
      await r.live.start();
      r.live.debugIn(const LiveInContent(heard: 'Tell me a long story'));
      r.live.debugIn(LiveInContent(audio: [(voice(4000), 24000)], said: 'Once upon a time.'));
      expect(r.player.playing, isTrue);
      final before = r.session.audio.length;
      // Her own voice coming back into the microphone: learnt, never sent.
      for (var i = 0; i < 40; i++) {
        r.advance(40);
        r.live.debugFrame(frame(2), 0.1);
      }
      final echoSent = r.session.audio.sublist(before);
      expect(echoSent, hasLength(40));
      expect(echoSent.every((a) => a.every((b) => b == 0)), isTrue, reason: 'silence only');
      expect(r.player.playing, isTrue, reason: 'her echo does not stop her');
      // The owner, clearly louder than her echo, for long enough.
      for (var i = 0; i < 12 && r.player.playing; i++) {
        r.advance(40);
        r.live.debugFrame(frame(3), 0.9);
      }
      expect(r.player.playing, isFalse, reason: 'stopped locally, at once');
      await pump();
      expect(r.events.whereType<LiveInterrupted>(), hasLength(1));
      final after = r.session.audio.sublist(before + 40);
      expect(after.where((a) => a.isNotEmpty && a.first == 3), isNotEmpty,
          reason: "the owner's own words, from the pre-roll on");
      // Anything left of the old answer is dropped until Live says so.
      r.live.debugIn(LiveInContent(audio: [(voice(200), 24000)]));
      expect(r.player.playing, isFalse);
      r.live.debugIn(const LiveInContent(interrupted: true));
      r.live.debugIn(LiveInContent(audio: [(voice(40), 24000)], said: 'Yes?'));
      expect(r.player.playing, isTrue, reason: 'the new answer plays');
      await r.live.stop();
      await r.player.stop();
    });

    test('a tap: she stops and the rest of that answer is dropped', () async {
      final r = _Rig();
      await r.live.start();
      r.live.debugIn(const LiveInContent(heard: 'Read me the news'));
      r.live.debugIn(LiveInContent(audio: [(voice(2000), 24000)], said: 'First, the weather.'));
      await r.live.interrupt();
      expect(r.player.playing, isFalse);
      r.live.debugIn(LiveInContent(audio: [(voice(200), 24000)]));
      expect(r.player.playing, isFalse);
      await pump();
      expect(r.events.whereType<LiveTurnDone>().single.interrupted, isTrue);
      await r.live.stop();
    });
  });

  // THE CLIENT'S S24 ULTRA, 2026-09-30: after a few turns the screen sat on
  // "Listening" and nothing he said did anything. Every way that could
  // happen now recovers on its own.
  // Owner, 2026-09-30: "the hello sir should not be a recorded audio, I
  // want the same tone which we get from the next conversation."
  group('her hello, in her own voice', () {
    test('Live says it; it is not a turn of the record; listening never waited', () async {
      final r = _Rig();
      await r.live.start();
      expect(r.live.listening, isTrue, reason: 'the microphone is open first');
      expect(r.live.greet('[SYSTEM] Greet me now: "Hello Sir!"'), isTrue);
      expect(r.session.texts.single, contains('Hello Sir!'));
      r.live.debugIn(LiveInContent(audio: [(voice(40), 24000)], said: 'Hello Sir!'));
      r.live.debugIn(const LiveInContent(turnComplete: true));
      await until(() => r.events.whereType<LiveTurnDone>().isNotEmpty);
      final done = r.events.whereType<LiveTurnDone>().single;
      expect(done.opening, isTrue);
      expect(done.reply, 'Hello Sir!');
      await pump();
      expect(r.server.records, isEmpty, reason: 'her hello is not recorded as a turn');
      await r.live.stop();
    });

    test('never over him: not said when he is already talking', () async {
      final r = _Rig();
      await r.live.start();
      for (var i = 0; i < 8; i++) {
        r.live.debugFrame(frame(), 0.6);
      }
      expect(r.live.greet('[SYSTEM] Greet me'), isFalse);
      expect(r.session.texts, isEmpty);
      await r.live.stop();
    });

    test('he starts talking before she has: his words are his own turn', () async {
      final r = _Rig();
      await r.live.start();
      expect(r.live.greet('[SYSTEM] Greet me'), isTrue);
      r.speak(ms: 800);
      r.live.debugIn(const LiveInContent(heard: 'What time is it'));
      r.live.debugIn(LiveInContent(audio: [(voice(40), 24000)], said: "It's five."));
      r.live.debugIn(const LiveInContent(turnComplete: true));
      await until(() => r.events.whereType<LiveTurnDone>().any((d) => !d.opening));
      final his = r.events.whereType<LiveTurnDone>().firstWhere((d) => !d.opening);
      expect(his.user, 'What time is it');
      expect(his.reply, "It's five.");
      await r.live.stop();
    });
  });

  group('never stuck on Listening', () {
    const quick = LiveTimeouts(
      connect: Duration(milliseconds: 300),
      firstReply: Duration(milliseconds: 600),
      afterTool: Duration(milliseconds: 300),
      hearing: Duration(milliseconds: 150),
    );

    /// [ms] of his speech (frames filled with [fill]), then quiet until
    /// this phone's VAD says he stopped.
    void say(_Rig r, {int ms = 1000, int fill = 5}) {
      for (var i = 0; i < ms ~/ 40; i++) {
        r.live.debugFrame(frame(fill), 0.6);
      }
      for (var i = 0; i < 15; i++) {
        r.live.debugFrame(frame(0), 0.005);
      }
    }

    test('the microphone stops sending (a notification paused it): opened again; '
        'for good: the cascade, with the Live microphone closed', () async {
      final r = _Rig(
          timeouts: const LiveTimeouts(
        connect: Duration(milliseconds: 300),
        micSilent: Duration(milliseconds: 200),
      ));
      await r.live.start();
      expect(r.mic.starts, 1);
      await until(() => r.mic.starts == 2, what: 'the microphone opened again');
      expect(r.mic.stops, greaterThanOrEqualTo(1));
      expect(r.live.listening, isTrue);
      expect(r.events.whereType<LiveFallback>(), isEmpty);
      // It never sends again: three times in a minute is enough.
      await until(() => r.events.whereType<LiveFallback>().isNotEmpty, what: 'the hand-over');
      expect(r.mic.starts, 4, reason: 'opened once, then again three times');
      expect(r.events.whereType<LiveFallback>().single.keepLive, isFalse);
      await until(() => !r.live.listening, what: 'the Live microphone closed');
    });

    test('the microphone stream ends: opened again at once', () async {
      final r = _Rig();
      await r.live.start();
      r.mic.onLost!('ended');
      await until(() => r.mic.starts == 2, what: 'the microphone opened again');
      expect(r.live.listening, isTrue);
      await r.live.stop();
    });

    test('a microphone that will not open again: the cascade', () async {
      final r = _Rig();
      await r.live.start();
      r.mic.opens = false;
      r.mic.onLost!('failed');
      await until(() => r.events.whereType<LiveFallback>().isNotEmpty, what: 'the hand-over');
      expect(r.events.whereType<LiveFallback>().single.keepLive, isFalse);
    });

    test('he spoke and the server made no sound: a fresh session hears his words again',
        () async {
      final r = _Rig(timeouts: quick);
      await r.live.start();
      r.live.debugIn(const LiveInResumption(handle: 'h-1', resumable: true));
      say(r);
      await until(() => r.connector.sessions.length == 2, what: 'a fresh session');
      expect(r.connector.handles.last, isNull, reason: 'never resumes the deaf one');
      expect(r.server.contexts, hasLength(2), reason: 'the conversation so far, afresh');
      await until(() => r.connector.sessions.first.closed, what: 'the deaf one closed');
      final fresh = r.session;
      await until(() => fresh.audio.isNotEmpty, what: 'his words sent again');
      expect(fresh.audio.where((a) => a.every((b) => b == 5)).length, 25,
          reason: "all of his words, from the phone's copy");
      expect(fresh.audio.last.every((b) => b == 0), isTrue, reason: 'then silence ends it');
      expect(r.events.whereType<LiveFallback>(), isEmpty);
      // The fresh session answers: an ordinary turn.
      r.live.debugIn(const LiveInContent(heard: 'What time is it'));
      r.live.debugIn(LiveInContent(audio: [(voice(40), 24000)], said: "It's five."));
      r.live.debugIn(const LiveInContent(turnComplete: true));
      await until(() => r.events.whereType<LiveTurnDone>().isNotEmpty, what: 'DONE');
      expect(r.events.whereType<LiveTurnDone>().single.reply, "It's five.");
      await r.live.stop();
    });

    test('a cough brings nothing back, and that is fine', () async {
      final r = _Rig(timeouts: quick);
      await r.live.start();
      say(r, ms: 280);
      await until(() => r.events.whereType<LiveTurnDone>().isNotEmpty, what: 'let go');
      expect(r.connector.sessions, hasLength(1), reason: 'no new session for a cough');
      expect(r.events.whereType<LiveFallback>(), isEmpty);
      await r.live.stop();
    });

    test('both halves of a recorded turn reach the review hook', () async {
      final r = _Rig(timeouts: quick);
      final heard = <LiveTurnAudio>[];
      r.live.onTurnAudio = heard.add;
      await r.live.start();
      say(r);
      r.live.debugIn(const LiveInContent(heard: 'hello there'));
      r.live.debugIn(LiveInContent(
          audio: [(voice(40), 24000)], said: 'Hello Sir.', turnComplete: true));
      await until(() => heard.isNotEmpty, what: 'the turn audio');
      final a = heard.single;
      expect(a.turnId, isNotEmpty);
      expect(a.user, isNotEmpty, reason: 'his microphone frames');
      expect(a.agent, isNotEmpty, reason: 'her reply PCM');
      expect(a.agentRate, 24000);
      await r.live.stop();
    });

    test('a server that sent something heard him: no new session', () async {
      final r = _Rig(timeouts: quick);
      await r.live.start();
      say(r);
      r.live.debugIn(const LiveInPing());
      await until(() => r.events.whereType<LiveTurnDone>().isNotEmpty, what: 'let go');
      expect(r.connector.sessions, hasLength(1));
      // ...but never his words, twice running: it is stuck.
      say(r);
      r.live.debugIn(const LiveInPing());
      await until(() => r.connector.sessions.length == 2, what: 'a fresh session');
      await r.live.stop();
    });

    test('a fresh session hears nothing either: let go once; twice, the cascade says so',
        () async {
      final r = _Rig(timeouts: quick);
      await r.live.start();
      say(r);
      await until(() => r.connector.sessions.length == 2, what: 'the first revival');
      await until(() => r.events.whereType<LiveTurnDone>().isNotEmpty, what: 'let go');
      expect(r.events.whereType<LiveFallback>(), isEmpty, reason: 'maybe it was a clatter');
      say(r);
      await until(() => r.connector.sessions.length == 3, what: 'the second revival');
      await until(() => r.events.whereType<LiveFallback>().isNotEmpty, what: 'the hand-over');
      final f = r.events.whereType<LiveFallback>().single;
      expect(f.keepLive, isFalse);
      expect(f.line, LiveVoice.missedLine, reason: 'he is told, and asked again');
      await until(() => !r.live.listening, what: 'the Live microphone closed');
    });

    test('a fresh session cannot open: the cascade says so', () async {
      final r = _Rig(timeouts: quick);
      await r.live.start();
      r.connector.mode = 'fail';
      say(r);
      await until(() => r.events.whereType<LiveFallback>().isNotEmpty, what: 'the hand-over');
      expect(r.events.whereType<LiveFallback>().single.line, LiveVoice.missedLine);
    });

    test("a microphone too quiet for this phone's VAD: his words start the watch", () async {
      final r = _Rig(
          timeouts: const LiveTimeouts(
        connect: Duration(milliseconds: 300),
        heardOnly: Duration(milliseconds: 300),
      ));
      await r.live.start();
      r.live.debugIn(const LiveInContent(heard: 'What time is it'));
      await until(() => r.events.whereType<LiveFallback>().isNotEmpty, what: 'the cascade');
      expect(r.events.whereType<LiveFallback>().single.words, 'What time is it');
      await r.live.stop();
    });

    test('no answer twice: the cascade answers, with the Live microphone closed', () async {
      final r = _Rig();
      await r.live.start();
      r.speak();
      r.live.debugIn(const LiveInContent(heard: 'What time is it'));
      await until(() => r.events.whereType<LiveFallback>().length == 1);
      expect(r.events.whereType<LiveFallback>().last.keepLive, isTrue);
      r.speak();
      r.live.debugIn(const LiveInContent(heard: 'What time is it now'));
      await until(() => r.events.whereType<LiveFallback>().length == 2);
      final f = r.events.whereType<LiveFallback>().last;
      expect(f.keepLive, isFalse);
      expect(f.words, 'What time is it now', reason: 'the cascade answers them');
      await until(() => !r.live.listening, what: 'the Live microphone closed');
      expect(r.mic.stops, greaterThan(0));
    });

    test('a tool that never comes back is still answered, or the model waits for good',
        () async {
      final r = _Rig(
          timeouts: const LiveTimeouts(
        connect: Duration(milliseconds: 300),
        tool: Duration(milliseconds: 200),
        afterTool: Duration(milliseconds: 300),
      ));
      r.server.hang = Completer<void>();
      await r.live.start();
      r.live.debugIn(const LiveInContent(heard: 'check my calendar'));
      r.live.debugIn(const LiveInToolCall([FunctionCall('get_calendar', {}, id: 'c')]));
      await until(() => r.session.toolResponses.isNotEmpty, what: 'the answer anyway');
      final resp = r.session.toolResponses.single.single;
      expect(resp.id, 'c');
      expect(resp.response['ok'], isFalse);
      await r.live.stop();
    });

    test('the renewed session closes at once: handed over, never left on a dead socket',
        () async {
      final r = _Rig();
      await r.live.start();
      r.connector.mode = 'flaky';
      r.live.debugIn(const LiveInGoAway('5s'));
      await until(() => r.events.whereType<LiveFallback>().isNotEmpty, what: 'the hand-over');
      expect(r.events.whereType<LiveFallback>().last.keepLive, isFalse);
    });
  });

  group('never without an answer', () {
    test('she says nothing in time: the cascade answers the words', () async {
      final r = _Rig();
      await r.live.start();
      r.speak();
      r.live.debugIn(const LiveInContent(heard: 'What time is it'));
      await until(() => r.events.whereType<LiveFallback>().isNotEmpty, what: 'the fallback');
      final f = r.events.whereType<LiveFallback>().single;
      expect(f.words, 'What time is it');
      expect(f.keepLive, isTrue, reason: 'one stall: Live tries the next turn');
      await r.live.stop();
    });

    test('silent after a tool: asked once to say it, then a line is said for her', () async {
      final r = _Rig();
      await r.live.start();
      r.live.debugIn(const LiveInContent(heard: 'check my calendar'));
      r.live.debugIn(const LiveInToolCall([FunctionCall('get_calendar', {}, id: 'c')]));
      await until(() => r.session.toolResponses.isNotEmpty);
      r.live.debugIn(const LiveInContent(turnComplete: true));
      expect(r.session.texts.single, contains('result'));
      await pump();
      expect(r.events.whereType<LiveFallback>(), isEmpty);
      r.live.debugIn(const LiveInContent(turnComplete: true));
      await pump();
      final f = r.events.whereType<LiveFallback>().single;
      expect(f.words, isNull, reason: 'a tool ran: never asked again');
      expect(f.line, 'Done.');
      expect(r.server.tools, hasLength(1));
      await r.live.stop();
    });

    test('a drop: reconnected once, resuming the session', () async {
      final r = _Rig();
      await r.live.start();
      r.live.debugIn(const LiveInResumption(handle: 'h-1', resumable: true));
      await r.session.inbox.close();
      await until(() => r.connector.sessions.length == 2, what: 'the reconnect');
      expect(r.connector.handles.last, 'h-1');
      await until(() => r.live.connected);
      // A second drop in the same turn: the cascade takes over.
      await r.session.inbox.close();
      await until(() => r.events.whereType<LiveFallback>().isNotEmpty);
      expect(r.events.whereType<LiveFallback>().single.keepLive, isFalse);
    });
  });
}
