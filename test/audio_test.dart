// THE KEPT AUDIO PIECES (lib/services/audio/): the 24 kHz PCM player the
// brain speaks through, the microphone's voice-activity detector, and
// talking over her (barge-in). Driven through the real per-frame paths
// with synthetic PCM and a fake clock, as the live-mode tests they replace
// were.
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/services/audio/barge_in.dart';
import 'package:myassistant/services/audio/mic_stream.dart';
import 'package:myassistant/services/audio/pcm_player.dart';

/// One 128 ms mic frame of PCM16 @16 kHz: a 220 Hz tone at [amp].
Uint8List mic(int amp) {
  const samples = 2048;
  final b = ByteData(samples * 2);
  for (var i = 0; i < samples; i++) {
    b.setInt16(i * 2, (amp * math.sin(2 * math.pi * 220 * i / 16000)).round(), Endian.little);
  }
  return b.buffer.asUint8List();
}

/// [ms] of her reply: PCM16 @24 kHz at [amp].
Uint8List reply(int ms, {int amp = 6000, int rate = 24000}) {
  final n = rate * ms ~/ 1000;
  final b = ByteData(n * 2);
  for (var i = 0; i < n; i++) {
    b.setInt16(i * 2, (amp * math.sin(2 * math.pi * 180 * i / rate)).round(), Endian.little);
  }
  return b.buffer.asUint8List();
}

class Rig {
  Rig() {
    player = PcmPlayer(output: out, clockUs: () => t.microsecondsSinceEpoch);
    watch = BargeInWatch(player: player);
  }

  final out = SilentOutput();
  DateTime t = DateTime(2026, 9, 29, 12);
  late final PcmPlayer player;
  late final BargeInWatch watch;
  int bargeIns = 0;

  void arm() => watch.debugArm(() => bargeIns++);

  /// She says something [ms] long (it arrives at once, like TTS does).
  Future<void> sheSays(int ms) => player.play(reply(ms), sampleRate: 24000);

  void feed(Uint8List frame, [int n = 1]) {
    for (var i = 0; i < n; i++) {
      watch.feed(frame, MicStream.levelOf(frame));
      t = t.add(const Duration(milliseconds: 128));
    }
  }

  /// Her own voice coming back into the microphone, wandering a little.
  void herEcho(int frames) {
    for (var i = 0; i < frames; i++) {
      feed(mic(1200 + (i * 211) % 600));
    }
  }
}

void main() {
  group('the PCM player (the brain\'s AudioSink)', () {
    test('queues each sentence behind the last, boosted; the clock says when it ends', () async {
      final r = Rig();
      await r.sheSays(500);
      await r.sheSays(500);
      expect(r.out.written.length, 2);
      expect(r.player.playing, isTrue);
      // 80 ms of player start-up, then a second of her.
      expect(r.player.remaining.inMilliseconds, 1080 + PcmPlayer.ringLatencyUs ~/ 1000);
      r.t = r.t.add(const Duration(milliseconds: 300));
      expect(r.player.levelNow(), greaterThan(0), reason: 'the rings move with what is heard');
      await r.player.stop();
    });

    test('stop is the barge-in: silent at once, everything queued dropped', () async {
      final r = Rig();
      await r.sheSays(3000);
      final drained = r.player.drained();
      await r.player.stop();
      await drained.timeout(const Duration(seconds: 1));
      expect(r.player.playing, isFalse);
      expect(r.player.remaining, Duration.zero);
      expect(r.out.stops, 1);
    });

    test('drained completes once the audio has played (a real clock)', () async {
      final out = SilentOutput();
      final player = PcmPlayer(output: out);
      await player.play(reply(40), sampleRate: 24000);
      expect(player.playing, isTrue);
      await player.drained().timeout(const Duration(seconds: 2));
      expect(player.playing, isFalse);
    });

    test('muted drops the sound, not the turn: the clock still runs', () async {
      final r = Rig();
      r.player.muted = true;
      await r.sheSays(800);
      expect(r.out.written, isEmpty);
      expect(r.player.playing, isTrue);
      expect(r.player.levelNow(), 0);
      await r.player.stop();
    });

    test('audio at another rate is resampled to the stream', () async {
      final r = Rig();
      await r.player.play(reply(1000, rate: 16000), sampleRate: 16000);
      expect(r.out.written.single.length, 24000 * 2);
      expect(PcmPlayer.resample(Uint8List(0), 16000, 24000), isEmpty);
      await r.player.stop();
    });

    group('the limiter', () {
      test('is exactly linear below the knee', () {
        for (final v in [0.0, 1000.0, -12000.0, 23000.0]) {
          expect(PcmPlayer.softLimit(v), v.round());
        }
      });

      test('bends peaks smoothly instead of cutting them flat', () {
        var last = PcmPlayer.softLimit(23000);
        for (var v = 23500.0; v <= 62000; v += 500) {
          final y = PcmPlayer.softLimit(v);
          expect(y, greaterThanOrEqualTo(last));
          expect(y, lessThanOrEqualTo(32767));
          last = y;
        }
        expect(PcmPlayer.softLimit(-62000), -PcmPlayer.softLimit(62000));
        expect(PcmPlayer.softLimit(34000), lessThan(32767));
        expect(PcmPlayer.softLimit(34000), greaterThan(PcmPlayer.softLimit(30000)));
      });
    });
  });

  group('voice activity', () {
    final quiet = mic(20);
    final speech = mic(8000);

    test('speech opens after the onset, the lead-in is kept, a pause ends it', () {
      final vad = VoiceActivityDetector();
      expect(vad.feed(quiet, MicStream.levelOf(quiet)!), VadEvent.quiet);
      expect(vad.feed(speech, MicStream.levelOf(speech)!), VadEvent.quiet,
          reason: '128 ms: a door slam, not yet speech');
      expect(vad.feed(speech, MicStream.levelOf(speech)!), VadEvent.onset);
      expect(vad.takeLeadIn().length, 3, reason: 'the first syllable is not lost');
      expect(vad.feed(speech, MicStream.levelOf(speech)!), VadEvent.speech);
      final events = [
        for (var i = 0; i < 8; i++) vad.feed(quiet, MicStream.levelOf(quiet)!),
      ];
      expect(events.last, VadEvent.end, reason: '1024 ms of quiet > the 1000 ms hangover');
      expect(events.where((e) => e == VadEvent.end).length, 1);
      expect(vad.speaking, isFalse);
    });

    test('the room is learnt while nobody talks, never from their voice', () {
      final vad = VoiceActivityDetector();
      for (var i = 0; i < 60; i++) {
        vad.feed(quiet, MicStream.levelOf(quiet)!);
      }
      final floor = vad.noiseFloor;
      expect(floor, closeTo(MicStream.levelOf(quiet)!, 0.002),
          reason: 'a still room: the floor comes down to it');
      for (var i = 0; i < 10; i++) {
        vad.feed(speech, MicStream.levelOf(speech)!);
      }
      expect(vad.noiseFloor, floor, reason: 'their own voice never drags it up');
    });

    test('the bar follows a quiet microphone (S24 Ultra), never below the room', () {
      expect(VoiceActivityDetector.speechThresholdFor(noiseFloor: 0.01, peakLevel: 0), 0.08);
      expect(VoiceActivityDetector.speechThresholdFor(noiseFloor: 0.01, peakLevel: 0.1),
          closeTo(0.03, 1e-9));
      expect(VoiceActivityDetector.speechThresholdFor(noiseFloor: 0.05, peakLevel: 0.1),
          closeTo(0.15, 1e-9));
    });
  });

  group('talking over her (barge-in)', () {
    setUp(() => BargeInWatch.detector.forget());

    test('her own voice coming back never interrupts her', () async {
      final r = Rig()..arm();
      await r.sheSays(12000);
      r.herEcho(80); // ten seconds of her talking
      expect(r.bargeIns, 0);
      expect(r.watch.running, isTrue);
      await r.player.stop();
    });

    test('the owner talking over her stops her, once', () async {
      final r = Rig()..arm();
      await r.sheSays(8000);
      r.herEcho(16); // two seconds: this phone's leak is learnt
      r.feed(mic(8000), 3); // 384 ms of the owner talking over her
      expect(r.bargeIns, 1);
      expect(r.watch.running, isFalse, reason: 'the recogniser needs the microphone next');
      r.feed(mic(8000), 3);
      expect(r.bargeIns, 1);
      await r.player.stop();
    });

    test('a cough over her is not an interruption', () async {
      final r = Rig()..arm();
      await r.sheSays(8000);
      r.herEcho(16);
      r.feed(mic(8000), 2);
      r.herEcho(8);
      expect(r.bargeIns, 0);
      await r.player.stop();
    });

    test('while she is silent the microphone only learns the room', () {
      final r = Rig()..arm();
      r.feed(mic(8000), 10);
      expect(r.bargeIns, 0);
      expect(r.watch.room.peakLevel, greaterThan(0));
    });

    test('one detector for the app: the leak learnt stays with the phone', () {
      expect(BargeInWatch.detector, same(BargeInWatch.detector));
      expect(BargeInWatch.detector, isA<BargeInDetector>());
    });
  });
}
