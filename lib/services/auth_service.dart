import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'net_status.dart';
import 'package:http/http.dart' as http;
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import '../core/log.dart';
import 'api_service.dart';
import 'push_service.dart';

/// A signed-in user, as returned by the backend.
class AppUser {
  final int id;
  final String? email;
  final String? name;
  final String provider; // email | google | apple
  final String? gender; // male | female | other | null (unset)
  final String? birthday; // YYYY-MM-DD | null

  /// The verified number in E.164, or null if none is on the account.
  final String? phone;

  /// Whether the number was proven by SMS OTP. An account without this
  /// cannot be addressed by another person's agent, so the app treats it
  /// as not yet finished signing up.
  final bool phoneVerified;

  const AppUser({
    required this.id,
    this.email,
    this.name,
    required this.provider,
    this.gender,
    this.birthday,
    this.phone,
    this.phoneVerified = false,
  });

  factory AppUser.fromJson(Map<String, dynamic> j) => AppUser(
        id: j['id'] as int,
        email: j['email'] as String?,
        name: j['name'] as String?,
        provider: (j['provider'] as String?) ?? 'email',
        gender: j['gender'] as String?,
        birthday: j['birthday'] as String?,
        phone: j['phone'] as String?,
        phoneVerified: j['phoneVerified'] == true,
      );
}

/// Thrown with a message safe to show directly in the UI.
class AuthException implements Exception {
  final String message;
  const AuthException(this.message);
  @override
  String toString() => message;
}

/// ALL sign-in flows end the same way: the backend returns a session token
/// (30-day JWT) + the user. We keep the token in secure storage and attach
/// it to every API call. Google/Apple are only used once, to prove identity
/// to the backend — the app never has to refresh their tokens.
class AuthService extends ChangeNotifier {
  AuthService._();
  static final AuthService instance = AuthService._();

  static const _storage = FlutterSecureStorage();
  static const _tokenKey = 'session_token';

  /// Must match the backend's GOOGLE_WEB_CLIENT_ID.
  /// Pass with: --dart-define=GOOGLE_WEB_CLIENT_ID=xxx.apps.googleusercontent.com
  ///
  /// 2026-09-23: moved from project 75982680339 (an account the owner can
  /// no longer administer) to 745518568956 (myassistant658). The server
  /// accepts the old client too (GOOGLE_WEB_CLIENT_ID_LEGACY) until every
  /// install is on this build.
  static const _googleWebClientId = String.fromEnvironment(
  'GOOGLE_WEB_CLIENT_ID',
  defaultValue: '745518568956-211gq0mf70kv5lq58nnv9k9gmfe9i3i1.apps.googleusercontent.com',
  );
  final _google = GoogleSignIn(
    serverClientId: _googleWebClientId.isEmpty ? null : _googleWebClientId,
  );

  /// Separate instance for the DATA link (Gmail + Calendar, read-only).
  /// forceCodeForRefreshToken makes Google hand us a serverAuthCode the
  /// backend can exchange for a long-lived refresh token.
  final _googleData = GoogleSignIn(
    serverClientId: _googleWebClientId.isEmpty ? null : _googleWebClientId,
    forceCodeForRefreshToken: true,
    scopes: const [
      'https://www.googleapis.com/auth/gmail.readonly',
      // D2 — reply drafts (kept: the draft fallback still uses it).
      'https://www.googleapis.com/auth/gmail.compose',
      // 2026-09-19 — the assistant now SENDS after a spoken confirmation
      // (same contract as the app-password path). Existing links without
      // this scope gracefully fall back to leaving a draft.
      'https://www.googleapis.com/auth/gmail.send',
      'https://www.googleapis.com/auth/calendar.readonly',
      // D3 — voice/preview event creation and edits.
      'https://www.googleapis.com/auth/calendar.events',
    ],
  );

  /// Ask for Gmail+Calendar access and hand the one-time code to the
  /// backend. Throws AuthException with a user-safe message on failure.
  Future<void> linkGoogleData() async {
    GoogleSignInAccount? account;
    try {
      account = await _googleData.signIn();
    } catch (_) {
      throw const AuthException('Google sign-in failed. Please try again.');
    }
    if (account == null) throw const AuthException('');
    final code = account.serverAuthCode;
    if (code == null) {
      throw const AuthException(
          "We couldn't connect your Google account just now. Please try again in a moment.");
    }
    await ApiService.connectGoogle(code);
  }

  AppUser? user;
  bool get isSignedIn => user != null;

  /// True right after a BRAND-NEW account was created (any provider) —
  /// the gate in main.dart uses this to show the one-time sign-up
  /// interview before landing on the home shell.
  bool lastSignInWasNew = false;

  /// Apple sign-in is iOS-only for now (Android needs a web-redirect setup).
  bool get appleAvailable => !kIsWeb && Platform.isIOS;

  /// Restore the previous session on app launch.
  /// Offline-friendly: if the server can't be reached we keep the saved
  /// session instead of logging the user out.
  ///
  /// INSTANT START: with a cached identity this returns without touching
  /// the network — the splash was costing every single launch a full
  /// /auth/me round-trip (up to 8s on a weak signal). The token is still
  /// validated, just in the background; a revoked one signs out a moment
  /// later instead of making every honest launch pay for the check.
  static const _userCacheKey = 'auth_user_json_v1';

  /// True once [init] has finished its first run for this process.
  ///
  /// The app root rebuilds its whole tree on a theme change, which
  /// destroys and recreates AuthGate — so without this the splash screen
  /// reappeared and the session was restored again every time the theme
  /// flipped, which adaptive mode does on its own at dusk and dawn.
  bool restored = false;

  Future<void> init() async {
    // A 401 mid-session means the account is gone (deleted from the admin
    // panel) or the token died. Re-verify against /auth/me — one flaky
    // proxy response must not log anyone out — then sign out for real, so
    // the app returns to the login screen instead of showing a ghost
    // account until the next cold start.
    ApiService.onSessionRejected = _onSessionRejected;
    String? token;
    try {
      token = await _storage.read(key: _tokenKey);
    } catch (e) {
      // Keystore hiccup (backup restore, OS update) — treat as signed out
      // rather than crash the launch.
      AppLog.add('auth', 'token read failed: $e');
    }
    if (token == null) {
      restored = true;
      return;
    }
    ApiService.sessionToken = token;
    _runSignInHooks(); // a restored session counts as signed in
    String? cached;
    try {
      cached = await _storage.read(key: _userCacheKey);
    } catch (_) {}
    if (cached != null) {
      try {
        user = AppUser.fromJson(jsonDecode(cached));
        restored = true;
        notifyListeners();
        _validate(token); // background — no launch stall
        return;
      } catch (_) {} // corrupt cache → fall through to the blocking path
    }
    await _validate(token);
    restored = true;
    notifyListeners();
  }

  Future<void> _validate(String token) async {
    try {
      final r = await http.get(
        Uri.parse('${ApiService.baseUrl}/auth/me'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 8));
      if (r.statusCode == 200) {
        final body = jsonDecode(r.body);
        final m = body['user'];
        user = AppUser.fromJson(m);
        _storage.write(key: _userCacheKey, value: jsonEncode(m));
        _adoptRenewedToken(body);
        // Returning user: re-assert the token. FCM rotates it on reinstall,
        // restore and app-data clear, and a stale token silently drops
        // every notification.
        PushService.instance.syncToken();
      } else if (r.statusCode == 401) {
        sessionEnded = true;
        await _clear(); // token expired or account gone
      } else {
        // Server hiccup — stay signed in with the cached identity.
        user ??= const AppUser(id: -1, provider: 'cached');
      }
    } catch (_) {
      user ??= const AppUser(id: -1, provider: 'cached'); // offline — stay signed in
    }
    notifyListeners();
  }

  /// Re-fetch the account (e.g. after the onboarding survey updated
  /// name/gender) so the avatar and greetings pick changes up at once.
  Future<void> refreshUser() async {
    final token = ApiService.sessionToken;
    if (token == null) return;
    try {
      final r = await http.get(
        Uri.parse('${ApiService.baseUrl}/auth/me'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 8));
      if (r.statusCode == 200) {
        final m = jsonDecode(r.body)['user'];
        user = AppUser.fromJson(m);
        _storage.write(key: _userCacheKey, value: jsonEncode(m));
        notifyListeners();
      }
    } catch (_) {}
  }

  // ---------------- EMAIL ----------------

  Future<void> signUp(
          {required String email,
          required String password,
          String? name,
          String? gender}) =>
      _post('/auth/signup',
          {'email': email, 'password': password, 'name': name, 'gender': gender});

  /// Set or change the user's gender (used by social sign-ins that have no
  /// sign-up form, and by settings later).
  Future<void> setGender(String gender) async {
    final token = ApiService.sessionToken;
    if (token == null) return;
    try {
      final r = await http.patch(
        Uri.parse('${ApiService.baseUrl}/auth/me'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'gender': gender}),
      ).timeout(const Duration(seconds: 8));
      if (r.statusCode == 200) {
        user = AppUser.fromJson(jsonDecode(r.body)['user']);
        notifyListeners();
      }
    } catch (_) {
      // Non-fatal — the avatar just uses the default until next sync.
    }
  }

  Future<void> logIn({required String email, required String password}) =>
      _post('/auth/login', {'email': email, 'password': password});

  // ---------------- GOOGLE ----------------

  Future<void> signInWithGoogle() async {
    final account = await _google.signIn();
    // Backing out of the Google sheet is a choice, not an error: an empty
    // message keeps the red error box hidden.
    if (account == null) throw const AuthException('');
    final idToken = (await account.authentication).idToken;
    if (idToken == null) {
      throw const AuthException(
          "We couldn't sign you in with Google just now. Please try again in a moment.");
    }
    await _post('/auth/google', {'idToken': idToken});
  }

  // ---------------- APPLE ----------------

  Future<void> signInWithApple() async {
    final cred = await SignInWithApple.getAppleIDCredential(
      scopes: [AppleIDAuthorizationScopes.email, AppleIDAuthorizationScopes.fullName],
    );
    if (cred.identityToken == null) {
      throw const AuthException('Apple sign-in failed. Please try again.');
    }
    // Apple sends the name ONLY on the very first sign-in — forward it
    // so the backend can store it.
    final name = [cred.givenName, cred.familyName]
        .where((s) => s != null && s.isNotEmpty)
        .join(' ');
    await _post('/auth/apple', {
      'identityToken': cred.identityToken,
      if (name.isNotEmpty) 'name': name,
    });
  }

  // ---------------- SESSION ----------------

  Future<void> signOut() async {
    try {
      await _google.signOut();
    } catch (_) {}
    await _clear();
    notifyListeners();
  }

  /// Set when the server ended the session (expired or revoked), so the
  /// login screen can say so instead of silently appearing.
  bool sessionEnded = false;

  /// /auth/me hands back a fresh token once the current one is a week old
  /// (sliding renewal) — keep it so regular users are never signed out.
  void _adoptRenewedToken(dynamic body) {
    final fresh = body is Map ? body['token'] : null;
    if (fresh is String && fresh.isNotEmpty && fresh != ApiService.sessionToken) {
      ApiService.sessionToken = fresh;
      _storage.write(key: _tokenKey, value: fresh).catchError((_) {});
    }
  }

  bool _rejectCheckRunning = false;

  Future<void> _onSessionRejected() async {
    if (_rejectCheckRunning || !isSignedIn) return;
    _rejectCheckRunning = true;
    try {
      final token = ApiService.sessionToken;
      if (token == null) return;
      final r = await http.get(
        Uri.parse('${ApiService.baseUrl}/auth/me'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 8));
      // Only an authoritative 401 signs the user out; network errors and
      // 5xx keep the session — the account may be fine and the server not.
      if (r.statusCode == 401) {
        sessionEnded = true; // the login screen explains why
        await _clear();
        notifyListeners(); // AuthGate swaps to the login screen
      }
    } catch (_) {
      // Unreachable server proves nothing about the account.
    } finally {
      _rejectCheckRunning = false;
    }
  }

  /// Run on every way out — sign-out, a rejected session, a deleted account.
  /// Services holding the previous user's data register here: the home
  /// brief (agenda, promises, messages) survived sign-out and was shown to
  /// the next account, and the assistant's live session kept streaming.
  /// A hook list rather than direct calls, so this file needs no imports
  /// of the services that depend on it.
  final List<Future<void> Function()> _signOutHooks = [];
  void onSignOut(Future<void> Function() hook) => _signOutHooks.add(hook);

  /// The other side: run once there is a session — a restored one at
  /// launch, or a fresh sign-in. The AI brain signs its Firebase identity
  /// in here (lib/ai/identity.dart). Not awaited: nothing waits on them.
  final List<Future<void> Function()> _signInHooks = [];
  void onSignIn(Future<void> Function() hook) => _signInHooks.add(hook);

  void _runSignInHooks() {
    for (final hook in _signInHooks) {
      hook().catchError((_) {});
    }
  }

  Future<void> _clear() async {
    user = null;
    ApiService.sessionToken = null;
    await _storage.delete(key: _tokenKey);
    await _storage.delete(key: _userCacheKey);
    for (final hook in _signOutHooks) {
      try {
        await hook();
      } catch (_) {
        // One service failing to clean up must not keep the user signed in.
      }
    }
  }

  /// Permanently deletes the account on the server, then signs out here.
  /// Throws (and stays signed in) if the server refused.
  Future<void> deleteAccount() async {
    await ApiService.deleteMyAccount();
    await signOut();
  }

  /// Shared tail of every flow: call the backend, store token, set user.
  Future<void> _post(String path, Map<String, dynamic> body) async {
    late http.Response r;
    try {
      r = await http
          .post(
            Uri.parse('${ApiService.baseUrl}$path'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 20));
    } catch (_) {
      // Say which it is: their internet, or our server (2026-10-09).
      await NetStatus.instance.check();
      throw AuthException(NetStatus.instance.state.value == NetState.offline
          ? 'No internet connection. Check Wi-Fi or mobile data and try again.'
          : 'Could not reach the server. Please try again in a moment.');
    }

    final Map<String, dynamic> data;
    try {
      data = jsonDecode(r.body) as Map<String, dynamic>;
    } catch (_) {
      throw AuthException(r.statusCode == 429
          ? 'Too many sign-in attempts just now. Please wait a few minutes and try again.'
          : "We couldn't sign you in just now. Please try again in a moment.");
    }

    if (r.statusCode != 200) {
      final msg = data['error'] as String?;
      throw AuthException(msg == null || msg.isEmpty
          ? "We couldn't sign you in just now. Please try again in a moment."
          : msg[0].toUpperCase() + msg.substring(1));
    }

    final token = data['token'] as String;
    sessionEnded = false;
    await _storage.write(key: _tokenKey, value: token);
    ApiService.sessionToken = token;
    user = AppUser.fromJson(data['user']);
    lastSignInWasNew = (data['isNew'] as bool?) ?? false;
    // Register this device NOW that there is a session to attach it to.
    // Doing it at app start meant the request went out unauthenticated and
    // the token was never stored, so incoming agent messages arrived with
    // no notification at all. Not awaited — sign-in must not wait on a
    // permission prompt.
    PushService.instance.syncToken();
    _runSignInHooks();
    notifyListeners();
  }
}
