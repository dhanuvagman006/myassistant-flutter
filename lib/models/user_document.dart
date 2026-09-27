/// Content type for a file the user picked, from its extension. The
/// server refuses anything it cannot read, so the type has to be right —
/// uploading a .docx labelled application/pdf is rejected outright.
String mimeForFilename(String filename) {
  final i = filename.lastIndexOf('.');
  final ext = i < 0 ? '' : filename.substring(i + 1).toLowerCase();
  switch (ext) {
    case 'pdf':
      return 'application/pdf';
    case 'docx':
      return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
    case 'xlsx':
      return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
    case 'pptx':
      return 'application/vnd.openxmlformats-officedocument.presentationml.presentation';
    case 'csv':
      return 'text/csv';
    case 'tsv':
      return 'text/tab-separated-values';
    case 'txt':
      return 'text/plain';
    case 'md':
      return 'text/markdown';
    case 'json':
      return 'application/json';
    case 'rtf':
      return 'application/rtf';
    case 'png':
      return 'image/png';
    case 'webp':
      return 'image/webp';
    default:
      return 'image/jpeg';
  }
}

/// The file extension for a content type, or null when it is not one we
/// know. The server's type is the truth about the bytes: a deck saved and
/// shared as ".jpg" (2026-09-27) opened nowhere.
String? extensionForMime(String mime) => const {
      'application/pdf': '.pdf',
      'image/jpeg': '.jpg',
      'image/png': '.png',
      'image/webp': '.webp',
      'image/heic': '.heic',
      'image/heif': '.heif',
      'image/gif': '.gif',
      'application/vnd.openxmlformats-officedocument.presentationml.presentation':
          '.pptx',
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document':
          '.docx',
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet':
          '.xlsx',
      'application/vnd.ms-powerpoint': '.ppt',
      'application/msword': '.doc',
      'application/vnd.ms-excel': '.xls',
      'text/csv': '.csv',
      'text/tab-separated-values': '.tsv',
      'text/plain': '.txt',
      'text/markdown': '.md',
      'application/json': '.json',
      'application/rtf': '.rtf',
      'text/rtf': '.rtf',
      'video/mp4': '.mp4',
      'video/quicktime': '.mov',
    }[mime.split(';').first.trim().toLowerCase()];

/// A document the user saved into Hari's long-term memory — a hospital
/// report, a prescription photo, a receipt… Stored server-side; Hari can
/// pull it back up from a voice request ("show me my last hospital report").
class UserDocument {
  final int id;
  final String filename;
  final String mime;
  final String title;
  final String category; // medical | prescription | receipt | bill | id | ticket | other
  final String docDate; // yyyy-mm-dd printed on the document, or ''
  final String summary; // AI plain-language summary
  final String note; // the user's own words (e.g. what the doctor said)
  final int? clientId; // professional mode: which case file it's filed in
  final int createdAt;

  /// yyyy-mm-dd the document expires or must be renewed (insurance,
  /// licence, passport, PUC, warranty…), or '' — read by the server.
  final String expiresOn;

  const UserDocument({
    required this.id,
    required this.filename,
    required this.mime,
    required this.title,
    required this.category,
    required this.docDate,
    required this.summary,
    required this.note,
    this.clientId,
    required this.createdAt,
    this.expiresOn = '',
  });

  /// Whole days until expiry (negative once lapsed), or null if none.
  int? daysToExpiry([DateTime? now]) {
    final e = DateTime.tryParse(expiresOn);
    if (expiresOn.isEmpty || e == null) return null;
    final n = now ?? DateTime.now();
    final today = DateTime(n.year, n.month, n.day);
    return DateTime(e.year, e.month, e.day).difference(today).inDays;
  }

  /// "Expires in 12 days", "Expires today", "Expired 3 days ago",
  /// "Valid till 12 Oct 2027" — or null when there is no expiry.
  String? expiryLabel([DateTime? now]) {
    final d = daysToExpiry(now);
    if (d == null) return null;
    if (d < 0) return d == -1 ? 'Expired yesterday' : 'Expired ${-d} days ago';
    if (d == 0) return 'Expires today';
    if (d == 1) return 'Expires tomorrow';
    if (d <= 60) return 'Expires in $d days';
    final e = DateTime.parse(expiresOn);
    const mo = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return 'Valid till ${e.day} ${mo[e.month - 1]} ${e.year}';
  }

  bool get isPdf => mime == 'application/pdf';

  /// Only an IMAGE can be shown inline. Everything else has to be handed
  /// to a viewer app — a .pptx pushed through Image.network just renders
  /// as a broken-image glyph, which is how generated decks first looked.
  bool get isImage => mime.startsWith('image/');

  /// Coarse type, for the icon, the label and how the file is opened:
  /// image | pdf | slides | doc | sheet | text | other
  String get kind {
    if (isImage) return 'image';
    if (isPdf) return 'pdf';
    if (mime.contains('presentationml') || mime.contains('ms-powerpoint')) {
      return 'slides';
    }
    if (mime.contains('wordprocessingml') || mime == 'application/msword') {
      return 'doc';
    }
    if (mime.contains('spreadsheetml') ||
        mime == 'application/vnd.ms-excel' ||
        mime == 'text/csv' ||
        mime == 'text/tab-separated-values') {
      return 'sheet';
    }
    if (mime.startsWith('text/') || mime == 'application/json') return 'text';
    return 'other';
  }

  /// What the phone needs to choose a viewer. Taken from the saved
  /// filename when it has one, else derived from the type.
  String get fileExtension {
    final i = filename.lastIndexOf('.');
    if (i > 0 && i < filename.length - 1) {
      final e = filename.substring(i).toLowerCase();
      if (RegExp(r'^\.[a-z0-9]{2,5}$').hasMatch(e)) return e;
    }
    final known = extensionForMime(mime);
    if (known != null) return known;
    switch (kind) {
      case 'pdf':
        return '.pdf';
      case 'slides':
        return '.pptx';
      case 'doc':
        return '.docx';
      case 'sheet':
        return mime == 'text/csv' ? '.csv' : '.xlsx';
      case 'text':
        return '.txt';
      default:
        return '.jpg';
    }
  }

  factory UserDocument.fromJson(Map<String, dynamic> j) => UserDocument(
        id: (j['id'] as num?)?.toInt() ?? 0,
        filename: (j['filename'] ?? '').toString(),
        mime: (j['mime'] ?? '').toString(),
        title: (j['title'] ?? j['filename'] ?? 'Document').toString(),
        category: (j['category'] ?? 'other').toString(),
        docDate: (j['docDate'] ?? '').toString(),
        summary: (j['summary'] ?? '').toString(),
        note: (j['note'] ?? '').toString(),
        clientId: (j['clientId'] as num?)?.toInt(),
        createdAt: (j['createdAt'] as num?)?.toInt() ?? 0,
        expiresOn: (j['expiresOn'] ?? '').toString(),
      );

  static List<UserDocument> listFromJson(dynamic j) {
    if (j is! List) return const [];
    return j
        .whereType<Map>()
        .map((m) => UserDocument.fromJson(m.cast<String, dynamic>()))
        .where((d) => d.id > 0)
        .toList(growable: false);
  }
}

/// Where the server ACTUALLY filed an upload — read from the response, never
/// assumed. `filedUnder` is 'client' (in [clientName]'s case file) or
/// 'personal' (My documents). [clientCandidates] is non-empty when a spoken
/// person name matched several clients, so nothing was linked.
class DocumentUploadResult {
  final UserDocument document;
  final String filedUnder;
  final int? clientId;
  final String? clientName;
  final List<String> clientCandidates;

  /// False for a file the server keeps but cannot read inside (an old
  /// .doc/.xls/.ppt, a GIF) — [notice] is then the sentence to show
  /// instead of "reading it now". Servers before 2026-09-27 send neither.
  final bool readable;
  final String? notice;

  const DocumentUploadResult({
    required this.document,
    required this.filedUnder,
    this.clientId,
    this.clientName,
    this.clientCandidates = const [],
    this.readable = true,
    this.notice,
  });

  bool get filedUnderClient => filedUnder == 'client' && clientId != null;

  factory DocumentUploadResult.fromJson(Map<String, dynamic> j) {
    final client = j['client'];
    final cands = j['clientCandidates'];
    return DocumentUploadResult(
      document: UserDocument.fromJson(
          (j['document'] as Map).cast<String, dynamic>()),
      filedUnder: (j['filedUnder'] ?? (client is Map ? 'client' : 'personal'))
          .toString(),
      clientId: client is Map ? (client['id'] as num?)?.toInt() : null,
      clientName: client is Map ? client['name']?.toString() : null,
      clientCandidates: cands is List
          ? cands
              .whereType<Map>()
              .map((m) => (m['name'] ?? '').toString())
              .where((n) => n.isNotEmpty)
              .toList(growable: false)
          : const [],
      readable: j['readable'] != false,
      notice: (j['notice'] is String && (j['notice'] as String).trim().isNotEmpty)
          ? (j['notice'] as String).trim()
          : null,
    );
  }
}

/// A non-200 from POST /docs — nothing was saved. [message] is the server's
/// own explanation when it gave one (e.g. the account's document limit).
class DocumentUploadException implements Exception {
  final int statusCode;
  final String message;
  const DocumentUploadException(this.statusCode, this.message);

  @override
  String toString() => 'DocumentUploadException($statusCode, $message)';
}
