import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

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
  static const _googleWebClientId = String.fromEnvironment(
  'GOOGLE_WEB_CLIENT_ID',
  defaultValue: '75982680339-lhs2k8cs72ml5eh2crte0e487c7fla9u.apps.googleusercontent.com',
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
      // D2 — reply DRAFTS only (compose never grants sending on our path;
      // the user reviews and taps Send inside Gmail themselves).
      'https://www.googleapis.com/auth/gmail.compose',
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
    if (account == null) throw const AuthException('Connection cancelled.');
    final code = account.serverAuthCode;
    if (code == null) {
      throw const AuthException(
          'Google did not return an auth code — check GOOGLE_WEB_CLIENT_ID.');
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

  Future<void> init() async {
    final token = await _storage.read(key: _tokenKey);
    if (token == null) return;
    ApiService.sessionToken = token;
    final cached = await _storage.read(key: _userCacheKey);
    if (cached != null) {
      try {
        user = AppUser.fromJson(jsonDecode(cached));
        notifyListeners();
        _validate(token); // background — no launch stall
        return;
      } catch (_) {} // corrupt cache → fall through to the blocking path
    }
    await _validate(token);
    notifyListeners();
  }

  Future<void> _validate(String token) async {
    try {
      final r = await http.get(
        Uri.parse('${ApiService.baseUrl}/auth/me'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 8));
      if (r.statusCode == 200) {
        final m = jsonDecode(r.body)['user'];
        user = AppUser.fromJson(m);
        _storage.write(key: _userCacheKey, value: jsonEncode(m));
        // Returning user: re-assert the token. FCM rotates it on reinstall,
        // restore and app-data clear, and a stale token silently drops
        // every notification.
        PushService.instance.syncToken();
      } else if (r.statusCode == 401) {
        await _clear(); // token expired or account gone
      } else if (user == null) {
        user = const AppUser(id: -1, provider: 'cached'); // server hiccup — stay signed in
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
    if (account == null) throw const AuthException('Sign-in cancelled.');
    final idToken = (await account.authentication).idToken;
    if (idToken == null) {
      throw const AuthException(
          'Google did not return an ID token — check GOOGLE_WEB_CLIENT_ID.');
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

  Future<void> _clear() async {
    user = null;
    ApiService.sessionToken = null;
    await _storage.delete(key: _tokenKey);
    await _storage.delete(key: _userCacheKey);
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
      throw const AuthException('Could not reach the server. Check your connection.');
    }

    final Map<String, dynamic> data;
    try {
      data = jsonDecode(r.body) as Map<String, dynamic>;
    } catch (_) {
      throw const AuthException('Unexpected server response. Please try again.');
    }

    if (r.statusCode != 200) {
      throw AuthException((data['error'] as String?) ?? 'Sign-in failed (${r.statusCode}).');
    }

    final token = data['token'] as String;
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
    notifyListeners();
  }
}
