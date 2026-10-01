import 'dart:async';
import 'dart:typed_data';

import 'package:firebase_ai/firebase_ai.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/ai/config.dart';
import 'package:myassistant/ai/listen.dart';

import 'fakes.dart';

class _FakeRecognizer implements RecognizerPort {
  bool available = true;
  List<String> locales = ['en_US', 'en_IN', 'ml_IN', 'hi_IN'];
  final listens = <({String? locale, bool onDevice, Duration pauseFor})>[];
  void Function(String status)? onStatus;
  void Function(String error, bool permanent)? onError;
  void Function(String words, bool isFinal)? onResult;
  void Function(double level)? onLevel;
  var stops = 0;
  var cancels = 0;

  @override
  Future<bool> initialize({
    required void Function(String status) onStatus,
    required void Function(String error, bool permanent) onError,
  }) async {
    this.onStatus = onStatus;
    this.onError = onError;
    return available;
  }

  @override
  Future<List<String>> localeIds() async => locales;

  @override
  Future<void> listen({
    required void Function(String words, bool isFinal) onResult,
    void Function(double level)? onLevel,
    String? localeId,
    required bool onDevice,
    required Duration listenFor,
    required Duration pauseFor,
  }) async {
    this.onResult = onResult;
    this.onLevel = onLevel;
    listens.add((locale: localeId, onDevice: onDevice, pauseFor: pauseFor));
    // Like the plugin: 'listening' arrives after the call, over the channel.
    scheduleMicrotask(() => onStatus?.call('listening'));
  }

  @override
  Future<void> stop() async => stops++;

  @override
  Future<void> cancel() async => cancels++;
}

class _FakeRecorder implements RecorderPort {
  bool canStart = true;
  final levelsController = StreamController<double>.broadcast();
  RecordedAudio? audio = RecordedAudio(Uint8List.fromList([1, 2, 3]), 'audio/wav');
  var started = 0;
  var stopped = 0;
  var cancelled = 0;

  @override
  Future<bool> start() async {
    started++;
    return canStart;
  }

  @override
  Stream<double> get levels => levelsController.stream;

  @override
  Future<RecordedAudio?> stop() async {
    stopped++;
    return audio;
  }

  @override
  Future<void> cancel() async => cancelled++;
}

Future<void> _tick() => Future<void>.delayed(Duration.zero);

void main() {
  const config = AiConfig(models: AiModels(ttsLanguage: 'ml-IN', cloudFast: 'fast-model'));

  group('the phone recogniser', () {
    test('partials for captions, end of speech, then the final words', () async {
      final r = _FakeRecognizer();
      final l = VoiceListener(recognizer: r, config: () => config);
      final events = <HearEvent>[];
      final done = Completer<void>();
      l.listen().listen(events.add, onDone: done.complete);
      await _tick();
      expect(r.listens.single.locale, 'ml_IN', reason: "the user's language");
      expect(r.listens.single.onDevice, isTrue, reason: 'on-device first');
      r.onLevel!(0.7);
      r.onResult!('amma', false);
      r.onResult!('amma', false); // repeated: no new caption
      r.onResult!('ammaye vilikku', false);
      r.onStatus!('done');
      r.onResult!('ammaye vilikku', true);
      await done.future;
      expect(events.whereType<HearPartial>().map((e) => e.text), ['amma', 'ammaye vilikku']);
      expect(events.whereType<HearLevel>().single.level, 0.7);
      expect(events.whereType<HearEndOfSpeech>().length, 1);
      final last = events.last as HearFinal;
      expect(last.text, 'ammaye vilikku');
      expect(last.fromCloud, isFalse);
    });

    test('the pause is timed from the last words, never from the start', () async {
      // 2026-09-30 (voice audit): 1.4 s from the start of listening cut off
      // slow starters and cost every turn; now [pauseFor] after the last
      // new words ends it, and the plugin only gets a long safety net.
      final r = _FakeRecognizer();
      final l = VoiceListener(recognizer: r, config: () => config);
      final events = <HearEvent>[];
      final done = Completer<void>();
      l.listen(pauseFor: const Duration(milliseconds: 60)).listen(events.add, onDone: done.complete);
      await _tick();
      expect(r.listens.single.pauseFor, VoiceListener.recognizerPause);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(r.stops, 0, reason: 'nothing said yet: nothing ends');
      r.onResult!('what is', false);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      r.onResult!('what is the time', false);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(r.stops, 0, reason: 'still talking');
      await done.future.timeout(const Duration(seconds: 2));
      expect(r.stops, 1, reason: 'the recogniser is stopped for its final words');
      expect(events.whereType<HearEndOfSpeech>().length, 1);
      expect((events.last as HearFinal).text, 'what is the time');
    });

    test('when no final result comes, what was heard is final once it is done', () async {
      final r = _FakeRecognizer();
      final l = VoiceListener(recognizer: r, config: () => config);
      final events = <HearEvent>[];
      final done = Completer<void>();
      l.listen().listen(events.add, onDone: done.complete);
      await _tick();
      r.onResult!('what time is it', false);
      r.onStatus!('notListening');
      await done.future;
      expect((events.last as HearFinal).text, 'what time is it');
    });

    test('on-device fails before any words: tried again online, once', () async {
      final r = _FakeRecognizer();
      final l = VoiceListener(recognizer: r, config: () => config);
      final events = <HearEvent>[];
      final done = Completer<void>();
      l.listen().listen(events.add, onDone: done.complete);
      await _tick();
      r.onError!('error_language_unavailable', false);
      await _tick();
      expect(r.listens.map((x) => x.onDevice), [true, false]);
      r.onResult!('hello', true);
      await done.future;
      expect((events.last as HearFinal).text, 'hello');
    });

    test("the failed session's own done does not end the retry", () async {
      final r = _FakeRecognizer();
      final l = VoiceListener(recognizer: r, config: () => config);
      final events = <HearEvent>[];
      final done = Completer<void>();
      l.listen().listen(events.add, onDone: done.complete);
      await _tick();
      // Real recognisers send the error, then "done", then the retry
      // starts listening. Hold the retry's start until after "done".
      final retryStarted = r.listens.length;
      r.onError!('error_language_unavailable', false);
      r.onStatus!('done');
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(events.whereType<HearFinal>(), isEmpty);
      expect(r.listens.length, retryStarted + 1);
      r.onResult!('still here', true);
      await done.future;
      expect((events.last as HearFinal).text, 'still here');
    });

    test('as the plugin really fails: "done" first, every error permanent; a new recogniser answers', () async {
      final r = _FakeRecognizer();
      final l = VoiceListener(recognizer: r, config: () => config);
      final events = <HearEvent>[];
      final done = Completer<void>();
      l.listen().listen(events.add, onDone: done.complete);
      await _tick();
      // Android 16, a reused on-device recogniser: over at once.
      r.onStatus!('notListening');
      r.onStatus!('doneNoResult');
      r.onError!('error_server_disconnected', true);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(r.listens.map((x) => x.onDevice), [true, false], reason: 'the other kind, made new');
      expect(events.whereType<HearError>(), isEmpty);
      expect(events.whereType<HearFinal>(), isEmpty, reason: 'the grace timer does not end it');
      expect(events.whereType<HearEndOfSpeech>(), isEmpty, reason: 'nothing was said');
      r.onResult!('what is the time', true);
      await done.future;
      expect((events.last as HearFinal).text, 'what is the time');
    });

    test('the new recogniser fails too: the words are recorded and written down in the cloud', () async {
      final r = _FakeRecognizer();
      final rec = _FakeRecorder();
      final model = FakeModel([textChunk('call amma')]);
      var now = DateTime(2026, 9, 29, 20);
      final l = VoiceListener(
        recognizer: r,
        recorder: rec,
        transcriber: CloudTranscriber(port: model, config: () => config),
        config: () => config,
        now: () => now,
      );
      final events = <HearEvent>[];
      final done = Completer<void>();
      l.listen(pauseFor: const Duration(milliseconds: 500)).listen(events.add, onDone: done.complete);
      await _tick();
      r.onError!('error_server_disconnected', true);
      await _tick();
      r.onError!('error_busy', true);
      await _tick();
      expect(r.listens.length, 2);
      expect(rec.started, 1, reason: 'the cloud fallback');
      rec.levelsController.add(0.9);
      rec.levelsController.add(0.05); // quiet from here
      await _tick();
      now = now.add(const Duration(milliseconds: 600));
      rec.levelsController.add(0.05); // quiet long enough
      await done.future;
      expect((events.last as HearFinal).text, 'call amma');
      expect((events.last as HearFinal).fromCloud, isTrue);
    });

    test('with no cloud fallback, a second failure is said, not retried forever', () async {
      final r = _FakeRecognizer();
      final l = VoiceListener(recognizer: r, config: () => config);
      final events = <HearEvent>[];
      final done = Completer<void>();
      l.listen().listen(events.add, onDone: done.complete);
      await _tick();
      r.onError!('error_server_disconnected', true);
      await _tick();
      r.onError!('error_network', true);
      await done.future;
      expect(r.listens.length, 2);
      final err = events.last as HearError;
      expect(err.code, 'network');
      expect(err.permanent, isFalse, reason: "the plugin's flag is not the listener's");
    });

    test('silence ends with empty words; a permission error is said as such', () async {
      final r = _FakeRecognizer();
      final l = VoiceListener(recognizer: r, config: () => config);
      final quiet = <HearEvent>[];
      final done = Completer<void>();
      l.listen().listen(quiet.add, onDone: done.complete);
      await _tick();
      r.onError!('error_speech_timeout', false);
      await done.future;
      expect((quiet.last as HearFinal).text, '');

      final refused = <HearEvent>[];
      final done2 = Completer<void>();
      l.listen(preferOnDevice: false).listen(refused.add, onDone: done2.complete);
      await _tick();
      r.onError!('error_insufficient_permissions', true);
      await done2.future;
      expect((refused.last as HearError).code, 'permission');
      expect((refused.last as HearError).permanent, isTrue);
    });

    test('stop() makes the words so far final; cancel() drops them', () async {
      final r = _FakeRecognizer();
      final l = VoiceListener(recognizer: r, config: () => config);
      final events = <HearEvent>[];
      final done = Completer<void>();
      l.listen().listen(events.add, onDone: done.complete);
      await _tick();
      r.onResult!('turn on the', false);
      await l.stop();
      await done.future;
      expect((events.last as HearFinal).text, 'turn on the');
      expect(r.stops, 1);

      final dropped = <HearEvent>[];
      final done2 = Completer<void>();
      l.listen().listen(dropped.add, onDone: done2.complete);
      await _tick();
      r.onResult!('never mind', false);
      await l.cancel();
      await done2.future;
      expect(dropped.whereType<HearFinal>(), isEmpty);
      expect(r.cancels, 1);
    });

    test('locales: exact, same language elsewhere, or the phone default', () {
      expect(resolveLocale('en-IN', ['en_US', 'en_IN']), 'en_IN');
      expect(resolveLocale('ml-IN', ['en_US', 'ml_IN']), 'ml_IN');
      expect(resolveLocale('en-AU', ['en_US', 'hi_IN']), 'en_US');
      expect(resolveLocale('ta-IN', ['en_US', 'hi_IN']), isNull);
      expect(resolveLocale('kn-IN', const []), 'kn-IN');
      expect(resolveLocale(null, ['en_US']), isNull);
    });
  });

  group('the cloud fallback (no recogniser on the phone)', () {
    test('records until the user stops talking, then transcribes with cloudFast', () async {
      final r = _FakeRecognizer()..available = false;
      final rec = _FakeRecorder();
      final model = FakeModel([textChunk('  "അമ്മയെ വിളിക്കൂ"  ')]);
      var now = DateTime(2026, 9, 29, 10);
      final l = VoiceListener(
        recognizer: r,
        recorder: rec,
        transcriber: CloudTranscriber(port: model, config: () => config),
        config: () => config,
        now: () => now,
      );
      final events = <HearEvent>[];
      final done = Completer<void>();
      l.listen(pauseFor: const Duration(milliseconds: 800))
          .listen(events.add, onDone: done.complete);
      await _tick();
      expect(rec.started, 1);
      rec.levelsController.add(0.1); // quiet before speaking: not the end
      now = now.add(const Duration(seconds: 2));
      rec.levelsController.add(0.1);
      rec.levelsController.add(0.8); // speech
      rec.levelsController.add(0.1);
      await _tick();
      now = now.add(const Duration(milliseconds: 900));
      rec.levelsController.add(0.1); // quiet long enough
      await done.future;

      expect(events.whereType<HearEndOfSpeech>().length, 1);
      final last = events.last as HearFinal;
      expect(last.text, 'അമ്മയെ വിളിക്കൂ');
      expect(last.fromCloud, isTrue);
      final req = model.requests.single;
      expect(req.model, 'fast-model');
      final parts = req.contents.single.parts;
      expect((parts[0] as TextPart).text, contains('ml-IN'));
      expect((parts[1] as InlineDataPart).mimeType, 'audio/wav');
      expect((parts[1] as InlineDataPart).bytes, [1, 2, 3]);
      expect(rec.stopped, 1);
    });

    test('nothing said: empty words and no cloud call', () async {
      final rec = _FakeRecorder();
      final model = FakeModel();
      final l = VoiceListener(
        recognizer: _FakeRecognizer()..available = false,
        recorder: rec,
        transcriber: CloudTranscriber(port: model, config: () => config),
        config: () => config,
      );
      final events = <HearEvent>[];
      final done = Completer<void>();
      l.listen().listen(events.add, onDone: done.complete);
      await _tick();
      await l.stop();
      await done.future;
      expect((events.last as HearFinal).text, '');
      expect(model.requests, isEmpty);
    });

    test('no recorder, or the microphone refused: an error, said plainly', () async {
      Future<HearEvent> last(VoiceListener l) async => (await l.listen().toList()).last;
      final none = await last(VoiceListener(
        recognizer: _FakeRecognizer()..available = false,
        config: () => config,
      ));
      expect((none as HearError).code, 'unavailable');
      final rec = _FakeRecorder()..canStart = false;
      final refused = await last(VoiceListener(
        recognizer: _FakeRecognizer()..available = false,
        recorder: rec,
        transcriber: CloudTranscriber(port: FakeModel(), config: () => config),
        config: () => config,
      ));
      expect((refused as HearError).code, 'recorder');
    });

    test('a failed transcription is empty words, not a crash', () async {
      final t = CloudTranscriber(port: FakeModel([Exception('offline')]), config: () => config);
      expect(await t.transcribe(Uint8List(4), 'audio/wav'), '');
    });
  });
}
