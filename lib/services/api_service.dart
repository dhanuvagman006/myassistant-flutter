import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kDebugMode, kReleaseMode;
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart' show MediaType;
import 'package:shared_preferences/shared_preferences.dart';

import '../core/log.dart';
import '../models/client.dart';
import '../models/memory_item.dart';
import '../models/place.dart';
import '../models/reminder.dart';
import '../models/call_outcome.dart';
import '../models/user_document.dart';
import '../models/remote_config.dart';
import 'document_events.dart';

/// All network traffic goes app → backend → AI providers.
/// The app never holds AI provider keys.
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

  /// This install's Android versionCode (set once at startup).
  static int? appBuild;

  static String? _runtimeBaseUrl;

  /// The URL every request uses right now.
  static String get baseUrl => _runtimeBaseUrl ?? _defaultBaseUrl;

  static const String _serverPrefKey = 'server_url_override';

  /// Which server URLs may replace the default. The override exists so a
  /// moved server needs no rebuild — but every request carries the session
  /// token to it, and Diagnostics (reachable by voice) could point release
  /// builds at a plain-http host. Release builds accept https only; debug
  /// builds may use a local http server.
  static bool overrideAllowed(String url, {bool release = kReleaseMode}) =>
      release ? url.startsWith('https://') : url.startsWith('http');

  /// Load a saved runtime override (called once at app start).
  static Future<void> loadServerOverride() async {
    try {
      final p = await SharedPreferences.getInstance();
      final v = p.getString(_serverPrefKey);
      if (v != null && overrideAllowed(v)) _runtimeBaseUrl = v;
      AppLog.add(
          'api',
          'server = $baseUrl'
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
    } else if (!overrideAllowed(clean)) {
      AppLog.add(
          'api', 'server override refused (release builds need https): $clean');
      return;
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
  ///
  /// [timeout] exists because this was the ONE helper here without one.
  /// Dart's http client has no default request deadline, so a half-open
  /// socket — the ordinary case of walking out of wifi range — left the
  /// request pending until the OS gave up minutes later. On the last
  /// onboarding step that meant a spinner that never resolved and an
  /// account that could not be finished; on Chat it meant a send button
  /// that span forever. Every caller already treats null as failure and
  /// says so, so a deadline simply lets them reach that path.
  static Future<Map<String, dynamic>?> sendJson(String path,
      {String method = 'POST',
      Object? body,
      Duration timeout = const Duration(seconds: 20)}) async {
    try {
      final uri = Uri.parse('$baseUrl$path');
      final headers = {..._authHeaders, 'Content-Type': 'application/json'};
      final payload = body == null ? null : jsonEncode(body);
      late final http.Response r;
      switch (method) {
        case 'PUT':
          r = await _client
              .put(uri, headers: headers, body: payload)
              .timeout(timeout);
        case 'PATCH':
          r = await _client
              .patch(uri, headers: headers, body: payload)
              .timeout(timeout);
        case 'DELETE':
          r = await _client
              .delete(uri, headers: headers, body: payload)
              .timeout(timeout);
        default:
          r = await _client
              .post(uri, headers: headers, body: payload)
              .timeout(timeout);
      }
      if (r.statusCode >= 300) {
        _flagAuthFailure(r.statusCode);
        AppLog.add('api', '$method $path -> ${r.statusCode}');
        // A REFUSAL THE USER CAN ACT ON IS NOT A NULL. 409 carries the
        // server's own explanation ("that is a female name and a male
        // voice…"); swallowing it left the app saying "couldn't save",
        // which tells the user nothing about what to change.
        if (r.statusCode == 409 && r.body.isNotEmpty) {
          try {
            final d = jsonDecode(r.body);
            if (d is Map<String, dynamic>) return {...d, 'rejected': true};
          } catch (_) {/* fall through to null */}
        }
        return null;
      }
      final decoded = r.body.isEmpty ? {} : jsonDecode(r.body);
      return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
    } catch (e) {
      AppLog.add('api', '$method $path -> $e');
      return null;
    }
  }

  /// Fires when the backend rejects our session token (401) — the account
  /// was deleted, or the token expired. AuthService wires this to a
  /// re-verify + sign-out, so a deleted user's app returns to the login
  /// screen on its own instead of limping along on cached data until the
  /// next cold start. Throttled: one burst of failing calls is one signal.
  static void Function()? onSessionRejected;
  static DateTime _lastAuthReject = DateTime.fromMillisecondsSinceEpoch(0);

  /// For clients outside this file (the voice loop's session and posts):
  /// a 401 there means the same thing as a 401 here.
  static void noteAuthStatus(int status) => _flagAuthFailure(status);

  static void _flagAuthFailure(int status) {
    if (status != 401 || sessionToken == null) return;
    final now = DateTime.now();
    if (now.difference(_lastAuthReject) < const Duration(seconds: 30)) return;
    _lastAuthReject = now;
    onSessionRejected?.call();
  }

  /// Small generic GET helper (used by the live-mode availability probe).
  /// [timeout] defaults to the 6s probe budget; endpoints that think
  /// before answering (mail triage runs a model) must pass their own or
  /// they fail as "unreachable" while the server is still working.
  // ---- NEARBY (2026-10-01): people around who share what they do ----
  static Future<Map<String, dynamic>?> nearbyMe() => getJson('/nearby/me');

  /// The profession and the switch; the phone's position rides along so
  /// the server can keep a coarse one while sharing is on.
  static Future<Map<String, dynamic>?> setNearbyMe(
          {String? profession, bool? shared}) =>
      sendJson('/nearby/me', method: 'PUT', body: {
        if (profession != null) 'profession': profession,
        if (shared != null) 'shared': shared,
        if (geoLat != null) 'lat': geoLat,
        if (geoLng != null) 'lng': geoLng,
      });

  static Future<List<Map<String, dynamic>>> nearbyProfessionals(
      String q) async {
    final lat = geoLat;
    final lng = geoLng;
    if (lat == null || lng == null) return const [];
    final j = await getJson(
        '/nearby/professionals?q=${Uri.encodeQueryComponent(q)}&lat=$lat&lng=$lng',
        timeout: const Duration(seconds: 12));
    final list = j?['people'];
    return list is List
        ? list
            .whereType<Map>()
            .map((m) => m.cast<String, dynamic>())
            .toList(growable: false)
        : const [];
  }

  static Future<bool> nearbyContact(int userId, String text) async {
    final j = await sendJson('/nearby/contact',
        body: {'user_id': userId, 'text': text});
    return j?['ok'] == true;
  }

  static Future<Map<String, dynamic>?> getJson(String path,
      {Duration timeout = const Duration(seconds: 6)}) async {
    try {
      final r = await _client
          .get(Uri.parse('$baseUrl$path'), headers: _authHeaders)
          .timeout(timeout);
      if (r.statusCode != 200) {
        _flagAuthFailure(r.statusCode);
        AppLog.add('api', '$path -> ${r.statusCode}');
        return null;
      }
      final body = jsonDecode(r.body);
      return body is Map<String, dynamic> ? body : null;
    } catch (e) {
      AppLog.add('api', '$path -> $e');
      return null;
    }
  }

  /// POST a JSON body and read a JSON answer. The twin of [getJson] —
  /// same auth headers, same "null rather than throw" contract, so a
  /// screen can treat a dead network and a refusal the same way.
  static Future<Map<String, dynamic>?> postJson(String path, Object body,
      {Duration timeout = const Duration(seconds: 12)}) async {
    try {
      final r = await _client
          .post(Uri.parse('$baseUrl$path'),
              headers: _authHeaders, body: jsonEncode(body))
          .timeout(timeout);
      if (r.statusCode < 200 || r.statusCode >= 300) {
        _flagAuthFailure(r.statusCode);
        AppLog.add('api', '$path -> ${r.statusCode}');
        return null;
      }
      if (r.body.isEmpty) return const {};
      final decoded = jsonDecode(r.body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (e) {
      AppLog.add('api', '$path -> $e');
      return null;
    }
  }

  /// GET a protected binary resource (voice samples, for example).
  /// Uses the same authentication and failure logging as the JSON helpers.
  static Future<Uint8List?> getBytes(String path,
      {Duration timeout = const Duration(seconds: 40)}) async {
    try {
      final headers = Map<String, String>.of(_authHeaders)
        ..remove('Content-Type');
      final r = await _client
          .get(Uri.parse('$baseUrl$path'), headers: headers)
          .timeout(timeout);
      if (r.statusCode < 200 || r.statusCode >= 300) {
        _flagAuthFailure(r.statusCode);
        AppLog.add('api', 'GET $path -> ${r.statusCode}');
        return null;
      }
      return r.bodyBytes;
    } catch (e) {
      AppLog.add('api', 'GET $path -> $e');
      return null;
    }
  }

  /// DELETE, for the places a resource is removed rather than changed.
  /// Same contract as [getJson] and [postJson]: null on anything that is
  /// not a success, so a caller never has to tell a refusal from a dead
  /// network.
  static Future<Map<String, dynamic>?> deleteJson(String path,
      {Duration timeout = const Duration(seconds: 12)}) async {
    try {
      final r = await _client
          .delete(Uri.parse('$baseUrl$path'), headers: _authHeaders)
          .timeout(timeout);
      if (r.statusCode < 200 || r.statusCode >= 300) {
        _flagAuthFailure(r.statusCode);
        AppLog.add('api', '$path -> ${r.statusCode}');
        return null;
      }
      if (r.body.isEmpty) return const {};
      final decoded = jsonDecode(r.body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (e) {
      AppLog.add('api', '$path -> $e');
      return null;
    }
  }

  /// Session JWT issued by the backend after any sign-in (email/Google/Apple).
  /// Managed by AuthService — set on sign-in, cleared on sign-out.
  static String? sessionToken;

  /// Last known GPS fix — set from LocationService;
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
        if (sessionToken != null)
          'Authorization': 'Bearer $sessionToken'
        else if (_appApiKey.isNotEmpty)
          'X-App-Key': _appApiKey,
        // Clock + place on EVERY call: the brief, the calendar and the
        // classic voice path all parse times server-side, and without
        // this header every user on earth was stamped IST (+330).
        'X-TZ-Offset': DateTime.now().timeZoneOffset.inMinutes.toString(),
        // Which build THIS install is — lets the server gate capabilities
        // (e.g. auto-SMS) so it never promises what the app can't do.
        if (appBuild != null) 'X-App-Build': appBuild.toString(),
        if (geoLat != null) 'X-Geo-Lat': geoLat!.toStringAsFixed(4),
        if (geoLng != null) 'X-Geo-Lng': geoLng!.toStringAsFixed(4),
        // THE CHARGE, because "I'm going out" is partly a question about
        // the phone. Read from a cached value, never inside this getter —
        // it runs on every single request.
        if (batteryPct != null) 'X-Battery': '$batteryPct',
        if (batteryPct != null) 'X-Charging': batteryCharging ? '1' : '0',
      };

  /// Last known battery level, refreshed by the app shell. Null until the
  /// first reading, and a null is simply not sent — the server leaves the
  /// charge out of its answer rather than guessing at it.
  static int? batteryPct;
  static bool batteryCharging = false;

  /// Chat calls also carry the user's clock + location so backend tools
  /// (reminder time parsing, weather) work on THEIR wall clock and place.
  static Map<String, String> get _chatHeaders => {
        ..._authHeaders,
        'X-TZ-Offset': DateTime.now().timeZoneOffset.inMinutes.toString(),
        if (geoLat != null) 'X-Geo-Lat': geoLat!.toStringAsFixed(4),
        if (geoLng != null) 'X-Geo-Lng': geoLng!.toStringAsFixed(4),
      };

  /// HAND A TASK OVER AND WALK AWAY — the home-screen widget's one call.
  ///
  /// Not a conversation: the server queues it, answers immediately, works
  /// on it with the phone in a pocket and pushes the outcome. Returns
  /// true when the server took it.
  static Future<bool> queueQuickTask(String task) async {
    final t = task.trim();
    if (t.isEmpty) return false;
    try {
      final r = await _client
          .post(Uri.parse('$baseUrl/tasks/quick'),
              headers: _authHeaders, body: jsonEncode({'task': t}))
          .timeout(const Duration(seconds: 20));
      return r.statusCode == 202;
    } catch (_) {
      return false;
    }
  }

  static RemoteConfig config = const RemoteConfig();

  /// Fire-and-forget connection warm-up. Called the instant the wake
  /// word fires so DNS/TLS (and a sleeping free-tier host) are already
  /// awake by the time the question finishes being spoken.
  static void warm() {
    http
        .get(Uri.parse('$baseUrl/health'))
        .timeout(const Duration(seconds: 8))
        .ignore();
  }

  /// C3 — nearby places search; geo rides on the standard headers.
  static Future<List<Place>> fetchPlaces(String q) async {
    final r = await _client
        .get(
          Uri.parse('$baseUrl/places?q=${Uri.encodeQueryComponent(q)}'),
          headers: _chatHeaders, // includes X-Geo-Lat/Lng when known
        )
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) {
      _flagAuthFailure(r.statusCode);
      throw Exception('places ${r.statusCode}');
    }
    return ((jsonDecode(r.body)['places'] as List?) ?? [])
        .map((j) => Place.fromJson(j as Map<String, dynamic>))
        .toList();
  }

  /// Proxied Google place photo (key stays server-side).
  static String placePhotoUrl(String ref) =>
      '$baseUrl/places/photo?ref=${Uri.encodeQueryComponent(ref)}';

  /// Auth headers for Image.network on protected endpoints (place photos).
  static Map<String, String> get imageHeaders =>
      Map.of(_authHeaders)..remove('Content-Type');

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
    String? person, // whose records this belongs to ("Prasant")
  }) async =>
      (await uploadDocumentDetailed(
        bytes: bytes,
        filename: filename,
        mimeType: mimeType,
        note: note,
        clientId: clientId,
        person: person,
      ))
          .document;

  /// Same upload, but returns WHERE the server actually filed it — the
  /// case file it landed in (if any), or the ambiguous candidates when a
  /// spoken person name matched several clients. Callers use this to tell
  /// the user the truth ("Saved to Manish's file" vs "Saved to your
  /// documents") instead of assuming.
  ///
  /// Throws [DocumentUploadException] with the server's message on any
  /// non-200 — nothing was saved in that case.
  static Future<DocumentUploadResult> uploadDocumentDetailed({
    required List<int> bytes,
    required String filename,
    required String mimeType,
    String note = '',
    int? clientId,
    String? person,
  }) async {
    final req = http.MultipartRequest('POST', Uri.parse('$baseUrl/docs'))
      ..headers.addAll(Map.of(_authHeaders)..remove('Content-Type'))
      ..fields['note'] = note
      ..files.add(http.MultipartFile.fromBytes('file', bytes,
          filename: filename, contentType: MediaType.parse(mimeType)));
    if (clientId != null) req.fields['clientId'] = clientId.toString();
    if (person != null && person.trim().isNotEmpty) {
      req.fields['person'] = person.trim();
    }
    final resp = await _client.send(req).timeout(const Duration(seconds: 90));
    final body = await resp.stream.bytesToString();
    if (resp.statusCode != 200) {
      throw DocumentUploadException(resp.statusCode, _errorMessage(body));
    }
    final j = jsonDecode(body) as Map<String, dynamic>;
    final result = DocumentUploadResult.fromJson(j);
    DocumentEvents.bump();
    return result;
  }

  static String _errorMessage(String body) {
    try {
      final j = jsonDecode(body);
      if (j is Map && j['error'] is String) return j['error'] as String;
    } catch (_) {}
    return '';
  }

  /// The user's OWN documents only (My documents) — never anything filed
  /// under a client/patient; those are read through [fetchClientProfile].
  /// Calls the assistant placed for the user, newest first — what the
  /// Calls screen shows, including what the other person actually said.
  static Future<List<CallOutcome>> fetchCallOutcomes({int limit = 50}) async {
    final r = await _client
        .get(Uri.parse('$baseUrl/outcomes?kind=agent_call&limit=$limit'),
            headers: _authHeaders)
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) {
      _flagAuthFailure(r.statusCode);
      throw Exception('outcomes ${r.statusCode}');
    }
    return CallOutcome.listFromJson(jsonDecode(r.body)['outcomes']);
  }

  /// [scope] personal (My Documents), clients (filed in case files) or all.
  static Future<List<UserDocument>> fetchDocuments(
      {String scope = 'personal'}) async {
    final r = await _client
        .get(Uri.parse('$baseUrl/docs?scope=$scope'), headers: _authHeaders)
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) {
      _flagAuthFailure(r.statusCode);
      throw Exception('docs ${r.statusCode}');
    }
    return UserDocument.listFromJson(jsonDecode(r.body)['documents']);
  }

  /// Permanently deletes a document from the account. Throws unless the
  /// server confirmed the deletion (404 = it was already gone, treated as
  /// success so a retry can't get stuck).
  static Future<void> deleteDocument(int id) async {
    final r = await _client
        .delete(Uri.parse('$baseUrl/docs/$id'), headers: _authHeaders)
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200 && r.statusCode != 404) {
      _flagAuthFailure(r.statusCode);
      throw Exception('docs ${r.statusCode}');
    }
    DocumentEvents.bump();
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
    if (r.statusCode != 200) {
      _flagAuthFailure(r.statusCode);
      throw Exception('docs ${r.statusCode}');
    }
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
    if (r.statusCode != 200) {
      _flagAuthFailure(r.statusCode);
      throw Exception('clients ${r.statusCode}');
    }
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
    if (r.statusCode != 200) {
      _flagAuthFailure(r.statusCode);
      throw Exception('clients ${r.statusCode}');
    }
    return Client.fromJson((jsonDecode(r.body)
        as Map<String, dynamic>)['client'] as Map<String, dynamic>);
  }

  /// The full case file: profile + notes (newest first) + linked documents.
  static Future<
      ({
        Client client,
        List<ClientNote> notes,
        List<UserDocument> documents,
        Map<String, dynamic>? recall,
        double balance,
      })> fetchClientProfile(int id) async {
    final r = await _client
        .get(Uri.parse('$baseUrl/clients/$id'), headers: _authHeaders)
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) {
      _flagAuthFailure(r.statusCode);
      throw Exception('clients ${r.statusCode}');
    }
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    return (
      client: Client.fromJson(j['client'] as Map<String, dynamic>),
      notes: ClientNote.listFromJson(j['notes']),
      documents: UserDocument.listFromJson(j['documents']),
      recall: j['recall'] is Map
          ? (j['recall'] as Map).cast<String, dynamic>()
          : null,
      balance: (j['balance'] as num?)?.toDouble() ?? 0,
    );
  }

  static Future<Client> updateClient(int id, Map<String, dynamic> patch) async {
    final r = await _client
        .patch(Uri.parse('$baseUrl/clients/$id'),
            headers: _authHeaders, body: jsonEncode(patch))
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) {
      _flagAuthFailure(r.statusCode);
      throw Exception('clients ${r.statusCode}');
    }
    return Client.fromJson((jsonDecode(r.body)
        as Map<String, dynamic>)['client'] as Map<String, dynamic>);
  }

  /// Deletes the person's card + notes. Their saved documents are KEPT
  /// (just unlinked) — the server never destroys files on card deletion.
  /// Deletes the case file AND the documents filed in it (the UI's
  /// confirmation says so). Throws unless the server confirmed.
  static Future<void> deleteClient(int id) async {
    final r = await _client
        .delete(Uri.parse('$baseUrl/clients/$id'), headers: _authHeaders)
        .timeout(const Duration(seconds: 30));
    if (r.statusCode != 200 && r.statusCode != 404) {
      _flagAuthFailure(r.statusCode);
      throw Exception('clients ${r.statusCode}');
    }
    DocumentEvents.bump();
  }

  static Future<ClientNote> addClientNote(int clientId, String text) async {
    final r = await _client
        .post(Uri.parse('$baseUrl/clients/$clientId/notes'),
            headers: _authHeaders, body: jsonEncode({'text': text}))
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) {
      _flagAuthFailure(r.statusCode);
      throw Exception('clients ${r.statusCode}');
    }
    return ClientNote.fromJson((jsonDecode(r.body)
        as Map<String, dynamic>)['note'] as Map<String, dynamic>);
  }

  /// Throws unless the server confirmed (404 = already gone).
  static Future<void> deleteClientNote(int clientId, int noteId) async {
    final r = await _client
        .delete(Uri.parse('$baseUrl/clients/$clientId/notes/$noteId'),
            headers: _authHeaders)
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200 && r.statusCode != 404) {
      _flagAuthFailure(r.statusCode);
      throw Exception('clients ${r.statusCode}');
    }
  }

  // ----------------------------------------------------------------------
  // Stocks & Market Data
  // ----------------------------------------------------------------------

  static Future<Map<String, dynamic>> fetchStocks() async {
    final r = await _client
        .get(Uri.parse('$baseUrl/stocks'), headers: _authHeaders)
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) {
      _flagAuthFailure(r.statusCode);
      throw Exception('stocks ${r.statusCode}');
    }
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  // ----------------------------------------------------------------------
  // Finance section (EMIs, incomes, expenses)
  // ----------------------------------------------------------------------

  static Future<Map<String, dynamic>> fetchFinance() async {
    final r = await _client
        .get(Uri.parse('$baseUrl/finance'), headers: _authHeaders)
        .timeout(const Duration(seconds: 12));
    if (r.statusCode != 200) {
      _flagAuthFailure(r.statusCode);
      throw Exception('finance ${r.statusCode}');
    }
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  static Future<bool> addFinanceItem(Map<String, dynamic> item) async {
    final r = await _client
        .post(Uri.parse('$baseUrl/finance'),
            headers: _authHeaders, body: jsonEncode(item))
        .timeout(const Duration(seconds: 12));
    _flagAuthFailure(r.statusCode);
    return r.statusCode == 200;
  }

  static Future<bool> deleteFinanceItem(int id) async {
    final r = await _client
        .delete(Uri.parse('$baseUrl/finance/$id'), headers: _authHeaders)
        .timeout(const Duration(seconds: 12));
    _flagAuthFailure(r.statusCode);
    return r.statusCode == 200;
  }

  // ----------------------------------------------------------------------
  // Admin & Analytics Data
  // ----------------------------------------------------------------------

  static Future<Map<String, dynamic>> fetchAnalytics() async {
    final r = await _client
        .get(Uri.parse('$baseUrl/analytics'), headers: _authHeaders)
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) {
      _flagAuthFailure(r.statusCode);
      throw Exception('analytics ${r.statusCode}');
    }
    return jsonDecode(r.body) as Map<String, dynamic>;
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
    // What the USER said should happen if nobody answers. Zero means one
    // attempt: the assistant never decides to ring someone again.
    int retryTimes = 0,
    int retryGapMinutes = 0,
    // How the call should sound, when the user asked for something other
    // than ordinary courtesy. Null keeps the warm default.
    String? tone,
    // Whose voice makes the call: 'woman' (default) or 'man', when asked.
    String? voice,
  }) async {
    final r = await _client
        .post(
          Uri.parse('$baseUrl/agent-call'),
          headers: _authHeaders,
          body: jsonEncode({
            'toNumber': toNumber,
            'contactName': contactName,
            'task': task,
            if (retryTimes > 0) 'retryTimes': retryTimes,
            if (retryGapMinutes > 0) 'retryGapMinutes': retryGapMinutes,
            if (tone != null && tone.isNotEmpty) 'tone': tone,
            if (voice != null && voice.isNotEmpty) 'voice': voice,
            if (lang != null) 'lang': lang,
          }),
        )
        // The server answers once the calling service has taken the call
        // (a few seconds); 35 s so a slow moment is not mistaken for a
        // failure (2026-09-26).
        .timeout(const Duration(seconds: 35));
    if (r.statusCode == 503) throw AgentCallUnavailable();
    checkQuota(r.statusCode, r.body); // 402 → QuotaExceeded (upsell)
    if (r.statusCode != 202 && r.statusCode != 200) {
      _flagAuthFailure(r.statusCode);
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
    if (r.statusCode != 200) {
      _flagAuthFailure(r.statusCode);
      throw Exception('preview ${r.statusCode}');
    }
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
    if (r.statusCode != 200) {
      _flagAuthFailure(r.statusCode);
      throw Exception('export failed ${r.statusCode}');
    }
    return const JsonEncoder.withIndent('  ').convert(jsonDecode(r.body));
  }

  /// Permanent, irreversible account deletion (server erases every row
  /// and every stored file). Caller signs the user out afterwards.
  static Future<void> deleteMyAccount() async {
    final r = await _client
        .delete(Uri.parse('$baseUrl/privacy/account'), headers: _authHeaders)
        .timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) {
      _flagAuthFailure(r.statusCode);
      throw Exception('delete failed ${r.statusCode}');
    }
  }

  /// One poll of an agent call. Terminal states:
  /// completed / no_answer / failed — `result` is the sentence to speak.
  static Future<({String state, String? result})> agentCallStatus(
      String id) async {
    final r = await _client
        .get(Uri.parse('$baseUrl/agent-call/$id'), headers: _authHeaders)
        .timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) {
      _flagAuthFailure(r.statusCode);
      throw Exception('status ${r.statusCode}');
    }
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
    if (r.statusCode != 200) {
      _flagAuthFailure(r.statusCode);
      throw Exception('billing ${r.statusCode}');
    }
    return jsonDecode(r.body) as Map<String, dynamic>;
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
      _flagAuthFailure(r.statusCode);
      throw Exception('Could not load memories (${r.statusCode})');
    }
    final list = (jsonDecode(r.body)['memories'] as List? ?? []);
    return list
        .map((m) => MemoryItem.fromJson(m as Map<String, dynamic>))
        .toList();
  }

  // ---------------- SWIGGY (FOOD ORDERING) ----------------

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
      _flagAuthFailure(r.statusCode);
      throw Exception(
          (jsonDecode(r.body)['error'] as String?) ?? 'link failed');
    }
  }

  /// True only when the server says the link is gone. A 5xx or a dead
  /// network used to read as "disconnected" while the server still held
  /// the grant and kept reading mail (audit, 2026-09-27).
  static Future<bool> disconnectGoogle() async {
    try {
      final r = await http
          .delete(Uri.parse('$baseUrl/google'), headers: _authHeaders)
          .timeout(const Duration(seconds: 15));
      _flagAuthFailure(r.statusCode);
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// null = Gmail not linked yet (409).
  static Future<List<Map<String, dynamic>>?> fetchGmailInbox() async {
    final r = await http
        .get(Uri.parse('$baseUrl/google/inbox'), headers: _authHeaders)
        .timeout(const Duration(seconds: 20));
    if (r.statusCode == 409) return null;
    if (r.statusCode != 200) {
      _flagAuthFailure(r.statusCode);
      throw Exception('inbox ${r.statusCode}');
    }
    return ((jsonDecode(r.body)['emails'] as List?) ?? [])
        .cast<Map<String, dynamic>>();
  }

  /// null = Calendar not linked yet (409). Throws when the fetch itself
  /// failed, so "nothing today" is never a guess.
  static Future<List<Map<String, dynamic>>?> fetchCalendarEvents(
      {int days = 7}) async {
    final r = await http
        .get(Uri.parse('$baseUrl/google/calendar?days=$days'),
            headers: _authHeaders)
        .timeout(const Duration(seconds: 20));
    if (r.statusCode == 409) return null;
    if (r.statusCode != 200) {
      _flagAuthFailure(r.statusCode);
      throw Exception('calendar ${r.statusCode}');
    }
    return ((jsonDecode(r.body)['events'] as List?) ?? [])
        .cast<Map<String, dynamic>>();
  }

  // ---------------- REMINDERS ----------------

  static Future<List<Reminder>> fetchReminders() async {
    final r = await http
        .get(Uri.parse('$baseUrl/reminders'), headers: _authHeaders)
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) {
      _flagAuthFailure(r.statusCode);
      throw Exception('reminders ${r.statusCode}');
    }
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
    if (r.statusCode != 200) {
      _flagAuthFailure(r.statusCode);
      throw Exception('reminders ${r.statusCode}');
    }
    return Reminder.fromJson(jsonDecode(r.body)['reminder']);
  }

  /// Throws unless the server confirmed, so a screen never says "Done"
  /// over a change that did not save.
  static Future<void> setReminderDone(int id, bool done) async {
    final r = await http
        .patch(
          Uri.parse('$baseUrl/reminders/$id'),
          headers: _authHeaders,
          body: jsonEncode({'done': done}),
        )
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) {
      _flagAuthFailure(r.statusCode);
      throw Exception('reminders ${r.statusCode}');
    }
  }

  static Future<void> deleteReminder(int id) async {
    final r = await http
        .delete(Uri.parse('$baseUrl/reminders/$id'), headers: _authHeaders)
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200 && r.statusCode != 404) {
      _flagAuthFailure(r.statusCode);
      throw Exception('reminders ${r.statusCode}');
    }
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

  /// null = the fetch failed; [] = a good answer with no headlines.
  static Future<List<Map<String, dynamic>>?> fetchNews() async {
    try {
      final r = await http
          .get(Uri.parse('$baseUrl/tools/news'), headers: _authHeaders)
          .timeout(const Duration(seconds: 12));
      if (r.statusCode != 200) {
        _flagAuthFailure(r.statusCode);
        return null;
      }
      return ((jsonDecode(r.body)['headlines'] as List?) ?? [])
          .cast<Map<String, dynamic>>();
    } catch (_) {
      return null;
    }
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
