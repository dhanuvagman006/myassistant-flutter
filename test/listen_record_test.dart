// RECORD MODE FOR THE CLASSIC VOICE (2026-10-01): the served setting is
// read, a recorder WAV is reduced to its samples for upload, and the
// recorded turn rides on HearFinal.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/ai/config.dart';
import 'package:myassistant/ai/listen.dart';
import 'package:myassistant/services/turn_audio_uploader.dart';

Uint8List wav(List<int> samples, {int extraChunk = 0}) {
  final data = Uint8List(samples.length * 2);
  for (var i = 0; i < samples.length; i++) {
    data[i * 2] = samples[i] & 0xff;
    data[i * 2 + 1] = (samples[i] >> 8) & 0xff;
  }
  final b = BytesBuilder();
  void u32(int v) => b.add([v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff]);
  void u16(int v) => b.add([v & 0xff, (v >> 8) & 0xff]);
  b.add('RIFF'.codeUnits);
  u32(36 + data.length + (extraChunk > 0 ? 8 + extraChunk : 0));
  b.add('WAVE'.codeUnits);
  b.add('fmt '.codeUnits);
  u32(16);
  u16(1);
  u16(1);
  u32(16000);
  u32(32000);
  u16(2);
  u16(16);
  if (extraChunk > 0) {
    b.add('LIST'.codeUnits);
    u32(extraChunk);
    b.add(List.filled(extraChunk, 0));
  }
  b.add('data'.codeUnits);
  u32(data.length);
  b.add(data);
  return b.toBytes();
}

void main() {
  test('the served listen block is read; anything else means the phone recogniser', () {
    expect(AiListen.fromJson({'cloudStt': 'record'}).record, isTrue);
    expect(AiListen.fromJson({'cloudStt': 'device'}).record, isFalse);
    expect(AiListen.fromJson(null).record, isFalse);
    expect(AiConfig.fromJson({'listen': {'cloudStt': 'record'}}).listen.record, isTrue);
    expect(AiConfig.defaults.listen.record, isFalse);
  });

  test('a recorder WAV is reduced to its samples, even with a chunk before the data', () {
    final samples = List.generate(2000, (i) => (i * 37) % 65536 - 32768);
    final pcm = TurnAudioUploader.wavPcm(wav(samples))!;
    expect(pcm.length, 4000);
    expect(pcm[0], samples[0] & 0xff);
    final odd = TurnAudioUploader.wavPcm(wav(samples, extraChunk: 26))!;
    expect(odd.length, 4000);
    expect(TurnAudioUploader.wavPcm(Uint8List.fromList('not a wav at all, honestly'.codeUnits)), isNull);
  });

  test('a recorded turn travels on HearFinal', () {
    final audio = RecordedAudio(Uint8List(10), 'audio/wav');
    final e = HearFinal('hello', fromCloud: true, audio: audio);
    expect(e.audio, same(audio));
    expect(const HearFinal('plain').audio, isNull);
  });
}
