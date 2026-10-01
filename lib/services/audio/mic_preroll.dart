import 'dart:collection';
import 'dart:typed_data';

/// THE MOMENT BEFORE THE USER SPEAKS.
///
/// Until the probe is sure the user is talking, live mode sends Google
/// only a whisper of the microphone — so a TV, a street or the people at
/// the next table can't open a turn on its high-sensitivity detector.
/// Whispering everything before the probe is sure would clip the first
/// syllable of every sentence, so the real audio of the last few hundred
/// milliseconds is kept here and replayed at full volume the instant
/// speech is confirmed. Google hears the start once as a whisper and
/// once properly; the whisper reads as silence.
class MicPreRoll {
  MicPreRoll({this.keepMs = 450});

  /// How much lead-in to keep. Onset takes 200 ms to confirm, and the
  /// first consonant starts before the level crosses the bar.
  final int keepMs;

  final _frames = ListQueue<(List<int>, int)>();
  int _ms = 0;

  int get heldMs => _ms;

  void add(List<int> chunk, int ms) {
    _frames.add((List<int>.from(chunk), ms));
    _ms += ms;
    while (_frames.length > 1 && _ms - _frames.first.$2 >= keepMs) {
      _ms -= _frames.removeFirst().$2;
    }
  }

  /// Everything held, oldest first, and empties the buffer.
  List<List<int>> drain() {
    final out = _frames.map((f) => f.$1).toList();
    clear();
    return out;
  }

  void clear() {
    _frames.clear();
    _ms = 0;
  }

  /// -28 dB: Google still hears the room go quiet between turns (its
  /// end-of-turn detector needs that), but nothing in it sounds like a
  /// person any more. The old gate's -18 dB, applied only to the quietest
  /// frames, let a TV at conversation level straight through.
  static const double whisperScale = 0.04;

  static Uint8List whisper(List<int> chunk) {
    final out = Uint8List(chunk.length & ~1);
    for (var i = 0; i + 1 < chunk.length; i += 2) {
      var s = (chunk[i] & 0xff) | ((chunk[i + 1] & 0xff) << 8);
      if (s > 0x7fff) s -= 0x10000;
      final v = (s * whisperScale).round();
      out[i] = v & 0xff;
      out[i + 1] = (v >> 8) & 0xff;
    }
    return out;
  }
}
