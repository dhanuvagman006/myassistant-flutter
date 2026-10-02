import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:firebase_ai/firebase_ai.dart' show FunctionCall, FunctionResponse;
import 'package:web_socket_channel/io.dart';

import '../core/log.dart';
import '../services/api_service.dart';
import 'config.dart';
import 'live_voice.dart';

/// THE FAST VOICE ON OPENAI REALTIME (2026-10-02, the owner: "completely
/// remove Gemini as the API provider and use OpenAI").
///
/// The phone opens its own socket to OpenAI's realtime model with a
/// short-lived key the server mints (POST /ai/realtime/secret — the real
/// key never leaves the server; the session's voice, instructions, tools
/// and audio formats are set there too). This connector speaks the app's
/// existing [LiveSessionPort] interface, so the engine that drives the
/// conversation — turns, barge-in, tools, captions — is unchanged.
///
/// Audio: the mic hands 16 kHz PCM; the model takes 24 kHz, so each chunk
/// is resampled on the way out. Replies come back as 24 kHz PCM, which the
/// player already handles by rate.
class OpenAiLiveConnector implements LiveConnector {
  OpenAiLiveConnector({
    Future<Map<String, dynamic>?> Function(Map<String, Object?> body)? mintSecret,
    OpenAiLiveSession Function(String model, String secret)? open,
  })  : _mint = mintSecret ?? ((body) => ApiService.postJson('/ai/realtime/secret', body)),
        _open = open ?? _dial;

  final Future<Map<String, dynamic>?> Function(Map<String, Object?> body) _mint;
  final OpenAiLiveSession Function(String model, String secret) _open;

  static OpenAiLiveSession _dial(String model, String secret) {
    final uri = Uri.parse('wss://api.openai.com/v1/realtime?model=${Uri.encodeQueryComponent(model)}');
    final channel = IOWebSocketChannel.connect(uri,
        headers: {'Authorization': 'Bearer $secret'}, pingInterval: const Duration(seconds: 20));
    return OpenAiLiveSession(channel.stream, (s) => channel.sink.add(s), () => channel.sink.close());
  }

  @override
  Future<LiveSessionPort> connect(LiveSetup setup, {String? resumeHandle}) async {
    final body = <String, Object?>{
      'model': setup.model,
      'voice': setup.voice,
      'instructions': setup.system,
      // Gemini-shaped declarations; the server turns them into OpenAI's.
      'tools': [for (final t in setup.tools) liveDeclarationFor(t).toJson()],
    };
    final minted = await _mint(body);
    final secret = (minted?['value'] ?? '').toString();
    if (secret.isEmpty) throw StateError('no realtime key from the server');
    final model = (minted?['model'] ?? setup.model).toString();
    final session = _open(model, secret);
    await session.ready.timeout(const Duration(seconds: 12));
    return session;
  }
}

/// One realtime session over a socket. Takes the incoming frames and two
/// callbacks rather than a socket type, so a test can drive it.
class OpenAiLiveSession implements LiveSessionPort {
  OpenAiLiveSession(Stream<dynamic> incoming, this._send, this._close) {
    // A socket that dies before anyone awaits [ready] must not be an
    // unhandled error; whoever awaits it still gets the failure.
    _ready.future.ignore();
    _sub = incoming.listen(_onFrame, onError: (Object e) {
      AppLog.add('live', 'realtime socket error: ${e.runtimeType}');
      _finish();
    }, onDone: _finish);
  }

  final void Function(String) _send;
  final Future<void> Function() _close;
  final _out = StreamController<LiveIn>();
  final _ready = Completer<void>();
  StreamSubscription<dynamic>? _sub;
  bool _closed = false;
  bool _responding = false;
  final _clock = Stopwatch()..start();
  int _pingMs = -1000;

  /// Resolves once the server has acknowledged the session.
  Future<void> get ready => _ready.future;

  @override
  Stream<LiveIn> get messages => _out.stream;

  void _emit(LiveIn m) {
    if (!_out.isClosed) _out.add(m);
  }

  void _alive() {
    final ms = _clock.elapsedMilliseconds;
    if (ms - _pingMs < 500) return;
    _pingMs = ms;
    _emit(const LiveInPing());
  }

  void _onFrame(dynamic frame) {
    Map<String, dynamic> e;
    try {
      final decoded = frame is String ? jsonDecode(frame) : jsonDecode(utf8.decode(frame as List<int>));
      if (decoded is! Map<String, dynamic>) return;
      e = decoded;
    } catch (_) {
      return;
    }
    _alive();
    final type = (e['type'] ?? '').toString();
    switch (type) {
      case 'session.created':
      case 'session.updated':
        if (!_ready.isCompleted) _ready.complete();
        _emit(const LiveInReady());
      case 'response.created':
        _responding = true;
      case 'input_audio_buffer.speech_started':
        // Barge-in only while she is answering: the model stops itself
        // (interrupt_response); the player stops here. Speech that opens a
        // turn in silence is just the owner talking.
        if (_responding) _emit(const LiveInContent(interrupted: true));
      case 'conversation.item.input_audio_transcription.completed':
        final heard = (e['transcript'] ?? '').toString();
        if (heard.trim().isNotEmpty) _emit(LiveInContent(heard: heard));
      case 'response.output_audio.delta':
      case 'response.audio.delta':
        final b64 = (e['delta'] ?? '').toString();
        if (b64.isNotEmpty) _emit(LiveInContent(audio: [(Uint8List.fromList(base64Decode(b64)), 24000)]));
      case 'response.output_audio_transcript.delta':
      case 'response.audio_transcript.delta':
        final said = (e['delta'] ?? '').toString();
        if (said.isNotEmpty) _emit(LiveInContent(said: said));
      case 'response.function_call_arguments.done':
        final name = (e['name'] ?? '').toString();
        if (name.isEmpty) break;
        Map<String, Object?> args;
        try {
          final parsed = jsonDecode((e['arguments'] ?? '{}').toString());
          args = parsed is Map ? parsed.cast<String, Object?>() : <String, Object?>{};
        } catch (_) {
          args = <String, Object?>{};
        }
        _emit(LiveInToolCall([FunctionCall(name, args, id: (e['call_id'] ?? '').toString())]));
      case 'response.done':
        _responding = false;
        final resp = e['response'];
        final status = resp is Map ? '${resp['status'] ?? ''}' : '';
        final output = resp is Map ? resp['output'] : null;
        final calledTools = output is List && output.any((o) => o is Map && o['type'] == 'function_call');
        if (status == 'failed' || status == 'incomplete') {
          AppLog.add('live', 'realtime response $status: ${resp is Map ? '${resp['status_details'] ?? ''}' : ''}');
        }
        // A response that ends in tool calls is not the end of her turn:
        // OpenAI closes it before the tools run, and she speaks the result
        // in the next response once the phone sends the outputs back. Told
        // "turn complete" here, the engine heard silence and gave up with
        // "no answer" (2026-10-02, the client's search).
        if (calledTools && status == 'completed') break;
        _emit(const LiveInContent(turnComplete: true));
      case 'error':
        final err = e['error'];
        final msg = err is Map ? '${err['message'] ?? err['code'] ?? err}' : '$err';
        AppLog.add('live', 'realtime: $msg');
        if (!_ready.isCompleted) _ready.completeError(StateError(msg));
      default:
        break;
    }
  }

  void _finish() {
    if (_closed) return;
    _closed = true;
    if (!_ready.isCompleted) _ready.completeError(StateError('the realtime socket closed'));
    if (!_out.isClosed) _out.close();
  }

  void _event(Map<String, Object?> e) {
    if (_closed) return;
    try {
      _send(jsonEncode(e));
    } catch (err) {
      AppLog.add('live', 'realtime send failed: ${err.runtimeType}');
      _finish();
    }
  }

  @override
  void sendAudio(Uint8List pcm16) =>
      _event({'type': 'input_audio_buffer.append', 'audio': base64Encode(resample16to24(pcm16))});

  @override
  void sendText(String text) {
    _event({
      'type': 'conversation.item.create',
      'item': {
        'type': 'message',
        'role': 'user',
        'content': [
          {'type': 'input_text', 'text': text}
        ],
      },
    });
    _event({'type': 'response.create'});
  }

  @override
  void sendToolResponses(List<FunctionResponse> responses) {
    for (final r in responses) {
      _event({
        'type': 'conversation.item.create',
        'item': {'type': 'function_call_output', 'call_id': r.id ?? '', 'output': jsonEncode(r.response)},
      });
    }
    _event({'type': 'response.create'});
  }

  @override
  Future<void> close() async {
    _closed = true;
    await _sub?.cancel();
    // Not awaited: with no listener yet, a controller's close() never settles.
    if (!_out.isClosed) unawaited(_out.close());
    try {
      await _close();
    } catch (_) {}
  }

  /// 16 kHz → 24 kHz, 16-bit mono: two input samples become three, the
  /// middle one halfway between. Good enough for speech, free of hiss.
  static Uint8List resample16to24(Uint8List pcm) {
    final n = pcm.length ~/ 2;
    if (n == 0) return Uint8List(0);
    final src = pcm.buffer.asByteData(pcm.offsetInBytes, n * 2);
    final outN = (n * 3) ~/ 2;
    final out = ByteData(outN * 2);
    for (var i = 0; i < outN; i++) {
      final pos = i * 2 / 3; // input index this output sample sits on
      final a = pos.floor();
      final b = a + 1 < n ? a + 1 : a;
      final t = pos - a;
      final sa = src.getInt16(a * 2, Endian.little);
      final sb = src.getInt16(b * 2, Endian.little);
      out.setInt16(i * 2, (sa + (sb - sa) * t).round().clamp(-32768, 32767), Endian.little);
    }
    return out.buffer.asUint8List();
  }
}

/// Picks the fast voice's connector by the served provider, per session.
class SwitchingLiveConnector implements LiveConnector {
  SwitchingLiveConnector({LiveConnector? gemini, LiveConnector? openai, bool Function()? viaServer})
      : _gemini = gemini ?? FirebaseLiveConnector(),
        _openai = openai ?? OpenAiLiveConnector(),
        _viaServer = viaServer ?? (() => AiConfigStore.instance.current.viaServer);

  final LiveConnector _gemini;
  final LiveConnector _openai;
  final bool Function() _viaServer;

  @override
  Future<LiveSessionPort> connect(LiveSetup setup, {String? resumeHandle}) =>
      (_viaServer() ? _openai : _gemini).connect(setup, resumeHandle: resumeHandle);
}

