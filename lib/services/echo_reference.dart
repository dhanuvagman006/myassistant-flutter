import 'dart:math' as math;
import 'dart:typed_data';

/// HER VOICE, AS IT WILL COME BACK INTO THE MICROPHONE (2026-09-26).
///
/// The barge-in check ([BargeInDetector]) has to tell the owner talking
/// over her from her own voice leaking back through the echo canceller.
/// What leaks back follows what she is saying: loud when she is loud, gone
/// when she pauses. So each reply chunk is cut into 20 ms windows and filed
/// under the moment it will sound, like [PlaybackEnvelope] does for the
/// orb. Unlike that one, reading here consumes nothing, because the check
/// looks back over the last half second for every microphone frame.
///
/// Levels are plain RMS of what is played (0..1 of full scale).
class EchoReference {
  EchoReference({
    this.capacity = 4096,
    this.windowUs = 20000,
    this.sampleRate = 24000,
    this.keepUs = 2000000,
  })  : _start = Int64List(capacity),
        _level = Float32List(capacity);

  /// How many windows it holds (about 80 s); the oldest go past this.
  final int capacity;

  /// One window's length, in microseconds.
  final int windowUs;

  /// Gemini's live voice is 24 kHz PCM16.
  final int sampleRate;

  /// How far behind the newest question a window is still kept.
  final int keepUs;

  final Int64List _start;
  final Float32List _level;
  int _head = 0; // the oldest window
  int _count = 0;

  /// Windows held right now (for tests).
  int get length => _count;

  void clear() {
    _head = 0;
    _count = 0;
  }

  /// Files [pcm16] (little-endian mono) as starting to sound at [startUs].
  /// Chunks arrive in order, each after the last.
  void add(int startUs, Uint8List pcm16) {
    final perWindow = sampleRate * windowUs ~/ 1000000;
    final samples = pcm16.length ~/ 2;
    final data = ByteData.sublistView(pcm16);
    var i = 0;
    var t = startUs;
    while (i < samples) {
      final n = math.min(perWindow, samples - i);
      var sum = 0.0;
      for (var k = 0; k < n; k++) {
        final s = data.getInt16((i + k) * 2, Endian.little).toDouble();
        sum += s * s;
      }
      _push(t, math.sqrt(sum / n) / 32768.0);
      i += n;
      t += n * 1000000 ~/ sampleRate;
    }
  }

  void _push(int startUs, double level) {
    if (_count == capacity) {
      _head = (_head + 1) % capacity;
      _count--;
    }
    final at = (_head + _count) % capacity;
    _start[at] = startUs;
    _level[at] = level;
    _count++;
  }

  /// The loudest window sounding at any moment in [fromUs, toUs], or 0.
  /// Asked with times that only move forward, so windows long past the
  /// question ([keepUs]) are dropped as it goes.
  double maxBetween(int fromUs, int toUs) {
    while (_count > 0 && _start[_head] + windowUs < fromUs - keepUs) {
      _head = (_head + 1) % capacity;
      _count--;
    }
    var best = 0.0;
    for (var k = 0; k < _count; k++) {
      final at = (_head + k) % capacity;
      final s = _start[at];
      if (s > toUs) break; // filed in order: nothing later overlaps
      if (s + windowUs <= fromUs) continue;
      if (_level[at] > best) best = _level[at];
    }
    return best;
  }
}
