// MIC TEST — the plan's P1 probe (owner, 2026-09-25: "start talk while it
// works").
//
// Before the voice session may stay open while a task runs in another app,
// the owner runs a mic test from Diagnostics that counts, while the app is
// off screen, how many microphone frames carry any sound. Pinned here:
//  * the counter math: exact zeros (a silenced mic), quiet-room noise and
//    speech land in different counts, and only frames from while the app
//    was away count;
//  * the plan's A1 pass line, judged only after 20 s away;
//  * the session's speech bar is unchanged by sharing it with the probe;
//  * the task mic settings differ from the session's in one thing only
//    (no audio-focus pause), and the session's own settings are unchanged;
//  * the probe restarts the session's recorder (session settings, then the
//    task settings), sends nothing anywhere, and lets the recorder go on
//    every way a test ends: a call, the screen, coming back, Stop;
//  * a stop that lands while the recorder is still being opened or
//    restarted leaves it OFF, checked through the record plugin's own
//    channel with a stand-in recorder, at every call of both restarts;
//  * a call already on when the test starts never opens the microphone.
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/core/log.dart';
import 'package:myassistant/services/live_service.dart';
import 'package:myassistant/services/mic_probe.dart';
import 'package:myassistant/services/task_voice.dart';
import 'package:record/record.dart';

/// One 128 ms frame of PCM16 @16 kHz (2048 samples) from [sample].
Uint8List frame(int Function(int i) sample) {
  final b = ByteData(2048 * 2);
  for (var i = 0; i < 2048; i++) {
    b.setInt16(i * 2, sample(i).clamp(-32768, 32767), Endian.little);
  }
  return b.buffer.asUint8List();
}

final zeros = frame((_) => 0);
Uint8List noise(int amp, [int seed = 1]) {
  final r = math.Random(seed);
  return frame((_) => r.nextInt(2 * amp + 1) - amp);
}

Uint8List tone(int amp) =>
    frame((i) => (amp * math.sin(2 * math.pi * 220 * i / 16000)).round());

final room = noise(20); // a quiet room: RMS about 12
final faint = noise(3); // non-zero, but under the 8 LSB bar
final speech = tone(8000);

/// 20 s of frames is 157 of them (128 ms each).
const twentySeconds = 157;

class FakeVoice implements TaskVoicePort {
  final log = <String>[];
  final events0 = StreamController<TaskVoiceEvent>.broadcast();
  TaskVoiceStart answer = const TaskVoiceStart.ok(0);
  int modeNow = 0;

  @override
  Future<TaskVoiceStart> start() async {
    log.add('start');
    return answer;
  }

  @override
  Future<int?> stop() async {
    log.add('stop');
    return modeNow;
  }

  @override
  Stream<TaskVoiceEvent> events() {
    log.add('listen');
    return events0.stream;
  }

  void send(TaskVoiceEvent e) => events0.add(e);
}

/// The record plugin's Android half, as much of it as the mic test uses:
/// one recorder that is on or off, and every call it answered, in order.
/// Each call takes a couple of milliseconds, as a platform round trip does,
/// and [onCall] runs the moment a call arrives, so a test can land a stop
/// exactly while that call is in flight.
class FakeRecorder {
  FakeRecorder(this.messenger);

  static const channel = MethodChannel('com.llfbandit.record/messages');

  final TestDefaultBinaryMessenger messenger;
  bool on = false;
  int inFlight = 0;
  final calls = <String>[];
  final _seen = <String, int>{};
  final _ids = <String>{};
  void Function(String method, int nth)? onCall;

  Future<Object?> handle(MethodCall call) async {
    final id = (call.arguments as Map?)?['recorderId'] as String?;
    if (id != null && _ids.add(id)) {
      // The recorder's own event channels: its frames, and its state.
      for (final name in ['eventsRecord', 'events']) {
        messenger.setMockStreamHandler(
            EventChannel('com.llfbandit.record/$name/$id'),
            MockStreamHandler.inline(onListen: (_, __) {}));
      }
    }
    final nth = _seen[call.method] = (_seen[call.method] ?? 0) + 1;
    inFlight++;
    onCall?.call(call.method, nth);
    await Future<void>.delayed(const Duration(milliseconds: 2));
    inFlight--;
    switch (call.method) {
      case 'hasPermission':
        return true;
      case 'isRecording':
        calls.add('isRecording=$on');
        return on;
      case 'startStream':
        on = true;
        calls.add('startStream');
        return null;
      case 'stop':
        on = false;
        calls.add('stop');
        return null;
    }
    return null;
  }

  void release() {
    for (final id in _ids) {
      for (final name in ['eventsRecord', 'events']) {
        messenger.setMockStreamHandler(
            EventChannel('com.llfbandit.record/$name/$id'), null);
      }
    }
  }
}

/// Waits (real time) until [done], failing after two seconds.
Future<void> until(bool Function() done) async {
  final give = DateTime.now().add(const Duration(seconds: 2));
  while (!done()) {
    if (DateTime.now().isAfter(give)) fail('timed out waiting');
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The recorder registers itself with its plugin when LiveService is
  // built; no microphone is used here, so the plugin just says yes.
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
          const MethodChannel('com.llfbandit.record/messages'),
          (call) async => null);

  group('one frame', () {
    test('exact zeros: nothing at all', () {
      final m = FrameMeasure.of(zeros);
      expect(m.samples, 2048);
      expect(m.nonZero, isFalse);
      expect(m.rms, 0);
    });

    test('a quiet room: non-zero and above 8', () {
      final m = FrameMeasure.of(room);
      expect(m.nonZero, isTrue);
      expect(m.rms, greaterThan(MicProbeCounts.epsilon));
      expect(m.rms, lessThan(20));
    });

    test('faint noise: non-zero but under the bar', () {
      final m = FrameMeasure.of(faint);
      expect(m.nonZero, isTrue);
      expect(m.rms, lessThan(MicProbeCounts.epsilon));
    });

    test('speech: the RMS of the tone', () {
      expect(FrameMeasure.of(speech).rms, closeTo(8000 / math.sqrt2, 20));
    });

    test('one non-zero sample is enough', () {
      final f = Uint8List.fromList(zeros)..[100] = 1;
      expect(FrameMeasure.of(f).nonZero, isTrue);
    });

    test('negative samples and an odd trailing byte', () {
      final f = frame((i) => -1000);
      expect(FrameMeasure.of(f).rms, closeTo(1000, 0.001));
      final odd = Uint8List.fromList([...f.take(10), 7]);
      expect(FrameMeasure.of(odd).samples, 5);
      expect(FrameMeasure.of(Uint8List(0)).samples, 0);
    });
  });

  group('the counts', () {
    test('zeros vs room noise vs speech', () {
      final c = MicProbeCounts();
      for (var i = 0; i < 10; i++) {
        c.add(zeros, away: true);
      }
      expect(c.frames, 10);
      expect(c.nonZeroFrames, 0);
      expect(c.aboveEpsilonFrames, 0);
      expect(c.peakRms, 0);
      expect(c.loudFrames, 0);

      for (var i = 0; i < 20; i++) {
        c.add(noise(20, i), away: true);
      }
      expect(c.frames, 30);
      expect(c.nonZeroFrames, 20);
      expect(c.aboveEpsilonFrames, 20);
      expect(c.loudFrames, 0, reason: 'a quiet room is never speech');

      for (var i = 0; i < 5; i++) {
        c.add(speech, away: true);
      }
      expect(c.frames, 35);
      expect(c.nonZeroFrames, 25);
      expect(c.aboveEpsilonFrames, 25);
      expect(c.loudFrames, 5);
      expect(c.peakRms, closeTo(8000 / math.sqrt2, 20));
    });

    test('faint noise is non-zero but not above 8', () {
      final c = MicProbeCounts();
      c.add(faint, away: true);
      expect(c.nonZeroFrames, 1);
      expect(c.aboveEpsilonFrames, 0);
    });

    test('frames while the app is on screen are kept apart', () {
      final c = MicProbeCounts();
      for (var i = 0; i < 4; i++) {
        c.add(speech, away: false);
      }
      c.add(zeros, away: true);
      expect(c.onScreenFrames, 4);
      expect(c.frames, 1);
      expect(c.nonZeroFrames, 0);
      expect(c.loudFrames, 0);
      expect(c.peakRms, 0);
    });

    test('time away comes from the bytes, 128 ms a frame', () {
      final c = MicProbeCounts();
      for (var i = 0; i < 10; i++) {
        c.add(room, away: true);
      }
      expect(c.awayMs, 1280);
      c.add(Uint8List(0), away: true);
      expect(c.frames, 10, reason: 'an empty chunk is not a frame');
    });

    test('A1 is judged only after 20 s away', () {
      final c = MicProbeCounts();
      for (var i = 0; i < twentySeconds - 1; i++) {
        c.add(noise(20, i), away: true);
      }
      expect(c.a1Pass, isNull);
      c.add(room, away: true);
      expect(c.awayMs, greaterThanOrEqualTo(20000));
      expect(c.a1Pass, isTrue);
    });

    test('A1 fails on a silenced mic', () {
      final c = MicProbeCounts();
      for (var i = 0; i < twentySeconds; i++) {
        c.add(zeros, away: true);
      }
      expect(c.a1Pass, isFalse);
    });

    test('A1 needs 95% non-zero AND 50% above 8', () {
      // 94% non-zero: fails even though every sound frame is loud.
      final a = MicProbeCounts();
      for (var i = 0; i < 200; i++) {
        a.add(i < 188 ? room : zeros, away: true);
      }
      expect(a.pct(a.nonZeroFrames), 94);
      expect(a.a1Pass, isFalse);
      // All non-zero, but under half above the bar: fails.
      final b = MicProbeCounts();
      for (var i = 0; i < 200; i++) {
        b.add(i < 99 ? room : faint, away: true);
      }
      expect(b.pct(b.nonZeroFrames), 100);
      expect(b.a1Pass, isFalse);
      // All non-zero, half above: passes.
      final c = MicProbeCounts();
      for (var i = 0; i < 200; i++) {
        c.add(i < 100 ? room : faint, away: true);
      }
      expect(c.a1Pass, isTrue);
    });

    test('the log line is counts only', () {
      final c = MicProbeCounts()
        ..modeAtStart = 0
        ..modeAtEnd = 3
        ..stopCode = 'call';
      c.add(room, away: true);
      final line = c.logLine();
      expect(line, contains('mic test ended (call)'));
      expect(line, contains('1 frames'));
      expect(line, contains('non-zero 1 (100%)'));
      expect(line, contains('audio mode NORMAL->IN_COMMUNICATION'));
      expect(RegExp(r'[^\x20-\x7E]').hasMatch(line), isFalse,
          reason: 'plain text, nothing but counts');
    });
  });

  group('the speech bar', () {
    test('shared, and the numbers it always gave', () {
      double bar(double f, double p) =>
          LiveService.speechThresholdFor(noiseFloor: f, peakLevel: p);
      expect(bar(0.01, 0), closeTo(0.08, 1e-9));
      expect(bar(0.01, 0.5), closeTo(0.08, 1e-9));
      expect(bar(0.01, 0.1), closeTo(0.03, 1e-9));
      expect(bar(0.05, 0.5), closeTo(0.15, 1e-9));
    });

    test('the probe detector hears speech, not the room', () {
      final v = ProbeVad();
      for (var i = 0; i < 30; i++) {
        expect(v.loud(noise(20, i)), isFalse);
      }
      expect(v.loud(speech), isTrue);
      expect(v.loud(zeros), isFalse);
    });
  });

  group('the microphone settings', () {
    const before = RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: 16000,
      numChannels: 1,
      echoCancel: true,
      noiseSuppress: true,
      androidConfig: AndroidRecordConfig(
        audioSource: AndroidAudioSource.voiceCommunication,
      ),
    );

    test('the session opens exactly what it always did', () {
      expect(LiveService.micConfig().toMap(), before.toMap());
    });

    test('task settings: the same, but never paused by audio focus', () {
      final task = LiveService.micConfig(task: true).toMap();
      expect(task['audioInterruption'], AudioInterruptionMode.none.index);
      final rest = Map.of(task)..remove('audioInterruption');
      final old = before.toMap()..remove('audioInterruption');
      expect(rest, old);
    });
  });

  group('the probe', () {
    final live = LiveService.instance;
    late FakeVoice voice;
    late MicProbe probe;
    late List<RecordConfig> opened;
    late List<StreamController<Uint8List>> mics;
    late List<Object> socket;

    StreamController<Uint8List> mic() => mics.last;

    setUp(() {
      voice = FakeVoice();
      probe = MicProbe(voice: voice, live: live);
      opened = [];
      mics = [];
      socket = [];
      AppLog.clear();
      live.probeSessionHold = Duration.zero;
      live.debugWatchSocket(socket.add);
      live.debugProbeStream = (cfg) async {
        opened.add(cfg);
        final c = StreamController<Uint8List>();
        mics.add(c);
        return c.stream;
      };
    });

    tearDown(() async {
      await live.stopProbe();
      live.debugProbeStream = null;
      live.debugWatchSocket(null);
      live.probeSessionHold = const Duration(seconds: 1);
      if (live.active) live.debugEndSession();
    });

    Future<void> settle() => Future<void>.delayed(Duration.zero);

    test('restarts the session recorder into the task settings, and '
        'counts only while away', () async {
      await probe.start();
      expect(probe.phase, MicProbePhase.running);
      expect(voice.log.take(2), ['listen', 'start'],
          reason: 'listening before the start, so no stop is missed');
      expect(opened.map((c) => c.audioInterruption), [
        LiveService.micConfig().audioInterruption,
        AudioInterruptionMode.none,
      ]);
      expect(mics.first.hasListener, isFalse,
          reason: 'the session-settings stream is let go at the restart');
      expect(probe.counts.modeAtStart, 0);

      mic().add(speech); // still on screen
      await settle();
      probe.didChangeAppLifecycleState(AppLifecycleState.paused);
      for (var i = 0; i < 5; i++) {
        mic().add(room);
      }
      mic().add(zeros);
      await settle();
      expect(probe.counts.onScreenFrames, 1);
      expect(probe.counts.frames, 6);
      expect(probe.counts.nonZeroFrames, 5);

      probe.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await settle();
      await settle();
      expect(probe.phase, MicProbePhase.done);
      expect(probe.counts.stopCode, MicProbe.endedReturned);
      expect(mic().hasListener, isFalse, reason: 'the recorder is let go');
      expect(live.probing, isFalse);
      expect(voice.log, contains('stop'));
      expect(AppLog.tail().last, contains('mic test ended (returned)'));
      expect(AppLog.tail().last, contains('6 frames'));
      expect(socket, isEmpty, reason: 'nothing ever goes up the socket');
      expect(live.active, isFalse);
    });

    test('a call stops it and records the audio mode', () async {
      await probe.start();
      probe.didChangeAppLifecycleState(AppLifecycleState.paused);
      mic().add(room);
      await settle();
      voice.send(const TaskVoiceEvent.stopped(TaskVoiceStop.call,
          modeStart: 0, modeEnd: 3));
      await settle();
      await settle();
      expect(probe.phase, MicProbePhase.done);
      expect(probe.counts.stopCode, 'call');
      expect(probe.counts.modeAtEnd, 3);
      expect(mic().hasListener, isFalse);
      expect(MicProbe.wordsFor(probe.counts.stopCode), 'a call started');
      expect(socket, isEmpty);
    });

    test('silenced is counted, then the stop that follows it', () async {
      await probe.start();
      voice.send(const TaskVoiceEvent.silenced());
      voice.send(const TaskVoiceEvent.stopped(TaskVoiceStop.silenced));
      await settle();
      await settle();
      expect(probe.counts.silencedEvents, 1);
      expect(probe.counts.stopCode, 'silenced');
      expect(probe.phase, MicProbePhase.done);
    });

    test('screen off, the 60 s cap and the notification each end it',
        () async {
      for (final r in [
        TaskVoiceStop.screenOff,
        TaskVoiceStop.timeCap,
        TaskVoiceStop.notification,
      ]) {
        await probe.start();
        voice.send(TaskVoiceEvent.stopped(r));
        await settle();
        await settle();
        expect(probe.counts.stopCode, r.wire);
        expect(mic().hasListener, isFalse, reason: r.name);
      }
    });

    test('Stop on the screen', () async {
      await probe.start();
      await probe.stop();
      expect(probe.counts.stopCode, MicProbe.endedButton);
      expect(voice.log.last, 'stop');
      expect(mic().hasListener, isFalse);
    });

    test('a refused service start never opens the microphone', () async {
      voice.answer = const TaskVoiceStart.failed('not_resumed');
      await probe.start();
      expect(probe.phase, MicProbePhase.failed);
      expect(probe.problem, contains('not_resumed'));
      expect(opened, isEmpty);
    });

    test('an open conversation comes first: no service, no recorder',
        () async {
      live.debugBeginSession(sink: socket.add);
      await probe.start();
      expect(probe.phase, MicProbePhase.failed);
      expect(voice.log, isEmpty);
      expect(opened, isEmpty);
      expect(await live.probeMic((_) {}), isFalse);
      live.debugEndSession();
      live.debugWatchSocket(socket.add);
    });

    test('the recorder stopping by itself ends it', () async {
      await probe.start();
      await mic().close();
      await settle();
      await settle();
      expect(probe.phase, MicProbePhase.done);
      expect(probe.counts.stopCode, LiveService.probeEndedByDone);
      expect(voice.log.last, 'stop', reason: 'the service goes with it');
    });

    test('frames never reach the session: no level, no socket', () async {
      var levels = 0;
      final before = live.onMicLevel;
      live.onMicLevel = (_) => levels++;
      await probe.start();
      probe.didChangeAppLifecycleState(AppLifecycleState.paused);
      for (var i = 0; i < 20; i++) {
        mic().add(i.isEven ? speech : room);
      }
      await settle();
      await probe.stop();
      live.onMicLevel = before;
      expect(probe.counts.frames, 20);
      expect(levels, 0);
      expect(socket, isEmpty);
    });

    test('a stop while the recorder is still opening leaves nothing '
        'listening to it', () async {
      final open = live.debugProbeStream!;
      live.debugProbeStream = (cfg) async {
        final s = await open(cfg);
        if (opened.length == 1) {
          // Android stopped the service (a call) right after promotion:
          // the event reaches Dart while the recorder is still opening.
          voice.send(const TaskVoiceEvent.stopped(TaskVoiceStop.call,
              modeStart: 0, modeEnd: 3));
          await settle();
          await settle();
        }
        return s;
      };
      await probe.start();
      await settle();
      await settle();
      expect(probe.phase, MicProbePhase.done);
      expect(probe.counts.stopCode, 'call');
      expect(live.probing, isFalse);
      expect(opened, hasLength(1), reason: 'no restart once it has ended');
      expect(mics.single.hasListener, isFalse,
          reason: 'nothing listens to the recorder after "Finished"');
      expect(voice.log.last, 'stop');
      expect(socket, isEmpty);
    });

    test('a call already on at the start never opens the microphone',
        () async {
      for (final mode in [2, 3]) {
        // IN_CALL, IN_COMMUNICATION: the service lets go at once anyway.
        voice = FakeVoice()..answer = TaskVoiceStart.ok(mode);
        probe = MicProbe(voice: voice, live: live);
        AppLog.clear();
        await probe.start();
        // The service's own stop, a moment later, changes nothing.
        voice.send(TaskVoiceEvent.stopped(TaskVoiceStop.call,
            modeStart: mode, modeEnd: mode));
        await settle();
        await settle();
        expect(probe.phase, MicProbePhase.done, reason: 'mode $mode');
        expect(probe.counts.stopCode, 'call');
        expect(probe.counts.modeAtStart, mode);
        expect(probe.counts.modeAtEnd, mode);
        expect(opened, isEmpty, reason: 'mode $mode: the mic is never opened');
        expect(live.probing, isFalse);
        expect(voice.log, ['listen', 'start', 'stop']);
        expect(
            AppLog.tail().where((l) => l.contains('mic test ended (call)')),
            hasLength(1));
      }
    });
  });

  // Through the record plugin's own channel, no seam: what the phone's
  // recorder is left doing once a test has ended. The recorder's calls run
  // one at a time, in order, so a stop that lands in the middle of a
  // restart queues behind it; whatever the timing, the microphone must end
  // up off (owner, 2026-09-25: "start talk while it works").
  group('the probe on the real recorder channel', () {
    final live = LiveService.instance;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    late FakeRecorder rec;
    late FakeVoice voice;
    late MicProbe probe;
    late List<Object> socket;
    const callStop =
        TaskVoiceEvent.stopped(TaskVoiceStop.call, modeStart: 0, modeEnd: 3);

    setUp(() {
      rec = FakeRecorder(messenger);
      messenger.setMockMethodCallHandler(FakeRecorder.channel, rec.handle);
      voice = FakeVoice();
      probe = MicProbe(voice: voice, live: live);
      socket = [];
      AppLog.clear();
      live.debugProbeStream = null;
      live.debugWatchSocket(socket.add);
      live.probeSessionHold = const Duration(milliseconds: 30);
    });

    tearDown(() async {
      rec.onCall = null;
      await live.stopProbe();
      await until(() => rec.inFlight == 0);
      live.debugWatchSocket(null);
      live.probeSessionHold = const Duration(seconds: 1);
      rec.release();
      messenger.setMockMethodCallHandler(
          FakeRecorder.channel, (call) async => null);
    });

    /// The test has ended and the recorder has answered everything.
    Future<void> ended() async {
      bool quiet() =>
          rec.inFlight == 0 &&
          AppLog.tail().any((l) => l.contains('mic test ended'));
      await until(quiet);
      // Nothing more arrives after it.
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(quiet(), isTrue, reason: '${rec.calls}');
    }

    void expectOff() {
      expect(probe.phase, MicProbePhase.done);
      expect(probe.counts.stopCode, 'call');
      expect(live.probing, isFalse);
      expect(rec.on, isFalse,
          reason: 'the microphone is off once the test has ended: '
              '${rec.calls}');
      expect(rec.calls.last, 'stop', reason: '${rec.calls}');
      expect(voice.log.last, 'stop', reason: 'the service goes too');
      expect(socket, isEmpty);
    }

    // Every call of both restarts: the stop arrives while it is in flight.
    for (final (method, nth, what) in [
      ('isRecording', 1, 'the first open checks the recorder'),
      ('startStream', 1, 'the first open starts it'),
      ('isRecording', 2, 'the task restart checks it'),
      ('stop', 1, 'the task restart stops it'),
      ('startStream', 2, 'the task restart starts it again'),
    ]) {
      test('a stop while $what ($method #$nth) leaves the microphone off',
          () async {
        rec.onCall = (m, n) {
          if (m == method && n == nth) voice.send(callStop);
        };
        await probe.start();
        await ended();
        expectOff();
        expect(rec.calls.where((c) => c == 'startStream').length,
            lessThanOrEqualTo(2));
      });
    }

    test('a stop while it holds the session settings leaves the microphone '
        'off, with no task restart', () async {
      rec.onCall = (m, n) {
        // The open answers in 2 ms and the hold lasts 30: this lands in it.
        if (m == 'startStream' && n == 1) {
          Timer(const Duration(milliseconds: 15), () => voice.send(callStop));
        }
      };
      await probe.start();
      await ended();
      expectOff();
      expect(rec.calls,
          ['isRecording=false', 'startStream', 'isRecording=true', 'stop']);
    });

    test('a stop once it runs leaves the microphone off', () async {
      await probe.start();
      expect(probe.phase, MicProbePhase.running);
      expect(rec.on, isTrue);
      voice.send(callStop);
      await ended();
      expectOff();
      expect(rec.calls, [
        'isRecording=false', 'startStream', // the session's settings
        'isRecording=true', 'stop', 'startStream', // the task restart
        'isRecording=true', 'stop', // the end
      ]);
    });
  });
}
