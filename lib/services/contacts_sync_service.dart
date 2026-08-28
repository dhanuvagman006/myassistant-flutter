import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_service.dart';
import 'call_service.dart';
import '../core/log.dart';

/// Mirrors the phone's address book so the assistant can resolve a name.
///
/// "Tell mom I'll be late" is handled by a tool running on the server, in
/// the middle of the model's turn. It cannot stop and ask the handset who
/// "mom" is, so the name→number mapping has to already be there.
///
/// Only names and numbers are sent — not emails, photos, addresses or any
/// of the other fields the address book holds. Nothing is read or uploaded
/// until the user has granted contacts permission.
class ContactsSyncService {
  ContactsSyncService._();
  static final ContactsSyncService instance = ContactsSyncService._();

  static const _lastSyncKey = 'contacts_last_sync_ms';

  /// Re-sync at most this often. The address book changes rarely, and a
  /// sync on every launch would be a lot of data for no new information.
  static const _minInterval = Duration(hours: 12);

  bool _running = false;

  /// Sync if permission is already granted and enough time has passed.
  /// Never prompts, so it is safe to call on launch.
  Future<void> maybeSync({bool force = false}) async {
    if (_running) return;
    _running = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final last = prefs.getInt(_lastSyncKey) ?? 0;
      final due = DateTime.now().millisecondsSinceEpoch - last > _minInterval.inMilliseconds;
      if (!force && !due) return;

      if (!await CallService.instance.ensurePermission()) {
        AppLog.add('contacts', 'permission not granted — skipping sync');
        return;
      }

      final all = await FlutterContacts.getContacts(withProperties: true);
      final payload = <Map<String, String>>[];
      for (final c in all) {
        if (c.phones.isEmpty) continue;
        final name = c.displayName.trim();
        if (name.isEmpty) continue;
        // Every number, not just the best one: relatives are often saved
        // under a landline as well as a mobile, and the person we are
        // trying to reach may have registered with either.
        for (final p in c.phones) {
          final number = p.number.trim();
          if (number.isEmpty) continue;
          payload.add({'name': name, 'phone': number});
        }
      }
      if (payload.isEmpty) return;

      final r = await ApiService.sendJson('/contacts/sync',
          method: 'POST', body: {'contacts': payload});
      if (r != null) {
        await prefs.setInt(
            _lastSyncKey, DateTime.now().millisecondsSinceEpoch);
        AppLog.add('contacts', 'synced ${r['stored'] ?? 0} numbers');
      }
    } catch (e) {
      // Never fatal: a failed sync only means the assistant may not know a
      // name yet, and the next launch tries again.
      AppLog.add('contacts', 'sync failed: $e');
    } finally {
      _running = false;
    }
  }
}
