import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'api_service.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  LIVE MODE — real speech-to-speech (Gemini Live API via the backend
///  /live/ws proxy). No transcription step, no client VAD, native barge-in:
///  the mic streams PCM up continuously, Hari's VOICE streams back down.
///
///  Wire protocol (must match backend src/live/proxy.js):
///    up:   binary frame           = PCM16 mono 16 kHz mic chunk
///    up:   {"type":"end"}         = close the session
///    down: binary frame           = PCM16 mono 24 kHz audio to play
///    down: {"type":"ready"} | {"type":"interrupted"} |
///          {"type":"turn_complete"} |
///          {"type":"input_transcript","text":…} |
///          {"type":"output_transcript","text":…} |
///          {"type":"error","message":…}
///
///  PLAYBACK: audioplayers can't consume a raw PCM stream, so incoming
///  audio is collected into short WAV segments (flushed on ~600 ms of
///  buffer or a ~250 ms gap) and played back-to-back from a queue. That
///  adds a few hundred ms before the first word — still far below the old
///  STT→TTS pipeline — with zero new native dependencies to break.
/// ─────────────────────────────────────────────────────────────────────────
class LiveService {
  LiveService._();
  static final LiveService instance = LiveService._();

  WebSocketChannel? _ch;
  StreamSubscription? _wsSub;
  final AudioRecorder _rec = AudioRecorder();
  StreamSubscription<List<int>>? _micSub;
  final AudioPlayer _player = AudioPlayer();

  bool _active = false;
  bool get active => _active;

  /// True while a reply segment is actually playing (drives the orb).
  bool playing = false;

  // ---- callbacks the engine wires up ----
  void Function()? onReady;
  void Function(String text)? onUserText; // incremental transcript fragments
  void Function(String text)? onHariText; // incremental transcript fragments
  void Function()? onTurnComplete;
  void Function()? onInterrupted;
  void Function(String message)? onError;
  void Function()? onClosed;
  void Function(double level)? onMicLevel; // 0..1 for the orb
  void Function(bool speaking)? onSpeaking; // playback started/stopped
  void Function(Uint8List chunk)? onAudioChunk; // For external renderer (Simli)

  // ---- incoming-audio segmenting ----
  final BytesBuilder _buf = BytesBuilder(copy: false);
  DateTime _lastChunkAt = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _flushTimer;
  final List<String> _queue = []; // WAV files waiting to play
  bool _draining = false;
  int _seq = 0;
  int _silenceMs = 0;
  bool _hasSpoken = false;
  final List<List<int>> _silenceBuffer = [];

  static const _outRate = 24000; // Gemini native-audio output sample rate
  static const _inRate = 16000; // what we send up

  /// Availability probe — GET /live on the backend.
  static Future<bool> available() async {
    try {
      final r = await ApiService.getJson('/live');
      return r?['available'] == true;
    } catch (_) {
      return false;
    }
  }

  /// Opens the session: connects the socket and starts streaming the mic.
  Future<void> start() async {
    if (_active) return;
    _active = true;
    _seq = 0;
    _silenceMs = 0;
    _hasSpoken = false;
    _silenceBuffer.clear();
    if (!await _rec.hasPermission()) {
      onError?.call('Microphone permission is needed for live mode.');
      return;
    }
    playing = false;
    _buf.clear();
    _queue.clear();

    // http(s)://host → ws(s)://host/live/ws?token=…
    final base = ApiService.baseUrl.replaceFirst(RegExp(r'^http'), 'ws');
    final qp = ApiService.sessionToken != null
        ? 'token=${Uri.encodeComponent(ApiService.sessionToken!)}'
        : 'appKey=${Uri.encodeComponent(ApiService.appApiKey)}';
    final uri = Uri.parse('$base/live/ws?$qp');

    try {
      _ch = WebSocketChannel.connect(uri);
    } catch (e) {
      _active = false;
      onError?.call('Could not reach live mode.');
      return;
    }

    _wsSub = _ch!.stream.listen(
      _onFrame,
      onError: (_) {
        onError?.call('Live connection lost.');
        stop();
      },
      onDone: () {
        if (_active) {
          _active = false;
          onClosed?.call();
        }
      },
    );

    // Mic: continuous raw PCM16 @16 kHz. voiceCommunication routes through
    // the hardware echo canceller so Hari's own playback doesn't feed back
    // into the model (which would make her interrupt herself).
    try {
      final mic = await _rec.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: _inRate,
          numChannels: 1,
          echoCancel: true,
          noiseSuppress: true,
          androidConfig: AndroidRecordConfig(
            audioSource: AndroidAudioSource.voiceCommunication,
          ),
        ),
      );
      _micSub = mic.listen((chunk) {
        if (!_active) return;
        _seq++;
        final l = _levelOf(chunk);
        if (l != null) onMicLevel?.call(l);
        try {
          if (!playing && l != null) {
            if (l > 0.03) {
              _hasSpoken = true;
              _silenceMs = 0;
              for (final c in _silenceBuffer) {
                _ch?.sink.add(Uint8List.fromList(c));
              }
              _silenceBuffer.clear();
              _ch?.sink.add(Uint8List.fromList(chunk));
            } else if (_hasSpoken) {
              // chunk size 4096 at 16kHz = ~128ms
              _silenceMs += 128;
              if (_silenceMs > 2500) {
                for (final c in _silenceBuffer) {
                  _ch?.sink.add(Uint8List.fromList(c));
                }
                _silenceBuffer.clear();
                _ch?.sink.add(Uint8List.fromList(chunk));
                _hasSpoken = false; // reset
              } else {
                // Cap buffer at 32 chunks (~4s) to prevent unbounded growth
                if (_silenceBuffer.length < 32) {
                  _silenceBuffer.add(chunk);
                }
              }
            }
          }
        } catch (_) {}
      });
    } catch (e) {
      onError?.call('Could not open the microphone for live mode.');
      await stop();
      return;
    }

    // Segment flusher: turn buffered reply PCM into playable WAVs.
    _flushTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (_buf.isEmpty) return;
      final bufferedMs = _buf.length * 1000 ~/ (_outRate * 2);
      final gapMs = DateTime.now().difference(_lastChunkAt).inMilliseconds;
      if (bufferedMs >= 600 || (gapMs >= 250 && bufferedMs >= 120)) {
        _flushSegment();
      }
    });
  }

  /// Ends the session and releases the mic/speaker.
  Future<void> stop() async {
    if (!_active && _ch == null) return;
    _active = false;
    try {
      _ch?.sink.add(jsonEncode({'type': 'end'}));
    } catch (_) {}
    _flushTimer?.cancel();
    _flushTimer = null;
    await _micSub?.cancel();
    _micSub = null;
    try {
      if (await _rec.isRecording()) await _rec.stop();
    } catch (_) {}
    await _wsSub?.cancel();
    _wsSub = null;
    try {
      await _ch?.sink.close();
    } catch (_) {}
    _ch = null;
    await _stopPlayback(clear: true);
    onSpeaking?.call(false);
  }

  /// Sends a text message directly through the live WebSocket.
  void sendText(String text) {
    if (_active && _ch != null) {
      _ch?.sink.add(jsonEncode({'type': 'text', 'text': text}));
    }
  }

  // ---------------- incoming frames ----------------

  void _onFrame(dynamic frame) {
    if (frame is List<int>) {
      // Reply audio: PCM16 @24 kHz. Buffer for segment playback.
      // record's stream already yields Uint8List; copy only if a platform
      // ever hands back a plain List<int>.
      final chunk = frame is Uint8List ? frame : Uint8List.fromList(frame as List<int>);
      _buf.add(chunk);
      onAudioChunk?.call(chunk);
      _lastChunkAt = DateTime.now();
      return;
    }
    if (frame is String) {
      Map<String, dynamic> m;
      try {
        m = jsonDecode(frame) as Map<String, dynamic>;
      } catch (_) {
        return;
      }
      switch (m['type']) {
        case 'ready':
          onReady?.call();
          break;
        case 'interrupted':
          // The user talked over Hari — Google already cut generation; we
          // must cut PLAYBACK immediately or she keeps talking from the
          // buffer.
          _stopPlayback(clear: true);
          onInterrupted?.call();
          break;
        case 'turn_complete':
          // Flush whatever tail audio is buffered so the last word plays.
          if (_buf.isNotEmpty) _flushSegment();
          onTurnComplete?.call();
          break;
        case 'input_transcript':
          final t = m['text'] as String? ?? '';
          if (t.isNotEmpty) onUserText?.call(t);
          break;
        case 'output_transcript':
          final t = m['text'] as String? ?? '';
          if (t.isNotEmpty) onHariText?.call(t);
          break;
        case 'error':
          onError?.call(m['message'] as String? ?? 'Live mode error.');
          stop();
          break;
      }
    }
  }

  // ---------------- playback (segmented WAV queue) ----------------

  void _flushSegment() {
    final pcm = _buf.takeBytes();
    if (pcm.isEmpty) return;
    _seq++;
    _writeWav(pcm).then((path) {
      if (path == null || !_active) return;
      _queue.add(path);
      _drain();
    });
  }

  Future<String?> _writeWav(Uint8List pcm) async {
    try {
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/hari_live_$_seq.wav';
      final header = _wavHeader(pcm.length, _outRate);
      final f = File(path);
      await f.writeAsBytes(header + pcm, flush: false);
      return path;
    } catch (_) {
      return null;
    }
  }

  static List<int> _wavHeader(int dataLen, int rate) {
    final h = ByteData(44);
    void s(int off, String t) {
      for (var i = 0; i < t.length; i++) {
        h.setUint8(off + i, t.codeUnitAt(i));
      }
    }

    s(0, 'RIFF');
    h.setUint32(4, 36 + dataLen, Endian.little);
    s(8, 'WAVE');
    s(12, 'fmt ');
    h.setUint32(16, 16, Endian.little);
    h.setUint16(20, 1, Endian.little); // PCM
    h.setUint16(22, 1, Endian.little); // mono
    h.setUint32(24, rate, Endian.little);
    h.setUint32(28, rate * 2, Endian.little); // byte rate
    h.setUint16(32, 2, Endian.little); // block align
    h.setUint16(34, 16, Endian.little); // bits
    s(36, 'data');
    h.setUint32(40, dataLen, Endian.little);
    return h.buffer.asUint8List();
  }

  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    try {
      while (_active && _queue.isNotEmpty) {
        final path = _queue.removeAt(0);
        playing = true;
        onSpeaking?.call(true);
        final done = Completer<void>();
        final sub = _player.onPlayerStateChanged.listen((s) {
          if ((s == PlayerState.completed || s == PlayerState.stopped) &&
              !done.isCompleted) {
            done.complete();
          }
        });
        try {
          await _player.play(DeviceFileSource(path));
          await done.future.timeout(const Duration(seconds: 30),
              onTimeout: () {});
        } catch (_) {
        } finally {
          await sub.cancel();
          File(path).delete().ignore();
        }
      }
    } finally {
      _draining = false;
      playing = false;
      onSpeaking?.call(false);
    }
  }

  Future<void> _stopPlayback({required bool clear}) async {
    try {
      await _player.stop();
    } catch (_) {}
    if (clear) {
      _buf.clear();
      // Delete all queued temp files — player is already stopped so no race
      for (final p in _queue) {
        File(p).delete().ignore();
      }
      _queue.clear();
    }
    playing = false;
  }

  /// 0..1 mic level from a PCM16 chunk, for the orb animation.
  static double? _levelOf(List<int> chunk) {
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
    // Perceptual-ish mapping: speech RMS ~0.02–0.2 → visible motion.
    return (rms * 6).clamp(0.0, 1.0);
  }
}
