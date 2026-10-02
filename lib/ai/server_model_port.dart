import 'dart:async';
import 'dart:convert';

import 'package:firebase_ai/firebase_ai.dart';
// The vendored package's own wire format (third_party/firebase_ai): the
// request is built and the answer parsed exactly as the SDK does it, so
// brain.dart, speech.dart and listen.dart keep working unchanged.
// ignore: implementation_imports
import 'package:firebase_ai/src/developer/api.dart' show DeveloperSerialization;
import 'package:http/http.dart' as http;

import '../core/log.dart';
import '../services/api_service.dart';
import 'model_port.dart';

/// THE MODEL BEHIND OUR OWN SERVER (2026-10-02, the owner: "completely
/// remove Gemini as the API provider and use OpenAI").
///
/// The phone used to call Gemini itself through Firebase AI Logic. Now it
/// sends the very same request — Gemini's wire shape, built by the SDK's
/// serializer — to POST /ai/generate, where the server answers it with
/// OpenAI and replies in the same shape (streamed as server-sent events).
/// The OpenAI key never leaves the server; the app's brain, speech and
/// listening code never learn the provider changed.
class ServerModelPort implements ModelPort {
  ServerModelPort({http.Client? client, String Function()? baseUrl, Map<String, String> Function()? headers})
      : _client = client ?? _shared,
        _baseUrl = baseUrl ?? (() => ApiService.baseUrl),
        _headers = headers ?? (() => ApiService.authHeaders);

  static final http.Client _shared = http.Client();
  static final DeveloperSerialization _wire = DeveloperSerialization();

  final http.Client _client;
  final String Function() _baseUrl;
  final Map<String, String> Function() _headers;
  DateTime? _warmedAt;

  /// Gemini's request JSON for [r], as the SDK would send it.
  static Map<String, Object?> requestJson(ModelRequest r) {
    final system = r.system;
    return _wire.generateContentRequest(
      r.contents,
      (prefix: 'models', name: r.model),
      const [],
      r.generationConfig,
      r.tools,
      r.toolConfig,
      system == null || system.trim().isEmpty ? null : Content.system(system),
    );
  }

  /// One server-sent `data:` line → the SDK's response object.
  static GenerateContentResponse parseChunk(Map<String, Object?> json) =>
      _wire.parseGenerateContentResponse(json);

  @override
  Stream<GenerateContentResponse> stream(ModelRequest request) async* {
    final req = http.Request('POST', Uri.parse('${_baseUrl()}/ai/generate'))
      ..headers.addAll({..._headers(), 'Content-Type': 'application/json', 'Accept': 'text/event-stream'})
      ..body = jsonEncode({...requestJson(request), 'stream': true});
    final resp = await _client.send(req).timeout(const Duration(seconds: 20));
    if (resp.statusCode != 200) {
      final body = await resp.stream.bytesToString().catchError((_) => '');
      throw ServerModelException(resp.statusCode, body);
    }
    var buffer = '';
    await for (final piece in resp.stream.transform(utf8.decoder)) {
      buffer += piece;
      int nl;
      while ((nl = buffer.indexOf('\n')) >= 0) {
        final line = buffer.substring(0, nl).trimRight();
        buffer = buffer.substring(nl + 1);
        final chunk = _dataOf(line);
        if (chunk != null) yield chunk;
      }
    }
    final last = _dataOf(buffer.trim());
    if (last != null) yield last;
  }

  GenerateContentResponse? _dataOf(String line) {
    if (!line.startsWith('data:')) return null;
    final payload = line.substring(5).trim();
    if (payload.isEmpty || payload == '[DONE]') return null;
    final json = jsonDecode(payload);
    if (json is! Map<String, Object?>) return null;
    if (json['error'] != null) {
      final e = json['error'];
      throw ServerModelException(0, e is Map ? '${e['message'] ?? e}' : '$e');
    }
    return parseChunk(json);
  }

  @override
  Future<GenerateContentResponse> generate(ModelRequest request) async {
    final resp = await _client
        .post(Uri.parse('${_baseUrl()}/ai/generate'),
            headers: {..._headers(), 'Content-Type': 'application/json'},
            body: jsonEncode({...requestJson(request), 'stream': false}))
        .timeout(const Duration(seconds: 90));
    if (resp.statusCode != 200) throw ServerModelException(resp.statusCode, resp.body);
    final json = jsonDecode(resp.body);
    if (json is! Map<String, Object?>) throw ServerModelException(0, 'not an answer');
    if (json['error'] != null) {
      final e = json['error'];
      throw ServerModelException(0, e is Map ? '${e['message'] ?? e}' : '$e');
    }
    return parseChunk(json);
  }

  /// A cheap round trip so the first real question does not pay for the
  /// connection; once in twenty seconds is plenty.
  @override
  Future<void> warmUp() async {
    final last = _warmedAt;
    if (last != null && DateTime.now().difference(last) < const Duration(seconds: 20)) return;
    _warmedAt = DateTime.now();
    try {
      await _client
          .get(Uri.parse('${_baseUrl()}/health'), headers: _headers())
          .timeout(const Duration(seconds: 5));
    } catch (e) {
      AppLog.add('ai', 'server warm-up skipped: ${e.runtimeType}');
    }
  }
}

class ServerModelException implements Exception {
  ServerModelException(this.status, this.body);
  final int status;
  final String body;
  @override
  String toString() => 'ServerModelException($status): ${body.length > 200 ? body.substring(0, 200) : body}';
}
