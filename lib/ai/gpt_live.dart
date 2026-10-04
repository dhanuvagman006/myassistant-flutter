import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:firebase_ai/firebase_ai.dart' show FunctionCall, FunctionResponse;
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../core/log.dart';
import '../services/api_service.dart';
import 'live_voice.dart';
import 'openai_live.dart';

/// THE FAST VOICE ON GPT-LIVE (the owner's agent, 2026-10-02).
///
/// GPT-Live runs over WebRTC only and has no client key: the phone makes
/// its offer, our server creates the session with OpenAI
/// (POST /ai/live/session, the agent's JSON lives there) and hands back the
/// answer. The microphone and her voice travel on the peer connection's
/// audio tracks; events travel on the `oai-events` data channel. The
/// session is started by that request, so nothing is sent at startup.
///
/// It speaks the app's [LiveSessionPort], so the engine's turns, tools and
/// captions are unchanged. GPT-Live has no turns, so a turn ends when the
/// last of her words, timed by `end_ms`, has been heard.
class GptLiveConnector implements LiveConnector {
  GptLiveConnector({Future<Map<String, dynamic>?> Function(Map<String, Object?> body)? createSession})
      : _create = createSession ?? ((body) => ApiService.postJson('/ai/live/session', body));

  final Future<Map<String, dynamic>?> Function(Map<String, Object?> body) _create;

  /// FASTER CONNECT (owner, 2026-10-04: "it takes too much time to
  /// connect"). The phone's half of the call — microphone, data channel,
  /// SDP offer — does not depend on the instruction, so [prepare] builds it
  /// while the context is fetched, and [connect] takes it. Unused for a
  /// minute, it is closed (it holds the microphone, track disabled).
  static Future<_Peer>? _spare;
  static Timer? _spareTtl;

  static void prepare() {
    if (_spare != null) return;
    final f = _openPeer();
    _spare = f;
    f.catchError((Object _) {
      if (identical(_spare, f)) _spare = null;
      return _Peer.none;
    });
    _spareTtl?.cancel();
    _spareTtl = Timer(const Duration(seconds: 60), () {
      final left = _spare;
      _spare = null;
      left?.then((p) => p.dispose()).catchError((Object _) {});
    });
  }

  static Future<_Peer> _take() async {
    final spare = _spare;
    _spare = null;
    _spareTtl?.cancel();
    if (spare != null) {
      try {
        final p = await spare;
        if (p.pc != null) return p;
      } catch (_) {}
    }
    return _openPeer();
  }

  static Future<_Peer> _openPeer() async {
    final sw = Stopwatch()..start();
    RTCPeerConnection? pc;
    MediaStream? mic;
    try {
      pc = await createPeerConnection(<String, dynamic>{});
      mic = await navigator.mediaDevices.getUserMedia(<String, dynamic>{
        'audio': {'echoCancellation': true, 'noiseSuppression': true, 'autoGainControl': true},
        'video': false,
      });
      final track = mic.getAudioTracks().first;
      // Closed until the conversation opens the microphone: a session
      // warmed on app-open must not hear the room.
      track.enabled = false;
      await pc.addTrack(track, mic);
      final remote = <MediaStreamTrack>[];
      pc.onTrack = (e) {
        if (e.track.kind == 'audio') remote.add(e.track);
      };
      // The event channel exists before the offer, or it is not in it.
      final channel = await pc.createDataChannel('oai-events', RTCDataChannelInit());
      final incoming = StreamController<String>();
      channel.onMessage = (m) {
        if (!m.isBinary && !incoming.isClosed) incoming.add(m.text);
      };
      channel.onDataChannelState = (s) {
        if (s == RTCDataChannelState.RTCDataChannelClosed && !incoming.isClosed) unawaited(incoming.close());
      };
      final offer = await pc.createOffer(<String, dynamic>{});
      await pc.setLocalDescription(offer);
      await _gathered(pc);
      final local = await pc.getLocalDescription();
      final sdp = local?.sdp ?? '';
      if (sdp.isEmpty) throw StateError('no local SDP offer');
      AppLog.add('live', 'gpt-live: phone side ready in ${sw.elapsedMilliseconds} ms');
      return _Peer(pc, mic, track, remote, channel, incoming, sdp);
    } catch (_) {
      for (final t in mic?.getTracks() ?? const <MediaStreamTrack>[]) {
        unawaited(t.stop().catchError((Object _) {}));
      }
      unawaited(pc?.close().catchError((Object _) {}));
      rethrow;
    }
  }

  @override
  Future<LiveSessionPort> connect(LiveSetup setup, {String? resumeHandle}) async {
    final p = await _take();
    final pc = p.pc!;
    final mic = p.mic!;
    final track = p.track!;
    final remote = p.remote;
    final channel = p.channel!;
    final incoming = p.incoming!;
    final sdp = p.sdp;
    final sw = Stopwatch()..start();
    try {
      final created = await _create({
        'sdp': sdp,
        'instructions': setup.system,
        // Gemini-shaped declarations; the server turns them into OpenAI's.
        'tools': [for (final t in setup.tools) liveDeclarationFor(t).toJson()],
      });
      final transport = created?['transport'];
      final answer = transport is Map ? '${transport['sdp'] ?? ''}' : '';
      if (answer.isEmpty) throw StateError('no GPT-Live session from the server');
      final id = created?['session'] is Map ? '${(created!['session'] as Map)['id'] ?? ''}' : '';
      AppLog.add('live', 'gpt-live session $id (server ${sw.elapsedMilliseconds} ms)');
      await pc.setRemoteDescription(RTCSessionDescription(answer, 'answer'));
      unawaited(Helper.setSpeakerphoneOn(true).catchError((Object _) {}));
      final peer = pc;
      final stream = mic;
      final session = GptLiveSession(
        incoming.stream,
        (s) {
          if (channel.state == RTCDataChannelState.RTCDataChannelOpen) unawaited(channel.send(RTCDataChannelMessage(s)));
        },
        () async {
          for (final t in stream.getTracks()) {
            await t.stop();
          }
          await stream.dispose();
          await channel.close();
          await peer.close();
        },
        mic: (open) => track.enabled = open,
        speaker: (on) {
          for (final t in remote) {
            t.enabled = on;
          }
        },
      );
      await session.ready.timeout(const Duration(seconds: 12));
      AppLog.add('live', 'gpt-live: started ${sw.elapsedMilliseconds} ms after the offer');
      return session;
    } catch (_) {
      await p.dispose();
      rethrow;
    }
  }

  /// The offer carries every ICE candidate (no trickle to OpenAI).
  static Future<void> _gathered(RTCPeerConnection pc) async {
    if (pc.iceGatheringState == RTCIceGatheringState.RTCIceGatheringStateComplete) return;
    final done = Completer<void>();
    pc.onIceGatheringState = (s) {
      if (s == RTCIceGatheringState.RTCIceGatheringStateComplete && !done.isCompleted) done.complete();
    };
    // 1.5 s, not 10 (2026-10-04): OpenAI's side has a public address, so
    // the phone's own host candidates gathered by now are enough; a slow
    // interface (often IPv6) used to hold the whole connect.
    await done.future.timeout(const Duration(milliseconds: 1500), onTimeout: () {
      AppLog.add('live', 'gpt-live: ICE gathering still running after 1.5 s, offering what there is');
    });
  }
}

/// The phone's half of a GPT-Live call, before the server has answered.
class _Peer {
  _Peer(this.pc, this.mic, this.track, this.remote, this.channel, this.incoming, this.sdp);
  static final none = _Peer(null, null, null, const [], null, null, '');
  final RTCPeerConnection? pc;
  final MediaStream? mic;
  final MediaStreamTrack? track;
  final List<MediaStreamTrack> remote;
  final RTCDataChannel? channel;
  final StreamController<String>? incoming;
  final String sdp;

  Future<void> dispose() async {
    for (final t in mic?.getTracks() ?? const <MediaStreamTrack>[]) {
      await t.stop().catchError((Object _) {});
    }
    await mic?.dispose().catchError((Object _) {});
    await channel?.close().catchError((Object _) {});
    await pc?.close().catchError((Object _) {});
  }
}

/// One GPT-Live conversation: its data-channel events, as the engine's
/// [LiveIn]s. The WebRTC plumbing is outside, so this is testable.
class GptLiveSession implements LiveSessionPort, CancellableReply, OwnsAudio {
  GptLiveSession(
    Stream<String> incoming,
    this._send,
    this._dispose, {
    void Function(bool open)? mic,
    void Function(bool on)? speaker,
    this.closeWait = const Duration(seconds: 15),
    this.tailMs = 600,
  })  : _mic = mic,
        _speaker = speaker {
    _sub = incoming.listen(_onEvent, onDone: _onChannelDone, onError: (Object _) => _onChannelDone());
  }

  final void Function(String) _send;
  final Future<void> Function() _dispose;
  final void Function(bool)? _mic;
  final void Function(bool)? _speaker;

  /// How long a close waits for `session.closed` before giving up.
  final Duration closeWait;

  /// Quiet after her last word's end before her turn is over.
  final int tailMs;

  final _out = StreamController<LiveIn>();
  final _ready = Completer<void>();
  final _closed = Completer<void>();
  StreamSubscription<String>? _sub;
  final _clock = Stopwatch();
  Timer? _turnEnd;
  bool _speaking = false;

  /// The backend is on their request (delegated, until its final answer).
  bool _pending = false;
  String? _tool;
  Timer? _stall;
  bool _muted = false;
  bool _closing = false;
  bool _disposed = false;
  int _events = 0;

  @override
  Stream<LiveIn> get messages => _out.stream;

  Future<void> get ready => _ready.future;

  void _emit(LiveIn m) {
    if (!_out.isClosed) _out.add(m);
  }

  void _event(Map<String, Object?> e) => _send(jsonEncode({'event_id': 'app_${++_events}', ...e}));

  void _onEvent(String raw) {
    Map<String, dynamic> e;
    try {
      final j = jsonDecode(raw);
      if (j is! Map<String, dynamic>) return;
      e = j;
    } catch (_) {
      return;
    }
    _emit(const LiveInPing());
    switch ('${e['type'] ?? ''}') {
      case 'session.started':
        _clock.start();
        if (!_ready.isCompleted) _ready.complete();
        _emit(const LiveInReady());
      case 'session.input_transcript.delta':
        final heard = '${e['delta'] ?? ''}';
        // They spoke after a stop: her voice is theirs to hear again.
        if (_muted) {
          _muted = false;
          _speaker?.call(true);
        }
        if (heard.isNotEmpty && OpenAiLiveSession.plausible(heard)) _emit(LiveInContent(heard: heard));
      case 'session.output_transcript.delta':
        final said = '${e['delta'] ?? ''}';
        if (said.isEmpty) break;
        _speaking = true;
        _emit(LiveInContent(said: said));
        _armTurnEnd(e['end_ms']);
      case 'session.delegation.created':
        _work(null);
      case 'response.event':
        _onBackend(e['event']);
      case 'session.usage.updated':
        final u = e['usage'];
        if (u is Map) AppLog.add('live', 'gpt-live: ${u['seconds']} s so far');
      case 'error':
        final err = e['error'];
        final msg = err is Map ? '${err['message'] ?? err['code'] ?? err}' : '$err';
        AppLog.add('live', 'gpt-live: $msg');
        if (_pending) _done();
        if (!_ready.isCompleted) _ready.completeError(StateError(msg));
      case 'session.closed':
        AppLog.add('live', 'gpt-live closed (${e['reason'] ?? 'no reason'})');
        if (!_closed.isCompleted) _closed.complete();
        unawaited(_finish());
      default:
        break;
    }
  }

  /// The backend model's own events, wrapped: its finished function calls
  /// are the app's to run.
  void _onBackend(Object? inner) {
    if (inner is! Map) return;
    final type = '${inner['type'] ?? ''}';
    final added = inner['item'] is Map ? inner['item'] as Map : const {};
    if (!_pending && type == 'response.created') _work(null);
    if (_pending) _armStall();
    if (type == 'response.output_item.added' && added['type'] == 'web_search_call') _work('web_search');
    if (type == 'response.completed' || type == 'response.failed' || type == 'response.incomplete') {
      final resp = inner['response'];
      final out = resp is Map ? resp['output'] : null;
      final calls = out is List && out.any((o) => o is Map && o['type'] == 'function_call');
      if (type != 'response.completed') AppLog.add('live', 'gpt-live backend: $type');
      // A function call is the phone's to answer; the work goes on.
      if (!calls || type != 'response.completed') _done();
      return;
    }
    if (type != 'response.output_item.done') return;
    final item = inner['item'] is Map ? inner['item'] as Map : inner;
    final name = '${item['name'] ?? ''}';
    if (name.isEmpty || (item['type'] != null && item['type'] != 'function_call')) return;
    Map<String, Object?> args;
    try {
      final parsed = jsonDecode('${item['arguments'] ?? '{}'}');
      args = parsed is Map ? parsed.cast<String, Object?>() : <String, Object?>{};
    } catch (_) {
      args = <String, Object?>{};
    }
    _turnEnd?.cancel();
    _emit(LiveInToolCall([FunctionCall(name, args, id: '${item['call_id'] ?? ''}')]));
  }

  /// The backend took their request: show it working (again, once her
  /// "let me check" has been said).
  void _work(String? tool) {
    _pending = true;
    if (tool != null) _tool = tool;
    _armStall();
    _emit(LiveInWorking(_tool));
  }

  /// The backend's answer is in: she says it next. Words or not, the turn
  /// ends — a few seconds' grace for her to start.
  void _done() {
    _pending = false;
    _tool = null;
    _stall?.cancel();
    _turnEnd?.cancel();
    _turnEnd = Timer(const Duration(seconds: 6), _endTurn);
  }

  /// Nothing from the backend for a minute: it is not coming.
  void _armStall() {
    _stall?.cancel();
    _stall = Timer(const Duration(seconds: 60), () {
      if (!_pending) return;
      AppLog.add('live', 'gpt-live: the backend went quiet for 60 s');
      _pending = false;
      _tool = null;
      _endTurn();
    });
  }

  void _endTurn() {
    _speaking = false;
    _emit(const LiveInContent(turnComplete: true));
  }

  /// Her turn is over once the audio of her last word has played: [endMs]
  /// is where it ends on the session's clock. While the backend is still
  /// working, the end of her "let me check" shows it working instead.
  void _armTurnEnd(Object? endMs) {
    _turnEnd?.cancel();
    final end = endMs is num ? endMs.toInt() : _clock.elapsedMilliseconds;
    final wait = (end - _clock.elapsedMilliseconds).clamp(0, 30000) + tailMs;
    _turnEnd = Timer(Duration(milliseconds: wait), () {
      if (_pending) {
        _emit(LiveInWorking(_tool));
        return;
      }
      if (!_speaking) return;
      _endTurn();
    });
  }

  @override
  void sendAudio(Uint8List pcm16) {} // the audio track carries the microphone

  @override
  void setMicOpen(bool open) {
    _mic?.call(open);
    _event({'type': open ? 'session.input_audio.unmute' : 'session.input_audio.mute'});
  }

  /// A nudge or a typed line: context for her, at most 500 tokens.
  @override
  void sendText(String text) {
    final t = text.length > 1800 ? text.substring(0, 1800) : text;
    _event({'type': 'session.instructions.append', 'delegation_id': null, 'content': t});
  }

  @override
  void sendToolResponses(List<FunctionResponse> responses) {
    for (final r in responses) {
      _event({
        'type': 'response.item.create',
        'item': {'type': 'function_call_output', 'call_id': r.id ?? '', 'output': jsonEncode(r.response)},
      });
    }
    _event({'type': 'response.create'});
  }

  /// The stop button: her voice goes quiet here until they speak again.
  @override
  void cancelReply() {
    _pending = false;
    _tool = null;
    _stall?.cancel();
    _muted = true;
    _speaker?.call(false);
    if (_speaking) {
      _speaking = false;
      _turnEnd?.cancel();
      _emit(const LiveInContent(turnComplete: true));
    }
  }

  /// `session.close`, then the audio and channel stay up until
  /// `session.closed` (the usage is final then); a timeout or a dropped
  /// channel is logged as an incomplete finalization.
  @override
  Future<void> close() async {
    if (_closing) return _closed.future;
    _closing = true;
    _mic?.call(false);
    if (!_ready.isCompleted) {
      _ready.completeError(StateError('closed before the session started'));
      _ready.future.ignore();
      await _finish();
      return;
    }
    _event({'type': 'session.close'});
    await _closed.future.timeout(closeWait, onTimeout: () {
      AppLog.add('live', 'gpt-live: incomplete finalization (no session.closed in ${closeWait.inSeconds} s)');
    });
    await _finish();
  }

  void _onChannelDone() {
    if (!_closed.isCompleted) {
      AppLog.add('live', 'gpt-live: incomplete finalization (the channel dropped)');
      _closed.complete();
    }
    if (!_ready.isCompleted) _ready.completeError(StateError('the GPT-Live channel closed'));
    unawaited(_finish());
  }

  Future<void> _finish() async {
    if (_disposed) return;
    _disposed = true;
    _turnEnd?.cancel();
    _stall?.cancel();
    await _sub?.cancel();
    if (!_out.isClosed) unawaited(_out.close());
    await _dispose().catchError((Object _) {});
  }
}
