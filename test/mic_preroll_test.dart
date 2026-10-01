import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/services/audio/mic_preroll.dart';

List<int> pcm(int sample, int n) {
  final out = <int>[];
  for (var i = 0; i < n; i++) {
    final s = sample & 0xffff;
    out
      ..add(s & 0xff)
      ..add((s >> 8) & 0xff);
  }
  return out;
}

int firstSample(List<int> b) {
  var s = b[0] | (b[1] << 8);
  if (s > 0x7fff) s -= 0x10000;
  return s;
}

void main() {
  test('keeps only the last moment before speech, oldest first', () {
    final p = MicPreRoll(keepMs: 300);
    for (var i = 1; i <= 5; i++) {
      p.add(pcm(i, 4), 128);
    }
    // 5 frames of 128 ms: the newest three cover the 300 ms window.
    final held = p.drain();
    expect(held.map(firstSample), [3, 4, 5]);
    expect(p.heldMs, 0, reason: 'drain empties it');
  });

  test('the frame that confirms speech is never dropped', () {
    final p = MicPreRoll(keepMs: 100);
    p.add(pcm(9, 4), 128); // one frame longer than the whole window
    expect(p.drain().map(firstSample), [9]);
  });

  test('the whisper keeps the room audible but nothing like a voice', () {
    final loud = MicPreRoll.whisper(pcm(20000, 4));
    final neg = MicPreRoll.whisper(pcm(-20000, 4));
    expect(firstSample(loud), 800); // x0.04, about -28 dB
    expect(firstSample(neg), -800);
    expect(loud.length, 8);
  });
}
