import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/services/live_service.dart';

/// Build 113: the owner can talk over her — only when they really are
/// (owner, 2026-09-26: "a strong valid one interrupt… how we talk with a
/// human") — and she stops at once, the way a person does. Driven through
/// the real per-frame path with a fake clock and a speaker that plays into
/// nothing.

/// One 128 ms mic frame of PCM16 @16 kHz: a 220 Hz tone at [amp].
Uint8List mic(int amp) {
  const samples = 2048;
  final b = ByteData(samples * 2);
  for (var i = 0; i < samples; i++) {
    b.setInt16(i * 2, (amp * math.sin(2 * math.pi * 220 * i / 16000)).round(),
        Endian.little);
  }
  return b.buffer.asUint8List();
}

/// [ms] of her reply: PCM16 @24 kHz at [amp].
Uint8List reply(int ms, {int amp = 6000}) {
  final n = 24 * ms;
  final b = ByteData(n * 2);
  for (var i = 0; i < n; i++) {
    b.setInt16(i * 2, (amp * math.sin(2 * math.pi * 180 * i / 24000)).round(),
        Endian.little);
  }
  return b.buffer.asUint8List();
}

int peakOf(Uint8List b) {
  final d = ByteData.sublistView(b);
  var m = 0;
  for (var i = 0; i + 1 < b.length; i += 2) {
    m = math.max(m, d.getInt16(i, Endian.little).abs());
  }
  return m;
}

class Rig {
  final svc = LiveService.instance;
  final sent = <Object>[];
  final said = <String>[];
  DateTime t = DateTime(2026, 9, 26, 12);
  int interrupts = 0;

  void begin({bool offered = true}) {
    svc.debugBarge.forget();
    svc.debugBeginSession(sink: sent.add, clock: () => t, speaker: true);
    svc.onInterrupted = () => interrupts++;
    svc.onHariText = said.add;
    server({'type': 'ready', if (offered) 'bargeIn': true});
  }

  void server(Map<String, dynamic> m) => svc.debugServerFrame(jsonEncode(m));

  /// She says something [ms] long (it arrives at once, like Gemini's).
  void sheSays(int ms) => svc.debugServerFrame(reply(ms));

  void feed(Uint8List frame, [int n = 1]) {
    for (var i = 0; i < n; i++) {
      svc.debugMicChunk(frame);
      t = t.add(const Duration(milliseconds: 128));
    }
  }

  /// Her own voice coming back into the microphone, wandering a little.
  void herEcho(int frames) {
    for (var i = 0; i < frames; i++) {
      feed(mic(1200 + (i * 211) % 600));
    }
  }

  List<String> get markers => [
        for (final f in sent)
          if (f is String) jsonDecode(f)['type'] as String,
      ];

  List<Uint8List> get audio => sent.whereType<Uint8List>().toList();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
          const MethodChannel('com.llfbandit.record/messages'),
          (call) async => null);
  late Rig r;

  setUp(() => r = Rig());
  tearDown(() {
    r.svc.onInterrupted = null;
    r.svc.onHariText = null;
    r.svc.debugEndSession();
  });

  test('not offered by the server: talking over her sends nothing, as before',
      () {
    r.begin(offered: false);
    r.sheSays(6000);
    expect(r.svc.playing, isTrue);
    r.sent.clear();
    r.herEcho(16);
    r.feed(mic(8000), 8); // the owner, loudly, for a whole second
    expect(r.audio, isEmpty);
    expect(r.markers, isEmpty);
    expect(r.svc.playing, isTrue, reason: 'she carries on');
    expect(r.interrupts, 0);
  });

  test('offered: her own voice coming back never interrupts her', () {
    r.begin();
    r.sheSays(12000);
    r.sent.clear();
    r.herEcho(80); // ten seconds of her talking
    expect(r.audio, isEmpty);
    expect(r.markers, isEmpty);
    expect(r.svc.playing, isTrue);
    expect(r.interrupts, 0);
  });

  test('offered: the owner talking over her stops her, and goes up whole', () {
    r.begin();
    r.sheSays(8000);
    r.herEcho(16); // two seconds: this phone's leak is learnt
    r.sent.clear();
    r.feed(mic(8000), 3); // 384 ms of the owner talking over her
    expect(r.svc.playing, isFalse, reason: 'she stops at once');
    expect(r.interrupts, 1);
    expect(r.markers, ['activity_start']);
    expect(r.audio.length, inInclusiveRange(3, 4),
        reason: 'their first words go up too (and one frame of lead-in), '
            'not seconds of her own voice');
    for (final a in r.audio.skip(r.audio.length - 3)) {
      expect(peakOf(a), greaterThan(5000), reason: 'at full volume');
    }
    // They keep talking: it streams, as any utterance does.
    final before = r.audio.length;
    r.feed(mic(8000), 4);
    expect(r.audio.length, before + 4);

    // The rest of the reply she was giving is never played or captioned…
    r.sheSays(2000);
    r.server({'type': 'output_transcript', 'text': 'and the weather is'});
    expect(r.svc.playing, isFalse);
    expect(r.said, isEmpty);
    // …until Google has ended that turn; the answer to them then plays.
    r.server({'type': 'interrupted'});
    r.sheSays(1500);
    expect(r.svc.playing, isTrue);
  });

  test('a reply that had already finished arriving: her next one still plays',
      () {
    r.begin();
    r.sheSays(8000);
    r.server({'type': 'turn_complete'}); // all of it is here; still playing
    r.herEcho(16);
    r.feed(mic(8000), 3);
    expect(r.svc.playing, isFalse);
    expect(r.interrupts, 1);
    // No "interrupted" will come — there was nothing left to interrupt.
    r.sheSays(1500); // the answer to what they said
    expect(r.svc.playing, isTrue, reason: 'not dropped as the old reply');
  });

  test('a cough over her is not an interruption', () {
    r.begin();
    r.sheSays(8000);
    r.herEcho(16);
    r.sent.clear();
    r.feed(mic(8000), 2);
    r.herEcho(8);
    expect(r.audio, isEmpty);
    expect(r.svc.playing, isTrue);
    expect(r.interrupts, 0);
  });

  test('typing still shuts the microphone, offer or not', () {
    r.begin();
    r.sheSays(8000);
    r.herEcho(16);
    r.svc.typingMute = true;
    r.sent.clear();
    r.feed(mic(8000), 6);
    expect(r.audio, isEmpty);
    expect(r.interrupts, 0);
  });

  group('the playback limiter', () {
    test('is exactly linear below the knee', () {
      for (final v in [0.0, 1000.0, -12000.0, 22999.0]) {
        expect(LiveService.softLimit(v), v.round());
      }
    });

    test('bends peaks smoothly instead of cutting them flat', () {
      var last = LiveService.softLimit(23000);
      for (var v = 23500.0; v <= 70000; v += 500) {
        final y = LiveService.softLimit(v);
        expect(y, greaterThanOrEqualTo(last), reason: 'never folds back');
        expect(y, lessThanOrEqualTo(32767));
        last = y;
      }
      expect(LiveService.softLimit(-62000), -LiveService.softLimit(62000));
      // A peak the old code cut flat at 32767 now keeps its shape below it.
      expect(LiveService.softLimit(34000), lessThan(32767));
      expect(LiveService.softLimit(34000),
          greaterThan(LiveService.softLimit(30000)));
    });
  });
}
