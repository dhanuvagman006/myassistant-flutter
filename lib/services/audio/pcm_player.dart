import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:logger/logger.dart' show Level;

import '../../ai/speech.dart' show AudioSink;
import 'echo_reference.dart';
import 'playback_envelope.dart';

/// Where the player's bytes go: the phone's speaker (flutter_sound), or
/// nothing at all in a test.
abstract interface class PcmOutput {
  /// Queue [pcm16] (mono, [sampleRate] Hz) behind what is already sounding.
  Future<void> write(Uint8List pcm16, int sampleRate);

  /// Silence at once, dropping whatever is buffered.
  Future<void> stop();

  /// Release the audio device.
  Future<void> close();
}

/// ONE flutter_sound STREAM player fed raw PCM as it arrives — truly
/// gapless. (Short WAV files played back to back paid a file write and a
/// player start at every boundary, heard as the voice "breaking".) Opened
/// on the first write and re-armed after every stop.
class FlutterSoundOutput implements PcmOutput {
  FlutterSoundPlayer? _fs;
  bool _open = false;
  int _streamRate = 0;
  Future<void> _ready = Future<void>.value();

  Future<void> _arm(int rate) async {
    final fs = _fs ??= FlutterSoundPlayer(logLevel: Level.error);
    if (!_open) {
      await fs.openPlayer();
      _open = true;
    }
    if (_streamRate == rate) return;
    if (_streamRate != 0) {
      try {
        await fs.stopPlayer();
      } catch (_) {}
    }
    await fs.startPlayerFromStream(
      codec: Codec.pcm16,
      numChannels: 1,
      sampleRate: rate,
      interleaved: true,
      bufferSize: 4096,
    );
    try {
      await fs.setVolume(1.0);
    } catch (_) {}
    _streamRate = rate;
  }

  /// Opens the device and starts the stream at [rate] before the first
  /// reply needs it (2026-09-30: the Live voice's first audio must not
  /// wait for the player to start).
  Future<void> warm(int rate) {
    final next = _ready.then((_) => _arm(rate));
    _ready = next.catchError((_) {});
    return next;
  }

  @override
  Future<void> write(Uint8List pcm16, int sampleRate) {
    // One at a time, in order: the stream must be up before its first byte.
    final next = _ready.then((_) async {
      await _arm(sampleRate);
      _fs?.uint8ListSink?.add(pcm16);
    });
    _ready = next.catchError((_) {});
    return next;
  }

  @override
  Future<void> stop() async {
    await _ready;
    if (_streamRate == 0) return;
    _streamRate = 0;
    try {
      await _fs?.stopPlayer();
    } catch (_) {}
  }

  @override
  Future<void> close() async {
    await stop();
    if (!_open) return;
    _open = false;
    try {
      await _fs?.closePlayer();
    } catch (_) {}
  }
}

/// Plays into nothing (tests): what was written is kept.
class SilentOutput implements PcmOutput {
  final written = <Uint8List>[];
  var stops = 0;

  @override
  Future<void> write(Uint8List pcm16, int sampleRate) async => written.add(pcm16);

  @override
  Future<void> stop() async => stops++;

  @override
  Future<void> close() async {}
}

/// ─────────────────────────────────────────────────────────────────────────
///  THE ASSISTANT'S VOICE OUT — raw PCM16 mono (24 kHz: Gemini's TTS and
///  Live audio) through one gapless stream player.
///
///  It is the brain's [AudioSink] (lib/ai/speech.dart): [play] queues a
///  sentence behind what is already sounding and returns once it is
///  queued; [stop] is the barge-in — silent at once, everything queued
///  dropped. The stream player has no per-chunk completion events, but
///  PCM maths is exact (bytes ÷ (rate × 2)), so [playing], [remaining] and
///  [drained] run on a playhead clock.
///
///  Kept for every voice feature: the brain's replies, the cached
///  greeting, and the hands-free cooking mode's Live audio next.
/// ─────────────────────────────────────────────────────────────────────────
class PcmPlayer implements AudioSink {
  PcmPlayer({
    PcmOutput? output,
    this.sampleRate = 24000,
    this.gain = 1.9,
    int Function()? clockUs,
  })  : _out = output ?? FlutterSoundOutput(),
        _nowUs = clockUs ?? _stopwatchUs;

  /// The app's one player: two would fight over the speaker.
  static final PcmPlayer instance = PcmPlayer();

  final PcmOutput _out;

  /// The stream's rate; audio at another rate is resampled to it.
  final int sampleRate;

  /// Gemini's PCM is mastered quiet — noticeably softer than a phone call.
  /// +5.6 dB, with the peaks rounded by [softLimit] rather than cut.
  final double gain;

  static final Stopwatch _clock = Stopwatch()..start();
  static int _stopwatchUs() => _clock.elapsedMicroseconds;
  final int Function() _nowUs;

  /// The monotonic clock the playhead, the envelope and the echo reference
  /// are filed on (tests drive it with their own).
  int nowUs() => _nowUs();

  /// How long after the playhead a sound is actually heard: the stream
  /// player's own buffer (4096) and the phone's audio path.
  static const int ringLatencyUs = 120000;

  /// MUTED DROPS THE SOUND, NOT THE TURN: the clock runs as if it played,
  /// so a muted reply opens and closes exactly like an audible one; only
  /// the write to the speaker is skipped.
  bool muted = false;

  /// True while the audio fed so far is still sounding.
  final ValueNotifier<bool> playingListenable = ValueNotifier<bool>(false);
  bool get playing => playingListenable.value;

  /// Her voice's loudness as heard, filed under the moment it is heard —
  /// what the rings round the orb move with while she speaks.
  final PlaybackEnvelope _envelope = PlaybackEnvelope();

  /// Her voice as it will come back into the microphone (barge-in).
  final EchoReference echo = EchoReference();

  int _playheadEndUs = 0;
  Timer? _endTimer;
  Completer<void>? _drained;

  /// When the reply playing now starts to be HEARD (its first chunk's
  /// playhead plus [ringLatencyUs]), on [nowUs]'s clock; null before one.
  /// The Live voice's latency log reads it (2026-09-30).
  int? replyStartUs;

  /// The speaker ready before the first reply (best effort).
  Future<void> warm() async {
    final out = _out;
    if (out is FlutterSoundOutput) {
      try {
        await out.warm(sampleRate);
      } catch (_) {}
    }
  }

  /// How loud her voice is coming out of the speaker right now, 0..1.
  double levelNow() => muted ? 0 : _envelope.levelAt(_nowUs() - ringLatencyUs);

  /// How long until the audio received so far has all been heard.
  Duration get remaining {
    final us = _playheadEndUs + ringLatencyUs - _nowUs();
    return us > 0 ? Duration(microseconds: us) : Duration.zero;
  }

  /// Completes once nothing is sounding (at once when nothing is).
  Future<void> drained() {
    if (!playing) return Future<void>.value();
    return (_drained ??= Completer<void>()).future;
  }

  @override
  Future<void> play(Uint8List pcm16, {required int sampleRate}) async {
    if (pcm16.length < 2) return;
    final raw = sampleRate == this.sampleRate
        ? pcm16
        : resample(pcm16, sampleRate, this.sampleRate);
    final chunk = boost(raw, gain);
    if (chunk.isEmpty) return;
    final now = _nowUs();
    // A fresh reply is padded slightly for the player's own start-up.
    final fresh = _playheadEndUs <= now;
    final base = fresh ? now + 80000 : _playheadEndUs;
    if (fresh) replyStartUs = base + ringLatencyUs;
    _envelope.add(base, chunk);
    if (!muted) echo.add(base, chunk);
    _playheadEndUs = base + chunk.length * 1000000 ~/ (this.sampleRate * 2);
    _setPlaying(true);
    _armEnd();
    if (muted) return;
    try {
      await _out.write(chunk, this.sampleRate);
    } catch (_) {
      // A speaker that fails is silent; the clock still ends the reply.
    }
  }

  @override
  Future<void> stop() async {
    _playheadEndUs = 0;
    _envelope.clear();
    _endTimer?.cancel();
    _endTimer = null;
    _setPlaying(false);
    try {
      await _out.stop();
    } catch (_) {}
  }

  /// Let the audio device go (the app is closing the voice for good).
  Future<void> close() async {
    await stop();
    try {
      await _out.close();
    } catch (_) {}
  }

  /// 2026-09-30 (voice audit): she is "playing" until her last sample has
  /// been HEARD — the playhead plus [ringLatencyUs] — so nothing opens a
  /// microphone into the last 120 ms of her voice.
  void _armEnd() {
    _endTimer?.cancel();
    final us = _playheadEndUs + ringLatencyUs - _nowUs();
    _endTimer = Timer(Duration(microseconds: us > 0 ? us : 0), () {
      _endTimer = null;
      if (_nowUs() >= _playheadEndUs + ringLatencyUs) {
        _setPlaying(false);
      } else {
        _armEnd();
      }
    });
  }

  void _setPlaying(bool on) {
    if (playingListenable.value != on) playingListenable.value = on;
    if (!on) {
      final d = _drained;
      _drained = null;
      if (d != null && !d.isCompleted) d.complete();
    }
  }

  // ---------------------------------------------------------------- PCM

  /// Where the limiter starts to lean in (about -3 dBFS). Below it, the
  /// boost is exactly linear.
  static const double _limiterKnee = 23000;

  /// THE LOUDEST SYLLABLES ARE ROUNDED, NOT CUT (2026-09-26): above the
  /// knee the level bends smoothly towards full scale (a tanh curve), so a
  /// peak comes out a little softer instead of broken — a burst of harsh
  /// distortion was part of what the owner heard as "robotic".
  static int softLimit(double v) {
    final a = v.abs();
    if (a <= _limiterKnee) return v.round();
    const room = 32767 - _limiterKnee;
    final x = (a - _limiterKnee) / room;
    final e = math.exp(2 * x);
    final y = _limiterKnee + room * ((e - 1) / (e + 1));
    final r = math.min(32767, y.round());
    return v.isNegative ? -r : r;
  }

  /// [chunk] (PCM16 little-endian) times [gain], through [softLimit].
  static Uint8List boost(Uint8List chunk, double gain) {
    final out = Uint8List(chunk.length & ~1);
    for (var i = 0; i + 1 < chunk.length; i += 2) {
      var s = chunk[i] | (chunk[i + 1] << 8);
      if (s >= 0x8000) s -= 0x10000;
      final v = softLimit(s * gain);
      out[i] = v & 0xFF;
      out[i + 1] = (v >> 8) & 0xFF;
    }
    return out;
  }

  /// PCM16 mono from [from] Hz to [to] Hz, by linear interpolation.
  static Uint8List resample(Uint8List pcm16, int from, int to) {
    if (from <= 0 || to <= 0 || from == to) return pcm16;
    final src = ByteData.sublistView(pcm16);
    final n = pcm16.length ~/ 2;
    if (n == 0) return Uint8List(0);
    final m = (n * to / from).floor();
    final out = ByteData(m * 2);
    for (var j = 0; j < m; j++) {
      final pos = j * from / to;
      final i = pos.floor();
      final f = pos - i;
      final a = src.getInt16(i * 2, Endian.little);
      final b = i + 1 < n ? src.getInt16((i + 1) * 2, Endian.little) : a;
      out.setInt16(j * 2, (a + (b - a) * f).round().clamp(-32768, 32767), Endian.little);
    }
    return out.buffer.asUint8List();
  }
}
