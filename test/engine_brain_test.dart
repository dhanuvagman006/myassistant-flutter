// THE ENGINE ON THE BRAIN (2026-09-29): every way into the assistant is a
// brain turn, and everything the brain hands the phone is done and
// answered. Driven with a scripted brain, a scripted recogniser and a
// player that plays into nothing.
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/ai/brain.dart';
import 'package:firebase_ai/firebase_ai.dart' show FunctionCall, FunctionResponse;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:myassistant/ai/listen.dart';
import 'package:myassistant/ai/live_voice.dart';
import 'package:myassistant/ai/speech.dart';
import 'package:myassistant/ai/tool_server.dart';
import 'package:myassistant/ai/types.dart' show AiAttachment, AiToolSpec;
import 'package:myassistant/services/audio/mic_stream.dart';
import 'package:myassistant/features/assistant/state/assistant_engine.dart';
import 'package:myassistant/features/assistant/state/assistant_state.dart';
import 'package:myassistant/services/api_service.dart';
import 'package:myassistant/services/audio/pcm_player.dart';
import 'package:myassistant/services/greeting_voice.dart';
import 'package:myassistant/services/location_service.dart';

import 'ai/fakes.dart';
import 'helpers/fake_brain.dart';

/// The phone's recogniser, scripted: each listen hears the next entry
/// ('' = silence); with nothing left it keeps listening.
class ScriptedRecognizer implements RecognizerPort {
  final said = <String>[];
  var listens = 0;

  @override
  Future<bool> initialize({
    required void Function(String status) onStatus,
    required void Function(String error, bool permanent) onError,
  }) async =>
      true;

  @override
  Future<List<String>> localeIds() async => const ['en-IN'];

  @override
  Future<void> listen({
    required void Function(String words, bool isFinal) onResult,
    void Function(double level)? onLevel,
    String? localeId,
    required bool onDevice,
    required Duration listenFor,
    required Duration pauseFor,
  }) async {
    listens++;
    if (said.isEmpty) return;
    final words = said.removeAt(0);
    scheduleMicrotask(() {
      if (words.isNotEmpty) onResult(words, false);
      onResult(words, true);
    });
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> cancel() async {}
}

/// THE FAST VOICE's outside world, scripted (2026-09-30).
class _LiveSession implements LiveSessionPort {
  final inbox = StreamController<LiveIn>();
  final responses = <List<FunctionResponse>>[];

  @override
  Stream<LiveIn> get messages => inbox.stream;

  @override
  void sendAudio(Uint8List pcm16) {}

  @override
  void sendText(String text) {}

  @override
  void sendToolResponses(List<FunctionResponse> r) => responses.add(r);

  @override
  Future<void> close() async {
    if (!inbox.isClosed) await inbox.close();
  }
}

class _LiveConnector implements LiveConnector {
  bool fail = false;
  final sessions = <_LiveSession>[];

  @override
  Future<LiveSessionPort> connect(LiveSetup setup, {String? resumeHandle}) async {
    if (fail) throw StateError('no socket');
    final s = _LiveSession();
    sessions.add(s);
    scheduleMicrotask(() => s.inbox.add(const LiveInReady()));
    return s;
  }
}

class _LiveServer extends ToolServer {
  _LiveServer() : super(client: MockClient((_) async => http.Response('', 500)));

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
  }) async =>
      const AiContext(
        sessionId: 's1',
        turnId: 't1',
        system: 'LIVE',
        tools: [AiToolSpec(name: 'get_calendar', description: 'Reads the calendar.')],
      );

  @override
  Future<AiContext?> openLiveTurn({
    required String? sessionId,
    Map<String, Object?> device = const {},
    Duration timeout = const Duration(seconds: 8),
  }) async =>
      const AiContext(sessionId: 's1', turnId: 't2');

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
  }) async =>
      AiTurnReceipt(reply: reply);
}

class _LiveMic extends MicStream {
  @override
  Future<bool> start(void Function(Uint8List pcm, double? level) onFrame,
          {int? bufferBytes, void Function(String why)? onLost}) async =>
      true;

  @override
  Future<void> stop() async {}
}

Future<void> until(bool Function() ok, {String what = 'the condition'}) async {
  for (var i = 0; i < 300; i++) {
    if (ok()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('timed out waiting for $what');
}

Uint8List pcm(int ms) => Uint8List(24 * ms * 2);

void main() {
  _unfinishedWordsTests();
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  for (final c in [
    SystemChannels.platform,
    const MethodChannel('xyz.luan/audioplayers'),
    const MethodChannel('xyz.luan/audioplayers.global'),
    const MethodChannel('com.llfbandit.record/messages'),
  ]) {
    messenger.setMockMethodCallHandler(c, (_) async => null);
  }

  final engine = AssistantEngine.instance;
  late FakeBrain brain;
  late ScriptedRecognizer ears;
  late SilentOutput out;
  late PcmPlayer player;
  late FakeModel voice;

  setUp(() {
    brain = FakeBrain();
    ears = ScriptedRecognizer();
    out = SilentOutput();
    player = PcmPlayer(output: out);
    voice = FakeModel();
    engine
      ..debugMarkStarted()
      ..debugUse(
        brain: brain,
        listener: VoiceListener(recognizer: ears, config: () => const AiConfig()),
        player: player,
        speech: SpeechEngine(port: voice, config: () => const AiConfig()),
      );
  });

  tearDown(() async {
    await engine.leaveConversation(chime: false);
    engine
      ..dismissError()
      ..cancelReconnect();
  });

  Future<void> talk() async {
    await engine.beginInlineConversation(name: 'Dhanush');
    expect(engine.liveActive, isTrue);
  }

  group('the voice conversation', () {
    test('listen -> a voice turn -> captions -> listen again', () async {
      ears.said.add('what time is it');
      brain.scripts.add((emit) async {
        emit(const BrainRouteChosen(AiRoute.cloud, 'conversation'));
        emit(const BrainPartialText('It is', 'It is'));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        emit(const BrainPartialText('It is ten past five.', ' ten past five.'));
        emit(const BrainFinalText(text: 'It is ten past five.', route: AiRoute.cloud));
      });
      await talk();
      await until(() => brain.turns.isNotEmpty, what: 'the turn');
      expect(brain.turns.single.text, 'what time is it');
      expect(brain.turns.single.mode, BrainMode.voice);
      await until(() => engine.caption.value?.text == 'It is ten past five.', what: 'the caption');
      expect(engine.caption.value!.speaker, 'hari');
      expect(engine.transcript.map((t) => t.text).toList().sublist(engine.transcript.length - 2),
          ['what time is it', 'It is ten past five.']);
      await until(() => ears.listens >= 2, what: 'listening again');
      expect(engine.phase, AssistantPhase.listening);
    });

    test('barge-in: a tap while she speaks stops her and the turn; it listens', () async {
      ears.said.add('tell me a long story');
      final stopped = Completer<void>();
      brain.scripts.add((emit) async {
        emit(const BrainPartialText('Once upon a time', 'Once upon a time'));
        await player.play(pcm(3000), sampleRate: 24000); // the brain's sink
        await stopped.future; // speaking until interrupted
      });
      await talk();
      await until(() => engine.phase == AssistantPhase.speaking, what: 'her voice');
      final before = ears.listens;
      await engine.bargeIn();
      stopped.complete();
      expect(brain.cancels, greaterThanOrEqualTo(1));
      expect(player.playing, isFalse);
      expect(out.stops, greaterThanOrEqualTo(1));
      await until(() => ears.listens > before, what: 'listening after the barge-in');
      expect(engine.phase, AssistantPhase.listening);
    });

    test('"bye" / end_conversation: her farewell plays, then it all closes', () async {
      ears.said.add('that is all');
      brain.scripts.add((emit) async {
        final done = Completer<DeviceOutcome>();
        emit(BrainDeviceAction(
            tool: 'end_conversation',
            action: const {'type': 'end_conversation'},
            respond: done.complete));
        expect((await done.future).ok, isTrue);
        emit(const BrainFinalText(text: 'Goodbye, Sir.', route: AiRoute.cloud));
        await player.play(pcm(60), sampleRate: 24000);
      });
      await talk();
      await until(() => !engine.liveActive && !engine.inlineVoice, what: 'the conversation to close');
      expect(engine.phase, AssistantPhase.idle);
    });

    test('a typed message in the conversation: a chat turn, answered out loud', () async {
      await talk();
      brain.scripts.add((emit) async {
        emit(const BrainFinalText(text: 'Hello!', route: AiRoute.cloud));
      });
      await engine.sendTypedMessage('hi there');
      expect(brain.turns.last.text, 'hi there');
      expect(brain.turns.last.mode, BrainMode.chat);
      expect(brain.turns.last.speak, isTrue);
    });

    test('the model stayed silent: nothing shown for her', () async {
      await talk();
      brain.scripts.add((emit) async {
        emit(const BrainFinalText(text: '', route: AiRoute.cloud, corrected: true));
      });
      final lines = engine.transcript.length;
      await engine.askAssistant('and the crowd goes wild');
      expect(engine.transcript.length, lines + 1, reason: 'only the words heard');
      expect(engine.caption.value?.speaker, 'you');
    });
  });

  group('device actions', () {
    Future<DeviceOutcome> act(Map<String, dynamic> action) async {
      final answer = Completer<DeviceOutcome>();
      brain.scripts.add((emit) async {
        emit(BrainDeviceAction(tool: 'tool', action: action, respond: answer.complete));
        await answer.future;
        emit(const BrainFinalText(text: 'Done.', route: AiRoute.cloud));
      });
      await engine.askAssistant('do it ${action['type']} ${DateTime.now().microsecondsSinceEpoch}');
      return answer.future.timeout(const Duration(seconds: 5));
    }

    test('performed through the same switch, and answered', () async {
      final o = await act({'type': 'show_text', 'title': 'Toast', 'content': 'Friends, …'});
      expect(o.ok, isTrue);
      expect(engine.presentedText, 'Friends, …');
      engine.dismissPresentedText();
    });

    test('a failure the phone reports is the answer', () async {
      final o = await act({'type': 'open_app_screen', 'screen': 'no_such_screen'});
      expect(o.ok, isFalse);
      expect(o.detail, contains('not available'));
    });

    test('a [SYSTEM] note said while it runs IS its outcome', () async {
      final o = await act({'type': 'open_video'});
      expect(o.ok, isFalse);
      expect(o.detail, contains('face-to-face video is not available'));
      expect(brain.turns.length, 1, reason: 'no second turn for it');
    });
  });

  group('confirmations and choices', () {
    test('the card, then its button is the yes (or no) of the next turn', () async {
      brain.scripts.add((emit) async {
        emit(const BrainNeedsConfirmation(
            tool: 'send_message',
            args: {'to': 'Amma', 'text': 'hi'},
            summary: "Send 'hi' to Amma",
            approvalToken: 'tok'));
        emit(const BrainFinalText(text: "Shall I send 'hi' to Amma?", route: AiRoute.cloud));
      });
      await engine.askAssistant('send hi to amma');
      expect(engine.pendingConfirmation?.question, "Send 'hi' to Amma");
      brain.scripts.add((emit) async {
        emit(const BrainFinalText(text: 'Sent.', route: AiRoute.cloud));
      });
      await engine.confirm(true);
      expect(brain.turns.last.text, 'Yes');
      expect(engine.pendingConfirmation, isNull);
      await engine.confirm(false);
      expect(brain.turns.last.text, 'No');
    });
  });

  group("the app's own notes", () {
    test('outside a turn a note starts one — after the turn running now', () async {
      final release = Completer<void>();
      brain.scripts.add((emit) async {
        await release.future;
        emit(const BrainFinalText(text: 'Here is your day.', route: AiRoute.cloud));
      });
      unawaited(engine.askAssistant('brief me'));
      await until(() => brain.turns.length == 1, what: 'the first turn');
      unawaited(engine.tellModel('[SYSTEM] The call to Ravi has ended. Result: he will come.'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(brain.turns.length, 1, reason: 'never over the turn running');
      release.complete();
      await until(() => brain.turns.length == 2, what: 'the note turn');
      final note = brain.turns.last;
      expect(note.text, startsWith('[SYSTEM] The call to Ravi has ended.'));
      expect(note.mode, BrainMode.voice);
      expect(note.untrusted, isFalse);
      expect(engine.transcript.where((t) => t.text.startsWith('[SYSTEM]')), isEmpty,
          reason: "the app's notes are not the owner's words");
    });

    test("someone else's message is an untrusted turn", () async {
      await engine.debugNote("[SYSTEM] New message just arrived. Read to me now: Hey, Ravi said: hi",
          untrusted: true);
      await until(() => brain.turns.isNotEmpty, what: 'the turn');
      expect(brain.turns.single.untrusted, isTrue);
    });
  });

  group('grounded answers', () {
    test("the pages and Google's search suggestions are shown with the reply", () async {
      brain.scripts.add((emit) async {
        emit(const BrainFinalText(
          text: 'India won by six wickets.',
          route: AiRoute.search,
          sources: [SourceLink(uri: 'https://www.espncricinfo.com/match/1', title: 'espncricinfo.com')],
          searchSuggestionsHtml:
              '<div class="carousel"><a class="chip" href="https://www.google.com/search?q=india+match">india match</a></div>',
        ));
      });
      await engine.askAssistant('who won the match today');
      expect(engine.searchResults.single.url, 'https://www.espncricinfo.com/match/1');
      expect(engine.searchSuggestions.single.label, 'india match');
      engine.dismissSearchResults();
      expect(engine.searchSuggestions, isEmpty);
    });
  });

  group('her voice without a model', () {
    test('the spoken greeting is a fixed line, straight through the speech engine', () async {
      await talk();
      voice.script.add(audioResponse(List.filled(4800, 1)));
      engine
        ..greetingEnabled = true
        ..resetGreeting();
      await engine.greetOnce(name: 'Dhanush');
      engine.greetingEnabled = false;
      expect(voice.requests, isNotEmpty);
      expect(out.written, isNotEmpty);
      expect(engine.transcript.last.text, startsWith('Good '));
      expect(brain.turns, isEmpty, reason: 'no model wrote it');
    });

    test('the orb greeting is cached once in her voice, then played from the file', () async {
      final dir = await Directory.systemTemp.createTemp('greet');
      addTearDown(() => dir.delete(recursive: true));
      final model = FakeModel([audioResponse(List.filled(4800, 7))]);
      final sink = RecordingSink();
      final g = GreetingVoice(
        speech: SpeechEngine(port: model, config: () => const AiConfig()),
        sink: sink,
        config: () => const AiConfig(),
        directory: () async => dir,
      );
      expect(await g.play('Hello Sir!'), isFalse, reason: 'not cached yet: silent');
      await until(
          () => dir.listSync().whereType<File>().any((f) => f.lengthSync() > 2000),
          what: 'the cache');
      // Written and closed (Windows will not delete a file still open).
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(await g.play('Hello Sir!'), isTrue);
      expect(sink.played.single.length, 4800);
      expect(sink.rates.single, 24000);
      expect(model.requests.length, 1, reason: 'one model call, ever');
      await g.clear();
      expect(dir.listSync(), isEmpty);
    });
  });

  group('where the owner is', () {
    test('every turn carries the position (it used to ride the live socket)', () async {
      ApiService.geoLat = 12.87041;
      ApiService.geoLng = 74.84312;
      LocationService.instance.accuracy = 18.4;
      addTearDown(() {
        ApiService.geoLat = null;
        ApiService.geoLng = null;
        LocationService.instance.accuracy = null;
      });
      final ctx = await AssistantEngine.debugDeviceContext();
      expect(ctx['lat'], 12.8704);
      expect(ctx['lng'], 74.8431);
      expect(ctx['acc'], 18);
      expect(ctx['caps'], isA<Map>());
    });

    test("which requests need the owner's position", () {
      for (final yes in [
        'restaurants near me',
        'any petrol pump nearby?',
        'nearest hospital',
        'where am I',
        'book a cab to the airport',
        'how far is the station',
        'directions to Kadri park',
      ]) {
        expect(LocationService.needsHere(yes), isTrue, reason: yes);
      }
      for (final no in ['weather in Delhi', 'call Ravi', 'what is the time', 'remind me at 5']) {
        expect(LocationService.needsHere(no), isFalse, reason: no);
      }
      expect(LocationService.locationTools, {'book_ride'});
    });

    test('a call the assistant placed keeps the conversation open', () {
      final t0 = DateTime(2026, 9, 24, 10);
      bool running(String? status, Duration ago) => AssistantEngine.callStillRunning(
          status == null ? null : CallStatusInfo(status: status, contactName: 'the clinic'),
          t0,
          t0.add(ago));
      for (final s in ['dialing', 'ringing', 'in_progress', 'summarizing']) {
        expect(running(s, const Duration(minutes: 2)), isTrue, reason: s);
      }
      for (final s in ['completed', 'failed', 'no_answer', 'ended', 'timeout', 'cancelled']) {
        expect(running(s, Duration.zero), isFalse, reason: s);
      }
      expect(running(null, Duration.zero), isFalse);
      expect(running('in_progress', const Duration(minutes: 5)), isFalse,
          reason: "past the server's own 180 s limit it is over");
    });
  });

  group('the fast voice (Gemini Live)', () {
    late _LiveConnector connector;
    late LiveVoice live;

    LiveVoice makeLive() => LiveVoice(
          connector: connector,
          server: _LiveServer(),
          brain: brain,
          player: player,
          mic: _LiveMic(),
          configs: AiConfigStore(fetch: () async => const {'live': {'on': true}}),
          enabled: () => true,
          timeouts: const LiveTimeouts(
            connect: Duration(milliseconds: 300),
            firstReply: Duration(milliseconds: 400),
          ),
        );

    setUp(() {
      connector = _LiveConnector();
      live = makeLive();
      engine.debugUse(
        brain: brain,
        listener: VoiceListener(recognizer: ears, config: () => const AiConfig()),
        player: player,
        speech: SpeechEngine(port: voice, config: () => const AiConfig()),
        live: live,
      );
    });

    void speak(String words) {
      for (var i = 0; i < 8; i++) {
        live.debugFrame(Uint8List(1280), 0.6);
      }
      live.debugIn(LiveInContent(heard: words));
      for (var i = 0; i < 20; i++) {
        live.debugFrame(Uint8List(1280), 0.005);
      }
    }

    test('LISTENING -> THINKING -> RESPONDING -> SPEAKING -> DONE -> LISTENING', () async {
      await talk();
      await until(() => engine.fastVoice, what: 'the fast voice');
      expect(engine.phase, AssistantPhase.listening);
      expect(ears.listens, 0, reason: "Live has the microphone, not the phone's recogniser");
      final seen = <AssistantPhase>[];
      void note() {
        if (seen.isEmpty || seen.last != engine.phase) seen.add(engine.phase);
      }

      engine.addListener(note);
      addTearDown(() => engine.removeListener(note));
      speak("What's on my calendar tomorrow?");
      await until(() => engine.phase == AssistantPhase.thinking, what: 'THINKING');
      live.debugIn(const LiveInToolCall([FunctionCall('get_calendar', {'day': 'tomorrow'}, id: 'c1')]));
      await until(() => connector.sessions.single.responses.isNotEmpty, what: 'the tool answer');
      await until(() => engine.phase == AssistantPhase.responding, what: 'RESPONDING');
      expect(engine.phaseLabel, 'Checking your calendar…');
      expect(brain.liveToolCalls.single.userText, "What's on my calendar tomorrow?");
      expect(connector.sessions.single.responses.single.single.id, 'c1');
      live.debugIn(LiveInContent(audio: [(pcm(40), 24000)], said: 'Two things tomorrow.'));
      await until(() => engine.phase == AssistantPhase.speaking, what: 'SPEAKING');
      live.debugIn(const LiveInContent(turnComplete: true));
      await until(() => engine.phase == AssistantPhase.completed, what: 'DONE');
      await until(() => engine.phase == AssistantPhase.listening, what: 'LISTENING again');
      expect(seen, [
        AssistantPhase.listening,
        AssistantPhase.thinking,
        AssistantPhase.responding,
        AssistantPhase.speaking,
        AssistantPhase.completed,
        AssistantPhase.listening,
      ]);
      expect(engine.transcript.map((t) => t.text).toList().sublist(engine.transcript.length - 2),
          ["What's on my calendar tomorrow?", 'Two things tomorrow.']);
      expect(brain.turns, isEmpty, reason: 'no cascade turn');
    });

    test('Live cannot connect: the classic voice listens and answers', () async {
      connector.fail = true;
      ears.said.add('what time is it');
      brain.scripts.add((emit) async {
        emit(const BrainFinalText(text: 'It is five.', route: AiRoute.cloud));
      });
      await talk();
      await until(() => brain.turns.isNotEmpty, what: 'the cascade turn');
      expect(engine.fastVoice, isFalse);
      expect(brain.turns.single.text, 'what time is it');
    });

    test('Live says nothing in time: the cascade answers the same words', () async {
      brain.scripts.add((emit) async {
        emit(const BrainFinalText(text: 'It is five.', route: AiRoute.cloud));
      });
      int asked() => engine.transcript.where((t) => t.text == 'what time is it').length;
      final before = asked();
      await talk();
      await until(() => engine.fastVoice, what: 'the fast voice');
      speak('what time is it');
      await until(() => brain.turns.isNotEmpty, what: 'the cascade answering');
      expect(brain.turns.single.text, 'what time is it');
      expect(brain.turns.single.mode, BrainMode.voice);
      await until(() => engine.transcript.any((t) => t.text == 'It is five.'));
      expect(asked() - before, 1, reason: 'one bubble for the question');
    });

    // The client's S24 Ultra, 2026-09-30: after the second stall the
    // classic voice took over while the Live microphone still ran — and
    // Android gives the phone's recogniser silence while another capture
    // is open, so it sat on "Listening" hearing nothing.
    test("Live gives up: its microphone closes before the phone's recogniser listens",
        () async {
      for (var i = 0; i < 2; i++) {
        brain.scripts.add((emit) async {
          emit(const BrainFinalText(text: 'It is five.', route: AiRoute.cloud));
        });
      }
      await talk();
      await until(() => engine.fastVoice, what: 'the fast voice');
      speak('what time is it');
      await until(() => brain.turns.length == 1, what: 'the first cascade answer');
      await until(() => engine.fastVoice && live.listening, what: 'Live listening again');
      speak('what time is it now');
      await until(() => brain.turns.length == 2, what: 'the second cascade answer');
      expect(brain.turns.last.text, 'what time is it now');
      await until(() => !engine.fastVoice, what: 'the classic voice from here');
      await until(() => !live.listening, what: 'the Live microphone closed');
      await until(() => ears.listens > 0, what: "the phone's recogniser listening");
    });
  });
}

// Half a sentence must never reach the cascade while Live is still
// listening (client's phone, 2026-10-01: "Tell me the", "He is" were
// answered twice).
void _unfinishedWordsTests() {
  test('half a sentence is unfinished; a whole request is not', () {
    for (final w in ['Tell me the', 'Can you tell me about Dr.', 'He is',
        'Now tell me about', 'I want you to', 'Okay, can you tell me about']) {
      expect(AssistantEngine.looksUnfinished(w), isTrue, reason: w);
    }
    for (final w in ['What?', 'Stop', 'Call Amma', 'Tell me the news',
        'ಸುದ್ದಿ ಹೇಳು', 'Open Swiggy', 'Remind me at 6', 'what time is it',
        'tell me what time it is', 'turn it on', 'who is he']) {
      expect(AssistantEngine.looksUnfinished(w), isFalse, reason: w);
    }
  });
}
