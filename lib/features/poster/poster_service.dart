import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart' show MediaType;

import '../../models/user_document.dart';
import '../../services/api_service.dart';
import '../../services/document_events.dart';
import 'poster_models.dart';

/// A non-2xx from /posters, or no answer at all ([status] 0).
class PosterApiException implements Exception {
  final int status;
  final String code;
  final String message;
  final List<PosterNeed> need;

  /// The server's copy, on a version conflict or nothing-to-undo.
  final Poster? poster;

  const PosterApiException(this.status, this.code, this.message,
      {this.need = const [], this.poster});

  bool get unreachable => status == 0;
  bool get isConflict => code == 'version_conflict';
  bool get isNeed => code == 'need';

  /// Worth keeping on this phone and trying again later: no answer, an
  /// older backend with no /posters yet, the card routes' own rate limit
  /// (429), or a server fault that is not one of its answers. The card
  /// still works here meanwhile.
  ///
  /// A 5xx the server NAMED is its answer, not an outage (integration
  /// check, 2026-09-26): 503 'unavailable' ("black and white" on a server
  /// without ffmpeg) and 507 'storage_full' fail the same way every time,
  /// so keeping them queued blocked every later change to the card — a
  /// corrected name included — behind a retry that could never succeed.
  bool get notAvailable =>
      unreachable ||
      (status == 404 && code.isEmpty) ||
      status == 429 ||
      (status >= 500 && (code.isEmpty || code == 'error'));

  /// What he may be shown. An unreachable server's text is the raw socket
  /// error (with the server's URL in it) — never for an elderly user's
  /// screen; the server's own messages are written for him.
  String friendly(String fallback) {
    if (unreachable || (status >= 500 && code.isEmpty)) return noInternet;
    return code.isNotEmpty && message.trim().isNotEmpty ? message : fallback;
  }

  static const noInternet = "Couldn't reach the internet just now — please try again in a moment.";

  factory PosterApiException.fromResponse(int status, String body) {
    try {
      final j = jsonDecode(body);
      if (j is Map<String, dynamic>) {
        return PosterApiException(
          status,
          (j['error'] ?? '').toString(),
          (j['message'] ?? '').toString(),
          need: [
            for (final n in (j['need'] as List? ?? const []))
              if (n is Map) PosterNeed.fromJson(n.cast<String, dynamic>()),
          ],
          poster: j['poster'] is Map
              ? Poster.fromJson((j['poster'] as Map).cast<String, dynamic>())
              : null,
        );
      }
    } catch (_) {}
    return PosterApiException(status, '', '');
  }

  @override
  String toString() => 'PosterApiException($status, $code, $message)';
}

/// The photo he gave, and the card it was added to (if any).
typedef PhotoUpload = ({PosterPhoto photo, Poster? poster});

/// Everything the card screen asks the server. An interface, so the
/// controller is tested against a fake.
abstract class PosterApi {
  Future<PhotoUpload> uploadPhoto({
    required Uint8List bytes,
    required String filename,
    required String mime,
    String source = 'gallery',
    int? posterId,
    String colour = 'keep',
  });
  Future<PhotoUpload> photoFromDocument(int documentId, {int? posterId});
  /// One variant of a photo. [colour] picks the cleaned-up copy's colour
  /// (a card asks for its spec.photoColour; contract v2) — each colour is
  /// its own URL, so a cached copy of one is never shown for another.
  Future<Uint8List> photoBytes(int photoId, String variant, {String? colour});

  /// Recolours a photo shown ON ITS OWN (the improve-old-photo screen).
  /// A card's photo colour is a PATCH (change.photoColour), not this.
  Future<PosterPhoto> recolourPhoto(int photoId, String colour);
  Future<UserDocument> keepPhoto(int photoId, String variant);
  Future<Poster> create({String occasion = 'birthday', Map<String, dynamic>? spec, int? photoId});
  Future<Poster?> latest();
  Future<Poster> get(int id);
  Future<({Poster poster, bool limitReached})> patch(int id, int version, PosterChange change);
  Future<UserDocument?> uploadFinal(int id, Uint8List png, int version);
  Future<void> delete(int id);
}

/// /posters over HTTP, with the app's own session headers.
class HttpPosterApi implements PosterApi {
  HttpPosterApi({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const _short = Duration(seconds: 20);
  static const _upload = Duration(seconds: 90);

  String get _base => '${ApiService.baseUrl}/posters';
  Map<String, String> get _json => ApiService.authHeaders;
  Map<String, String> get _multipart => Map.of(ApiService.authHeaders)..remove('Content-Type');

  Future<Map<String, dynamic>> _send(Future<http.Response> Function() call,
      {Set<int> ok = const {200, 201}}) async {
    http.Response r;
    try {
      r = await call();
    } catch (e) {
      throw PosterApiException(0, 'unreachable', '$e');
    }
    if (!ok.contains(r.statusCode)) {
      ApiService.noteAuthStatus(r.statusCode);
      throw PosterApiException.fromResponse(r.statusCode, r.body);
    }
    if (r.body.isEmpty) return const {};
    final j = jsonDecode(r.body);
    return j is Map<String, dynamic> ? j : const {};
  }

  Future<Map<String, dynamic>> _multipartSend(http.MultipartRequest req) async {
    http.StreamedResponse resp;
    String body;
    try {
      resp = await _client.send(req).timeout(_upload);
      body = await resp.stream.bytesToString();
    } catch (e) {
      throw PosterApiException(0, 'unreachable', '$e');
    }
    if (resp.statusCode != 200 && resp.statusCode != 201) {
      ApiService.noteAuthStatus(resp.statusCode);
      throw PosterApiException.fromResponse(resp.statusCode, body);
    }
    final j = jsonDecode(body);
    return j is Map<String, dynamic> ? j : const {};
  }

  static PhotoUpload _upload0(Map<String, dynamic> j) => (
        photo: PosterPhoto.fromJson((j['photo'] as Map).cast<String, dynamic>()),
        poster: j['poster'] is Map
            ? Poster.fromJson((j['poster'] as Map).cast<String, dynamic>())
            : null,
      );

  static Poster _poster(Map<String, dynamic> j) =>
      Poster.fromJson((j['poster'] as Map).cast<String, dynamic>());

  @override
  Future<PhotoUpload> uploadPhoto({
    required Uint8List bytes,
    required String filename,
    required String mime,
    String source = 'gallery',
    int? posterId,
    String colour = 'keep',
  }) async {
    final req = http.MultipartRequest('POST', Uri.parse('$_base/photos'))
      ..headers.addAll(_multipart)
      ..fields['source'] = source
      ..fields['colour'] = colour
      // No AI in v1 (2026-09-26): the server only cleans the photo up.
      ..fields['ai'] = 'false'
      ..files.add(http.MultipartFile.fromBytes('photo', bytes,
          filename: filename, contentType: MediaType.parse(mime)));
    if (posterId != null && posterId > 0) req.fields['posterId'] = '$posterId';
    return _upload0(await _multipartSend(req));
  }

  @override
  Future<PhotoUpload> photoFromDocument(int documentId, {int? posterId}) async =>
      _upload0(await _send(() => _client
          .post(Uri.parse('$_base/photos/from-document'),
              headers: _json,
              body: jsonEncode({
                'documentId': documentId,
                if (posterId != null && posterId > 0) 'posterId': posterId,
              }))
          .timeout(_upload)));

  @override
  Future<Uint8List> photoBytes(int photoId, String variant, {String? colour}) async {
    // The original has one colour only (the phone tints it); the cleaned-up
    // copy is asked for in the colour the card wants.
    final c = variant == 'enhanced' && colour != null && posterPhotoColours.contains(colour)
        ? '&colour=$colour'
        : '';
    http.Response r;
    try {
      r = await _client
          .get(Uri.parse('$_base/photos/$photoId/file?v=$variant$c'), headers: _json)
          .timeout(const Duration(seconds: 40));
    } catch (e) {
      throw PosterApiException(0, 'unreachable', '$e');
    }
    if (r.statusCode != 200) throw PosterApiException.fromResponse(r.statusCode, r.body);
    return r.bodyBytes;
  }

  @override
  Future<PosterPhoto> recolourPhoto(int photoId, String colour) async {
    final j = await _send(() => _client
        .post(Uri.parse('$_base/photos/$photoId/colour'),
            headers: _json, body: jsonEncode({'colour': colour}))
        .timeout(const Duration(seconds: 45)));
    return PosterPhoto.fromJson((j['photo'] as Map).cast<String, dynamic>());
  }

  @override
  Future<UserDocument> keepPhoto(int photoId, String variant) async {
    final j = await _send(() => _client
        .post(Uri.parse('$_base/photos/$photoId/keep'),
            headers: _json, body: jsonEncode({'v': variant}))
        .timeout(_short));
    DocumentEvents.bump();
    return UserDocument.fromJson((j['document'] as Map).cast<String, dynamic>());
  }

  @override
  Future<Poster> create({String occasion = 'birthday', Map<String, dynamic>? spec, int? photoId}) async =>
      _poster(await _send(() => _client
          .post(Uri.parse(_base),
              headers: _json,
              body: jsonEncode({
                'occasion': occasion,
                if (spec != null) 'spec': spec,
                if (photoId != null) 'photoId': photoId,
              }))
          .timeout(_short)));

  @override
  Future<Poster?> latest() async {
    try {
      return _poster(await _send(
          () => _client.get(Uri.parse('$_base/latest'), headers: _json).timeout(_short)));
    } on PosterApiException catch (e) {
      if (e.code == 'not_found') return null;
      rethrow;
    }
  }

  @override
  Future<Poster> get(int id) async => _poster(
      await _send(() => _client.get(Uri.parse('$_base/$id'), headers: _json).timeout(_short)));

  @override
  Future<({Poster poster, bool limitReached})> patch(
      int id, int version, PosterChange change) async {
    final j = await _send(() => _client
        .patch(Uri.parse('$_base/$id'),
            headers: _json, body: jsonEncode({'version': version, 'change': change.toJson()}))
        .timeout(_short));
    return (poster: _poster(j), limitReached: j['limitReached'] == true);
  }

  @override
  Future<UserDocument?> uploadFinal(int id, Uint8List png, int version) async {
    final req = http.MultipartRequest('POST', Uri.parse('$_base/$id/final'))
      ..headers.addAll(_multipart)
      ..fields['version'] = '$version'
      ..files.add(http.MultipartFile.fromBytes('image', png,
          filename: 'card-$id.png', contentType: MediaType('image', 'png')));
    final j = await _multipartSend(req);
    DocumentEvents.bump();
    return j['document'] is Map
        ? UserDocument.fromJson((j['document'] as Map).cast<String, dynamic>())
        : null;
  }

  @override
  Future<void> delete(int id) async {
    await _send(() => _client.delete(Uri.parse('$_base/$id'), headers: _json).timeout(_short));
  }
}
