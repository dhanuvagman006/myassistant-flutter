import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:myassistant/services/api_service.dart';

import '../core/log.dart';
import '../features/assistant/state/assistant_engine.dart';
import 'app_feedback.dart';
import 'avatar_message_service.dart';
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
        // App is open in the foreground. DON'T speak unprompted — the user
        // may be reading, in a meeting, on another screen. A quiet toast
        // + the Home feed carry the news; the voice delivers it when the
        // user opens a conversation or taps the notification.
        if (m.data['kind'] == 'agent_message') {
          AppLog.add('push', 'agent message arrived (foreground)');
          AppFeedback.toast(
              'New message from your circle — tap the mic and I\'ll read it.');
          BriefService.instance.refresh(force: true);
        }
      });
      FirebaseMessaging.onMessageOpenedApp.listen((m) {
        // User tapped the notification — the app is coming to front.
        if (m.data['kind'] == 'agent_message') {
          AppLog.add('push', 'agent message opened from notification');
          _deliver(m);
          BriefService.instance.refresh(force: true);
        }
      });
      // Cold start FROM the notification (app was killed).
      FirebaseMessaging.instance.getInitialMessage().then((m) {
        if (m != null && m.data['kind'] == 'agent_message') {
          AppLog.add('push', 'agent message launched the app');
          _deliver(m);
        }
      });
      _listenerAttached = true;
    } catch (e) {
      AppLog.add('push', 'init failed: $e');
    }
  }

  /// A tapped agent message: avatar media (the sender's AI face/voice)
  /// shows as a popup; anything without media is spoken by the assistant
  /// exactly as before. The popup service reports whether it consumed
  /// pending rows, so both can coexist in one inbox sweep.
  Future<void> _deliver(RemoteMessage m) async {
    if (m.data['avatar'] == '1') {
      final shown = await AvatarMessageService.instance.showPending();
      if (shown) {
        // Any remaining text-only rows still deserve their voice delivery.
        AssistantEngine.instance.announceIncomingMessages();
        return;
      }
    }
    final engine = AssistantEngine.instance;
    // Tapping a message notification means "tell me" — so the ASSISTANT
    // POPS UP: open the conversation screen, whose live session delivers
    // the message after the greeting and is already listening for the
    // reply. On a cold start HomeShell may not have wired the navigation
    // hook yet — wait briefly for it rather than falling back too soon.
    for (var i = 0; i < 10 && engine.onOpenConversation == null; i++) {
      await Future.delayed(const Duration(milliseconds: 500));
    }
    if (!engine.requestConversationOpen()) {
      // Conversation already on screen (or no navigator): speak in place —
      // announceIncomingMessages hands the text to the live session when
      // one is active, else reads it out over the current screen.
      engine.announceIncomingMessages();
    }
  }

  /// Called once the user is signed in. Requests notification permission
  /// (the Android 13+ runtime prompt happens here) and registers the token.
  /// [force] re-sends the token even if this process already registered
  /// it. The server PRUNES tokens FCM reports dead, and it has no way to
  /// tell the device — so a phone that trusted its in-memory "already
  /// registered" state stayed unregistered until the next cold start.
  /// Resume passes force so every return to the app re-asserts the truth.
  Future<void> syncToken({bool force = false}) async {
    try {
      if (force) _registeredToken = null;
      AppLog.add('push', 'syncToken start (force=$force)');
      // The permission reply can be LOST: on Dhanush's SM-E156B the plugin
      // delivered Firebase replies from a background thread, FlutterJNI
      // threw, and the Dart future never completed — so syncToken hung
      // here forever and the device never registered. The OS permission is
      // long granted on these phones, so on timeout we PROCEED: getToken
      // doesn't need the prompt, and worst case notifications stay hidden
      // rather than the device staying unreachable.
      try {
        final settings = await FirebaseMessaging.instance
            .requestPermission()
            .timeout(const Duration(seconds: 8));
        final status = settings.authorizationStatus;
        if (status != AuthorizationStatus.authorized &&
            status != AuthorizationStatus.provisional) {
          AppLog.add('push', 'permission ${status.name} — no notifications');
          return;
        }
      } on TimeoutException {
        AppLog.add('push', 'permission reply lost — proceeding anyway');
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
      // v4 (2026-09-05): deleteToken ONLY — no FirebaseInstallations
      // .delete(). v3 deleted the installation, and the next mint raced
      // it: the "fresh" token came out bound to the just-deleted
      // installation, so FCM rejected it as NotRegistered from birth.
      // deleteToken alone forces a re-mint under the CURRENT (healthy)
      // installation, which is all a dead-token cure needs now that the
      // wrong-package era config is history. The done-flag is only set
      // once a token is actually in hand, so a failed run retries on the
      // next launch instead of being remembered as cured.
      final resetDone = prefs.getBool('fcm_identity_reset_v5') ?? false;
      if (!resetDone) {
        try {
          await FirebaseMessaging.instance
              .deleteToken()
              .timeout(const Duration(seconds: 8));
          AppLog.add('push', 'token cache purged (v4)');
        } catch (e) {
          AppLog.add('push', 'deleteToken skipped: $e');
        }
      }
      // A fresh mint after an identity reset can take 30-60s, and this
      // device has also been seen losing the reply outright — so try a few
      // times with a pause rather than giving up on one 25s window. A
      // token minted between attempts is served from cache instantly.
      String? token;
      for (var attempt = 1; token == null && attempt <= 3; attempt++) {
        try {
          token = await FirebaseMessaging.instance
              .getToken()
              .timeout(const Duration(seconds: 20));
        } catch (e) {
          AppLog.add('push', 'getToken attempt $attempt failed: $e');
          if (attempt < 3) await Future.delayed(const Duration(seconds: 15));
        }
      }
      AppLog.add('push', 'token ${token == null ? "null" : token.substring(0, 12)}');
      if (token == null) {
        AppLog.add('push', 'no FCM token available');
        return;
      }
      if (!resetDone) await prefs.setBool('fcm_identity_reset_v5', true);
      if (token == _registeredToken) return; // already stored this one
      await _send(token);
    } catch (e) {
      AppLog.add('push', 'sync failed: $e');
    }
  }

  int _sendAttempts = 0;

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
      _sendAttempts = 0;
      AppLog.add('push', 'device registered for notifications');
    } else {
      // Actually retry, here and now. "Will retry on the next launch" left
      // phones that first opened the app offline (or mid sign-in race)
      // unregistered for days — a person who silently receives nothing.
      // Bounded: resume/sign-in call syncToken again anyway.
      if (_sendAttempts < 3) {
        _sendAttempts++;
        AppLog.add('push', 'registration rejected — retry $_sendAttempts in 30s');
        Future.delayed(const Duration(seconds: 30), () {
          if (_registeredToken != token) _send(token);
        });
      } else {
        AppLog.add('push', 'registration rejected — retries exhausted');
      }
    }
  }
}
