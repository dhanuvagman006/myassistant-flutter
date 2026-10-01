import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/painting.dart' show Color;
import 'package:http/http.dart' as http;

import '../../services/api_service.dart';
import 'studio_models.dart';
import 'studio_palettes.dart';

/// A non-2xx from /posters/ai, or no answer at all ([status] 0).
class StudioApiException implements Exception {
  const StudioApiException(this.status, this.code, this.message);
  final int status;
  final String code;
  final String message;

  bool get unreachable => status == 0;

  /// AI pictures are switched off on the server, or this server has no
  /// studio yet (404 before the route is mounted): the drawn art stands in.
  bool get off => (status == 503 && code == 'off') || (status == 404 && code.isEmpty);

  /// One picture at a time per person.
  bool get busy => status == 429 && code == 'busy';
  bool get dailyLimit => status == 429 && code == 'daily_limit';

  /// Words fit for his screen: the server's own, or plain ones.
  String friendly(String fallback) {
    if (unreachable || (status >= 500 && code.isEmpty)) {
      return "Couldn't reach the internet just now — please try again in a moment.";
    }
    return message.trim().isNotEmpty && code.isNotEmpty ? message : fallback;
  }

  factory StudioApiException.fromResponse(int status, String body) {
    try {
      final j = jsonDecode(body);
      if (j is Map) {
        return StudioApiException(status, '${j['error'] ?? ''}', '${j['message'] ?? ''}');
      }
    } catch (_) {}
    return StudioApiException(status, '', '');
  }

  @override
  String toString() => 'StudioApiException($status, $code, $message)';
}

/// A background still being painted (`GET /posters/ai/background/jobs/:id`).
class StudioJob {
  const StudioJob(this.id, this.status, {this.background, this.error});
  final String id;

  /// running | done | failed
  final String status;
  final StudioBackground? background;
  final String? error;

  bool get running => status == 'running';
}

/// What the studio asks the server. An interface, so the controller is
/// tested against a fake.
abstract class PosterStudioApi {
  /// POST /posters/ai/design — his words into a poster's words and look.
  Future<EventDesign> design(String request,
      {StudioFormat format = StudioFormat.portrait, String? brandName, List<Color> brandColours = const []});

  /// POST /posters/ai/background — a picture with no words in it.
  Future<StudioBackground> background(
      {required String prompt, required String style, required StudioFormat format, int? seed});

  /// GET /posters/ai/background/jobs/:jobId
  Future<StudioJob> job(String jobId);

  /// The picture's bytes (GET /docs/:id/file).
  Future<Uint8List> bytes(StudioBackground b);

  /// Keeps the finished poster in his documents. Returns false when it
  /// could not be saved (the share still went).
  Future<bool> saveFinal(Uint8List png, {required String name, String note = ''});
}

/// /posters/ai over HTTP with the app's session headers (which carry
/// X-TZ-Offset, so "tomorrow" is his tomorrow).
class HttpPosterStudioApi implements PosterStudioApi {
  HttpPosterStudioApi({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;

  String get _base => '${ApiService.baseUrl}/posters/ai';
  Map<String, String> get _json => ApiService.authHeaders;

  Future<Map<String, dynamic>> _send(Future<http.Response> Function() call) async {
    http.Response r;
    try {
      r = await call();
    } catch (e) {
      throw StudioApiException(0, 'unreachable', '$e');
    }
    if (r.statusCode != 200 && r.statusCode != 201) {
      ApiService.noteAuthStatus(r.statusCode);
      throw StudioApiException.fromResponse(r.statusCode, r.body);
    }
    final j = r.body.isEmpty ? null : jsonDecode(r.body);
    return j is Map<String, dynamic> ? j : const {};
  }

  @override
  Future<EventDesign> design(String request,
      {StudioFormat format = StudioFormat.portrait, String? brandName, List<Color> brandColours = const []}) async {
    final j = await _send(() => _client
        .post(Uri.parse('$_base/design'),
            headers: _json,
            body: jsonEncode({
              'request': request,
              'format': format.name,
              if (brandName != null || brandColours.isNotEmpty)
                'brand': {
                  if (brandName != null) 'name': brandName,
                  if (brandColours.isNotEmpty) 'colors': [for (final c in brandColours) toHex(c)],
                },
            }))
        .timeout(const Duration(seconds: 25)));
    final d = j['design'];
    if (d is! Map) throw const StudioApiException(502, 'bad_design', '');
    return EventDesign.fromJson(d.cast<String, dynamic>());
  }

  @override
  Future<StudioBackground> background(
      {required String prompt, required String style, required StudioFormat format, int? seed}) async {
    final j = await _send(() => _client
        .post(Uri.parse('$_base/background'),
            headers: _json,
            body: jsonEncode({
              'prompt': prompt,
              'style': style,
              'format': format.name,
              if (seed != null) 'seed': seed,
            }))
        // The server gives itself 75 s across its providers.
        .timeout(const Duration(seconds: 95)));
    final b = StudioBackground.fromJson(j['background'] ?? j);
    if (b == null) throw const StudioApiException(502, 'generation_failed', '');
    return b;
  }

  @override
  Future<StudioJob> job(String jobId) async {
    final j = await _send(() => _client
        .get(Uri.parse('$_base/background/jobs/${Uri.encodeComponent(jobId)}'), headers: _json)
        .timeout(const Duration(seconds: 20)));
    return StudioJob(
      '${j['jobId'] ?? jobId}',
      '${j['status'] ?? 'failed'}',
      background: StudioBackground.fromJson(j['background']),
      error: j['error']?.toString(),
    );
  }

  @override
  Future<Uint8List> bytes(StudioBackground b) async {
    final path = b.url.startsWith('/') ? b.url : '/docs/${Uri.encodeComponent(b.id)}/file';
    http.Response r;
    try {
      r = await _client
          .get(Uri.parse('${ApiService.baseUrl}$path'), headers: _json)
          .timeout(const Duration(seconds: 40));
    } catch (e) {
      throw StudioApiException(0, 'unreachable', '$e');
    }
    if (r.statusCode != 200) throw StudioApiException.fromResponse(r.statusCode, r.body);
    return r.bodyBytes;
  }

  @override
  Future<bool> saveFinal(Uint8List png, {required String name, String note = ''}) async {
    try {
      await ApiService.uploadDocument(bytes: png, filename: name, mimeType: 'image/png', note: note);
      return true;
    } catch (_) {
      return false;
    }
  }
}
