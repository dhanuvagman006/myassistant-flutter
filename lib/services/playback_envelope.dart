import 'dart:math' as math;
import 'dart:typed_data';

/// HER VOICE'S LOUDNESS, AT THE MOMENT IT IS HEARD (2026-09-25).
///
/// The client asked for the rings round the orb to move "forward and
/// backwards" like a speaker while it is on — listening AND speaking (the
/// owner: "with animation while speaking and listening"). Listening had a
/// level: his mic. Speaking had none. In live mode the engine ignores the
/// mic while her reply plays (so her own voice coming back in does not
/// count as him talking) and nothing measured the reply itself, so the
/// orb held whatever the mic last said until she stopped.
///
/// Her audio arrives faster than it is played — seconds of it can be
/// queued in the stream player — so measuring each chunk as it ARRIVES
/// would move the rings to words she has not said yet. Instead each chunk
/// is cut into 20 ms windows and filed under the time it will actually
/// come out of the speaker (the playhead the live service already keeps),
/// and the painter asks "how loud is it now?" on each frame.
///
/// A fixed ring of windows (about 41 seconds' worth), filled and read in
/// order: nothing is allocated per chunk or per frame.
class PlaybackEnvelope {
  PlaybackEnvelope({
    this.capacity = 2048,
    this.windowUs = 20000,
    this.sampleRate = 24000,
    this.gain = 4.0,
  })  : _start = Int64List(capacity),
        _level = Float32List(capacity);

  /// How many windows it holds; the oldest are dropped past this.
  final int capacity;

  /// One window's length, in microseconds.
  final int windowUs;

  /// The audio's sample rate (Gemini's live voice is 24 kHz PCM16).
  final int sampleRate;

  /// Loudness = RMS x [gain], clamped to 1. Speech fed to the speaker
  /// (already lifted by the live service's playback gain) sits around
  /// 0.05-0.2 RMS, which this maps to a clearly moving 0.2-0.8. To be
  /// checked on his phone.
  final double gain;

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

  /// Files [pcm16] (little-endian mono samples) as starting to sound at
  /// [startUs] on the same clock [levelAt] is asked on. Chunks arrive in
  /// order, each after the last.
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
      final rms = math.sqrt(sum / n) / 32768.0;
      _push(t, (rms * gain).clamp(0.0, 1.0));
      i += n;
      t += n * 1000000 ~/ sampleRate;
    }
  }

  void _push(int startUs, double level) {
    if (_count == capacity) {
      // Full: drop the oldest.
      _head = (_head + 1) % capacity;
      _count--;
    }
    final at = (_head + _count) % capacity;
    _start[at] = startUs;
    _level[at] = level;
    _count++;
  }

  /// How loud it is at [nowUs]: the window sounding then, or 0 before the
  /// first and after the last. Asked with a clock that only goes forward,
  /// so windows already past are dropped as it goes.
  double levelAt(int nowUs) {
    while (_count > 0) {
      final s = _start[_head];
      if (nowUs < s) return 0;
      if (nowUs < s + windowUs) return _level[_head];
      _head = (_head + 1) % capacity;
      _count--;
    }
    return 0;
  }
}
