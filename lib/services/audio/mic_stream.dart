import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:record/record.dart';

import '../../core/log.dart';
import 'barge_in.dart';
import 'mic_preroll.dart';
import 'mic_stats.dart';
import 'pcm_player.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  THE MICROPHONE AS RAW PCM — PCM16 mono 16 kHz, frames of ~128 ms, each
///  with its level (0..1, for the orb and the detectors below).
///
///  voiceCommunication routes the capture through the hardware echo
///  canceller, so the assistant's own voice coming out of the speaker is
///  mostly gone before a frame reaches us. Kept for the barge-in watch
///  below and for the hands-free cooking mode (Gemini Live) next.
/// ─────────────────────────────────────────────────────────────────────────
class MicStream {
  MicStream({AudioRecorder Function()? recorder})
      : _make = recorder ?? AudioRecorder.new;

  static const sampleRate = 16000;

  /// THE MICROPHONE'S SETTINGS, IN ONE PLACE. [streamBufferSize] asks the
  /// platform for small reads (bytes): the Live voice wants 20-40 ms
  /// chunks, never the ~128 ms the default buffer hands over.
  ///
  /// [AudioInterruptionMode.none] (2026-09-30, the client's S24 Ultra stuck
  /// on "Listening"): record's default PAUSES the capture on any audio-focus
  /// loss — a WhatsApp ping, a notification, Bixby — and never resumes it.
  /// The stream stays open with no frames in it, so nothing ever noticed.
  /// A phone call is PhoneStateGuard's to handle, not the recorder's.
  static RecordConfig config({int? streamBufferSize}) => RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: sampleRate,
        numChannels: 1,
        echoCancel: true,
        noiseSuppress: true,
        audioInterruption: AudioInterruptionMode.none,
        streamBufferSize: streamBufferSize,
        androidConfig: const AndroidRecordConfig(
          audioSource: AndroidAudioSource.voiceCommunication,
        ),
      );

  /// 40 ms of PCM16 @16 kHz: the chunk Gemini Live is sent (Google's Live
  /// best practice: 20-40 ms, never about a second).
  static const liveChunkBytes = 1280;

  /// [chunk] cut into pieces of at most [maxBytes] (even), in order.
  static Iterable<Uint8List> split(Uint8List chunk, [int maxBytes = liveChunkBytes]) sync* {
    final step = maxBytes & ~1;
    if (chunk.length <= step) {
      yield chunk;
      return;
    }
    for (var i = 0; i < chunk.length; i += step) {
      final end = i + step < chunk.length ? i + step : chunk.length;
      yield Uint8List.sublistView(chunk, i, end);
    }
  }

  /// PCM16 mono @16 kHz: 32 bytes per millisecond. Durations come from the
  /// buffer, so every threshold stays honest whatever chunk size a phone's
  /// recorder hands us.
  static int msOf(List<int> chunk) => chunk.length ~/ 32;

  /// 0..1 level of a PCM16 chunk: RMS through x6, so speech lands around
  /// 0.12-1.0 and a still room well under 0.03. Null for a runt chunk.
  static double? levelOf(List<int> chunk) {
    if (chunk.length < 32) return null;
    var sum = 0.0;
    var n = 0;
    for (var i = 0; i + 1 < chunk.length; i += 2) {
      var s = chunk[i] | (chunk[i + 1] << 8);
      if (s >= 0x8000) s -= 0x10000;
      sum += (s * s).toDouble();
      n++;
    }
    if (n == 0) return null;
    final rms = math.sqrt(sum / n) / 32768.0;
    return (rms * 6).clamp(0.0, 1.0);
  }

  final AudioRecorder Function() _make;
  AudioRecorder? _rec;
  StreamSubscription<Uint8List>? _sub;
  int _gen = 0;

  bool get running => _sub != null;

  /// Opens the microphone; [onFrame] gets every chunk with its level.
  /// False when it cannot be opened (no permission, a busy microphone).
  /// [bufferBytes] asks for small platform reads; a recorder that refuses
  /// that size (under the hardware's minimum) is opened with its own.
  /// [onLost]: the stream ended or failed without [stop] (once).
  Future<bool> start(
    void Function(Uint8List pcm, double? level) onFrame, {
    int? bufferBytes,
    void Function(String why)? onLost,
  }) async {
    if (_sub != null) return true;
    final gen = ++_gen;
    StreamSubscription<Uint8List> listen(Stream<Uint8List> s, void Function(Uint8List) f) =>
        s.listen(f,
            onError: (Object e) => _lost(gen, 'failed: $e', onLost),
            onDone: () => _lost(gen, 'ended', onLost));
    try {
      final rec = _rec ??= _make();
      // No time limit here: Android's permission dialog waits for him.
      if (!await rec.hasPermission()) return false;
      if (bufferBytes == null) {
        final stream = await _open(rec, config());
        if (gen != _gen) {
          // Stopped while opening: this capture is not wanted.
          unawaited(rec.stop().catchError((Object _) => null));
          return false;
        }
        _sub = listen(stream, (c) => onFrame(c, levelOf(c)));
        return true;
      }
      // A size under the hardware's minimum fails INSIDE the recorder (no
      // audio ever comes), so the first frame is waited for, briefly.
      var heard = false;
      final stream = await _open(rec, config(streamBufferSize: bufferBytes));
      if (gen != _gen) {
        unawaited(rec.stop().catchError((Object _) => null));
        return false;
      }
      _sub = listen(stream, (c) {
        heard = true;
        onFrame(c, levelOf(c));
      });
      Timer(smallBufferGrace, () async {
        if (heard || gen != _gen || _sub == null) return;
        AppLog.add('mic', 'no audio with a $bufferBytes-byte buffer: the default one');
        final old = _sub;
        _sub = null;
        await old?.cancel();
        try {
          if (await rec.isRecording()) await rec.stop();
          if (gen != _gen) return; // stopped meanwhile
          final again = await _open(rec, config());
          if (gen != _gen) {
            await rec.stop();
            return;
          }
          _sub = listen(again, (c) => onFrame(c, levelOf(c)));
        } catch (e) {
          AppLog.add('mic', 'could not reopen: $e');
          _lost(gen, 'could not reopen', onLost);
        }
      });
      return true;
    } catch (e) {
      AppLog.add('mic', 'could not open: $e');
      return false;
    }
  }

  /// startStream within [openTimeout]. One that comes back later is
  /// stopped then (it would hold the microphone for good), and the next
  /// open uses a new recorder.
  Future<Stream<Uint8List>> _open(AudioRecorder rec, RecordConfig cfg) async {
    final started = rec.startStream(cfg);
    try {
      return await started.timeout(openTimeout);
    } on TimeoutException {
      if (identical(_rec, rec)) _rec = null;
      unawaited(started
          .then((_) => rec.stop())
          .then((_) => rec.dispose())
          .catchError((Object _) {}));
      rethrow;
    }
  }

  /// The stream of start [gen] ended without [stop]: said once.
  void _lost(int gen, String why, void Function(String why)? onLost) {
    if (gen != _gen) return;
    _gen++;
    _sub = null;
    AppLog.add('mic', 'the microphone stream $why');
    onLost?.call(why);
  }

  /// How long the first frame of a small-buffer stream may take.
  static const smallBufferGrace = Duration(milliseconds: 600);

  /// Opening the recorder never hangs a conversation longer than this.
  static const openTimeout = Duration(seconds: 3);

  /// Closes the microphone (safe when it is not open).
  Future<void> stop() async {
    _gen++;
    final sub = _sub;
    _sub = null;
    await sub?.cancel();
    final rec = _rec;
    if (rec == null) return;
    try {
      await () async {
        if (await rec.isRecording()) await rec.stop();
      }()
          .timeout(openTimeout);
    } on TimeoutException {
      // Blocked in the platform: this recorder is given up, the next open
      // makes a new one.
      AppLog.add('mic', 'the recorder would not stop: a new one next time');
      if (identical(_rec, rec)) _rec = null;
      // Still stopped and released in the background: a recorder left
      // running keeps the microphone, and the next open finds it busy.
      unawaited(rec.stop().then((_) => rec.dispose()).catchError((Object _) {}));
    } catch (_) {}
  }
}

enum VadEvent { quiet, onset, speech, end }

/// ─────────────────────────────────────────────────────────────────────────
///  VOICE ACTIVITY — this side decides who is talking, not the server.
///
///  ADAPTIVE: a fixed level cannot work (a quiet room and a moving car
///  differ by an order of magnitude), so the room's noise floor is learnt
///  while nobody speaks, and speech is "clearly louder than this room".
///  The bar also follows the loudest thing THIS microphone has produced —
///  Samsung's voiceCommunication path on an S24 Ultra (2026-09-20) hands
///  over speech under 0.08, which a fixed bar never accepted.
///
///  [onsetMs] of loud audio opens an utterance (a door slam does not);
///  [hangoverMs] of quiet ends it (a breath does not); [maxUtteranceMs]
///  bounds a room so loud it never falls quiet. The frames just before
///  the onset are kept ([takeLeadIn]) so the first syllable is not lost.
/// ─────────────────────────────────────────────────────────────────────────
class VoiceActivityDetector {
  VoiceActivityDetector({
    this.onsetMs = 200,
    this.hangoverMs = 1000,
    this.maxUtteranceMs = 120000,
    int preRollMs = 450,
  }) : _preRoll = MicPreRoll(keepMs: preRollMs);

  final int onsetMs;
  final int hangoverMs;
  final int maxUtteranceMs;
  final MicPreRoll _preRoll;

  /// Speech must be this many times the room's noise floor.
  static const speechFactor = 3.0;

  /// An absolute floor, so a very quiet room's tiny noise estimate cannot
  /// make a fan or a distant voice look like speech.
  static const minSpeechLevel = 0.08;

  double noiseFloor = 0.01;
  double peakLevel = 0;
  bool speaking = false;
  int _aboveMs = 0;
  int _belowMs = 0;
  int _utteranceMs = 0;

  /// What counts as speech on THIS phone right now.
  double get threshold =>
      speechThresholdFor(noiseFloor: noiseFloor, peakLevel: peakLevel);

  /// The bar, as a pure function of the room's [noiseFloor] and the
  /// loudest [peakLevel] this microphone has produced.
  static double speechThresholdFor({
    required double noiseFloor,
    required double peakLevel,
  }) {
    final adaptive = peakLevel > 0.012 ? peakLevel * 0.30 : minSpeechLevel;
    return math.max(noiseFloor * speechFactor, math.min(minSpeechLevel, adaptive));
  }

  /// One frame and its level ([MicStream.levelOf]).
  VadEvent feed(List<int> chunk, double level) {
    final ms = MicStream.msOf(chunk);
    if (level > peakLevel) {
      peakLevel = level; // attack
    } else {
      peakLevel *= 0.9995; // decay, ~a minute of speech to forget
    }
    final bar = threshold;
    final loud = level > bar;
    MicStats.note(
      level: level,
      noiseFloor: noiseFloor,
      speechThreshold: bar,
      loud: loud,
      gated: !speaking,
    );
    if (!speaking) {
      _preRoll.add(chunk, ms);
      if (!loud) {
        // Learnt only while nobody talks, or their own voice drags the
        // floor up until they are inaudible.
        noiseFloor = noiseFloor * 0.95 + level * 0.05;
        _aboveMs = 0;
        return VadEvent.quiet;
      }
      _aboveMs += ms;
      if (_aboveMs < onsetMs) return VadEvent.quiet;
      speaking = true;
      _belowMs = 0;
      _utteranceMs = 0;
      return VadEvent.onset;
    }
    _utteranceMs += ms;
    if (loud) {
      _belowMs = 0;
    } else {
      _belowMs += ms;
    }
    if (_belowMs >= hangoverMs || _utteranceMs >= maxUtteranceMs) {
      speaking = false;
      _aboveMs = 0;
      _belowMs = 0;
      _utteranceMs = 0;
      _preRoll.clear();
      return VadEvent.end;
    }
    return VadEvent.speech;
  }

  /// The real audio of the moments that led to the onset (then empty).
  List<List<int>> takeLeadIn() => _preRoll.drain();

  /// A new session: nobody is talking. [forgetRoom] also forgets the
  /// room's noise and this microphone's loudest level.
  void reset({bool forgetRoom = false}) {
    speaking = false;
    _aboveMs = 0;
    _belowMs = 0;
    _utteranceMs = 0;
    _preRoll.clear();
    if (forgetRoom) {
      noiseFloor = 0.01;
      peakLevel = 0;
    }
  }
}

/// ─────────────────────────────────────────────────────────────────────────
///  TALKING OVER HER. While the player is sounding, the microphone listens
///  for the owner REALLY talking over her ([BargeInDetector]: sustained
///  speech well above what her own voice puts into this phone's
///  microphone, learnt from her echo) — then [start]'s callback fires once
///  and the watch closes the microphone, so the recogniser can have it.
///
///  Owner, 2026-09-26: "interrupt should be there… a strong valid one…
///  how we talk with a human". A cough over her is not an interruption.
/// ─────────────────────────────────────────────────────────────────────────
class BargeInWatch {
  BargeInWatch({required this.player, MicStream? mic}) : _mic = mic ?? MicStream();

  /// One per app: how much of her voice leaks back belongs to the handset,
  /// not to a conversation, so a new reply starts already knowing it.
  static final BargeInDetector detector = BargeInDetector();

  final PcmPlayer player;
  final MicStream _mic;

  /// The room (its floor and speech bar), learnt from frames she is silent in.
  final VoiceActivityDetector room = VoiceActivityDetector();

  void Function()? _onBargeIn;

  bool get running => _onBargeIn != null;

  /// Starts listening; [onBargeIn] fires at most once. False when the
  /// microphone could not be opened (the owner can still tap).
  Future<bool> start(void Function() onBargeIn) async {
    final wasRunning = _onBargeIn != null;
    _onBargeIn = onBargeIn;
    if (wasRunning) return true;
    detector.resetRun();
    final ok = await _mic.start(feed);
    if (!ok && identical(_onBargeIn, onBargeIn)) _onBargeIn = null;
    return ok;
  }

  Future<void> stop() async {
    _onBargeIn = null;
    await _mic.stop();
  }

  /// Arms the watch with no microphone: a test feeds [feed] itself.
  @visibleForTesting
  void debugArm(void Function() onBargeIn) {
    _onBargeIn = onBargeIn;
    detector.resetRun();
  }

  /// One microphone frame. True when it confirmed that the owner is
  /// talking over her (the callback has fired).
  bool feed(List<int> chunk, double? level) {
    final cb = _onBargeIn;
    if (cb == null || level == null) return false;
    if (!player.playing) {
      room.feed(chunk, level); // her silence teaches the room
      return false;
    }
    final ms = MicStream.msOf(chunk);
    // What of her voice this frame can hold: the moments it covers, as
    // heard, reaching 300 ms back for the room's tail and the canceller,
    // and 100 ms on for timing slop.
    final heardUs = player.nowUs() - PcmPlayer.ringLatencyUs;
    final echo = player.echo.maxBetween(heardUs - ms * 1000 - 300000, heardUs + 100000);
    final confirmed = detector.feed(
      mic: level,
      echo: echo,
      floor: room.noiseFloor,
      speechBar: room.threshold,
      ms: ms,
    );
    if (!confirmed) return false;
    MicStats.bargeIns++;
    MicStats.echoCoupling = detector.coupling;
    AppLog.add('voice', 'barge-in (leak ${detector.coupling.toStringAsFixed(2)})');
    _onBargeIn = null;
    unawaited(_mic.stop()); // the recogniser needs the microphone next
    cb();
    return true;
  }
}
