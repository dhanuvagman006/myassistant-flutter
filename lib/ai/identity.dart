// IDENTITY — what Firebase AI Logic needs before it answers this app:
//
//  1. APP CHECK (required from 2026-11-02). App Distribution builds are
//     sideloaded, so Play Integrity cannot vouch for them: they carry a
//     debug token the owner registered in the console, compiled in with
//     --dart-define=APP_CHECK_DEBUG_TOKEN=… (tool/build_apk.sh reads it
//     from the git-ignored android/app-check-debug-token.txt; it is never
//     committed). Without that define, Play Integrity (App Attest with
//     DeviceCheck fallback on iOS).
//  2. A FIREBASE USER (AI Logic's authentication mode + per-user limits).
//     Our backend mints a custom token for "u<id>" (POST /ai/firebase-token)
//     and firebase_auth signs in with it. This is not phone sign-in: SMS
//     codes stay removed. Firebase keeps the session across launches and
//     refreshes its ID token itself.
//
// main.dart calls [AiIdentity.start] once Firebase is up; AuthService's
// sign-in and sign-out hooks do the rest.
import 'dart:async';

import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../services/auth_service.dart';
import 'config.dart';
import 'tool_server.dart';

const _debugTokenDefine = String.fromEnvironment('APP_CHECK_DEBUG_TOKEN');

abstract interface class AppCheckPort {
  /// [debugToken] non-empty: the debug provider with that token.
  Future<void> activate({required String debugToken});
}

class FirebaseAppCheckPort implements AppCheckPort {
  @override
  Future<void> activate({required String debugToken}) {
    final debug = debugToken.isNotEmpty;
    return FirebaseAppCheck.instance.activate(
      providerAndroid: debug
          ? AndroidDebugProvider(debugToken: debugToken)
          : const AndroidPlayIntegrityProvider(),
      providerApple: debug
          ? AppleDebugProvider(debugToken: debugToken)
          : const AppleAppAttestWithDeviceCheckFallbackProvider(),
    );
  }
}

abstract interface class FirebaseAuthPort {
  String? get uid;

  /// The signed-in uid.
  Future<String?> signInWithCustomToken(String token);
  Future<void> signOut();
}

class FirebaseAuthAdapter implements FirebaseAuthPort {
  @override
  String? get uid => FirebaseAuth.instance.currentUser?.uid;

  @override
  Future<String?> signInWithCustomToken(String token) async =>
      (await FirebaseAuth.instance.signInWithCustomToken(token)).user?.uid;

  @override
  Future<void> signOut() => FirebaseAuth.instance.signOut();
}

class AiIdentity {
  AiIdentity({
    AppCheckPort? appCheck,
    FirebaseAuthPort? auth,
    Future<FirebaseTokenResult?> Function()? mintToken,
    String? Function()? expectedUid,
    this.debugToken = _debugTokenDefine,
  })  : _appCheck = appCheck ?? FirebaseAppCheckPort(),
        _auth = auth ?? FirebaseAuthAdapter(),
        _mint = mintToken ?? (() => ToolServer().firebaseToken()),
        _expectedUid = expectedUid ?? _accountUid;

  static final AiIdentity instance = AiIdentity();

  static String? _accountUid() {
    final id = AuthService.instance.user?.id;
    return id != null && id > 0 ? 'u$id' : null;
  }

  final AppCheckPort _appCheck;
  final FirebaseAuthPort _auth;
  final Future<FirebaseTokenResult?> Function() _mint;
  final String? Function() _expectedUid;

  /// Compiled in from --dart-define=APP_CHECK_DEBUG_TOKEN (App
  /// Distribution builds); empty otherwise.
  final String debugToken;

  bool _appCheckActive = false;
  bool _hooked = false;
  Future<bool>? _signingIn;

  bool get appCheckActive => _appCheckActive;

  /// Which provider vouches for this build.
  String get appCheckProvider => debugToken.isNotEmpty ? 'debug' : 'playIntegrity';

  String? get uid => _auth.uid;

  /// Once Firebase is initialised: App Check, then the AuthService hooks
  /// (sign-in -> Firebase user + fresh /ai/config; sign-out -> both gone).
  Future<void> start({AiConfigStore? configs}) async {
    final store = configs ?? AiConfigStore.instance;
    if (!_hooked) {
      _hooked = true;
      AuthService.instance.onSignIn(() async {
        await signIn();
        await store.refresh();
      });
      AuthService.instance.onSignOut(() async {
        await signOut();
        store.clear();
      });
    }
    await activateAppCheck();
  }

  /// Never throws; true once App Check is on.
  Future<bool> activateAppCheck() async {
    if (_appCheckActive) return true;
    try {
      await _appCheck.activate(debugToken: debugToken);
      _appCheckActive = true;
    } catch (_) {
      _appCheckActive = false;
    }
    return _appCheckActive;
  }

  /// Signs the Firebase user in for this account (kept when it already
  /// is). One attempt at a time; never throws; false when the backend or
  /// Firebase refused.
  Future<bool> signIn({bool force = false}) {
    return _signingIn ??= _signIn(force).whenComplete(() => _signingIn = null);
  }

  Future<bool> _signIn(bool force) async {
    try {
      final current = _auth.uid;
      final expected = _expectedUid();
      if (!force && current != null && (expected == null || current == expected)) {
        return true;
      }
      if (current != null) await _auth.signOut();
      final minted = await _mint();
      if (minted == null) return false;
      final uid = await _auth.signInWithCustomToken(minted.token);
      return uid != null;
    } catch (_) {
      return false;
    }
  }

  Future<void> signOut() async {
    try {
      await _auth.signOut();
    } catch (_) {}
  }
}
