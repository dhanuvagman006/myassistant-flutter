import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../services/api_service.dart';
import '../../services/device_capabilities.dart';
import '../log.dart';

/// Thin client for the backend's /assistant module.
///
/// One session per app launch. Events (states, transcripts, search results,
/// call updates…) arrive over a single Server-Sent-Events stream; commands
/// go out as small POSTs. All provider keys stay server-side — this client
/// only ever carries the user's own JWT.
class AssistantApi {
  AssistantApi._();
  static final AssistantApi instance = AssistantApi._();

  String? _sessionId;
  String? _streamToken;
  http.Client? _sseClient;
  StreamSubscription<String>? _sseSub;
  int _lastEventId = 0;
  bool _closed = false;

  /// Bumped by every connect() and close(). A reconnect scheduled before
  /// either one belongs to a connection that no longer exists: without this
  /// check, close() then connect() let the OLD delayed retry fire into the
  /// new session and open a second, competing stream.
  int _gen = 0;

  /// The server writes ": hb" every 20 s. A stream silent for longer than
  /// this is dead even if the socket never said so — a Wi-Fi → mobile
  /// handover leaves exactly that: "connected", and every turn then dying
  /// at the 35 s watchdog.
  static const _idleLimit = Duration(seconds: 50);
  Timer? _idle;

  String? get sessionId => _sessionId;

  // The classic path used to send auth alone — no timezone (every user
  // stamped IST), no location, and no X-App-Key fallback (dev-key builds
  // 401'd on the session while every other screen worked).
  Map<String, String> get _headers => ApiService.authHeaders;

  /// Fires every time the stream is (re)established — the UI's "connected"
  /// flag follows THIS, not just the first connect. Without it, any stream
  /// blip (a server restart) left the header saying "Connecting" forever
  /// even though the auto-reconnect had long since succeeded.
  void Function()? _onConnected;

  /// Creates a session and opens the event stream. [onEvent] receives every
  /// decoded JSON event; [onDisconnect] fires when the stream drops (the
  /// client auto-reconnects with Last-Event-ID so nothing is missed) and
  /// [onConnected] fires on every successful (re)connect.
  Future<void> connect({
    required void Function(Map<String, dynamic> event) onEvent,
    void Function()? onDisconnect,
    void Function()? onConnected,
  }) async {
    _onConnected = onConnected;
    _closed = false;
    _gen++;
    AppLog.add('sse', 'POST ${ApiService.baseUrl}/assistant/session');
    final http.Response r;
    try {
      r = await http
          .post(Uri.parse('${ApiService.baseUrl}/assistant/session'),
              headers: _headers)
          .timeout(const Duration(seconds: 12));
    } catch (e) {
      AppLog.add('sse', 'session FAILED: $e');
      rethrow;
    }
    if (r.statusCode != 200) {
      AppLog.add('sse', 'session HTTP ${r.statusCode}: '
          '${r.body.length > 120 ? r.body.substring(0, 120) : r.body}');
      // A rejected sign-in is not a network blip: without this the loop
      // retried a revoked token every minute, forever, behind a "Connecting"
      // screen. AuthService re-verifies and signs out, which closes us.
      ApiService.noteAuthStatus(r.statusCode);
      throw Exception('assistant session failed (${r.statusCode})');
    }
    AppLog.add('sse', 'session ok');
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    _sessionId = j['sessionId'] as String;
    _streamToken = j['streamToken'] as String;
    _lastEventId = 0; // a fresh session has no replayable history
    _failStreak = 0;
    _openStream(onEvent, onDisconnect);
    // WHAT THIS PHONE CAN DO, once per session and never blocking it. The
    // server otherwise knows only the build number and will happily offer
    // a capability whose permission the user revoked months ago.
    DeviceCapabilities.report(reportCapabilities);
  }

  void _openStream(
    void Function(Map<String, dynamic>) onEvent,
    void Function()? onDisconnect,
  ) async {
    if (_closed || _sessionId == null) return;
    final gen = _gen;
    _idle?.cancel();
    _sseClient?.close();
    final client = http.Client();
    _sseClient = client;
    try {
      final req = http.Request(
        'GET',
        Uri.parse(
          '${ApiService.baseUrl}/assistant/stream/$_sessionId?token=$_streamToken',
        ),
      );
      req.headers['Accept'] = 'text/event-stream';
      if (_lastEventId > 0) req.headers['Last-Event-ID'] = '$_lastEventId';
      // Bounded: on a half-open connection send() never returns at all.
      final res = await client.send(req).timeout(const Duration(seconds: 15));
      if (gen != _gen) {
        client.close(); // closed or replaced while we waited
        return;
      }
      if (res.statusCode != 200) {
        AppLog.add('sse', 'stream HTTP ${res.statusCode}');
        // A restarted/redeployed server no longer knows this session — the
        // old token would 401 on every retry FOREVER, which the user sees
        // as a permanent "Connecting". Drop the dead session so the
        // reconnect below performs the full handshake instead.
        if (res.statusCode == 401 || res.statusCode == 404) {
          _sessionId = null;
          _streamToken = null;
          _lastEventId = 0;
        }
        throw Exception('stream ${res.statusCode}');
      }
      AppLog.add('sse', 'stream connected');
      _failStreak = 0; // healthy again — next drop starts the backoff over
      _onConnected?.call();

      void armIdle() {
        _idle?.cancel();
        _idle = Timer(_idleLimit, () {
          if (gen != _gen || _closed) return;
          AppLog.add('sse', 'stream silent ${_idleLimit.inSeconds}s — reconnecting');
          _sseSub?.cancel();
          client.close();
          _reconnect(onEvent, onDisconnect);
        });
      }

      armIdle();
      final parser = SseParser(onEvent);
      _sseSub = res.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
        (line) {
          armIdle(); // any line — an event or the ": hb" — proves it lives
          final id = parser.line(line);
          if (id != null) _lastEventId = id;
        },
        onDone: () {
          _idle?.cancel();
          if (gen == _gen) _reconnect(onEvent, onDisconnect);
        },
        onError: (_) {
          _idle?.cancel();
          if (gen == _gen) _reconnect(onEvent, onDisconnect);
        },
        cancelOnError: true,
      );
    } catch (_) {
      if (gen == _gen) _reconnect(onEvent, onDisconnect);
    }
  }

  /// Consecutive failed attempts since the last healthy stream. Drives
  /// the backoff, and after a few misses forces a FULL handshake — a
  /// server that answers 500 (or a connection that dies before any HTTP
  /// status) used to retry a dead session id every 2 s forever, which
  /// your phone logs showed as a 30-attempts-per-minute battery drain.
  int _failStreak = 0;

  void _reconnect(
    void Function(Map<String, dynamic>) onEvent,
    void Function()? onDisconnect,
  ) {
    if (_closed) return;
    _failStreak++;
    final delay = Duration(
        seconds: (2 << (_failStreak - 1).clamp(0, 5)).clamp(2, 60));
    if (_failStreak >= 3) {
      // Whatever we think we know about this session, three straight
      // misses say otherwise — rebuild from scratch on the next attempt.
      _sessionId = null;
      _streamToken = null;
      _lastEventId = 0;
    }
    AppLog.add('sse',
        'stream dropped — retry $_failStreak in ${delay.inSeconds}s');
    onDisconnect?.call();
    final gen = _gen;
    Future.delayed(delay, () {
      if (_closed || gen != _gen) return;
      if (_sessionId == null) {
        connect(
          onEvent: onEvent,
          onDisconnect: onDisconnect,
          onConnected: _onConnected,
        ).catchError((_) => _reconnect(onEvent, onDisconnect));
      } else {
        _openStream(onEvent, onDisconnect);
      }
    });
  }

  Future<void> _post(String path, [Map<String, dynamic>? body]) async {
    final sid = _sessionId;
    if (sid == null) throw Exception('no assistant session');
    final r = await http
        .post(
          Uri.parse('${ApiService.baseUrl}/assistant/$sid/$path'),
          headers: _headers,
          body: jsonEncode(body ?? const {}),
        )
        .timeout(const Duration(seconds: 12));
    if (r.statusCode >= 300) {
      AppLog.add('sse', 'POST /assistant/$path HTTP ${r.statusCode}');
      ApiService.noteAuthStatus(r.statusCode);
      throw Exception('assistant/$path failed (${r.statusCode})');
    }
  }

  Future<void> sendText(String text) => _post('message', {'text': text});

  /// Uploads a recorded clip; transcription + the whole turn run
  /// server-side and stream back as events.
  ///
  /// [auto] marks a clip from a SELF-reopened mic (continuous loop). The
  /// server then treats an empty transcript as a normal quiet moment
  /// instead of scolding "I couldn't hear that clearly".
  Future<void> sendAudio(List<int> bytes,
      {String filename = 'turn.m4a', bool auto = false}) async {
    final sid = _sessionId;
    if (sid == null) throw Exception('no assistant session');
    final req = http.MultipartRequest(
      'POST',
      Uri.parse('${ApiService.baseUrl}/assistant/$sid/audio'),
    );
    // The same context every JSON post carries (auth, timezone, place,
    // build, battery). This upload is the main voice path and it sent the
    // bearer token alone, so the server could not tell the time or place
    // of a spoken turn. Content-Type is dropped: multipart sets its own.
    req.headers.addAll(
        Map.of(ApiService.authHeaders)..remove('Content-Type'));
    if (auto) req.fields['auto'] = 'true';
    req.files.add(http.MultipartFile.fromBytes('audio', bytes,
        filename: filename));
    final res = await req.send().timeout(const Duration(seconds: 30));
    if (res.statusCode >= 300) {
      throw Exception('assistant audio failed (${res.statusCode})');
    }
  }

  Future<void> sendContactMatches(List<Map<String, dynamic>> matches) =>
      _post('contacts', {'matches': matches});

  Future<void> chooseContact(String contactId) =>
      _post('choose', {'contactId': contactId});

  Future<void> confirm(bool approved) => _post('confirm', {'approved': approved});

  /// The phone reporting what REALLY happened after it was asked to dial.
  Future<void> callResult({
    required int outcomeId,
    required String status,
    String reason = '',
    String contactName = '',
  }) =>
      _post('call_result', {
        'outcome_id': outcomeId,
        'status': status,
        if (reason.isNotEmpty) 'reason': reason,
        if (contactName.isNotEmpty) 'contact_name': contactName,
      });

  /// The phone reporting that a DEVICE ACTION did not happen.
  ///
  /// Only calls used to report back. Everything else the phone was asked
  /// to do — open an app, open a link, start navigation, play music, set
  /// an alarm, toggle a control — was recorded as succeeding the moment
  /// the server dispatched it, and stayed that way. If the app was not
  /// installed or the deep link went nowhere, the user watched it fail
  /// and the record said it worked.
  Future<void> deviceResult({
    required String tool,
    required bool ok,
    String target = '',
    String reason = '',
  }) =>
      _post('device_result', {
        'tool': tool,
        'ok': ok,
        if (target.isNotEmpty) 'target': target,
        if (reason.isNotEmpty) 'reason': reason,
      });

  /// What this install can actually DO: its build and which Android
  /// permissions the user has granted. Posted once per session so the
  /// server stops offering capabilities this phone will silently drop.
  Future<void> reportCapabilities(Map<String, dynamic> caps) =>
      _post('capabilities', caps);

  Future<void> cancel() => _post('cancel');

  void close() {
    _lastEventId = 0;
    _failStreak = 0;
    _closed = true;
    _gen++;
    _idle?.cancel();
    _sseSub?.cancel();
    _sseClient?.close();
    _sessionId = null;
  }
}

/// Server-Sent Events, one line at a time (WHATWG rules, the subset the
/// server uses). Kept apart from the socket so it can be tested.
///
/// A multi-line `data:` field is joined with newlines — the old parser kept
/// only the LAST line, so any event whose JSON contained a raw newline was
/// dropped as undecodable. One optional space after the colon is part of
/// the syntax, not the value; comment lines (": hb") are ignored.
class SseParser {
  SseParser(this.onEvent);
  final void Function(Map<String, dynamic> event) onEvent;
  final List<String> _data = [];

  /// Feeds one line. Returns the event id when the line carried one.
  int? line(String line) {
    if (line.isEmpty) {
      if (_data.isNotEmpty) {
        final payload = _data.join('\n');
        _data.clear();
        try {
          final e = jsonDecode(payload);
          if (e is Map<String, dynamic>) onEvent(e);
        } catch (_) {}
      }
      return null;
    }
    if (line.startsWith(':')) return null;
    final colon = line.indexOf(':');
    final field = colon < 0 ? line : line.substring(0, colon);
    var value = colon < 0 ? '' : line.substring(colon + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    if (field == 'data') _data.add(value);
    if (field == 'id') return int.tryParse(value.trim());
    return null;
  }
}
