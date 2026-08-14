import 'dart:async';
import 'dart:convert';
import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../../core/log.dart';
import '../../../services/api_service.dart';
import '../../../services/voice_service.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  LIVE SESSION — the ONE canonical assistant session (Rebuild §7, §8).
///
///  There is exactly one live-video pipeline in this app: the backend
///  mints a Tavus CVI conversation (POST /avatar/session — personalised
///  with the user's assistant profile, standing rules and memories) and
///  this controller embeds the returned WebRTC room. Tavus runs the whole
///  loop: hears the user, reasons, speaks with lip-sync, and supports
///  natural barge-in. The greeting is spoken by the avatar itself via
///  `custom_greeting`, which Tavus delivers only after the participant
///  has actually joined — so a greeting while disconnected is
///  structurally impossible (§10).
///
///  STATE IS REAL (§9): `ready` is not "the page loaded". A JavaScript
///  probe injected into the room watches for an actually *playing* remote
///  video element (frames decoded, non-zero dimensions) and only then
///  reports READY over the LiveBridge channel. Until that happens the UI
///  shows connecting — never a greeting, never a LIVE badge.
/// ─────────────────────────────────────────────────────────────────────────

/// Explicit connection state machine (§9). No state is ever inferred from
/// "a widget rendered" or "an object exists".
enum LiveSessionState {
  /// Checking permissions + server availability.
  initializing,

  /// Session minted, room loading / WebRTC negotiating.
  connecting,

  /// Room page is up but the avatar's video is not yet playing.
  connected,

  /// The avatar's video stream is genuinely playing. LIVE.
  ready,

  /// Recoverable failure — shown honestly, with retry.
  error,

  /// Device appears to have no route to the server.
  offline,

  /// User ended the call (or the room closed).
  ended,
}

class LiveSessionController extends ChangeNotifier {
  LiveSessionState _state = LiveSessionState.initializing;
  LiveSessionState get state => _state;

  WebViewController? _web;
  WebViewController? get web => _web;

  /// The configured assistant name from the backend ("Maya", "Hari"…).
  String assistantName = '';

  /// Honest, user-facing description of the current failure. Only set in
  /// [LiveSessionState.error] / [LiveSessionState.offline].
  String errorMessage = '';

  /// Speaker (remote audio) toggle. Muting is done inside the room page,
  /// so it genuinely silences the avatar rather than pretending to.
  bool speakerOn = true;

  Timer? _readyTimeout;
  bool _disposed = false;

  /// How long we wait for actual playing video after the room loads
  /// before declaring the connection failed instead of spinning forever.
  static const _readyDeadline = Duration(seconds: 45);

  void _set(LiveSessionState s) {
    if (_disposed || _state == s) return;
    _state = s;
    AppLog.add('live', 'state -> ${s.name}');
    notifyListeners();
  }

  /// Starts (or restarts) the one live session.
  Future<void> start() async {
    errorMessage = '';
    _readyTimeout?.cancel();
    _set(LiveSessionState.initializing);

    // One voice at a time: the avatar speaks, local TTS must be silent.
    VoiceService.instance.stopSpeaking();

    // 1. Microphone is required for a live conversation; camera optional.
    final mic = await Permission.microphone.request();
    await Permission.camera.request();
    if (!mic.isGranted) {
      errorMessage = 'Your assistant needs the microphone to hear you. '
          'Allow microphone access and try again.';
      _set(LiveSessionState.error);
      return;
    }

    // 2. Is the avatar service reachable and configured? A failed probe is
    //    reported as OFFLINE — the app must never fake readiness (§10).
    try {
      final r = await http
          .get(Uri.parse('${ApiService.baseUrl}/avatar/status'),
              headers: ApiService.authHeaders)
          .timeout(const Duration(seconds: 8));
      if (r.statusCode != 200 ||
          (jsonDecode(r.body) as Map)['enabled'] != true) {
        errorMessage =
            'Live video isn\u2019t set up on the server yet. You can still '
            'talk to your assistant in voice mode.';
        _set(LiveSessionState.error);
        return;
      }
    } catch (e) {
      AppLog.add('live', 'status probe failed: $e');
      errorMessage = 'Can\u2019t reach the server. Check your connection.';
      _set(LiveSessionState.offline);
      return;
    }

    // 3. Mint the personalised conversation.
    _set(LiveSessionState.connecting);
    String url;
    try {
      final r = await http
          .post(Uri.parse('${ApiService.baseUrl}/avatar/session'),
              headers: {
                ...ApiService.authHeaders,
                'Content-Type': 'application/json',
              },
              // Device-local hour so the spoken greeting says the right
              // "Good morning/afternoon/evening" (§15).
              body: jsonEncode({'localHour': DateTime.now().hour}))
          .timeout(const Duration(seconds: 25));
      if (r.statusCode != 200) {
        AppLog.add('live', 'session HTTP ${r.statusCode}: ${r.body}');
        final detail = _detailOf(r.body);
        errorMessage = r.statusCode == 503
            ? 'Live video isn\u2019t set up on the server yet.'
            : 'Couldn\u2019t start the live session'
                '${detail.isEmpty ? '.' : ' ($detail).'}';
        _set(LiveSessionState.error);
        return;
      }
      final j = jsonDecode(r.body) as Map;
      url = j['url'] as String;
      assistantName = (j['assistantName'] as String?)?.trim() ?? '';
    } catch (e) {
      AppLog.add('live', 'session mint failed: $e');
      errorMessage = 'Couldn\u2019t start the live session. '
          'Check your connection and try again.';
      _set(LiveSessionState.offline);
      return;
    }

    // 4. Join the room. `onPageFinished` means CONNECTED, not READY —
    //    READY comes only from the LiveBridge probe seeing real video.
    AppLog.add('live', 'joining room');
    final c = WebViewController(
      onPermissionRequest: (request) => request.grant(),
    )
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color.fromARGB(255, 6, 8, 14))
      ..addJavaScriptChannel('LiveBridge', onMessageReceived: _onBridge)
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (_) {
          if (_state == LiveSessionState.connecting) {
            _set(LiveSessionState.connected);
          }
          _injectProbe();
          _armReadyTimeout();
        },
        onWebResourceError: (e) {
          if (e.isForMainFrame == true) {
            errorMessage =
                'Couldn\u2019t join the call. Check your connection.';
            _set(LiveSessionState.error);
          }
        },
      ));
    await c.loadRequest(Uri.parse(url));
    if (_disposed) return;
    _web = c;
    notifyListeners();
  }

  static String _detailOf(String body) {
    try {
      return ((jsonDecode(body) as Map)['detail'] as String?) ?? '';
    } catch (_) {
      return '';
    }
  }

  /// READY watchdog — if no real video ever plays, say so instead of
  /// spinning forever behind a loading indicator.
  void _armReadyTimeout() {
    _readyTimeout?.cancel();
    _readyTimeout = Timer(_readyDeadline, () {
      if (_state == LiveSessionState.connected ||
          _state == LiveSessionState.connecting) {
        errorMessage =
            'Connected, but the live video never arrived. This is usually '
            'a network or provider issue \u2014 try again.';
        _set(LiveSessionState.error);
      }
    });
  }

  /// Injected into the room: reports READY only when a remote <video>
  /// element is actually decoding frames, and LEFT when the room's media
  /// disappears after having played. This is the honest readiness signal
  /// (§9) — the DOM cannot lie about a playing video the way a spinner can.
  void _injectProbe() {
    _web?.runJavaScript('''
      (function () {
        if (window.__liveProbe) return;
        window.__liveProbe = true;
        var wasReady = false;
        function playing() {
          var vs = document.querySelectorAll('video');
          for (var i = 0; i < vs.length; i++) {
            var v = vs[i];
            if (v.readyState >= 2 && v.videoWidth > 0 && !v.paused) return true;
          }
          return false;
        }
        setInterval(function () {
          try {
            if (playing()) {
              if (!wasReady) { wasReady = true; LiveBridge.postMessage('ready'); }
            } else if (wasReady) {
              wasReady = false; LiveBridge.postMessage('stalled');
            }
          } catch (e) {}
        }, 500);
      })();
    ''');
  }

  void _onBridge(JavaScriptMessage m) {
    AppLog.add('live', 'bridge: ${m.message}');
    switch (m.message) {
      case 'ready':
        _readyTimeout?.cancel();
        _set(LiveSessionState.ready);
      case 'stalled':
        // Video stopped after playing — likely reconnecting. Fall back to
        // connected and re-arm the watchdog; never keep claiming LIVE.
        if (_state == LiveSessionState.ready) {
          _set(LiveSessionState.connected);
          _armReadyTimeout();
        }
    }
  }

  /// Genuinely mutes/unmutes the avatar's audio inside the room.
  Future<void> toggleSpeaker() async {
    speakerOn = !speakerOn;
    notifyListeners();
    await _web?.runJavaScript('''
      document.querySelectorAll('audio,video').forEach(function (el) {
        el.muted = ${speakerOn ? 'false' : 'true'};
      });
    ''');
  }

  /// Ends the call: unloads the room so mic + WebRTC are released.
  Future<void> end() async {
    _readyTimeout?.cancel();
    try {
      await _web?.loadRequest(Uri.parse('about:blank'));
    } catch (_) {}
    _set(LiveSessionState.ended);
  }

  @override
  void dispose() {
    _disposed = true;
    _readyTimeout?.cancel();
    super.dispose();
  }
}
