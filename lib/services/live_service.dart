import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_sound/flutter_sound.dart';
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
///  PLAYBACK: a single flutter_sound STREAM player fed raw PCM as it
///  arrives — truly gapless. The old approach (short WAV segments played
///  back-to-back through a file player) paid file-write + player-startup
///  latency at EVERY ~600 ms boundary, which the user heard as the voice
///  "breaking" mid-sentence.
/// ─────────────────────────────────────────────────────────────────────────
class LiveService {
  LiveService._();
  static final LiveService instance = LiveService._();

  WebSocketChannel? _ch;
  StreamSubscription? _wsSub;
  final AudioRecorder _rec = AudioRecorder();
  StreamSubscription<List<int>>? _micSub;
  final FlutterSoundPlayer _fs = FlutterSoundPlayer();

  bool _active = false;
  bool get active => _active;

  /// True while the AVATAR is speaking out of the phone's loudspeaker.
  ///
  /// In avatar mode Hari's audio never reaches this app — it goes to the
  /// avatar service — so [playing] stays false for the whole conversation
  /// and the mic gate below never closes. The result is that her own voice,
  /// picked up by the microphone, is uploaded to the model as if the user
  /// were talking over her, and she interrupts herself mid-sentence.
  /// AvatarService drives this flag from the real audio in the room.
  bool remoteSpeaking = false;

  /// Fires when the server reports the avatar starting/stopping speech.
  void Function(bool speaking)? onAvatarSpeaking;

  /// A DEVICE ACTION the assistant wants this phone to perform — open the
  /// camera, look up a contact, capture a document.
  ///
  /// Tools that need the handset return these, and the server forwards them
  /// down this socket. Nothing was listening: the switch below handled only
  /// the protocol's own message types and everything else fell through, so
  /// in live mode the assistant would say "Opening the camera" and then
  /// nothing happened at all.
  void Function(Map<String, dynamic> action)? onDeviceAction;

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
  void Function(Uint8List chunk)? onAudioChunk; // For external renderer (avatar)

  // ---- streaming playback state ----
  bool _fsOpen = false;
  bool _fsStreaming = false;

  /// When the audio fed so far will finish coming out of the speaker.
  /// The stream player has no per-chunk completion events, but PCM maths
  /// is exact: bytes ÷ (rate × 2) — so [playing] is derived from the clock.
  DateTime _playheadEnd = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _playStateTimer;

  static const _outRate = 24000; // Gemini native-audio output sample rate
  static const _inRate = 16000; // what we send up

  // ---- VOICE ACTIVITY DETECTION (this side decides, not Google) ----
  //
  // Every mic frame is ~128 ms of audio at 16 kHz, so these are counted in
  // frames rather than milliseconds.
  //
  // The detector is ADAPTIVE. A fixed level threshold cannot work: a quiet
  // room and a moving car differ by an order of magnitude, and a fixed
  // number is either deaf in one or permanently triggered in the other. So
  // the noise floor is measured continuously while nobody is speaking, and
  // speech is "clearly louder than this room currently is".
  double _noiseFloor = 0.01; // running estimate of the room
  bool _speaking = false; // is the user mid-utterance right now?
  int _aboveMs = 0; // consecutive audio above the speech threshold
  int _belowMs = 0; // consecutive audio below it
  int _utteranceMs = 0; // length of the current utterance

  /// Speech must be this many times the room's noise floor. Background
  /// sound sits at the floor by definition, so it never clears this bar.
  static const _speechFactor = 3.0;

  /// An absolute floor too, so a very quiet room's tiny noise estimate
  /// cannot make a fan or a distant voice look like speech. _levelOf maps
  /// RMS through x6, so speech lands around 0.12-1.0 and a still room sits
  /// well under 0.03; 0.08 sits in the gap between them.
  static const _minSpeechLevel = 0.08;

  /// How much loud audio before we accept it as speech. Stops a door slam
  /// or a keyboard click from opening a turn.
  static const _onsetMs = 200;

  /// How much quiet before the turn is ENDED. This is the number the user
  /// feels — the pause between them stopping and Hari starting. Short
  /// enough to feel immediate, long enough to survive the gap between
  /// words. Tuned here rather than on the server because only this side
  /// knows the room.
  static const _hangoverMs = 450;

  /// A turn that never ends is a hung app. If someone is in a genuinely
  /// loud place the detector could in principle stay open, so cut it.
  static const _maxUtteranceMs = 30000;

  /// PCM16 mono @16 kHz: 32 bytes per millisecond. Deriving duration from
  /// the buffer means the thresholds above stay honest whatever chunk size
  /// the recorder happens to hand us — assuming a fixed frame length would
  /// silently scale every timeout on a different device.
  static int _msOf(List<int> chunk) => chunk.length ~/ 32;

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
  ///
  /// [avatarRoom] is the LiveKit room reserved for this conversation, when
  /// the avatar is in play. Passing it tells the backend to route Hari's
  /// voice into that room for lip-sync instead of sending PCM down this
  /// socket, so the app must not expect reply audio here in that case.
  Future<void> start({String? avatarRoom}) async {
    if (_active) return;
    _active = true;
    if (!await _rec.hasPermission()) {
      onError?.call('Microphone permission is needed for live mode.');
      return;
    }
    playing = false;
    remoteSpeaking = false;
    _speaking = false;
    _aboveMs = 0;
    _belowMs = 0;
    _utteranceMs = 0;
    _noiseFloor = 0.01;
    _playheadEnd = DateTime.fromMillisecondsSinceEpoch(0);

    // Open the gapless PCM stream player up-front, so the very first reply
    // byte can be fed straight to the speaker.
    try {
      if (!_fsOpen) {
        await _fs.openPlayer();
        _fsOpen = true;
      }
      await _startStream();
    } catch (_) {
      // Playback failing must not kill the session in avatar mode, where
      // audio never reaches this app anyway.
    }

    // http(s)://host → ws(s)://host/live/ws?token=…
    final base = ApiService.baseUrl.replaceFirst(RegExp(r'^http'), 'ws');
    final qp = ApiService.sessionToken != null
        ? 'token=${Uri.encodeComponent(ApiService.sessionToken!)}'
        : 'appKey=${Uri.encodeComponent(ApiService.appApiKey)}';
    final room = avatarRoom == null
        ? ''
        : '&room=${Uri.encodeComponent(avatarRoom)}';
    // Device context for server-side tools: timezone so "tomorrow at 8"
    // lands in the right day, platform so deep links can use Android
    // intent:// URLs. Same facts the classic path sends as headers.
    final tz = DateTime.now().timeZoneOffset.inMinutes;
    final platform = Platform.isAndroid
        ? 'android'
        : Platform.isIOS
            ? 'ios'
            : 'other';
    // Coordinates ride along when known, so live-mode tools can answer
    // "weather here", "hotels near me", cab pickups — same as the headers
    // on the classic path.
    final geo = ApiService.geoLat != null
        ? '&lat=${ApiService.geoLat!.toStringAsFixed(4)}'
            '&lng=${ApiService.geoLng!.toStringAsFixed(4)}'
        : '';
    final uri =
        Uri.parse('$base/live/ws?$qp$room&tz=$tz&platform=$platform$geo');

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
        final l = _levelOf(chunk);
        if (l != null) onMicLevel?.call(l);
        try {
          // While Hari is audible her voice must never go back up the mic,
          // or the model hears itself. Also drop any half-open turn so we
          // do not resume mid-utterance when she finishes.
          if (playing || remoteSpeaking) {
            if (_speaking) _endUtterance();
            return;
          }
          if (l == null) return;

          final threshold =
              math.max(_noiseFloor * _speechFactor, _minSpeechLevel);
          final loud = l > threshold;

          final ms = _msOf(chunk);

          // STREAM EVERY FRAME, INCLUDING THE SILENCE.
          //
          // Google's detector decides when the turn ends, and it decides by
          // HEARING the pause. Withholding quiet audio — which an earlier
          // version did, and which manual activity markers also effectively
          // did — means the pause never arrives and the turn hangs open.
          // So the audio path is unconditional; the detection below is only
          // a probe for timing logs and for driving the orb.
          _ch?.sink.add(Uint8List.fromList(chunk));

          if (!_speaking) {
            if (!loud) {
              // Learn the room while nobody is talking. Never while they
              // are, or the user's own voice drags the floor up until they
              // are inaudible to the probe.
              _noiseFloor = _noiseFloor * 0.95 + l * 0.05;
              _aboveMs = 0;
              return;
            }
            _aboveMs += ms;
            if (_aboveMs < _onsetMs) return;
            _speaking = true;
            _belowMs = 0;
            _utteranceMs = 0;
            _send({'type': 'activity_start'});
            return;
          }

          _utteranceMs += ms;
          if (loud) {
            _belowMs = 0;
          } else {
            _belowMs += ms;
          }
          if (_belowMs >= _hangoverMs || _utteranceMs >= _maxUtteranceMs) {
            _endUtterance();
          }
        } catch (_) {}
      });
    } catch (e) {
      onError?.call('Could not open the microphone for live mode.');
      await stop();
      return;
    }

    // Playback-state clock: [playing] gates the mic, so it must fall to
    // false the moment the fed audio has actually finished sounding.
    _playStateTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      final isPlaying = DateTime.now().isBefore(_playheadEnd);
      if (isPlaying != playing) {
        playing = isPlaying;
        onSpeaking?.call(playing);
      }
    });
  }

  /// (Re)arms the PCM stream. Called at session start and after every
  /// hard stop (barge-in interrupt), so the next turn plays instantly.
  Future<void> _startStream() async {
    if (!_fsOpen || _fsStreaming) return;
    await _fs.startPlayerFromStream(
      codec: Codec.pcm16,
      numChannels: 1,
      sampleRate: _outRate,
      interleaved: true,
      bufferSize: 4096,
    );
    try {
      await _fs.setVolume(1.0);
    } catch (_) {}
    _fsStreaming = true;
  }

  /// Gemini's live PCM is mastered quiet — noticeably softer than the
  /// avatar path, which plays through WebRTC's call stack. +5.6 dB with a
  /// hard ceiling brings the two in line; speech rarely peaks, so clipping
  /// is inaudible in practice.
  static const double _playbackGain = 1.9;

  static Uint8List _boost(Uint8List chunk) {
    final out = Uint8List(chunk.length & ~1);
    for (var i = 0; i + 1 < chunk.length; i += 2) {
      var s = chunk[i] | (chunk[i + 1] << 8);
      if (s >= 0x8000) s -= 0x10000;
      var v = (s * _playbackGain).round();
      if (v > 32767) v = 32767;
      if (v < -32768) v = -32768;
      out[i] = v & 0xFF;
      out[i + 1] = (v >> 8) & 0xFF;
    }
    return out;
  }

  /// Feeds one reply chunk to the speaker and advances the playhead clock.
  void _feed(Uint8List rawChunk) {
    final chunk = _boost(rawChunk);
    if (!_fsStreaming || chunk.isEmpty) return;
    try {
      _fs.uint8ListSink?.add(chunk);
    } catch (_) {
      return;
    }
    final ms = chunk.length * 1000 ~/ (_outRate * 2);
    final now = DateTime.now();
    final base = _playheadEnd.isAfter(now)
        ? _playheadEnd
        // Fresh turn: pad slightly for the player's own startup latency.
        : now.add(const Duration(milliseconds: 80));
    _playheadEnd = base.add(Duration(milliseconds: ms));
    if (!playing) {
      // Close the mic gate IMMEDIATELY — waiting for the 100 ms timer left
      // a window where the reply's first syllable re-entered the mic.
      playing = true;
      onSpeaking?.call(true);
    }
  }

  /// Closes the current utterance and asks the server to answer NOW.
  void _endUtterance() {
    if (!_speaking) return;
    _speaking = false;
    _aboveMs = 0;
    _belowMs = 0;
    _utteranceMs = 0;
    _send({'type': 'activity_end'});
  }

  void _send(Map<String, dynamic> m) {
    try {
      _ch?.sink.add(jsonEncode(m));
    } catch (_) {}
  }

  /// Ends the session and releases the mic/speaker.
  Future<void> stop() async {
    if (!_active && _ch == null) return;
    _active = false;
    try {
      _ch?.sink.add(jsonEncode({'type': 'end'}));
    } catch (_) {}
    _playStateTimer?.cancel();
    _playStateTimer = null;
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
      // Reply audio: PCM16 @24 kHz — straight to the stream player.
      final chunk = frame is Uint8List ? frame : Uint8List.fromList(frame);
      _feed(chunk);
      onAudioChunk?.call(chunk);
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
        case 'avatar_speaking':
          // Authoritative "Hari is audible" signal from the server, which
          // is the only side that can know: her audio goes to the avatar
          // service, never to this app. It already accounts for the avatar
          // still playing out audio after the last byte was sent.
          final speaking = m['speaking'] == true;
          remoteSpeaking = speaking;
          onAvatarSpeaking?.call(speaking);
          break;
        case 'interrupted':
          // The user talked over Hari — Google already cut generation; we
          // must cut PLAYBACK immediately or she keeps talking from the
          // buffer.
          _stopPlayback(clear: true);
          onInterrupted?.call();
          break;
        case 'turn_complete':
          // Nothing to flush — every byte was fed on arrival.
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
        // Anything that is not part of the wire protocol above is a DEVICE
        // ACTION for the app to carry out. Matching the fallthrough rather
        // than listing action names keeps this from needing an edit every
        // time a new handset-side tool is added. Nothing was listening
        // before, so in live mode the assistant announced "Opening the
        // camera" and then nothing happened.
        default:
          final t = m['type'];
          if (t is String && t.isNotEmpty) {
            onDeviceAction?.call(Map<String, dynamic>.from(m));
          }
      }
    }
  }

  // ---------------- playback (gapless PCM stream) ----------------

  /// Hard-stops whatever is sounding RIGHT NOW (barge-in, session end) and
  /// re-arms the stream for the next turn while the session lives on.
  Future<void> _stopPlayback({required bool clear}) async {
    _playheadEnd = DateTime.fromMillisecondsSinceEpoch(0);
    playing = false;
    if (_fsStreaming) {
      _fsStreaming = false;
      try {
        await _fs.stopPlayer();
      } catch (_) {}
    }
    if (_active) {
      try {
        await _startStream();
      } catch (_) {}
    }
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
