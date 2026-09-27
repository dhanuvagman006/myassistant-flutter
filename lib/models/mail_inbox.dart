/// BILLS BY EMAIL (build 120) — the user's private address and what the
/// emails sent to it became. Every parser tolerates missing keys: a server
/// without the feature answers nothing, and the card simply stays hidden.
library;

int _int(Object? v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}') ?? 0;
String _str(Object? v) => v == null ? '' : v.toString();

class MailAddress {
  final String address;
  final String status; // active | off
  final int createdAt;
  const MailAddress({required this.address, required this.status, this.createdAt = 0});

  bool get on => status == 'active';

  static MailAddress? fromJson(Object? j) {
    if (j is! Map) return null;
    final a = _str(j['address']);
    if (a.isEmpty) return null;
    return MailAddress(address: a, status: _str(j['status']), createdAt: _int(j['createdAt']));
  }
}

class MailReminder {
  final int id;
  final String text;
  final int atMs;
  const MailReminder({required this.id, required this.text, required this.atMs});

  static List<MailReminder> listFromJson(Object? j) => j is List
      ? j
          .whereType<Map>()
          .map((m) => MailReminder(id: _int(m['id']), text: _str(m['text']), atMs: _int(m['atMs'])))
          .where((r) => r.text.isNotEmpty)
          .toList(growable: false)
      : const [];
}

class MailSkipped {
  final String name;
  final String why;
  const MailSkipped(this.name, this.why);
}

class MailItem {
  final int id;
  final int receivedAt;
  final String subject;
  final String from; // the sending DOMAIN, or "You"
  final String auth; // you | verified | personal | unverified
  final bool verified;
  final String? fromAddress; // only on 'personal' rows, for "This was me"
  final String status; // saved | already_saved | not_saved | couldnt_read | confirm_code | processing
  final String reason;
  final String kind;
  final List<int> documentIds;
  final List<MailReminder> reminders;
  final bool remindersDone;
  final List<MailSkipped> skipped;
  final String? confirmCode;

  const MailItem({
    required this.id,
    this.receivedAt = 0,
    this.subject = '',
    this.from = '',
    this.auth = 'unverified',
    this.verified = false,
    this.fromAddress,
    this.status = 'processing',
    this.reason = '',
    this.kind = '',
    this.documentIds = const [],
    this.reminders = const [],
    this.remindersDone = false,
    this.skipped = const [],
    this.confirmCode,
  });

  bool get isPersonal => auth == 'personal';

  /// Saved, but nobody vouched for the sender: reminders wait for a tap.
  bool get needsReminderTap =>
      status == 'saved' && !remindersDone && reminders.isEmpty && !verified;

  factory MailItem.fromJson(Map<String, dynamic> j) {
    final fa = _str(j['fromAddress']);
    final code = _str(j['confirmCode']);
    return MailItem(
      id: _int(j['id']),
      receivedAt: _int(j['receivedAt']),
      subject: _str(j['subject']),
      from: _str(j['from']),
      auth: _str(j['auth']).isEmpty ? 'unverified' : _str(j['auth']),
      verified: j['verified'] == true,
      fromAddress: fa.isEmpty ? null : fa,
      status: _str(j['status']).isEmpty ? 'processing' : _str(j['status']),
      reason: _str(j['reason']),
      kind: _str(j['kind']),
      documentIds: j['documentIds'] is List
          ? (j['documentIds'] as List).map(_int).where((i) => i > 0).toList(growable: false)
          : const [],
      reminders: MailReminder.listFromJson(j['reminders']),
      remindersDone: j['remindersDone'] == true,
      skipped: j['skipped'] is List
          ? (j['skipped'] as List)
              .whereType<Map>()
              .map((m) => MailSkipped(_str(m['name']), _str(m['why'])))
              .toList(growable: false)
          : const [],
      confirmCode: code.isEmpty ? null : code,
    );
  }

  static List<MailItem> listFromJson(Object? j) => j is List
      ? j
          .whereType<Map>()
          .map((m) => MailItem.fromJson(m.cast<String, dynamic>()))
          .where((m) => m.id > 0)
          .toList(growable: false)
      : const [];
}

class MailInboxState {
  final bool available;
  final MailAddress? address;
  final List<String> trustedFrom;
  final int maxMb;
  final int perDay;

  const MailInboxState({
    this.available = false,
    this.address,
    this.trustedFrom = const [],
    this.maxMb = 10,
    this.perDay = 25,
  });

  factory MailInboxState.fromJson(Map<String, dynamic> j) {
    final limits = j['limits'] is Map ? j['limits'] as Map : const {};
    return MailInboxState(
      available: j['available'] == true,
      address: MailAddress.fromJson(j['address']),
      trustedFrom: j['trustedFrom'] is List
          ? (j['trustedFrom'] as List).map(_str).where((s) => s.isNotEmpty).toList(growable: false)
          : const [],
      maxMb: _int(limits['maxMb']) > 0 ? _int(limits['maxMb']) : 10,
      perDay: _int(limits['perDay']) > 0 ? _int(limits['perDay']) : 25,
    );
  }

  MailInboxState copyWith({MailAddress? address, List<String>? trustedFrom}) => MailInboxState(
        available: available,
        address: address ?? this.address,
        trustedFrom: trustedFrom ?? this.trustedFrom,
        maxMb: maxMb,
        perDay: perDay,
      );
}
