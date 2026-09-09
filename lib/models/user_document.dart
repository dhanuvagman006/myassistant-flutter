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
  });

  bool get isPdf => mime == 'application/pdf';

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

  const DocumentUploadResult({
    required this.document,
    required this.filedUnder,
    this.clientId,
    this.clientName,
    this.clientCandidates = const [],
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
