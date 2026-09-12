import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import '../core/log.dart';
import '../models/user_document.dart';
import '../services/api_service.dart';
import '../services/document_events.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  STYLE STUDIO — the app's side of "show me how I'd look".
///
///  The server owns the catalogue: which looks exist, what each one asks
///  for, and which presets it offers all arrive from GET /studio. Nothing
///  here hardcodes a recipe, so a look added on the server appears in the
///  app on the next launch without a release.
/// ─────────────────────────────────────────────────────────────────────────

/// A thing the studio can make.
class StudioRecipe {
  final String id;
  final String title;
  final String blurb;
  final String icon;
  final String group;
  final bool needsModel;

  /// 'no' | 'optional' | 'required' — whether a second photo (a garment,
  /// a pair of frames) may be attached.
  final String garment;
  final List<StudioParam> params;
  final List<StudioPreset> presets;
  final List<StudioSpec> specs;

  const StudioRecipe({
    required this.id,
    required this.title,
    required this.blurb,
    required this.icon,
    required this.group,
    required this.needsModel,
    required this.garment,
    required this.params,
    required this.presets,
    required this.specs,
  });

  bool get acceptsGarment => garment != 'no';

  factory StudioRecipe.fromJson(Map<String, dynamic> j) => StudioRecipe(
        id: (j['id'] ?? '').toString(),
        title: (j['title'] ?? '').toString(),
        blurb: (j['blurb'] ?? '').toString(),
        icon: (j['icon'] ?? '').toString(),
        group: (j['group'] ?? 'More').toString(),
        needsModel: j['needsModel'] == true,
        garment: (j['garment'] ?? 'no').toString(),
        params: (j['params'] as List? ?? const [])
            .whereType<Map>()
            .map((m) => StudioParam.fromJson(m.cast<String, dynamic>()))
            .toList(growable: false),
        presets: (j['presets'] as List? ?? const [])
            .whereType<Map>()
            .map((m) => StudioPreset.fromJson(m.cast<String, dynamic>()))
            .toList(growable: false),
        specs: (j['specs'] as List? ?? const [])
            .whereType<Map>()
            .map((m) => StudioSpec.fromJson(m.cast<String, dynamic>()))
            .toList(growable: false),
      );
}

class StudioParam {
  final String key;
  final String label;
  final String type; // text | choice
  final String hint;
  final bool required;
  final List<String> options;

  const StudioParam({
    required this.key,
    required this.label,
    required this.type,
    required this.hint,
    required this.required,
    required this.options,
  });

  factory StudioParam.fromJson(Map<String, dynamic> j) => StudioParam(
        key: (j['key'] ?? '').toString(),
        label: (j['label'] ?? '').toString(),
        type: (j['type'] ?? 'text').toString(),
        hint: (j['hint'] ?? '').toString(),
        required: j['required'] == true,
        options: (j['options'] as List? ?? const [])
            .map((o) => o.toString())
            .toList(growable: false),
      );
}

class StudioPreset {
  final String id;
  final String label;
  const StudioPreset({required this.id, required this.label});
  factory StudioPreset.fromJson(Map<String, dynamic> j) => StudioPreset(
        id: (j['id'] ?? '').toString(),
        label: (j['label'] ?? '').toString(),
      );
}

/// An official document's photo spec — the numbers that decide whether a
/// passport application is accepted.
class StudioSpec {
  final String id;
  final String label;
  final List<int> mm;
  final List<int> px;
  const StudioSpec(
      {required this.id, required this.label, required this.mm, required this.px});
  factory StudioSpec.fromJson(Map<String, dynamic> j) => StudioSpec(
        id: (j['id'] ?? '').toString(),
        label: (j['label'] ?? '').toString(),
        mm: (j['mm'] as List? ?? const [])
            .map((n) => (n as num).toInt())
            .toList(growable: false),
        px: (j['px'] as List? ?? const [])
            .map((n) => (n as num).toInt())
            .toList(growable: false),
      );
  String get size => mm.length == 2 ? '${mm[0]} × ${mm[1]} mm' : '';
}

/// A photo the user keeps in the studio: themselves, or a wardrobe item.
class StudioPhoto {
  final int id;
  final String role; // model | garment
  final int documentId;
  final String label;
  final bool isDefault;
  final int createdAt;

  const StudioPhoto({
    required this.id,
    required this.role,
    required this.documentId,
    required this.label,
    required this.isDefault,
    required this.createdAt,
  });

  String get imageUrl => ApiService.documentFileUrl(documentId);

  factory StudioPhoto.fromJson(Map<String, dynamic> j) => StudioPhoto(
        id: (j['id'] as num?)?.toInt() ?? 0,
        role: (j['role'] ?? 'model').toString(),
        documentId: (j['documentId'] as num?)?.toInt() ?? 0,
        label: (j['label'] ?? '').toString(),
        isDefault: j['isDefault'] == true,
        createdAt: (j['createdAt'] as num?)?.toInt() ?? 0,
      );
}

/// A finished look.
class StudioLook {
  final int id;
  final String recipe;
  final int documentId;
  final String prompt;
  final String provider;
  final bool favorite;
  final int createdAt;

  const StudioLook({
    required this.id,
    required this.recipe,
    required this.documentId,
    required this.prompt,
    required this.provider,
    required this.favorite,
    required this.createdAt,
  });

  String get imageUrl => ApiService.documentFileUrl(documentId);

  factory StudioLook.fromJson(Map<String, dynamic> j) => StudioLook(
        id: (j['id'] as num?)?.toInt() ?? 0,
        recipe: (j['recipe'] ?? '').toString(),
        documentId: (j['documentId'] as num?)?.toInt() ?? 0,
        prompt: (j['prompt'] ?? '').toString(),
        provider: (j['provider'] ?? '').toString(),
        favorite: j['favorite'] == true,
        createdAt: (j['createdAt'] as num?)?.toInt() ?? 0,
      );
}

/// Everything the Studio screen needs in one round trip.
class StudioState {
  final List<StudioRecipe> recipes;
  final List<StudioPhoto> photos;
  final List<StudioLook> looks;
  final int used;
  final int limit;
  final int consentedAt;

  /// Whether the server can actually make a look. When nothing is ready
  /// the screen says so up front instead of letting the user pick an
  /// outfit and then fail.
  final bool anyProviderReady;

  const StudioState({
    required this.recipes,
    required this.photos,
    required this.looks,
    required this.used,
    required this.limit,
    required this.consentedAt,
    required this.anyProviderReady,
  });

  List<StudioPhoto> get myPhotos =>
      photos.where((p) => p.role == 'model').toList(growable: false);
  List<StudioPhoto> get wardrobe =>
      photos.where((p) => p.role == 'garment').toList(growable: false);
  StudioPhoto? get defaultPhoto {
    final mine = myPhotos;
    if (mine.isEmpty) return null;
    return mine.firstWhere((p) => p.isDefault, orElse: () => mine.first);
  }

  bool get consented => consentedAt > 0;
  int get remaining => (limit - used).clamp(0, limit);

  factory StudioState.fromJson(Map<String, dynamic> j) {
    final providers = (j['providers'] as List? ?? const [])
        .whereType<Map>()
        .toList(growable: false);
    return StudioState(
      recipes: (j['recipes'] as List? ?? const [])
          .whereType<Map>()
          .map((m) => StudioRecipe.fromJson(m.cast<String, dynamic>()))
          .toList(growable: false),
      photos: (j['photos'] as List? ?? const [])
          .whereType<Map>()
          .map((m) => StudioPhoto.fromJson(m.cast<String, dynamic>()))
          .toList(growable: false),
      looks: (j['looks'] as List? ?? const [])
          .whereType<Map>()
          .map((m) => StudioLook.fromJson(m.cast<String, dynamic>()))
          .toList(growable: false),
      used: ((j['cap'] as Map?)?['used'] as num?)?.toInt() ?? 0,
      limit: ((j['cap'] as Map?)?['limit'] as num?)?.toInt() ?? 0,
      consentedAt: (j['consentedAt'] as num?)?.toInt() ?? 0,
      anyProviderReady: providers.any((p) => p['ready'] == true),
    );
  }
}

/// The result of one render.
class StudioResult {
  final UserDocument document;
  final StudioLook look;
  final int width;
  final int height;
  final int ms;

  /// Present for an ID photo: the millimetre size it was made to.
  final String specSize;

  const StudioResult({
    required this.document,
    required this.look,
    required this.width,
    required this.height,
    required this.ms,
    required this.specSize,
  });

  factory StudioResult.fromJson(Map<String, dynamic> j) {
    final spec = j['spec'];
    return StudioResult(
      document:
          UserDocument.fromJson((j['document'] as Map).cast<String, dynamic>()),
      look: StudioLook.fromJson((j['look'] as Map).cast<String, dynamic>()),
      width: (j['width'] as num?)?.toInt() ?? 0,
      height: (j['height'] as num?)?.toInt() ?? 0,
      ms: (j['ms'] as num?)?.toInt() ?? 0,
      specSize: spec is Map && spec['mm'] is List
          ? '${(spec['mm'] as List)[0]} × ${(spec['mm'] as List)[1]} mm'
          : '',
    );
  }
}

/// A non-200 from any /studio call. [code] is the server's machine-readable
/// reason, which is what decides whether the app offers a fix (add a photo,
/// accept the consent) or simply shows the sentence.
class StudioException implements Exception {
  final int statusCode;
  final String message;
  final String code;
  const StudioException(this.statusCode, this.message, this.code);

  bool get needsConsent => code == 'consent_required';
  bool get needsPhoto => code == 'no_model_photo';
  bool get overCap => code == 'daily_cap';
  bool get notConfigured => code == 'no_provider';

  @override
  String toString() => message.isNotEmpty ? message : 'Studio error $statusCode';
}

class StudioService {
  StudioService._();

  static final http.Client _client = http.Client();

  static Map<String, String> get _h => ApiService.authHeaders;
  static Map<String, String> get _multipartHeaders =>
      Map.of(_h)..remove('Content-Type');

  static String get _base => '${ApiService.baseUrl}/studio';

  static Never _throw(int status, String body) {
    String message = '';
    String code = '';
    try {
      final j = jsonDecode(body);
      if (j is Map) {
        message = (j['error'] ?? '').toString();
        code = (j['code'] ?? '').toString();
      }
    } catch (_) {}
    throw StudioException(status, message, code);
  }

  static Future<StudioState> load() async {
    final r = await _client
        .get(Uri.parse(_base), headers: _h)
        .timeout(const Duration(seconds: 25));
    if (r.statusCode != 200) _throw(r.statusCode, r.body);
    return StudioState.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
  }

  /// The full preset text lists — fetched only when a recipe screen opens,
  /// because the catalogue carries labels alone.
  static Future<Map<String, dynamic>> presets() async {
    final r = await _client
        .get(Uri.parse('$_base/presets'), headers: _h)
        .timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) _throw(r.statusCode, r.body);
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  static Future<void> acceptConsent() async {
    final r = await _client
        .post(Uri.parse('$_base/consent'), headers: _h)
        .timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) _throw(r.statusCode, r.body);
  }

  /// Withdraw it. The server deletes the stored photos of the person with
  /// it — the count it removed comes back so the user is told.
  static Future<int> withdrawConsent() async {
    final r = await _client
        .delete(Uri.parse('$_base/consent'), headers: _h)
        .timeout(const Duration(seconds: 25));
    if (r.statusCode != 200) _throw(r.statusCode, r.body);
    final j = jsonDecode(r.body);
    return j is Map ? ((j['photosDeleted'] as num?)?.toInt() ?? 0) : 0;
  }

  static Future<StudioPhoto> addPhoto({
    required List<int> bytes,
    required String filename,
    required String mimeType,
    String role = 'model',
    String label = '',
    bool makeDefault = false,
  }) async {
    final req = http.MultipartRequest('POST', Uri.parse('$_base/photos'))
      ..headers.addAll(_multipartHeaders)
      ..fields['role'] = role
      ..fields['label'] = label
      ..fields['makeDefault'] = makeDefault.toString()
      ..files.add(http.MultipartFile.fromBytes('file', bytes,
          filename: filename, contentType: MediaType.parse(mimeType)));
    final resp = await _client.send(req).timeout(const Duration(seconds: 90));
    final body = await resp.stream.bytesToString();
    if (resp.statusCode != 201 && resp.statusCode != 200) {
      _throw(resp.statusCode, body);
    }
    DocumentEvents.bump();
    return StudioPhoto.fromJson(
        (jsonDecode(body) as Map)['photo'].cast<String, dynamic>());
  }

  static Future<void> makeDefault(int photoId) async {
    final r = await _client
        .post(Uri.parse('$_base/photos/$photoId/default'), headers: _h)
        .timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) _throw(r.statusCode, r.body);
  }

  static Future<void> deletePhoto(int photoId) async {
    final r = await _client
        .delete(Uri.parse('$_base/photos/$photoId'), headers: _h)
        .timeout(const Duration(seconds: 25));
    if (r.statusCode != 200) _throw(r.statusCode, r.body);
    DocumentEvents.bump();
  }

  /// Make a look.
  ///
  /// Long by nature — a purpose-built try-on model takes ten to twenty
  /// seconds and a high-resolution edit can take a minute — so the timeout
  /// is generous. The screen shows progress; it must not give up before
  /// the server does.
  static Future<StudioResult> run({
    required String recipe,
    Map<String, String> params = const {},
    int? photoId,
    int? garmentId,
    List<int>? photoBytes,
    String? photoMime,
    List<int>? garmentBytes,
    String? garmentMime,
    bool keepPhoto = false,
  }) async {
    final req = http.MultipartRequest('POST', Uri.parse('$_base/run'))
      ..headers.addAll(_multipartHeaders)
      ..fields['recipe'] = recipe
      ..fields['params'] = jsonEncode(params);
    if (photoId != null) req.fields['photoId'] = photoId.toString();
    if (garmentId != null) req.fields['garmentId'] = garmentId.toString();
    if (keepPhoto) req.fields['keepPhoto'] = 'true';
    if (photoBytes != null && photoBytes.isNotEmpty) {
      req.files.add(http.MultipartFile.fromBytes('photo', photoBytes,
          filename: 'me.jpg',
          contentType: MediaType.parse(photoMime ?? 'image/jpeg')));
    }
    if (garmentBytes != null && garmentBytes.isNotEmpty) {
      req.files.add(http.MultipartFile.fromBytes('garment', garmentBytes,
          filename: 'garment.jpg',
          contentType: MediaType.parse(garmentMime ?? 'image/jpeg')));
    }
    final resp = await _client.send(req).timeout(const Duration(minutes: 3));
    final body = await resp.stream.bytesToString();
    if (resp.statusCode != 200) _throw(resp.statusCode, body);
    AppLog.add('studio', 'made a $recipe look');
    DocumentEvents.bump();
    return StudioResult.fromJson(jsonDecode(body) as Map<String, dynamic>);
  }

  static Future<List<StudioLook>> looks({String? recipe}) async {
    final q = recipe == null ? '' : '?recipe=$recipe';
    final r = await _client
        .get(Uri.parse('$_base/looks$q'), headers: _h)
        .timeout(const Duration(seconds: 25));
    if (r.statusCode != 200) _throw(r.statusCode, r.body);
    return ((jsonDecode(r.body) as Map)['looks'] as List? ?? const [])
        .whereType<Map>()
        .map((m) => StudioLook.fromJson(m.cast<String, dynamic>()))
        .toList(growable: false);
  }

  static Future<void> favorite(int lookId, bool on) async {
    final r = await _client
        .post(Uri.parse('$_base/looks/$lookId/favorite'),
            headers: {..._h, 'Content-Type': 'application/json'},
            body: jsonEncode({'on': on}))
        .timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) _throw(r.statusCode, r.body);
  }

  static Future<void> deleteLook(int lookId) async {
    final r = await _client
        .delete(Uri.parse('$_base/looks/$lookId'), headers: _h)
        .timeout(const Duration(seconds: 25));
    if (r.statusCode != 200) _throw(r.statusCode, r.body);
    DocumentEvents.bump();
  }
}
