import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../services/api_service.dart';
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

  String? get sessionId => _sessionId;

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (ApiService.sessionToken != null)
          'Authorization': 'Bearer ${ApiService.sessionToken}',
      };

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
      throw Exception('assistant session failed (${r.statusCode})');
    }
    AppLog.add('sse', 'session ok');
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    _sessionId = j['sessionId'] as String;
    _streamToken = j['streamToken'] as String;
    _openStream(onEvent, onDisconnect);
  }

  void _openStream(
    void Function(Map<String, dynamic>) onEvent,
    void Function()? onDisconnect,
  ) async {
    if (_closed || _sessionId == null) return;
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
      final res = await client.send(req);
      if (res.statusCode != 200) {
        AppLog.add('sse', 'stream HTTP ${res.statusCode}');
        throw Exception('stream ${res.statusCode}');
      }
      AppLog.add('sse', 'stream connected');
      _onConnected?.call();

      String? pendingData;
      _sseSub = res.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
        (line) {
          if (line.startsWith('id:')) {
            _lastEventId =
                int.tryParse(line.substring(3).trim()) ?? _lastEventId;
          } else if (line.startsWith('data:')) {
            pendingData = line.substring(5).trim();
          } else if (line.isEmpty && pendingData != null) {
            try {
              final e = jsonDecode(pendingData!) as Map<String, dynamic>;
              onEvent(e);
            } catch (_) {}
            pendingData = null;
          }
        },
        onDone: () => _reconnect(onEvent, onDisconnect),
        onError: (_) => _reconnect(onEvent, onDisconnect),
        cancelOnError: true,
      );
    } catch (_) {
      _reconnect(onEvent, onDisconnect);
    }
  }

  void _reconnect(
    void Function(Map<String, dynamic>) onEvent,
    void Function()? onDisconnect,
  ) {
    if (_closed) return;
    AppLog.add('sse', 'stream dropped — reconnecting in 2s');
    onDisconnect?.call();
    Future.delayed(const Duration(seconds: 2), () {
      _openStream(onEvent, onDisconnect);
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
    if (ApiService.sessionToken != null) {
      req.headers['Authorization'] = 'Bearer ${ApiService.sessionToken}';
    }
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

  Future<void> cancel() => _post('cancel');

  void close() {
    _closed = true;
    _sseSub?.cancel();
    _sseClient?.close();
    _sessionId = null;
  }
}
