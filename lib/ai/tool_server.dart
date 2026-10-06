// TOOL SERVER — the backend's /ai/* routes. No model runs there: the
// server builds the context a turn needs, executes every tool that touches
// server data, other people, money, memory or the audit ledger, records the
// finished turn, and mints the Firebase identity AI Logic requires.
//
//   POST /ai/context        -> system instruction, tools, history
//   POST /ai/tool           -> one tool call, through registry.execute
//   POST /ai/turn           -> the turn recorded; the reply claim-checked
//   POST /ai/firebase-token -> a custom token for FirebaseAuth
//   GET  /ai/config         -> models, voice, routing words (config.dart)
import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:http/http.dart' as http;

import '../services/api_service.dart';
import 'types.dart';

/// What /ai/context returns for one turn.
class AiContext {
  const AiContext({
    this.sessionId,
    this.turnId,
    this.shortcut,
    this.system = '',
    this.tools = const [],
    this.history = const [],
    this.fromServer = true,
  });

  final String? sessionId;
  final String? turnId;

  /// The shortcut the server matched on the whole text (route.shortcut).
  final String? shortcut;

  /// The full cloud system instruction.
  final String system;

  /// Tools offered this turn (relevance-filtered, availability-gated).
  final List<AiToolSpec> tools;

  /// The last turns from the server's memory (<= 8).
  final List<ChatTurn> history;

  /// False for the stand-in used when the server could not be reached.
  final bool fromServer;

  factory AiContext.fromJson(Map<String, dynamic> j) {
    final route = j['route'];
    final shortcut = route is Map ? route['shortcut'] : null;
    return AiContext(
      sessionId: j['sessionId'] is String ? j['sessionId'] as String : null,
      turnId: j['turnId'] is String ? j['turnId'] as String : null,
      shortcut: shortcut is String && shortcut.trim().isNotEmpty ? shortcut : null,
      system: j['system'] is String ? j['system'] as String : '',
      tools: [
        if (j['tools'] is List)
          for (final t in j['tools'] as List)
            if (AiToolSpec.fromJson(t) case final spec?) spec,
      ],
      history: [
        if (j['history'] is List)
          for (final h in j['history'] as List)
            if (ChatTurn.fromJson(h) case final turn?) turn,
      ],
    );
  }
}

/// What /ai/tool returns for one call.
class AiToolResult {
  const AiToolResult({
    required this.ok,
    this.result = const {},
    this.speak,
    this.deviceAction,
    this.needsConfirmation = false,
    this.summary,
    this.approvalToken,
    this.error,
    this.status = 200,
  });

  final bool ok;

  /// What the model is handed as the function response.
  final Map<String, Object?> result;

  /// A line to say (a shortcut's reply).
  final String? speak;

  /// Something the PHONE must do (same shapes the app performs today).
  final Map<String, dynamic>? deviceAction;

  /// The action waits for the user's yes; retry with [approvalToken].
  final bool needsConfirmation;
  final String? summary;
  final String? approvalToken;
  final String? error;

  /// HTTP status (0 when the server was not reached).
  final int status;

  factory AiToolResult.fromJson(Map<String, dynamic> j, {int status = 200}) {
    final result = j['result'];
    final device = j['deviceAction'];
    return AiToolResult(
      ok: j['ok'] == true,
      result: result is Map ? Map<String, Object?>.from(result) : const {},
      speak: j['speak'] is String ? j['speak'] as String : null,
      deviceAction: device is Map ? Map<String, dynamic>.from(device) : null,
      needsConfirmation: j['needsConfirmation'] == true,
      summary: j['summary'] is String ? j['summary'] as String : null,
      approvalToken: j['approvalToken'] is String ? j['approvalToken'] as String : null,
      error: j['error'] is String ? j['error'] as String : null,
      status: status,
    );
  }

  const AiToolResult.failed(String this.error, {this.status = 0})
      : ok = false,
        result = const {},
        speak = null,
        deviceAction = null,
        needsConfirmation = false,
        summary = null,
        approvalToken = null;

  /// The function response the model reads: the server's result, plus what
  /// the model must know when it is empty (a failure, a pending yes).
  Map<String, Object?> toFunctionResponse() => {
        ...result,
        if (!result.containsKey('ok')) 'ok': ok,
        if (!ok && error != null && !result.containsKey('error')) 'error': error,
        if (needsConfirmation && !result.containsKey('needsConfirmation'))
          'needsConfirmation': true,
        if (needsConfirmation && summary != null && !result.containsKey('summary'))
          'summary': summary,
      };
}

/// What /ai/turn answers.
class AiTurnReceipt {
  const AiTurnReceipt({required this.reply, this.corrected = false});

  /// The reply, corrected by the server's claim check when it claimed
  /// something no tool in this turn did. Empty (with [corrected]) when the
  /// model chose to stay silent: nothing is shown or said.
  final String reply;
  final bool corrected;
}

/// What /ai/firebase-token answers.
class FirebaseTokenResult {
  const FirebaseTokenResult({required this.token, required this.uid});

  final String token;

  /// "u<id>".
  final String uid;
}

class ToolServer {
  ToolServer({
    http.Client? client,
    String Function()? baseUrl,
    Map<String, String> Function()? headers,
    void Function(int status)? onStatus,
  })  : _client = client ?? http.Client(),
        _baseUrl = baseUrl ?? (() => ApiService.baseUrl),
        _headers = headers ?? (() => ApiService.authHeaders),
        _onStatus = onStatus ?? ApiService.noteAuthStatus;

  final http.Client _client;
  final String Function() _baseUrl;
  final Map<String, String> Function() _headers;
  final void Function(int status) _onStatus;

  Map<String, String> get _jsonHeaders => {..._headers(), 'Content-Type': 'application/json'};

  Future<(int, Map<String, dynamic>?)> _send(
    String method,
    String path,
    Object? body,
    Duration timeout,
  ) async {
    try {
      final uri = Uri.parse('${_baseUrl()}$path');
      final r = await (method == 'GET'
              ? _client.get(uri, headers: _headers())
              : _client.post(uri, headers: _jsonHeaders, body: jsonEncode(body)))
          .timeout(timeout);
      if (r.statusCode >= 300) _onStatus(r.statusCode);
      Map<String, dynamic>? decoded;
      if (r.body.isNotEmpty) {
        try {
          final d = jsonDecode(r.body);
          if (d is Map<String, dynamic>) decoded = d;
        } catch (_) {/* not JSON: a proxy's error page */}
      }
      return (r.statusCode, decoded);
    } catch (_) {
      return (0, null);
    }
  }

  /// GET /ai/config (config.dart parses it). Null when unreachable.
  Future<Map<String, dynamic>?> config({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    // The build decides what this phone can play (the expressive voice
    // from 126).
    final (status, body) =
        await _send('GET', '/ai/config?build=${ApiService.appBuild ?? 0}', null, timeout);
    return status == 200 ? body : null;
  }

  /// POST /ai/context. Null when the server could not build one.
  Future<AiContext?> context({
    required String text,
    required String mode,
    String? sessionId,
    List<AiAttachment> attachments = const [],
    bool untrusted = false,
    bool shared = false,
    bool expressive = false,
    Map<String, Object?> device = const {},
    Duration timeout = const Duration(seconds: 8),
    String? transport,
  }) async {
    final body = <String, Object?>{
      'text': text,
      'mode': mode,
      // 'gpt-live': its delegated model takes every tool, not the live 40.
      if (transport != null) 'transport': transport,
      'sessionId': sessionId,
      'build': ApiService.appBuild ?? 0,
      'platform': _platform(),
      'tz': DateTime.now().timeZoneOffset.inMinutes,
      if (ApiService.geoLat != null) 'lat': ApiService.geoLat,
      if (ApiService.geoLng != null) 'lng': ApiService.geoLng,
      ...device,
      if (attachments.isNotEmpty) 'attachments': [for (final a in attachments) a.toJson()],
      if (untrusted) 'untrusted': true,
      if (shared) 'shared': true,
      // The reply will be spoken: the model may mark how it should sound.
      if (expressive) 'expressive': true,
    };
    final (status, j) = await _send('POST', '/ai/context', body, timeout);
    if (status != 200 || j == null) return null;
    return AiContext.fromJson(j);
  }

  /// POST /ai/tool. Never throws: an unreachable server or a refusal comes
  /// back as ok == false with the reason, which the model is told.
  Future<AiToolResult> tool({
    required String sessionId,
    required String turnId,
    required String name,
    required Map<String, Object?> args,
    required String userText,
    String? approvalToken,
    // 45 s since 2026-10-02: a picture (made, then saved) took ~24 s and the
    // old 25 s cut it off — the assistant then said it was not saved.
    Duration timeout = const Duration(seconds: 45),
  }) async {
    final (status, j) = await _send(
        'POST',
        '/ai/tool',
        {
          'sessionId': sessionId,
          'turnId': turnId,
          'name': name,
          'args': args,
          'userText': userText,
          if (approvalToken != null) 'approvalToken': approvalToken,
        },
        timeout);
    if (status == 0) return const AiToolResult.failed('The server could not be reached.');
    if (j == null) return AiToolResult.failed('The server answered $status.', status: status);
    if (status != 200 && !j.containsKey('ok')) {
      return AiToolResult.failed(
          j['error'] is String ? j['error'] as String : 'The server answered $status.',
          status: status);
    }
    return AiToolResult.fromJson(j, status: status);
  }

  /// POST /ai/turn. Null when it could not be recorded (the reply stands).
  Future<AiTurnReceipt?> recordTurn({
    required String sessionId,
    required String turnId,
    required String user,
    required String reply,
    required String engine,
    required List<Map<String, Object?>> tools,
    required int latencyMs,
    required String mode,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final (status, j) = await _send(
        'POST',
        '/ai/turn',
        {
          'sessionId': sessionId,
          'turnId': turnId,
          'user': user,
          'reply': reply,
          'engine': engine,
          'tools': tools,
          'latencyMs': latencyMs,
          'mode': mode,
        },
        timeout);
    if (status != 200 || j == null || j['ok'] != true) return null;
    final corrected = j['corrected'] == true;
    final said = j['reply'];
    return AiTurnReceipt(
      // "" with corrected: the model chose to stay silent - say nothing.
      reply: said is String && (said.trim().isNotEmpty || corrected) ? said : reply,
      corrected: corrected,
    );
  }

  /// A NEW TURN IN A LIVE CONVERSATION (2026-09-30). Every turn needs its
  /// own server turn — an approval asked in one turn is only accepted in a
  /// later one, and /ai/turn records a turn once — but the Live session
  /// already has its instruction and tools, so this is /ai/context with
  /// `turnOnly` (a server that does not know it builds the whole prompt,
  /// which is simply not used). Null when unreachable.
  Future<AiContext?> openLiveTurn({
    required String? sessionId,
    Map<String, Object?> device = const {},
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final (status, j) = await _send(
        'POST',
        '/ai/context',
        {
          'text': '',
          'mode': 'live',
          'turnOnly': true,
          'sessionId': sessionId,
          'build': ApiService.appBuild ?? 0,
          'platform': _platform(),
          'tz': DateTime.now().timeZoneOffset.inMinutes,
          if (ApiService.geoLat != null) 'lat': ApiService.geoLat,
          if (ApiService.geoLng != null) 'lng': ApiService.geoLng,
          ...device,
        },
        timeout);
    if (status != 200 || j == null) return null;
    return AiContext.fromJson(j);
  }

  /// POST /ai/turn for a Live turn: mode 'live', how fast she answered
  /// ([latency]: endToFirstAudio, endToPlay and tool ms), and — when the
  /// owner talked over her — [cutOffAfter], how many characters of [reply]
  /// were heard. Null when it could not be recorded.
  Future<AiTurnReceipt?> recordLiveTurn({
    required String sessionId,
    required String turnId,
    required String user,
    required String reply,
    required List<Map<String, Object?>> tools,
    required Map<String, int> latency,
    int? cutOffAfter,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final (status, j) = await _send(
        'POST',
        '/ai/turn',
        {
          'sessionId': sessionId,
          'turnId': turnId,
          'user': user,
          'reply': reply,
          'engine': 'live',
          'tools': tools,
          'latencyMs': latency['endToFirstAudio'] ?? 0,
          'latency': latency,
          'mode': 'live',
          if (cutOffAfter != null) 'cutOffAfter': cutOffAfter,
        },
        timeout);
    if (status != 200 || j == null || j['ok'] != true) return null;
    final corrected = j['corrected'] == true;
    final said = j['reply'];
    return AiTurnReceipt(
      reply: said is String && (said.trim().isNotEmpty || corrected) ? said : reply,
      corrected: corrected,
    );
  }

  /// POST /ai/firebase-token. Null when unreachable or "firebase unavailable".
  Future<FirebaseTokenResult?> firebaseToken({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final (status, j) = await _send('POST', '/ai/firebase-token', const {}, timeout);
    if (status != 200 || j == null) return null;
    final token = j['token'];
    final uid = j['uid'];
    if (token is! String || token.isEmpty) return null;
    return FirebaseTokenResult(token: token, uid: uid is String ? uid : '');
  }

  static String _platform() {
    try {
      return Platform.isIOS ? 'ios' : 'android';
    } catch (_) {
      return 'android';
    }
  }
}
