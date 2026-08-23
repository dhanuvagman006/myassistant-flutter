import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart' show MediaType;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/log.dart';
import '../models/chat_message.dart';
import '../models/client.dart';
import '../models/memory_item.dart';
import '../models/place.dart';
import '../models/reminder.dart';
import '../models/user_document.dart';
import '../models/vision_result.dart';
import '../models/remote_config.dart';
import 'style_prefs.dart';

/// All network traffic goes app → backend → AI providers.
/// The app never holds AI provider keys.
/// Thrown when /vision returns a non-200 so screens can show the REAL
/// reason (server not configured, signed out, file too big…) instead of
/// a generic "check your connection".
class VisionException implements Exception {
  final int status;

  /// The backend's `{"error": "..."}` message, if it sent one.
  final String serverMessage;

  VisionException(this.status, String rawBody)
      : serverMessage = _extract(rawBody);

  static String _extract(String body) {
    try {
      final j = jsonDecode(body);
      if (j is Map && j['error'] is String) return j['error'] as String;
    } catch (_) {}
    return '';
  }

  @override
  String toString() => 'VisionException($status, $serverMessage)';
}

class ApiService {
  /// Compile-time BASE_URL wins when provided:
  ///   flutter run --dart-define=BASE_URL=http://192.168.1.5:3000
  static const String _envBaseUrl = String.fromEnvironment('BASE_URL');

  /// When no override is provided, default to the production backend.
  /// RELEASE builds default to production. Diagnostics can override at
  /// runtime (persisted), --dart-define=BASE_URL overrides at build.
  static String get _defaultBaseUrl {
    if (_envBaseUrl.isNotEmpty) return _envBaseUrl;
    if (kDebugMode) return 'https://api.hariassistant.tech';
    return 'https://api.hariassistant.tech';
  }

  static String? _runtimeBaseUrl;

  /// The URL every request uses right now.
  static String get baseUrl => _runtimeBaseUrl ?? _defaultBaseUrl;

  static const String _serverPrefKey = 'server_url_override';

  /// Load a saved runtime override (called once at app start).
  static Future<void> loadServerOverride() async {
    try {
      final p = await SharedPreferences.getInstance();
      final v = p.getString(_serverPrefKey);
      if (v != null && v.startsWith('http')) _runtimeBaseUrl = v;
      AppLog.add('api', 'server = $baseUrl'
          '${_runtimeBaseUrl != null ? ' (runtime override)' : ''}');
    } catch (_) {}
  }

  /// Set (or clear with null/empty) the runtime server override.
  static Future<void> setServerOverride(String? url) async {
    final clean = url?.trim();
    final p = await SharedPreferences.getInstance();
    if (clean == null || clean.isEmpty) {
      _runtimeBaseUrl = null;
      await p.remove(_serverPrefKey);
    } else {
      _runtimeBaseUrl = clean.replaceAll(RegExp(r'/+$'), '');
      await p.setString(_serverPrefKey, _runtimeBaseUrl!);
    }
    AppLog.add('api', 'server changed to $baseUrl');
  }

  /// Shared secret matching the backend's APP_API_KEY (dev/X-App-Key mode).
  /// Pass with: --dart-define=APP_API_KEY=...
  static const String _appApiKey = String.fromEnvironment('APP_API_KEY');

  /// Exposed for the live-mode WebSocket URL (query-string auth).
  static String get appApiKey => _appApiKey;

  /// Generic JSON request helper (POST/PUT/DELETE) used by MCP settings.
  /// Returns the decoded body, or null on any failure — callers surface a
  /// friendly message rather than an exception.
  static Future<Map<String, dynamic>?> sendJson(String path,
      {String method = 'POST', Object? body}) async {
    try {
      final uri = Uri.parse('$baseUrl$path');
      final headers = {..._authHeaders, 'Content-Type': 'application/json'};
      final payload = body == null ? null : jsonEncode(body);
      late final http.Response r;
      switch (method) {
        case 'PUT':
          r = await _client.put(uri, headers: headers, body: payload);
        case 'DELETE':
          r = await _client.delete(uri, headers: headers, body: payload);
        default:
          r = await _client.post(uri, headers: headers, body: payload);
      }
      if (r.statusCode >= 300) return null;
      final decoded = r.body.isEmpty ? {} : jsonDecode(r.body);
      return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
    } catch (_) {
      return null;
    }
  }

  /// Small generic GET helper (used by the live-mode availability probe).
  static Future<Map<String, dynamic>?> getJson(String path) async {
    try {
      final r = await _client
          .get(Uri.parse('$baseUrl$path'), headers: _authHeaders)
          .timeout(const Duration(seconds: 6));
      if (r.statusCode != 200) return null;
      final body = jsonDecode(r.body);
      return body is Map<String, dynamic> ? body : null;
    } catch (_) {
      return null;
    }
  }

  /// Session JWT issued by the backend after any sign-in (email/Google/Apple).
  /// Managed by AuthService — set on sign-in, cleared on sign-out.
  static String? sessionToken;

  /// Last known GPS fix — set from RegionLanguage;
  /// lets the backend answer "what's the weather" without a city name.
  static double? geoLat;
  static double? geoLng;

  /// One long-lived client: the TCP+TLS connection to the backend stays
  /// open between turns, saving a full handshake on every voice exchange.
  static final http.Client _client = http.Client();

  /// Public alias for feature modules (avatar screen etc.).
  static Map<String, String> get authHeaders => _authHeaders;

  static Map<String, String> get _authHeaders => {
        'Content-Type': 'application/json',
        if (sessionToken != null) 'Authorization': 'Bearer $sessionToken'
        else if (_appApiKey.isNotEmpty) 'X-App-Key': _appApiKey,
      };

  /// Chat calls also carry the user's clock + location so backend tools
  /// (reminder time parsing, weather) work on THEIR wall clock and place.
  static Map<String, String> get _chatHeaders => {
        ..._authHeaders,
        'X-TZ-Offset': DateTime.now().timeZoneOffset.inMinutes.toString(),
        if (geoLat != null) 'X-Geo-Lat': geoLat!.toStringAsFixed(4),
        if (geoLng != null) 'X-Geo-Lng': geoLng!.toStringAsFixed(4),
      };

  static RemoteConfig config = const RemoteConfig();

  /// Fetched on every launch — drives feature flags, announcements, update prompts.
  static Future<RemoteConfig> refreshConfig() async {
    try {
      final r = await http
          .get(Uri.parse('$baseUrl/config'))
          .timeout(const Duration(seconds: 10));
      if (r.statusCode == 200) {
        config = RemoteConfig.fromJson(jsonDecode(r.body));
      }
    } catch (_) {
      // Offline or server down — keep the last known config. Never crash on config.
    }
    return config;
  }

  /// Fire-and-forget connection warm-up. Called the instant the wake
  /// word fires so DNS/TLS (and a sleeping free-tier host) are already
  /// awake by the time the question finishes being spoken.
  static void warm() {
    http
        .get(Uri.parse('$baseUrl/health'))
        .timeout(const Duration(seconds: 8))
        .ignore();
  }

  /// Regional language from the caller's IP (server-side lookup —
  /// no location permission needed). Returns e.g. 'kn_IN', or null.
  static Future<String?> fetchRegionLocale() async {
    try {
      final r = await http
          .get(Uri.parse('$baseUrl/region'), headers: _authHeaders)
          .timeout(const Duration(seconds: 8));
      if (r.statusCode != 200) return null;
      final locale = jsonDecode(r.body)['locale'] as String?;
      return (locale != null && locale.isNotEmpty) ? locale : null;
    } catch (_) {
      return null;
    }
  }

  /// Sends a recorded question to /stt (Whisper). Returns the
  /// transcript; the language is auto-detected server-side.
  static Future<String> transcribe(
    String filePath, {
    String? forceLanguage, // ISO-639-1, e.g. 'kn' — user picked it: lock it
    String? hintLanguage, // ISO-639-1 — bias detection, others still work
  }) async {
    final req = http.MultipartRequest('POST', Uri.parse('$baseUrl/stt'));
    // Multipart sets its own Content-Type; add only auth.
    if (sessionToken != null) {
      req.headers['Authorization'] = 'Bearer $sessionToken';
    } else if (_appApiKey.isNotEmpty) {
      req.headers['X-App-Key'] = _appApiKey;
    }
    if (forceLanguage != null) req.fields['language'] = forceLanguage;
    if (hintLanguage != null) req.fields['hint'] = hintLanguage;
    req.files.add(await http.MultipartFile.fromPath('audio', filePath));

    final streamed = await req.send().timeout(const Duration(seconds: 40));
    final r = await http.Response.fromStream(streamed);
    try {
      File(filePath).delete().ignore();
    } catch (_) {}
    if (r.statusCode != 200) {
      throw Exception('stt ${r.statusCode}');
    }
    return (jsonDecode(r.body)['text'] as String?)?.trim() ?? '';
  }

  /// Synthesizes [text] to a natural neural voice via the backend /tts
  /// endpoint (Gemini TTS). Writes the returned WAV to a temp file and
  /// returns its path, or null on any failure so the caller can fall back
  /// to the on-device voice. [language] is an ISO-639-1 hint for accent.
  static Future<String?> synthesizeSpeech(
    String text, {
    String? language, // 'kn', 'hi', 'en'…
    String? voice, // optional Gemini voice name override
  }) async {
    final say = text.trim();
    if (say.isEmpty) return null;
    try {
      final r = await _client
          .post(
            Uri.parse('$baseUrl/tts'),
            headers: _authHeaders,
            body: jsonEncode({
              'text': say,
              if (language != null && language.isNotEmpty) 'language': language,
              if (voice != null && voice.isNotEmpty) 'voice': voice,
            }),
          )
          .timeout(const Duration(seconds: 20));
      if (r.statusCode != 200 || r.bodyBytes.isEmpty) return null;
      final dir = await getTemporaryDirectory();
      final path =
          '${dir.path}/hari_tts_${DateTime.now().microsecondsSinceEpoch}.wav';
      await File(path).writeAsBytes(r.bodyBytes, flush: true);
      return path;
    } catch (_) {
      return null;
    }
  }

  /// Returns the assistant reply with any live-information sources (A5).
  /// Style preferences (A4) ride as headers — zero extra round-trips.
  static Future<ChatMessage> sendChat(List<ChatMessage> history) async {
    // (402 → QuotaExceeded is raised below, after the response arrives)
    final prefs = StylePrefs.instance;
    final r = await _client
        .post(
          Uri.parse('$baseUrl/chat'),
          headers: {
            ..._chatHeaders,
            'X-Style-Tone': prefs.tone,
            'X-Style-Length': prefs.answerLength,
          },
          body: jsonEncode({
            'messages': history.map((m) => m.toJson()).toList(),
            'language': 'auto',
          }),
        )
        .timeout(const Duration(seconds: 60));

    if (r.statusCode == 401) {
      throw Exception('Sign-in required — check APP_API_KEY or Google sign-in.');
    }
    checkQuota(r.statusCode, r.body); // 402 → QuotaExceeded (upsell)
    if (r.statusCode != 200) {
      throw Exception('Server error ${r.statusCode}');
    }
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    return ChatMessage(
      role: 'assistant',
      content: (j['reply'] as String?) ?? '',
      sources: ChatSource.listFromJson(j['sources']),
      documents: UserDocument.listFromJson(j['documents']),
    );
  }

  /// C3 — nearby places search; geo rides on the standard headers.
  static Future<List<Place>> fetchPlaces(String q) async {
    final r = await _client
        .get(
          Uri.parse('$baseUrl/places?q=${Uri.encodeQueryComponent(q)}'),
          headers: _chatHeaders, // includes X-Geo-Lat/Lng when known
        )
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) throw Exception('places ${r.statusCode}');
    return ((jsonDecode(r.body)['places'] as List?) ?? [])
        .map((j) => Place.fromJson(j as Map<String, dynamic>))
        .toList();
  }

  /// Proxied Google place photo (key stays server-side).
  static String placePhotoUrl(String ref) =>
      '$baseUrl/places/photo?ref=${Uri.encodeQueryComponent(ref)}';

  /// Auth headers for Image.network on protected endpoints (place photos).
  static Map<String, String> get imageHeaders => Map.of(_authHeaders)
    ..remove('Content-Type');

  /// Group B — vision: photo Q&A (B1), document reading (B2), OCR (B3),
  /// screenshot helper (B4). One multipart call; [history] lets
  /// follow-up questions reuse the same uploaded file.
  static Future<VisionResult> visionAsk({
    required List<int> bytes,
    required String filename,
    required String mimeType,
    String mode = 'ask', // ask | ocr | screenshot
    String question = '',
    List<ChatMessage> history = const [],
  }) async {
    final req = http.MultipartRequest('POST', Uri.parse('$baseUrl/vision'))
      ..headers.addAll(
          Map.of(_authHeaders)..remove('Content-Type')) // multipart sets its own
      ..fields['mode'] = mode
      ..fields['question'] = question
      ..fields['history'] =
          jsonEncode(history.map((m) => m.toJson()).toList())
      ..files.add(http.MultipartFile.fromBytes('file', bytes,
          filename: filename, contentType: MediaType.parse(mimeType)));

    final resp = await _client.send(req).timeout(const Duration(seconds: 90));
    final body = await resp.stream.bytesToString();
    if (resp.statusCode != 200) {
      throw VisionException(resp.statusCode, body);
    }
    final j = jsonDecode(body) as Map<String, dynamic>;
    return VisionResult.fromJson(j);
  }


  // ---------------------------------------------------------------------
  // SAVED DOCUMENTS — Hari's long-term document memory. Upload once; the
  // backend analyzes it (title/date/summary/tags) and can recall it later
  // from a plain voice request in any chat.
  // ---------------------------------------------------------------------

  /// Save a file into Hari's memory. [note] is the user's own words —
  /// e.g. what the doctor suggested — recited back on recall. Pass
  /// [clientId] to file it straight into that person's case file.
  static Future<UserDocument> uploadDocument({
    required List<int> bytes,
    required String filename,
    required String mimeType,
    String note = '',
    int? clientId,
  }) async {
    final req = http.MultipartRequest('POST', Uri.parse('$baseUrl/docs'))
      ..headers.addAll(Map.of(_authHeaders)..remove('Content-Type'))
      ..fields['note'] = note
      ..files.add(http.MultipartFile.fromBytes('file', bytes,
          filename: filename, contentType: MediaType.parse(mimeType)));
    if (clientId != null) req.fields['clientId'] = clientId.toString();
    final resp = await _client.send(req).timeout(const Duration(seconds: 90));
    final body = await resp.stream.bytesToString();
    if (resp.statusCode != 200) throw Exception('docs ${resp.statusCode}');
    return UserDocument.fromJson(
        (jsonDecode(body) as Map<String, dynamic>)['document']
            as Map<String, dynamic>);
  }

  static Future<List<UserDocument>> fetchDocuments() async {
    final r = await _client
        .get(Uri.parse('$baseUrl/docs'), headers: _authHeaders)
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) throw Exception('docs ${r.statusCode}');
    return UserDocument.listFromJson(jsonDecode(r.body)['documents']);
  }

  static Future<void> deleteDocument(int id) async {
    await _client
        .delete(Uri.parse('$baseUrl/docs/$id'), headers: _authHeaders)
        .timeout(const Duration(seconds: 15));
  }

  /// URL of the original file bytes (use with [imageHeaders] for auth).
  static String documentFileUrl(int id) => '$baseUrl/docs/$id/file';

  /// Downloads a saved document's raw bytes (auth required) so the app can
  /// share it out — WhatsApp, email, etc. Returns the bytes + mime type.
  static Future<({List<int> bytes, String mime})> downloadDocument(
      int id) async {
    final r = await _client
        .get(Uri.parse('$baseUrl/docs/$id/file'), headers: _authHeaders)
        .timeout(const Duration(seconds: 30));
    if (r.statusCode != 200) throw Exception('docs ${r.statusCode}');
    final mime = r.headers['content-type']?.split(';').first.trim() ??
        'application/octet-stream';
    return (bytes: r.bodyBytes, mime: mime);
  }

  // ---------------------------------------------------------------------
  // PROFESSIONAL MODE — clients / patients. One case file per person:
  // profile + dated notes + linked documents. Recalled by voice
  // ("pull up patient Ramesh's file") through the normal chat/voice loop.
  // ---------------------------------------------------------------------

  static Future<List<Client>> fetchClients() async {
    final r = await _client
        .get(Uri.parse('$baseUrl/clients'), headers: _authHeaders)
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) throw Exception('clients ${r.statusCode}');
    return Client.listFromJson(jsonDecode(r.body)['clients']);
  }

  static Future<Client> createClient({
    required String name,
    String kind = 'client',
    String phone = '',
    String email = '',
    String summary = '',
    String tags = '',
  }) async {
    final r = await _client
        .post(Uri.parse('$baseUrl/clients'),
            headers: _authHeaders,
            body: jsonEncode({
              'name': name,
              'kind': kind,
              'phone': phone,
              'email': email,
              'summary': summary,
              'tags': tags,
            }))
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) throw Exception('clients ${r.statusCode}');
    return Client.fromJson(
        (jsonDecode(r.body) as Map<String, dynamic>)['client']
            as Map<String, dynamic>);
  }

  /// The full case file: profile + notes (newest first) + linked documents.
  static Future<({Client client, List<ClientNote> notes, List<UserDocument> documents})>
      fetchClientProfile(int id) async {
    final r = await _client
        .get(Uri.parse('$baseUrl/clients/$id'), headers: _authHeaders)
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) throw Exception('clients ${r.statusCode}');
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    return (
      client: Client.fromJson(j['client'] as Map<String, dynamic>),
      notes: ClientNote.listFromJson(j['notes']),
      documents: UserDocument.listFromJson(j['documents']),
    );
  }

  static Future<Client> updateClient(int id, Map<String, dynamic> patch) async {
    final r = await _client
        .patch(Uri.parse('$baseUrl/clients/$id'),
            headers: _authHeaders, body: jsonEncode(patch))
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) throw Exception('clients ${r.statusCode}');
    return Client.fromJson(
        (jsonDecode(r.body) as Map<String, dynamic>)['client']
            as Map<String, dynamic>);
  }

  /// Deletes the person's card + notes. Their saved documents are KEPT
  /// (just unlinked) — the server never destroys files on card deletion.
  static Future<void> deleteClient(int id) async {
    await _client
        .delete(Uri.parse('$baseUrl/clients/$id'), headers: _authHeaders)
        .timeout(const Duration(seconds: 15));
  }

  static Future<ClientNote> addClientNote(int clientId, String text) async {
    final r = await _client
        .post(Uri.parse('$baseUrl/clients/$clientId/notes'),
            headers: _authHeaders, body: jsonEncode({'text': text}))
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) throw Exception('clients ${r.statusCode}');
    return ClientNote.fromJson(
        (jsonDecode(r.body) as Map<String, dynamic>)['note']
            as Map<String, dynamic>);
  }

  static Future<void> deleteClientNote(int clientId, int noteId) async {
    await _client
        .delete(Uri.parse('$baseUrl/clients/$clientId/notes/$noteId'),
            headers: _authHeaders)
        .timeout(const Duration(seconds: 15));
  }

  // ----------------------------------------------------------------------
  // Stocks & Market Data
  // ----------------------------------------------------------------------

  static Future<Map<String, dynamic>> fetchStocks() async {
    final r = await _client
        .get(Uri.parse('$baseUrl/stocks'), headers: _authHeaders)
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) throw Exception('stocks ${r.statusCode}');
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  // ----------------------------------------------------------------------
  // Admin & Analytics Data
  // ----------------------------------------------------------------------

  static Future<Map<String, dynamic>> fetchAnalytics() async {
    final r = await _client
        .get(Uri.parse('$baseUrl/analytics'), headers: _authHeaders)
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) throw Exception('analytics ${r.statusCode}');
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// File an already-saved document into a case file (or out of it).
  static Future<void> linkDocumentToClient(int clientId, int docId) async {
    final r = await _client
        .post(Uri.parse('$baseUrl/clients/$clientId/docs/$docId'),
            headers: _authHeaders)
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) throw Exception('clients ${r.statusCode}');
  }

  static Future<void> unlinkDocumentFromClient(int clientId, int docId) async {
    await _client
        .delete(Uri.parse('$baseUrl/clients/$clientId/docs/$docId'),
            headers: _authHeaders)
        .timeout(const Duration(seconds: 15));
  }

  /// STREAMING chat for the voice loop (Gemini-Live-style latency).
  /// Calls [onDelta] with each text fragment the moment the model writes
  /// it; returns the complete reply with sources when the stream ends.
  /// Throws if the stream can't start — caller falls back to [sendChat].
  static Future<ChatMessage> sendChatStream(
    List<ChatMessage> history, {
    required void Function(String delta) onDelta,
  }) async {
    final prefs = StylePrefs.instance;
    final req = http.Request('POST', Uri.parse('$baseUrl/chat/stream'))
      ..headers.addAll({
        ..._chatHeaders,
        'X-Style-Tone': prefs.tone,
        'X-Style-Length': prefs.answerLength,
      })
      ..body = jsonEncode({
        'messages': history.map((m) => m.toJson()).toList(),
        'language': 'auto',
      });

    // 20 s to first byte; 30 s max gap between chunks mid-stream.
    final resp = await _client.send(req).timeout(const Duration(seconds: 20));
    if (resp.statusCode == 402) {
      final body = await resp.stream.bytesToString();
      checkQuota(402, body); // always throws QuotaExceeded
    }
    if (resp.statusCode != 200) throw Exception('stream ${resp.statusCode}');

    final full = StringBuffer();
    var sources = const <ChatSource>[];
    var documents = const <UserDocument>[];
    var lineBuf = '';
    await for (final chunk in resp.stream
        .transform(utf8.decoder)
        .timeout(const Duration(seconds: 30))) {
      lineBuf += chunk;
      int nl;
      while ((nl = lineBuf.indexOf('\n')) >= 0) {
        final line = lineBuf.substring(0, nl).trim();
        lineBuf = lineBuf.substring(nl + 1);
        if (line.isEmpty) continue;
        final j = jsonDecode(line) as Map<String, dynamic>;
        final d = j['d'] as String?;
        if (d != null && d.isNotEmpty) {
          full.write(d);
          onDelta(d);
        }
        if (j['done'] == true) {
          sources = ChatSource.listFromJson(j['sources']);
          documents = UserDocument.listFromJson(j['documents']);
        }
        if (j['error'] != null) throw Exception('assistant unavailable');
      }
    }
    if (full.isEmpty) throw Exception('empty stream');
    return ChatMessage(
        role: 'assistant',
        content: full.toString(),
        sources: sources,
        documents: documents);
  }

  /// Personalized spoken greeting for app open / sign-in. The backend
  /// builds it from the user's memory; if Hari barely knows them, the
  /// greeting includes one get-to-know-you question.
  static Future<String?> fetchGreeting() async {
    try {
      final r = await http
          .post(Uri.parse('$baseUrl/chat/greeting'), headers: _authHeaders)
          .timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) return null;
      final g = (jsonDecode(r.body)['greeting'] as String?)?.trim();
      return (g == null || g.isEmpty) ? null : g;
    } catch (_) {
      return null;
    }
  }

  // ---------------- AGENT CALLS ----------------
  // "Call Allen Lobo and ask him what time he'll be home": the BACKEND
  // places the call (Plivo — India-capable) and the AI talks on it; the app polls the
  // call state and speaks the contact's answer back to the user.

  /// Starts an agent call. Returns the call id, or throws:
  ///   AgentCallUnavailable — backend has no telephony configured
  ///                          (caller should fall back to direct dialing).
  static Future<String> startAgentCall({
    required String toNumber,
    required String contactName,
    required String task,
    String? lang,
  }) async {
    final r = await _client
        .post(
          Uri.parse('$baseUrl/agent-call'),
          headers: _authHeaders,
          body: jsonEncode({
            'toNumber': toNumber,
            'contactName': contactName,
            'task': task,
            if (lang != null) 'lang': lang,
          }),
        )
        .timeout(const Duration(seconds: 20));
    if (r.statusCode == 503) throw AgentCallUnavailable();
    checkQuota(r.statusCode, r.body); // 402 → QuotaExceeded (upsell)
    if (r.statusCode != 202 && r.statusCode != 200) {
      throw Exception('agent call failed: ${r.statusCode}');
    }
    return jsonDecode(r.body)['id'] as String;
  }

  /// G2 — exactly what Hari will say when the contact answers, plus a
  /// server verdict on the user's own call rules (hours, daily limit,
  /// master switch). Nothing is dialed. 403 rule blocks on the real
  /// POST carry a ready-to-speak `say` line.
  static Future<({String opening, bool allowed, String? reason})>
      agentCallPreview({
    required String contactName,
    required String task,
    String? lang,
  }) async {
    final r = await _client
        .post(
          Uri.parse('$baseUrl/agent-call/preview'),
          headers: _authHeaders,
          body: jsonEncode({
            'contactName': contactName,
            'task': task,
            if (lang != null) 'lang': lang,
          }),
        )
        .timeout(const Duration(seconds: 12));
    if (r.statusCode != 200) throw Exception('preview ${r.statusCode}');
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    return (
      opening: j['opening'] as String? ?? '',
      allowed: j['allowed'] as bool? ?? true,
      reason: j['reason'] as String?,
    );
  }

  // ---------------- PRIVACY (F2) ----------------

  /// Everything the server holds on this account, as pretty JSON —
  /// the user saves or shares the file from the Privacy screen.
  static Future<String> exportMyData() async {
    final r = await _client
        .get(Uri.parse('$baseUrl/privacy/export'), headers: _authHeaders)
        .timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) throw Exception('export failed ${r.statusCode}');
    return const JsonEncoder.withIndent('  ')
        .convert(jsonDecode(r.body));
  }

  /// Permanent, irreversible account deletion (server erases every row
  /// and every stored file). Caller signs the user out afterwards.
  static Future<void> deleteMyAccount() async {
    final r = await _client
        .delete(Uri.parse('$baseUrl/privacy/account'), headers: _authHeaders)
        .timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) throw Exception('delete failed ${r.statusCode}');
  }

  /// One poll of an agent call. Terminal states:
  /// completed / no_answer / failed — `result` is the sentence to speak.
  static Future<({String state, String? result})> agentCallStatus(
      String id) async {
    final r = await _client
        .get(Uri.parse('$baseUrl/agent-call/$id'), headers: _authHeaders)
        .timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) throw Exception('status ${r.statusCode}');
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    return (state: j['state'] as String, result: j['result'] as String?);
  }

  // ---------------- BILLING ----------------
  // Plans, usage, Razorpay checkout (hosted payment page opened in the
  // browser; the backend webhook activates the plan), family accounts.

  static Future<Map<String, dynamic>> fetchBilling() async {
    final r = await _client
        .get(Uri.parse('$baseUrl/billing'), headers: _authHeaders)
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) throw Exception('billing ${r.statusCode}');
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// Starts a Pro/Family checkout → the Razorpay page URL to open.
  static Future<String> startCheckout(String plan) async {
    final r = await _client
        .post(Uri.parse('$baseUrl/billing/checkout'),
            headers: _authHeaders, body: jsonEncode({'plan': plan}))
        .timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) {
      throw Exception(
          (jsonDecode(r.body)['error'] as String?) ?? 'checkout failed');
    }
    return jsonDecode(r.body)['url'] as String;
  }

  static Future<String> familyInvite() async {
    final r = await _client
        .post(Uri.parse('$baseUrl/billing/family/invite'),
            headers: _authHeaders)
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) {
      throw Exception(
          (jsonDecode(r.body)['error'] as String?) ?? 'invite failed');
    }
    return jsonDecode(r.body)['code'] as String;
  }

  static Future<void> familyJoin(String code) async {
    final r = await _client
        .post(Uri.parse('$baseUrl/billing/family/join'),
            headers: _authHeaders, body: jsonEncode({'code': code}))
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) {
      throw Exception(
          (jsonDecode(r.body)['error'] as String?) ?? 'could not join');
    }
  }

  /// Throws [QuotaExceeded] when the backend answers 402 (plan limit).
  static void checkQuota(int statusCode, String body) {
    if (statusCode != 402) return;
    String msg = 'You have reached your plan limit.';
    try {
      msg = (jsonDecode(body)['error'] as String?) ?? msg;
    } catch (_) {}
    throw QuotaExceeded(msg);
  }

  // ---------------- PER-USER MEMORY ----------------
  // Backs the "Privacy & memory → WHAT I REMEMBER" screen. All calls
  // require a signed-in session (memory is per-account, not per-device).

  /// Everything Hari remembers about the signed-in user.
  static Future<List<MemoryItem>> fetchMemories() async {
    final r = await http
        .get(Uri.parse('$baseUrl/memory'), headers: _authHeaders)
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) {
      throw Exception('Could not load memories (${r.statusCode})');
    }
    final list = (jsonDecode(r.body)['memories'] as List? ?? []);
    return list
        .map((m) => MemoryItem.fromJson(m as Map<String, dynamic>))
        .toList();
  }

  /// User teaches Hari a fact directly ("remember that I'm vegetarian").
  static Future<void> addMemory(String key, String value,
      {String category = 'fact'}) async {
    final r = await http
        .post(
          Uri.parse('$baseUrl/memory'),
          headers: _authHeaders,
          body: jsonEncode({'key': key, 'value': value, 'category': category}),
        )
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) throw Exception('Could not save (${r.statusCode})');
  }

  /// Forget one fact — powers the per-row delete button.
  static Future<void> deleteMemory(int id) async {
    final r = await http
        .delete(Uri.parse('$baseUrl/memory/$id'), headers: _authHeaders)
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) throw Exception('Could not delete (${r.statusCode})');
  }

  // ---------------- SWIGGY (FOOD ORDERING) ----------------

  /// Whether this account has linked Swiggy (Builders Club MCP).
  static Future<bool> swiggyLinked() async {
    try {
      final r = await http
          .get(Uri.parse('$baseUrl/swiggy/status'), headers: _authHeaders)
          .timeout(const Duration(seconds: 10));
      return r.statusCode == 200 &&
          (jsonDecode(r.body)['linked'] as bool? ?? false);
    } catch (_) {
      return false;
    }
  }

  /// Browser URL for the Swiggy phone+OTP link flow (backend builds it
  /// with PKCE; the app never sees Swiggy tokens).
  static Future<String> swiggyConnectUrl() async {
    final r = await http
        .get(Uri.parse('$baseUrl/swiggy/connect'), headers: _authHeaders)
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) {
      throw Exception(
          (jsonDecode(r.body)['error'] as String?) ?? 'Swiggy unavailable');
    }
    return jsonDecode(r.body)['url'] as String;
  }

  static Future<void> disconnectSwiggy() async {
    await http
        .delete(Uri.parse('$baseUrl/swiggy'), headers: _authHeaders)
        .timeout(const Duration(seconds: 15));
  }

  // ---------------- GOOGLE (GMAIL + CALENDAR) ----------------

  static Future<void> connectGoogle(String serverAuthCode) async {
    final r = await http
        .post(
          Uri.parse('$baseUrl/google/connect'),
          headers: _authHeaders,
          body: jsonEncode({'serverAuthCode': serverAuthCode}),
        )
        .timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) {
      throw Exception(
          (jsonDecode(r.body)['error'] as String?) ?? 'link failed');
    }
  }

  static Future<bool> googleConnected() async {
    try {
      final r = await http
          .get(Uri.parse('$baseUrl/google/status'), headers: _authHeaders)
          .timeout(const Duration(seconds: 10));
      return r.statusCode == 200 &&
          (jsonDecode(r.body)['connected'] as bool? ?? false);
    } catch (_) {
      return false;
    }
  }

  static Future<void> disconnectGoogle() async {
    await http
        .delete(Uri.parse('$baseUrl/google'), headers: _authHeaders)
        .timeout(const Duration(seconds: 15));
  }

  /// null = Gmail not linked yet (409).
  static Future<List<Map<String, dynamic>>?> fetchGmailInbox() async {
    final r = await http
        .get(Uri.parse('$baseUrl/google/inbox'), headers: _authHeaders)
        .timeout(const Duration(seconds: 20));
    if (r.statusCode == 409) return null;
    if (r.statusCode != 200) throw Exception('inbox ${r.statusCode}');
    return ((jsonDecode(r.body)['emails'] as List?) ?? [])
        .cast<Map<String, dynamic>>();
  }

  /// null = Calendar not linked yet (409).
  static Future<List<Map<String, dynamic>>?> fetchCalendarEvents(
      {int days = 7}) async {
    try {
      final r = await http
          .get(Uri.parse('$baseUrl/google/calendar?days=$days'),
              headers: _authHeaders)
          .timeout(const Duration(seconds: 20));
      if (r.statusCode == 409) return null;
      if (r.statusCode != 200) return const [];
      return ((jsonDecode(r.body)['events'] as List?) ?? [])
          .cast<Map<String, dynamic>>();
    } catch (_) {
      return const [];
    }
  }

  // ---------------- REMINDERS ----------------

  static Future<List<Reminder>> fetchReminders() async {
    final r = await http
        .get(Uri.parse('$baseUrl/reminders'), headers: _authHeaders)
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) throw Exception('reminders ${r.statusCode}');
    return ((jsonDecode(r.body)['reminders'] as List?) ?? [])
        .map((j) => Reminder.fromJson(j as Map<String, dynamic>))
        .toList();
  }

  static Future<Reminder> createReminder(String text, DateTime? dueAt) async {
    final r = await http
        .post(
          Uri.parse('$baseUrl/reminders'),
          headers: _authHeaders,
          body: jsonEncode({
            'text': text,
            if (dueAt != null) 'dueAt': dueAt.millisecondsSinceEpoch,
          }),
        )
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) throw Exception('reminders ${r.statusCode}');
    return Reminder.fromJson(jsonDecode(r.body)['reminder']);
  }

  static Future<void> setReminderDone(int id, bool done) async {
    await http
        .patch(
          Uri.parse('$baseUrl/reminders/$id'),
          headers: _authHeaders,
          body: jsonEncode({'done': done}),
        )
        .timeout(const Duration(seconds: 15));
  }

  static Future<void> deleteReminder(int id) async {
    await http
        .delete(Uri.parse('$baseUrl/reminders/$id'), headers: _authHeaders)
        .timeout(const Duration(seconds: 15));
  }

  // ---------------- TODAY-SCREEN LIVE DATA ----------------

  /// Weather for the Today card. Uses the last GPS fix, else [city].
  static Future<Map<String, dynamic>?> fetchWeather({String? city}) async {
    try {
      final q = geoLat != null
          ? 'lat=$geoLat&lng=$geoLng'
          : (city != null ? 'city=${Uri.encodeComponent(city)}' : null);
      if (q == null) return null;
      final r = await http
          .get(Uri.parse('$baseUrl/tools/weather?$q'), headers: _authHeaders)
          .timeout(const Duration(seconds: 12));
      if (r.statusCode != 200) return null;
      return jsonDecode(r.body) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  static Future<List<Map<String, dynamic>>> fetchNews() async {
    try {
      final r = await http
          .get(Uri.parse('$baseUrl/tools/news'), headers: _authHeaders)
          .timeout(const Duration(seconds: 12));
      if (r.statusCode != 200) return const [];
      return ((jsonDecode(r.body)['headlines'] as List?) ?? [])
          .cast<Map<String, dynamic>>();
    } catch (_) {
      return const [];
    }
  }

  /// One sign-up interview answer → the backend extracts durable facts
  /// from it immediately (no learning throttle).
  static Future<void> submitInterviewAnswer(
      String question, String answer) async {
    final r = await http
        .post(
          Uri.parse('$baseUrl/memory/interview'),
          headers: _authHeaders,
          body: jsonEncode({'question': question, 'answer': answer}),
        )
        .timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) throw Exception('Could not save (${r.statusCode})');
  }

  /// Forget everything — the nuclear "clear memory" button.
  static Future<void> clearMemories() async {
    final r = await http
        .delete(Uri.parse('$baseUrl/memory'), headers: _authHeaders)
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) throw Exception('Could not clear (${r.statusCode})');
  }

}

/// The backend answered 402 pro_required — this feature needs Pro.
class ProRequired implements Exception {}

/// The backend has no telephony (Plivo) configured — agent calls are
/// unavailable; the app falls back to placing a normal direct call.
class AgentCallUnavailable implements Exception {}

/// The backend answered 402: the current plan's allowance is used up.
/// [message] is a ready-to-speak upsell line from the server.
class QuotaExceeded implements Exception {
  final String message;
  QuotaExceeded(this.message);
  @override
  String toString() => message;
}
