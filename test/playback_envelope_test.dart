// HER VOICE'S LOUDNESS FOR THE RINGS (2026-09-25). While she speaks the
// rings round the orb move with her voice as it comes out of the speaker —
// not as it arrives, which is seconds early (the live reply streams in
// faster than it plays). These pin the timing and the bookkeeping.
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/services/audio/pcm_player.dart';
import 'package:myassistant/services/audio/playback_envelope.dart';

/// [ms] of a 440 Hz tone at [amp] (0..1 of full scale), PCM16 at 24 kHz.
Uint8List _tone(int ms, double amp) {
  final n = 24 * ms;
  final d = ByteData(n * 2);
  for (var i = 0; i < n; i++) {
    final v = (math.sin(2 * math.pi * 440 * i / 24000) * amp * 32767).round();
    d.setInt16(i * 2, v, Endian.little);
  }
  return d.buffer.asUint8List();
}

void main() {
  test('the level shows when the audio is HEARD, not when it arrives', () {
    final e = PlaybackEnvelope();
    // Arrives now, will sound from t = 1 s for 200 ms.
    e.add(1000000, _tone(200, 0.1));
    expect(e.levelAt(0), 0, reason: 'nothing is sounding yet');
    expect(e.levelAt(999999), 0);
    final heard = e.levelAt(1050000);
    // A sine's RMS is amp / sqrt 2; times the gain of 4.
    expect(heard, closeTo(0.1 / math.sqrt2 * 4, 0.01));
    expect(e.levelAt(1199000), greaterThan(0));
    expect(e.levelAt(1250000), 0, reason: 'she has finished');
  });

  test('quiet is low, loud is clamped at 1, silence is 0', () {
    final e = PlaybackEnvelope();
    e.add(0, _tone(20, 0.02));
    e.add(20000, _tone(20, 0.9));
    e.add(40000, Uint8List(960));
    expect(e.levelAt(10000), lessThan(0.1));
    expect(e.levelAt(30000), 1.0);
    expect(e.levelAt(50000), 0);
  });

  test('chunks queue one after another, each in 20 ms windows', () {
    final e = PlaybackEnvelope();
    e.add(0, _tone(100, 0.05));
    e.add(100000, _tone(100, 0.2));
    expect(e.length, 10);
    expect(e.levelAt(50000), lessThan(e.levelAt(150000)));
  });

  test('clear() forgets everything queued (a barge-in, a stop)', () {
    final e = PlaybackEnvelope()..add(0, _tone(100, 0.2));
    e.clear();
    expect(e.length, 0);
    expect(e.levelAt(50000), 0);
  });

  test('a full ring drops the oldest, never grows', () {
    final e = PlaybackEnvelope(capacity: 4);
    e.add(0, _tone(200, 0.2)); // ten windows
    expect(e.length, 4);
    expect(e.levelAt(10000), 0, reason: 'the first windows were dropped');
    expect(e.levelAt(190000), greaterThan(0));
  });

  test('muted, she makes no sound, so the rings do not move', () async {
    var now = 0;
    final player = PcmPlayer(output: SilentOutput(), clockUs: () => now);
    expect(player.levelNow(), 0, reason: 'nothing queued');
    player.muted = true;
    await player.play(_tone(400, 0.5), sampleRate: 24000);
    now = 200000;
    expect(player.levelNow(), 0);
    player.muted = false;
    await player.play(_tone(400, 0.5), sampleRate: 24000);
    now = 600000;
    expect(player.levelNow(), greaterThan(0), reason: 'heard, unmuted');
    await player.stop();
  });
}
