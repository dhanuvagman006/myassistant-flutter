import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/services/barge_in.dart';
import 'package:myassistant/services/echo_reference.dart';

/// Talking over her (owner, 2026-09-26: "interrupt should be there… a
/// strong valid one interrupt… how we talk with a human"), without her
/// ever cutting herself off on a phone that leaks her voice back — the
/// Samsung S24 failure that removed barge-in on 2026-09-20.
void main() {
  const frame = 128; // ms, as the recorder hands them over
  const bar = 0.08; // the session's ordinary speech threshold

  /// Her voice alone for [ms], leaking back at [leak] x her level, with the
  /// level and the leak both wandering the way speech and a canceller do.
  int herVoice(BargeInDetector d, int ms,
      {required double leak, double floor = 0.01, int seed = 1}) {
    final rnd = math.Random(seed);
    var confirmed = 0;
    for (var t = 0; t < ms; t += frame) {
      final echo = 0.05 + rnd.nextDouble() * 0.15; // she is talking
      final wobble = 0.7 + rnd.nextDouble() * 0.6; // ±30 % on the leak
      final mic = floor + leak * echo * wobble;
      if (d.feed(mic: mic, echo: echo, floor: floor, speechBar: bar, ms: frame)) {
        confirmed++;
      }
    }
    return confirmed;
  }

  test('her own voice never interrupts her, however much this phone leaks',
      () {
    for (final leak in [0.2, 0.8, 1.5, 3.0]) {
      final d = BargeInDetector();
      expect(herVoice(d, 120000, leak: leak, seed: (leak * 10).round()), 0,
          reason: 'leak x$leak: two minutes of her talking');
    }
  });

  test('nothing counts until the leak is known', () {
    final d = BargeInDetector();
    for (var i = 0; i < 5; i++) {
      expect(d.feed(mic: 1, echo: 0.1, floor: 0.01, speechBar: bar, ms: frame),
          isFalse);
    }
    expect(d.warm, isFalse);
  });

  test('the owner talking over her is heard within about 0.4 s', () {
    final d = BargeInDetector();
    herVoice(d, 3000, leak: 0.8);
    expect(d.warm, isTrue);
    // Their voice on top of hers: well clear of her leak.
    var frames = 0;
    var heard = false;
    while (!heard && frames < 10) {
      frames++;
      heard = d.feed(
          mic: 0.6, echo: 0.15, floor: 0.01, speechBar: bar, ms: frame);
    }
    expect(heard, isTrue);
    expect(frames, 3, reason: '3 x 128 ms = 384 ms of speech');
    expect(d.confirmed, 1);
  });

  test('a cough, a clink or one loud syllable is not an interruption', () {
    final d = BargeInDetector();
    herVoice(d, 3000, leak: 0.8);
    bool loud() =>
        d.feed(mic: 0.9, echo: 0.15, floor: 0.01, speechBar: bar, ms: frame);
    bool quiet() =>
        d.feed(mic: 0.05, echo: 0.15, floor: 0.01, speechBar: bar, ms: frame);
    expect(loud(), isFalse);
    expect(loud(), isFalse);
    expect(quiet(), isFalse); // forgiven once
    expect(quiet(), isFalse); // …but not twice: the run is over
    expect(loud(), isFalse);
    expect(loud(), isFalse);
    expect(d.confirmed, 0);
  });

  test('one quiet frame between syllables is forgiven', () {
    final d = BargeInDetector();
    herVoice(d, 3000, leak: 0.8);
    bool at(double mic) =>
        d.feed(mic: mic, echo: 0.15, floor: 0.01, speechBar: bar, ms: frame);
    expect(at(0.7), isFalse);
    expect(at(0.1), isFalse);
    expect(at(0.7), isFalse);
    expect(at(0.7), isTrue);
  });

  test('a phone that leaks heavily raises its own bar', () {
    final light = BargeInDetector();
    final heavy = BargeInDetector();
    herVoice(light, 4000, leak: 0.3);
    herVoice(heavy, 4000, leak: 3.0);
    expect(heavy.coupling, greaterThan(light.coupling * 5));
    // What would interrupt on the light phone does not on the heavy one.
    bool over(BargeInDetector d) {
      var hit = false;
      for (var i = 0; i < 4; i++) {
        hit = d.feed(mic: 0.35, echo: 0.15, floor: 0.01, speechBar: bar,
                ms: frame) ||
            hit;
      }
      return hit;
    }

    expect(over(light), isTrue);
    expect(over(heavy), isFalse);
  });

  test('a noisy room is not mistaken for a leak', () {
    final d = BargeInDetector();
    // A loud room (floor 0.06) and a phone that barely leaks.
    herVoice(d, 4000, leak: 0.3, floor: 0.06);
    expect(d.coupling, lessThan(0.5),
        reason: 'the room is subtracted before the leak is worked out');
    var heard = false;
    for (var i = 0; i < 4 && !heard; i++) {
      heard = d.feed(
          mic: 0.5, echo: 0.15, floor: 0.06, speechBar: bar, ms: frame);
    }
    expect(heard, isTrue);
  });

  test('one odd frame does not lock the owner out', () {
    final d = BargeInDetector();
    herVoice(d, 4000, leak: 0.5);
    final before = d.coupling;
    // A single "hmm" from the owner, under the bar, is learnt as a leak…
    d.feed(mic: 0.2, echo: 0.05, floor: 0.01, speechBar: bar, ms: frame);
    // …but the leak is read near the top, not at it.
    expect(d.coupling, lessThan(before * 2));
  });

  test('a new session keeps what was learnt about the phone', () {
    final d = BargeInDetector();
    herVoice(d, 3000, leak: 0.8);
    d.resetRun();
    expect(d.warm, isTrue);
    d.forget();
    expect(d.warm, isFalse);
    expect(d.coupling, 0);
  });

  group('the echo reference', () {
    Uint8List pcm(int amp, int ms) {
      final n = 24 * ms;
      final b = ByteData(n * 2);
      for (var i = 0; i < n; i++) {
        b.setInt16(i * 2, (amp * math.sin(2 * math.pi * 200 * i / 24000)).round(),
            Endian.little);
      }
      return b.buffer.asUint8List();
    }

    test('answers with the loudest moment in the window, without using it up',
        () {
      final e = EchoReference();
      e.add(0, pcm(1000, 200)); // 0–200 ms quiet
      e.add(200000, pcm(16000, 100)); // 200–300 ms loud
      e.add(300000, pcm(1000, 200)); // 300–500 ms quiet
      final loud = e.maxBetween(150000, 250000);
      expect(loud, closeTo(16000 / math.sqrt2 / 32768, 0.01));
      expect(e.maxBetween(150000, 250000), loud, reason: 'read, not consumed');
      expect(e.maxBetween(0, 150000), lessThan(0.05));
      expect(e.maxBetween(400000, 450000), lessThan(0.05));
      expect(e.maxBetween(600000, 700000), 0, reason: 'nothing sounding');
    });

    test('forgets windows long past', () {
      final e = EchoReference(keepUs: 1000000);
      e.add(0, pcm(8000, 1000));
      final held = e.length;
      e.maxBetween(5000000, 5100000);
      expect(e.length, lessThan(held));
    });
  });
}
