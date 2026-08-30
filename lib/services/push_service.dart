import 'package:firebase_app_installations/firebase_app_installations.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:myassistant/services/api_service.dart';

import '../core/log.dart';
import '../features/assistant/state/assistant_engine.dart';
import 'brief_service.dart';

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

      // AGENT-TO-AGENT DELIVERY, receiving half. The push is only a nudge
      // (no message text on the lock screen); the words come from our own
      // inbox and are SPOKEN by Hari — that is the product: your assistant
      // tells you, you don't read a banner.
      FirebaseMessaging.onMessage.listen((m) {
        // App is open in the foreground — speak it right now.
        if (m.data['kind'] == 'agent_message') {
          AppLog.add('push', 'agent message arrived (foreground)');
          AssistantEngine.instance.announceIncomingMessages();
          BriefService.instance.refresh(force: true);
        }
      });
      FirebaseMessaging.onMessageOpenedApp.listen((m) {
        // User tapped the notification — the app is coming to front.
        if (m.data['kind'] == 'agent_message') {
          AppLog.add('push', 'agent message opened from notification');
          AssistantEngine.instance.announceIncomingMessages();
          BriefService.instance.refresh(force: true);
        }
      });
      // Cold start FROM the notification (app was killed).
      FirebaseMessaging.instance.getInitialMessage().then((m) {
        if (m != null && m.data['kind'] == 'agent_message') {
          AppLog.add('push', 'agent message launched the app');
          AssistantEngine.instance.announceIncomingMessages();
        }
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

      // ONE-TIME identity reset. Devices that ran early builds carry a
      // Firebase installation FCM no longer recognises: every token minted
      // from it comes back "NotRegistered" on send, getToken() serves the
      // dead value from cache in milliseconds, and no push ever arrives.
      // The cure is deleteToken() FIRST (purges the local cache while the
      // old installation still exists) then an installations reset, so the
      // next mint happens under a fresh identity. Done once, remembered in
      // prefs — repeating it every launch would kill each good token at
      // the following startup.
      final prefs = await SharedPreferences.getInstance();
      // v2: the project finally has this package registered as a real
      // Firebase Android app (it was com.example.myassistant only — every
      // token ever minted was unsendable). One more clean mint under the
      // correct app id.
      if (!(prefs.getBool('fcm_identity_reset_v2') ?? false)) {
        try {
          await FirebaseMessaging.instance
              .deleteToken()
              .timeout(const Duration(seconds: 8));
          AppLog.add('push', 'token cache purged');
        } catch (e) {
          AppLog.add('push', 'deleteToken skipped: $e');
        }
        try {
          await FirebaseInstallations.instance
              .delete()
              .timeout(const Duration(seconds: 8));
          AppLog.add('push', 'installation reset ok');
        } catch (e) {
          AppLog.add('push', 'installation reset failed: $e');
        }
        await prefs.setBool('fcm_identity_reset_v2', true);
      }
      final token = await FirebaseMessaging.instance
          .getToken()
          .timeout(const Duration(seconds: 25));
      AppLog.add('push', 'token ${token == null ? "null" : token.substring(0, 12)}');
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
