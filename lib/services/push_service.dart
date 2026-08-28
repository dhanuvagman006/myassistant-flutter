import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:myassistant/services/api_service.dart';

import '../core/log.dart';

/// Registers this device with the backend so other people's agents can
/// reach the user.
///
/// The FCM token is stored against the USER's row, so registering it needs
/// a signed-in session. This used to run from main() before sign-in: the
/// PUT went out unauthenticated, failed silently, and no token was ever
/// stored — so a message from someone else's agent produced no
/// notification at all and only surfaced whenever the app next happened to
/// be opened. Registration is therefore split in two:
///
///   init()       at startup — listeners only, no permission prompt, no
///                network. Safe before anyone has signed in.
///   syncToken()  after sign-in — asks permission, then registers.
///
/// syncToken() is idempotent and re-tries on every call until it succeeds,
/// because the first attempt can legitimately fail (offline, permission
/// not yet granted) and a device that never registers is a person who
/// silently stops receiving messages.
class PushService {
  PushService._();
  static final PushService instance = PushService._();

  bool _listenerAttached = false;
  String? _registeredToken;

  /// Startup wiring. Deliberately does NOT request permission: at cold
  /// start the user has not seen the app yet, and a notification prompt
  /// before sign-in is both confusing and likely to be denied — which on
  /// Android is a decision that is awkward to reverse.
  Future<void> init() async {
    if (_listenerAttached) return;
    try {
      FirebaseMessaging.instance.onTokenRefresh.listen((token) {
        // A refreshed token makes the stored one dead, so push it up
        // immediately rather than waiting for the next sign-in.
        _registeredToken = null;
        _send(token);
      });
      _listenerAttached = true;
    } catch (e) {
      AppLog.add('push', 'init failed: $e');
    }
  }

  /// Called once the user is signed in. Requests notification permission
  /// (the Android 13+ runtime prompt happens here) and registers the token.
  Future<void> syncToken() async {
    try {
      final settings = await FirebaseMessaging.instance.requestPermission();
      final status = settings.authorizationStatus;
      if (status != AuthorizationStatus.authorized &&
          status != AuthorizationStatus.provisional) {
        AppLog.add('push', 'permission ${status.name} — no notifications');
        return;
      }

      final token = await FirebaseMessaging.instance.getToken();
      if (token == null) {
        AppLog.add('push', 'no FCM token available');
        return;
      }
      if (token == _registeredToken) return; // already stored this one
      await _send(token);
    } catch (e) {
      AppLog.add('push', 'sync failed: $e');
    }
  }

  Future<void> _send(String token) async {
    // sendJson returns null on ANY failure, including 401. Only remember
    // the token as registered when the server actually accepted it, so a
    // failed attempt is retried instead of being assumed done.
    final r = await ApiService.sendJson(
      '/profile/details',
      method: 'PUT',
      body: {'fcm_token': token},
    );
    if (r != null) {
      _registeredToken = token;
      AppLog.add('push', 'device registered for notifications');
    } else {
      AppLog.add('push', 'registration rejected — will retry');
    }
  }
}
