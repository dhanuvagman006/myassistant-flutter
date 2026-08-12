/// PROFESSIONAL MODE — a person the user works with (a doctor's patient,
/// a lawyer's client…). One "case file" per person on the backend:
/// this profile row + dated case notes + linked saved documents.
/// Voice recall ("pull up patient Ramesh's file") reads it all back.
class Client {
  final int id;
  final String name;
  final String kind; // patient | client | student | customer | other
  final String phone;
  final String email;
  final String summary; // one line: "42M, type-2 diabetic" / "Property dispute"
  final String tags;
  final int createdAt;
  final int updatedAt;

  const Client({
    required this.id,
    required this.name,
    required this.kind,
    required this.phone,
    required this.email,
    required this.summary,
    required this.tags,
    required this.createdAt,
    required this.updatedAt,
  });

  factory Client.fromJson(Map<String, dynamic> j) => Client(
        id: (j['id'] as num?)?.toInt() ?? 0,
        name: (j['name'] ?? '').toString(),
        kind: (j['kind'] ?? 'client').toString(),
        phone: (j['phone'] ?? '').toString(),
        email: (j['email'] ?? '').toString(),
        summary: (j['summary'] ?? '').toString(),
        tags: (j['tags'] ?? '').toString(),
        createdAt: (j['createdAt'] as num?)?.toInt() ?? 0,
        updatedAt: (j['updatedAt'] as num?)?.toInt() ?? 0,
      );

  static List<Client> listFromJson(dynamic j) {
    if (j is! List) return const [];
    return j
        .whereType<Map>()
        .map((m) => Client.fromJson(m.cast<String, dynamic>()))
        .where((c) => c.id > 0)
        .toList(growable: false);
  }
}

/// One dated case/visit note ("allergic to penicillin", "hearing moved
/// to Friday"). Created from the detail screen or by voice:
/// "note for patient Ramesh: …".
class ClientNote {
  final int id;
  final int clientId;
  final String text;
  final int createdAt;

  const ClientNote({
    required this.id,
    required this.clientId,
    required this.text,
    required this.createdAt,
  });

  factory ClientNote.fromJson(Map<String, dynamic> j) => ClientNote(
        id: (j['id'] as num?)?.toInt() ?? 0,
        clientId: (j['clientId'] as num?)?.toInt() ?? 0,
        text: (j['text'] ?? '').toString(),
        createdAt: (j['createdAt'] as num?)?.toInt() ?? 0,
      );

  static List<ClientNote> listFromJson(dynamic j) {
    if (j is! List) return const [];
    return j
        .whereType<Map>()
        .map((m) => ClientNote.fromJson(m.cast<String, dynamic>()))
        .where((n) => n.id > 0)
        .toList(growable: false);
  }
}
