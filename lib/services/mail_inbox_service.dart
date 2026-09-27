import 'package:flutter/foundation.dart';

import '../models/mail_inbox.dart';
import 'api_service.dart';

typedef MailGet = Future<Map<String, dynamic>?> Function(String path);
typedef MailPost = Future<Map<String, dynamic>?> Function(String path, Object body);

/// BILLS BY EMAIL (build 120) — talks to /mailin. Every call answers null
/// on any failure, and the screen shows its error state. The card in You
/// and the screen are shown only when the server says `available`, which
/// it does only once the owner has switched the feature on.
class MailInboxService {
  MailInboxService({MailGet? get, MailPost? post})
      : _get = get ?? ((p) => ApiService.getJson(p)),
        _post = post ?? ((p, b) => ApiService.postJson(p, b));

  static final MailInboxService instance = MailInboxService();

  final MailGet _get;
  final MailPost _post;

  final ValueNotifier<MailInboxState?> state = ValueNotifier<MailInboxState?>(null);

  bool get available => state.value?.available == true;

  Future<MailInboxState?> refresh() async {
    final j = await _get('/mailin');
    if (j == null) return state.value;
    final s = MailInboxState.fromJson(j);
    state.value = s;
    return s;
  }

  MailAddress? _address(Map<String, dynamic>? j) {
    final a = j == null ? null : MailAddress.fromJson(j['address']);
    if (a != null && state.value != null) state.value = state.value!.copyWith(address: a);
    return a;
  }

  Future<MailAddress?> turnOn() async => _address(await _post('/mailin/address', const {}));

  Future<MailAddress?> setOn(bool on) async =>
      _address(await _post('/mailin/address/state', {'on': on}));

  Future<MailAddress?> rotate() async => _address(await _post('/mailin/address/rotate', const {}));

  Future<List<MailItem>?> recent() async {
    final j = await _get('/mailin/messages?limit=20');
    return j == null ? null : MailItem.listFromJson(j['messages']);
  }

  /// "Set reminders" — the user's own tap, for a sender nobody vouched for.
  Future<bool> remindAnyway(int id) async =>
      await _post('/mailin/messages/$id/remind', const {}) != null;

  /// "This was me" — trust that sending address and set the reminders.
  Future<bool> trust(int id) async {
    final j = await _post('/mailin/messages/$id/trust', const {});
    if (j == null) return false;
    final list = j['trustedFrom'];
    if (list is List && state.value != null) {
      state.value = state.value!.copyWith(trustedFrom: list.map((e) => '$e').toList());
    }
    return true;
  }

  Future<bool> untrust(String address) async {
    final j = await _post('/mailin/trusted/remove', {'address': address});
    if (j == null) return false;
    final list = j['trustedFrom'];
    if (state.value != null) {
      state.value = state.value!.copyWith(
          trustedFrom: list is List ? list.map((e) => '$e').toList() : const []);
    }
    return true;
  }
}
