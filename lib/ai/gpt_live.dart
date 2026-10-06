import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:firebase_ai/firebase_ai.dart' show FunctionCall, FunctionResponse;
import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding;
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../core/log.dart';
import '../services/api_service.dart';
import 'live_voice.dart';

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
  /// connect"; 2026-10-06: "make it much more faster"). The phone's half of
  /// the call (peer, an audio slot, data channel, SDP offer, ICE) does not
  /// depend on the instruction, so [prepare] builds it ahead and [connect]
  /// takes it. It holds NO microphone: the audio slot is an empty
  /// send-receive transceiver, and the microphone is opened at connect, in
  /// parallel with the server's session, and put in the slot with
  /// replaceTrack (no renegotiation). So a spare costs nothing, shows no
  /// microphone indicator, and can be kept ready for minutes.
  static Future<_Peer>? _spare;
  static Timer? _spareTtl;

  /// A spare's offer is good while the network it was gathered on is.
  static const spareTtl = Duration(minutes: 3);

  /// Sound to the loudspeaker (call mode routes it to the earpiece).
  static Future<void> loudspeaker() async {
    try {
      await Helper.setSpeakerphoneOn(true);
    } catch (_) {}
  }

  static void prepare() {
    if (_spare != null) return;
    final f = _openPeer();
    _spare = f;
    f.catchError((Object _) {
      if (identical(_spare, f)) _spare = null;
      return _Peer.none;
    });
    _spareTtl?.cancel();
    _spareTtl = Timer(spareTtl, () {
      final left = _spare;
      _spare = null;
      left?.then((p) => p.dispose()).catchError((Object _) {});
      // Kept ready while the app is in front: the next one is gathered on
      // the network as it is now. In the background nothing is kept.
      if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) prepare();
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

  static Future<MediaStream> _openMic() => navigator.mediaDevices.getUserMedia(<String, dynamic>{
        'audio': {'echoCancellation': true, 'noiseSuppression': true, 'autoGainControl': true},
        'video': false,
      });

  static Future<_Peer> _openPeer() async {
    final sw = Stopwatch()..start();
    RTCPeerConnection? pc;
    try {
      pc = await createPeerConnection(<String, dynamic>{'sdpSemantics': 'unified-plan'});
      // The microphone's place in the call, empty until connect.
      final audio = await pc.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.SendRecv),
      );
      final remote = <MediaStreamTrack>[];
      // Her voice stays silent until the conversation opens: a warmed
      // session may decide to speak, and nobody asked it to yet.
      final audible = _Audible();
      pc.onTrack = (e) {
        if (e.track.kind != 'audio') return;
        e.track.enabled = audible.on;
        remote.add(e.track);
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
      return _Peer(pc, audio.sender, remote, channel, incoming, sdp, audible);
    } catch (_) {
      unawaited(pc?.close().catchError((Object _) {}));
      rethrow;
    }
  }

  @override
  Future<LiveSessionPort> connect(LiveSetup setup, {String? resumeHandle}) async {
    final p = await _take();
    final pc = p.pc!;
    final sender = p.sender!;
    final remote = p.remote;
    final audible = p.audible;
    final channel = p.channel!;
    final incoming = p.incoming!;
    final sdp = p.sdp;
    final sw = Stopwatch()..start();
    // THE MICROPHONE OPENS WHEN THEY ARE LISTENED TO (2026-10-06), not when
    // the session is warmed: a session waiting for the tap holds none (no
    // privacy indicator), and the greeting needs none. The first
    // setMicOpen(true) opens it and puts it in the call's audio slot.
    MediaStream? mic;
    MediaStreamTrack? track;
    Future<void>? micOpening;
    var micWanted = false;
    var disposed = false;
    void openMic() {
      micOpening ??= () async {
        final opened = Stopwatch()..start();
        final m = await _openMic();
        if (disposed) {
          for (final t in m.getTracks()) {
            await t.stop();
          }
          await m.dispose();
          return;
        }
        final t = m.getAudioTracks().first;
        t.enabled = micWanted;
        await sender.replaceTrack(t);
        mic = m;
        track = t;
        AppLog.add('live', 'gpt-live: microphone on in ${opened.elapsedMilliseconds} ms');
      }()
          .catchError((Object e) {
        AppLog.add('live', 'gpt-live: the microphone could not open: ${e.runtimeType}');
        micOpening = null;
      });
    }
    try {
      // The server builds the agent per user (voice, the opening line by
      // their gender, the delegated model). The delegated model gets the
      // same context and every tool the other live transports get.
      final created = await _create({
        'transport': {'type': 'webrtc', 'sdp': sdp},
        'voice': setup.voice,
        'instructions': setup.system,
        'tools': [
          for (final t in setup.tools)
            {'name': t.name, 'description': t.description, 'parameters': t.parameters},
        ],
      });
      final transport = created?['transport'];
      final answer = transport is Map ? '${transport['sdp'] ?? ''}' : '';
      if (answer.isEmpty) throw StateError('no GPT-Live session from the server');
      final sessionInfo = created?['session'];
      final id = sessionInfo is Map ? '${sessionInfo['id'] ?? ''}' : '';
      if (id.isEmpty) throw StateError('the GPT-Live session id is missing');
      final opening = created?['opening'];
      final openingInstruction = opening is Map ? '${opening['instruction'] ?? ''}' : '';
      AppLog.add('live',
          'gpt-live session created (server ${sw.elapsedMilliseconds} ms, voice ${created?['voice'] ?? '?'})');
      pc.onIceConnectionState = (st) {
        if (st == RTCIceConnectionState.RTCIceConnectionStateConnected) {
          AppLog.add('live', 'gpt-live: network connected ${sw.elapsedMilliseconds} ms after the offer');
        }
      };
      channel.onDataChannelState = (st) {
        if (st == RTCDataChannelState.RTCDataChannelOpen) {
          AppLog.add('live', 'gpt-live: channel open ${sw.elapsedMilliseconds} ms after the offer');
        }
        if (st == RTCDataChannelState.RTCDataChannelClosed && !incoming.isClosed) unawaited(incoming.close());
      };
      await pc.setRemoteDescription(RTCSessionDescription(answer, 'answer'));
      unawaited(Helper.setSpeakerphoneOn(true).catchError((Object _) {}));
      final peer = pc;
      final session = GptLiveSession(
        incoming.stream,
        (s) {
          if (channel.state != RTCDataChannelState.RTCDataChannelOpen) {
            AppLog.add('live', 'gpt-live: could not send an event; channel is not open');
            return;
          }
          unawaited(channel
              .send(RTCDataChannelMessage(s))
              .catchError((Object error) {
            AppLog.add('live', 'gpt-live: event send failed: ${error.runtimeType}');
          }));
        },
        () async {
          disposed = true;
          final stream = mic;
          for (final t in stream?.getTracks() ?? const <MediaStreamTrack>[]) {
            await t.stop();
          }
          await stream?.dispose();
          await channel.close();
          await peer.close();
          // The next call's phone side, ready before it is needed.
          prepare();
        },
        mic: (open) {
          micWanted = open;
          final t = track;
          if (t != null) {
            t.enabled = open;
          } else if (open) {
            openMic();
          }
          // LOUDSPEAKER ON EVERY OPEN (2026-10-04, "the volume has dropped"):
          // a session warmed in the background set it while the previous
          // call was still closing, and that close put Android back on the
          // earpiece — her voice came out of the phone's top speaker.
          if (open) unawaited(Helper.setSpeakerphoneOn(true).catchError((Object _) {}));
        },
        speaker: (on) {
          audible.on = on;
          for (final t in remote) {
            t.enabled = on;
          }
        },
        openingInstruction: openingInstruction,
      );
      await session.ready.timeout(const Duration(seconds: 12));
      AppLog.add('live', 'gpt-live: started ${sw.elapsedMilliseconds} ms after the offer');
      return session;
    } catch (_) {
      disposed = true;
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
    // An offer without a single candidate cannot connect at all. Slow
    // radios (some phones on mobile data) need longer for the first one:
    // wait for it, up to 5 s more, instead of failing every time there.
    if (!_hasCandidate((await pc.getLocalDescription())?.sdp)) {
      final until = DateTime.now().add(const Duration(seconds: 5));
      while (DateTime.now().isBefore(until) && !done.isCompleted) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        if (_hasCandidate((await pc.getLocalDescription())?.sdp)) break;
      }
      AppLog.add('live', 'gpt-live: waited for a first ICE candidate');
    }
  }

  static bool _hasCandidate(String? sdp) => sdp != null && sdp.contains('a=candidate:');
}

/// The phone's half of a GPT-Live call, before the server has answered.
class _Peer {
  _Peer(this.pc, this.sender, this.remote, this.channel, this.incoming, this.sdp, this.audible);
  static final none = _Peer(null, null, const [], null, null, '', _Audible());
  final RTCPeerConnection? pc;

  /// The audio slot the microphone goes into at connect.
  final RTCRtpSender? sender;
  final List<MediaStreamTrack> remote;
  final RTCDataChannel? channel;
  final StreamController<String>? incoming;
  final String sdp;
  final _Audible audible;

  Future<void> dispose() async {
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
    this.openingInstruction = '',
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

  /// The server's direction for the opening line ("Hello Sir" / "Hello
  /// Madam", by the user's gender). Empty: an older server; no greeting.
  final String openingInstruction;
  bool _greeted = false;

  /// Nothing she says is heard or shown before the conversation opens
  /// ([greetOpening] or the microphone opening): a warmed session waiting
  /// for the tap stays silent even if the model decides to speak.
  bool _audible = false;

  /// When the opening line was asked for (session clock), until her first
  /// words: how long GPT-Live takes to start speaking.
  int? _openingAskedMs;



  void _becomeAudible() {
    if (_audible) return;
    _audible = true;
    _speaker?.call(true);
  }

  late final _out = StreamController<LiveIn>(onListen: _flushBuffered);
  final List<LiveIn> _buffered = [];
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
  String? _activeDelegation;
  final Map<String, String> _responseForDelegation = {};
  final Map<String, _DelegationInvocation> _invocations = {};
  final Map<String, _InvocationRef> _invocationForCall = {};
  final Map<String, _SubmittedOutput> _clientEvents = {};
  final Map<String, int> _continuationRetries = {};

  @override
  Stream<LiveIn> get messages => _out.stream;

  Future<void> get ready => _ready.future;

  void _emit(LiveIn m) {
    if (_out.isClosed) return;
    if (!_out.hasListener) {
      _buffered.add(m);
    } else {
      _out.add(m);
    }
  }

  void _flushBuffered() {
    if (_out.isClosed) return;
    for (final message in _buffered) {
      _out.add(message);
    }
    _buffered.clear();
  }

  String _eventId() => 'live_${DateTime.now().microsecondsSinceEpoch}_${++_events}';

  void _event(Map<String, Object?> e) =>
      _send(jsonEncode({'event_id': _eventId(), ...e}));

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
        // No greeting here: a session can be up before anyone tapped the
        // orb. The engine asks for it with [greetOpening] when they did.
        _clock.start();
        if (!_ready.isCompleted) _ready.complete();
        _emit(const LiveInReady());
      case 'session.instructions.appended':
        final asked = _openingAskedMs;
        if (asked != null) {
          AppLog.add('live', 'gpt-live: opening acknowledged ${_clock.elapsedMilliseconds - asked} ms after the request');
        }
      case 'session.input_transcript.delta':
        // Nobody is heard before the conversation opens: a warmed session
        // has no microphone, yet GPT-Live once transcribed its silence
        // (2026-10-06), and that phantom turn made the tap skip the hello.
        if (!_audible) break;
        final heard = '${e['delta'] ?? ''}';
        // They spoke after a stop: her voice is theirs to hear again.
        if (_muted) {
          _muted = false;
          _speaker?.call(true);
        }
        if (heard.isNotEmpty) {
          _emit(LiveInContent(
            heard: heard,
            startMs: _eventMillis(e['start_ms']),
            endMs: _eventMillis(e['end_ms']),
          ));
        }
      case 'session.output_transcript.delta':
        final said = '${e['delta'] ?? ''}';
        if (said.isEmpty || !_audible) break;
        final asked = _openingAskedMs;
        if (asked != null) {
          _openingAskedMs = null;
          AppLog.add('live', 'gpt-live: first words ${_clock.elapsedMilliseconds - asked} ms after the opening request');
        }
        _speaking = true;
        _emit(LiveInContent(
          said: said,
          startMs: _eventMillis(e['start_ms']),
          endMs: _eventMillis(e['end_ms']),
        ));
        _armTurnEnd(e['end_ms']);
      case 'session.delegation.created' || 'response.event' when !_audible:
        // Nothing was asked before the conversation opened: no tool runs
        // for a request nobody made.
        AppLog.add('live', 'gpt-live: ignored backend work before the conversation opened');
      case 'session.delegation.created':
        final delegation = e['delegation'];
        _activeDelegation = delegation is Map
            ? '${delegation['id'] ?? ''}'
            : '${e['delegation_id'] ?? ''}';
        if (_activeDelegation!.isEmpty) _activeDelegation = null;
        _work(null);
      case 'response.event':
        _onBackend(e['event'], '${e['delegation_id'] ?? _activeDelegation ?? ''}');
      case 'session.usage.updated':
        final u = e['usage'];
        if (u is Map) AppLog.add('live', 'gpt-live: ${u['seconds']} s so far');
      case 'error':
        final err = e['error'];
        final msg = err is Map ? '${err['message'] ?? err['code'] ?? err}' : '$err';
        AppLog.add('live', 'gpt-live: $msg');
        _handleClientError(err);
        if (_pending && !_hasOpenInvocation) _done();
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
  /// are the app's to run. The outer delegation id is part of the routing
  /// context; response.output is not used because it is intentionally empty.
  void _onBackend(Object? inner, String delegationId) {
    if (inner is! Map) return;
    final type = '${inner['type'] ?? ''}';
    final added = inner['item'] is Map ? inner['item'] as Map : const {};
    final response = inner['response'] is Map ? inner['response'] as Map : const {};
    final responseId = '${response['id'] ?? inner['response_id'] ?? ''}';
    if (type == 'response.created') {
      final id = responseId.isNotEmpty ? responseId : '${inner['id'] ?? ''}';
      if (delegationId.isNotEmpty && id.isNotEmpty) {
        _responseForDelegation[delegationId] = id;
        _invocations.putIfAbsent(_invocationKey(delegationId, id), _DelegationInvocation.new);
      }
      _work(null);
    }
    if (_pending) _armStall();
    if (type == 'response.output_item.added' && added['type'] == 'web_search_call') _work('web_search');
    if (type == 'response.completed') {
      // What this backend call cost: cached input is billed at a tenth.
      final usage = response['usage'];
      if (usage is Map) {
        final details = usage['input_tokens_details'];
        final cached = details is Map ? details['cached_tokens'] : null;
        AppLog.add('live',
            'gpt-live backend tokens: in ${usage['input_tokens']} (cached ${cached ?? 0}), out ${usage['output_tokens']}');
      }
      final id = responseId.isNotEmpty
          ? responseId
          : _responseForDelegation[delegationId] ?? '';
      final key = _invocationKey(delegationId, id);
      final invocation = _invocations.remove(key);
      if (invocation != null && invocation.calls.isNotEmpty) {
        for (final call in invocation.calls) {
          final callId = call.id ?? '';
          if (callId.isNotEmpty) {
            _invocationForCall[callId] = _InvocationRef(delegationId, id);
          }
        }
        _emit(LiveInToolCall(
          List<FunctionCall>.unmodifiable(invocation.calls),
          delegationId: delegationId,
        ));
      } else if (!_hasOpenInvocation) {
        _done();
      }
      return;
    }
    if (type == 'response.failed' || type == 'response.incomplete') {
      AppLog.add('live', 'gpt-live backend: $type');
      final id = responseId.isNotEmpty
          ? responseId
          : _responseForDelegation[delegationId] ?? '';
      _invocations.remove(_invocationKey(delegationId, id));
      if (!_hasOpenInvocation) _done();
      return;
    }
    if (type != 'response.output_item.done') return;
    final item = inner['item'] is Map ? inner['item'] as Map : inner;
    final name = '${item['name'] ?? ''}';
    final callId = '${item['call_id'] ?? ''}';
    if (name.isEmpty || callId.isEmpty || item['type'] != 'function_call') return;
    final id = responseId.isNotEmpty
        ? responseId
        : _responseForDelegation[delegationId] ?? '';
    if (delegationId.isEmpty || id.isEmpty) {
      AppLog.add('live', 'gpt-live: function call had no delegation/response id');
      return;
    }
    Map<String, Object?> args;
    try {
      final parsed = jsonDecode('${item['arguments'] ?? '{}'}');
      if (parsed is! Map) throw const FormatException('arguments must be an object');
      args = parsed.cast<String, Object?>();
    } catch (_) {
      AppLog.add('live', 'gpt-live: discarded malformed function arguments');
      return;
    }
    final invocation = _invocations.putIfAbsent(
      _invocationKey(delegationId, id),
      _DelegationInvocation.new,
    );
    if (invocation.calls.any((call) => call.id == callId)) return;
    _turnEnd?.cancel();
    invocation.calls.add(FunctionCall(name, args, id: callId));
  }

  String _invocationKey(String delegationId, String responseId) =>
      '$delegationId\u0000$responseId';

  bool get _hasOpenInvocation => _invocations.values.any((b) => b.calls.isNotEmpty);

  int? _eventMillis(Object? value) =>
      value is num && value >= 0 ? value.toInt() : null;

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
    if (open) _becomeAudible();
    // Audio keeps flowing (silence while closed), as the guide asks;
    // session.input_audio.mute left GPT-Live ignoring later requests.
    _mic?.call(open);
  }

  /// THE OPENING LINE, IN THE SESSION'S OWN VOICE. GPT-Live has no greeting
  /// field: the guide's way is a system-level `session.instructions.append`
  /// after `session.started`. Once per session; false when the server gave
  /// no line or it was already said.
  bool greetOpening() {
    if (_greeted || openingInstruction.isEmpty || _closing || _disposed) return false;
    _greeted = true;
    _becomeAudible();
    _openingAskedMs = _clock.elapsedMilliseconds;
    AppLog.add('live', 'gpt-live: opening requested');
    _event({
      'type': 'session.instructions.append',
      'delegation_id': null,
      'content': openingInstruction,
    });
    return true;
  }

  /// Silent context for her (`session.thinking.append`): known, not said.
  void sendThinking(String text) {
    final t = text.length > 1800 ? text.substring(0, 1800) : text;
    _event({'type': 'session.thinking.append', 'delegation_id': null, 'content': t});
  }

  /// A nudge or a typed line: context for her, at most 500 tokens.
  @override
  void sendText(String text) {
    final t = text.length > 1800 ? text.substring(0, 1800) : text;
    _event({'type': 'session.commentary.append', 'delegation_id': null, 'content': t});
  }

  @override
  void sendToolResponses(List<FunctionResponse> responses) {
    final batches = <String, _OutputBatch>{};
    for (final response in responses) {
      final callId = response.id ?? '';
      final invocation = _invocationForCall[callId];
      if (callId.isEmpty || invocation == null || invocation.delegationId.isEmpty) {
        AppLog.add('live', 'gpt-live: dropped an uncorrelated tool result');
        continue;
      }
      final outputKey = '${invocation.key}\u0000$callId';
      if (_submittedOutputs.contains(outputKey)) continue;
      final item = <String, Object?>{
        'type': 'function_call_output',
        'call_id': callId,
        'output': _boundedOutput(response.response),
      };
      batches.putIfAbsent(
        invocation.key,
        () => _OutputBatch(invocation),
      ).items.add(item);
    }

    for (final entry in batches.entries) {
      final batch = entry.value;
      // No session-wide budget (2026-10-06): one used to drop every result
      // past 32 KB, so a long conversation's later tools never answered.
      // Each result is bounded instead (_boundedOutput).
      for (final item in batch.items) {
        final callId = '${item['call_id']}';
        final outputKey = '${batch.invocation.key}\u0000$callId';
        _submittedOutputs.add(outputKey);
        _sendOutput(batch.invocation, item);
      }
      _sendContinuation(batch.invocation);
    }
  }

  /// A tool's result for the backend, at most [_maxOutputChars]. Every later
  /// delegated call in the session re-reads it, so a long search result or
  /// list costs its tokens again and again; the voice needs a summary.
  static String _boundedOutput(Map<String, Object?> result) {
    final s = jsonEncode(result);
    if (s.length <= _maxOutputChars) return s;
    return jsonEncode({
      'truncated': true,
      'result': s.substring(0, _maxOutputChars),
    });
  }

  final Set<String> _submittedOutputs = {};
  final Map<String, int> _outputRetries = {};

  void _sendOutput(_InvocationRef invocation, Map<String, Object?> item) {
    final id = _eventId();
    // NO delegation_id HERE (2026-10-06, production): GPT-Live rejects it on
    // response.item.create ("Unknown parameter: 'delegation_id'"), the result
    // never arrives, the continuation is refused ("Submit the pending tool
    // results…"), and she says "one moment" and never answers. The result
    // is matched to its call by call_id alone.
    final envelope = <String, Object?>{
      'event_id': id,
      'type': 'response.item.create',
      'item': item,
    };
    _clientEvents[id] = _SubmittedOutput.item(invocation, item);
    _send(jsonEncode(envelope));
  }

  void _sendContinuation(_InvocationRef invocation) {
    final id = _eventId();
    _clientEvents[id] = _SubmittedOutput.continuation(invocation);
    _send(jsonEncode({'event_id': id, 'type': 'response.create'}));
  }

  void _handleClientError(Object? error) {
    if (error is! Map) return;
    final eventId = '${error['client_event_id'] ?? ''}';
    if (eventId.isEmpty) return;
    final failed = _clientEvents.remove(eventId);
    if (failed == null) return;
    final message = '${error['message'] ?? error['code'] ?? 'request rejected'}';
    if (failed.isItem) {
      AppLog.add('live', 'gpt-live: result item rejected: $message');
      final key = '${failed.invocation.key}\u0000${failed.item!['call_id']}';
      final attempts = _outputRetries[key] ?? 0;
      if (attempts == 0) {
        _outputRetries[key] = 1;
        _sendOutput(failed.invocation, failed.item!);
      }
      return;
    }
    AppLog.add('live', 'gpt-live: continuation rejected: $message');
    final retries = _continuationRetries[failed.invocation.key] ?? 0;
    if (retries == 0) {
      _continuationRetries[failed.invocation.key] = 1;
      _sendContinuation(failed.invocation);
    }
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

/// Whether her remote audio track may play (shared with onTrack).
class _Audible {
  bool on = false;
}

class _DelegationInvocation {
  final List<FunctionCall> calls = [];
}

class _InvocationRef {
  const _InvocationRef(this.delegationId, this.responseId);

  final String delegationId;
  final String responseId;
  String get key => '$delegationId\u0000$responseId';
}

class _OutputBatch {
  _OutputBatch(this.invocation);

  final _InvocationRef invocation;
  final List<Map<String, Object?>> items = [];
}

class _SubmittedOutput {
  const _SubmittedOutput._(this.invocation, this.item);

  const _SubmittedOutput.item(
    _InvocationRef invocation,
    Map<String, Object?> item,
  ) : this._(invocation, item);

  const _SubmittedOutput.continuation(_InvocationRef invocation)
      : this._(invocation, null);

  final _InvocationRef invocation;
  final Map<String, Object?>? item;
  bool get isItem => item != null;
}

const _maxOutputChars = 4000;
