import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

import 'api_service.dart';
import 'auth_service.dart';
import '../core/log.dart';

/// SMS verification of the user's own number, via Firebase Phone Auth.
///
/// The number is what other people's agents address messages to, so it has
/// to be PROVEN rather than typed. Firebase sends the code and, once it is
/// entered on the handset that received it, mints an ID token carrying the
/// number as a verified claim. That token — not the digits the user typed —
/// is what goes to our backend, which re-verifies it with the Admin SDK
/// before writing anything. A caller therefore cannot register a number
/// they do not control, which is what stops one person receiving another's
/// messages.
class PhoneVerifyService {
  PhoneVerifyService._();
  static final PhoneVerifyService instance = PhoneVerifyService._();

  final FirebaseAuth _fb = FirebaseAuth.instance;

  String? _verificationId;
  int? _resendToken;

  /// The number the code was sent to, for display while confirming.
  String? pendingNumber;

  /// Ask Firebase to text a code to [e164].
  ///
  /// [onAutoVerified] fires when Android resolves the SMS by itself, which
  /// is common on the sending handset — the user never sees a code, so the
  /// UI must be ready to skip straight past the entry field.
  Future<void> sendCode(
    String e164, {
    required void Function(String message) onError,
    required void Function() onCodeSent,
    required Future<void> Function(PhoneAuthCredential cred) onAutoVerified,
  }) async {
    pendingNumber = e164;
    await _fb.verifyPhoneNumber(
      phoneNumber: e164,
      forceResendingToken: _resendToken,
      verificationCompleted: onAutoVerified,
      verificationFailed: (FirebaseAuthException e) {
        AppLog.add('phone', 'verify failed: ${e.code}');
        onError(_friendly(e));
      },
      codeSent: (String id, int? token) {
        _verificationId = id;
        _resendToken = token;
        onCodeSent();
      },
      codeAutoRetrievalTimeout: (String id) => _verificationId = id,
      timeout: const Duration(seconds: 60),
    );
  }

  /// Confirm the typed code and register the number with our backend.
  /// Returns null on success, or a message safe to show the user.
  Future<String?> confirmCode(String smsCode) async {
    final id = _verificationId;
    if (id == null) return 'Request a code first.';
    try {
      return await submit(
        PhoneAuthProvider.credential(verificationId: id, smsCode: smsCode.trim()),
      );
    } on FirebaseAuthException catch (e) {
      return _friendly(e);
    }
  }

  /// Shared tail of both paths (typed code and Android auto-retrieval).
  Future<String?> submit(PhoneAuthCredential cred) async {
    try {
      final result = await _fb.signInWithCredential(cred);
      final idToken = await result.user?.getIdToken();
      if (idToken == null) return 'Could not confirm the code. Try again.';

      final r = await http.post(
        Uri.parse('${ApiService.baseUrl}/phone/verify'),
        headers: {
          'Content-Type': 'application/json',
          ...ApiService.authHeaders,
        },
        body: jsonEncode({'firebaseIdToken': idToken}),
      );

      if (r.statusCode == 409) {
        // One number, one account — deliberately not silently reassigned.
        return 'This number is already registered to another account.';
      }
      if (r.statusCode >= 300) {
        final body = jsonDecode(r.body);
        return (body is Map ? body['error'] as String? : null) ??
            'Could not register this number.';
      }

      // Refresh so the gate sees phoneVerified and lets the user through.
      await AuthService.instance.refreshUser();
      AppLog.add('phone', 'verified ${pendingNumber ?? ""}');
      return null;
    } on FirebaseAuthException catch (e) {
      return _friendly(e);
    } catch (e) {
      return 'Could not reach the server. Check your connection.';
    } finally {
      // The Firebase phone session has done its job. Leaving it signed in
      // would leave a second identity on the device that nothing else uses.
      try { await _fb.signOut(); } catch (_) {}
    }
  }

  /// Whether the backend is offering the no-OTP path. Asked rather than
  /// assumed, so the button cannot appear against a server that would
  /// refuse it — and disappears the moment the flag is turned off.
  Future<bool> devVerifyAvailable() async {
    try {
      final r = await ApiService.getJson('/phone/dev-available');
      return r != null && r['available'] == true;
    } catch (_) {
      return false;
    }
  }

  /// DEV ONLY — claim a number with no SMS. The server enforces the same
  /// normalisation and one-number-one-account rule as the real path, so
  /// everything downstream behaves identically.
  Future<String?> devVerify(String e164) async {
    try {
      final r = await http.post(
        Uri.parse('${ApiService.baseUrl}/phone/dev-verify'),
        headers: {'Content-Type': 'application/json', ...ApiService.authHeaders},
        body: jsonEncode({'phone': e164}),
      );
      if (r.statusCode >= 300) {
        final body = jsonDecode(r.body);
        return (body is Map ? body['error'] as String? : null) ??
            'Could not register this number.';
      }
      await AuthService.instance.refreshUser();
      AppLog.add('phone', 'DEV verified $e164 (no OTP)');
      return null;
    } catch (_) {
      return 'Could not reach the server.';
    }
  }

  String _friendly(FirebaseAuthException e) {
    // Firebase reports project-level misconfiguration as code 'unknown'
    // with the real reason buried in the message. CONFIGURATION_NOT_FOUND
    // means Phone sign-in is not switched on for the project, which no
    // amount of retrying fixes — say so instead of "try again".
    final detail = e.message ?? '';
    if (detail.contains('CONFIGURATION_NOT_FOUND')) {
      return 'Phone sign-in is not enabled for this Firebase project. '
          'Enable it under Authentication → Sign-in method → Phone.';
    }
    if (detail.contains('BILLING_NOT_ENABLED')) {
      return 'Firebase Phone Auth needs billing enabled on the project.';
    }
    return _byCode(e);
  }

  String _byCode(FirebaseAuthException e) => switch (e.code) {
        'invalid-phone-number' => 'That phone number does not look right.',
        'invalid-verification-code' => 'That code is not correct.',
        'session-expired' => 'The code expired. Request a new one.',
        'too-many-requests' =>
          'Too many attempts. Wait a few minutes and try again.',
        'quota-exceeded' => 'SMS limit reached. Try again later.',
        _ => e.message ?? 'Verification failed. Try again.',
      };
}
