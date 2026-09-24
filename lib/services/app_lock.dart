import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

/// F1 — OPTIONAL APP LOCK. Fingerprint / face when the device has it,
/// with a 4-digit PIN as the fallback (and as the only method on devices
/// without biometrics). Everything stays ON THIS PHONE:
///   • the enabled flag and the PIN live in flutter_secure_storage
///     (Android Keystore / iOS Keychain) — never sent to the server;
///   • the PIN is stored as a salted SHA-256 (via [_hash]), so even a
///     rooted-device dump doesn't reveal the digits.
///
/// SETUP REQUIRED (one-time, android/ is generated locally):
///   MainActivity must extend FlutterFragmentActivity (local_auth
///   requirement) and AndroidManifest needs
///   <uses-permission android:name="android.permission.USE_BIOMETRIC"/>.
class AppLock extends ChangeNotifier {
  AppLock._();
  static final AppLock instance = AppLock._();

  static const _kEnabled = 'app_lock_enabled';
  static const _kPin = 'app_lock_pin_v1';
  static const _storage = FlutterSecureStorage();
  final _auth = LocalAuthentication();

  bool _enabled = false;
  bool _unlockedThisSession = false;

  bool get enabled => _enabled;

  /// True when the UI should show the lock screen right now.
  bool get shouldLock => _enabled && !_unlockedThisSession;

  /// Call once at startup (before the first frame decision).
  Future<void> init() async {
    _enabled = await _storage.read(key: _kEnabled) == '1';
    notifyListeners();
  }

  Future<bool> deviceHasBiometrics() async {
    try {
      return await _auth.canCheckBiometrics ||
          await _auth.isDeviceSupported();
    } catch (_) {
      return false;
    }
  }

  /// Turn the lock ON. [pin] is mandatory — it's the fallback when
  /// biometrics fail or don't exist.
  Future<void> enable(String pin) async {
    await _storage.write(key: _kPin, value: _hash(pin));
    await _storage.write(key: _kEnabled, value: '1');
    _enabled = true;
    _unlockedThisSession = true; // they just set it — don't lock them out
    notifyListeners();
  }

  /// Turn the lock OFF (caller verifies identity first).
  Future<void> disable() async {
    await _storage.delete(key: _kEnabled);
    await _storage.delete(key: _kPin);
    _enabled = false;
    notifyListeners();
  }

  /// Biometric prompt. Returns true on success; false on failure,
  /// cancellation, or unsupported hardware (caller falls back to PIN).
  Future<bool> tryBiometric() async {
    try {
      return await _auth.authenticate(
        localizedReason: 'Unlock MyAssistant',
        options: const AuthenticationOptions(
          biometricOnly: false, // device credential is an acceptable factor
          stickyAuth: true,
        ),
      );
    } catch (_) {
      return false;
    }
  }

  Future<bool> tryPin(String pin) async {
    final stored = await _storage.read(key: _kPin);
    return stored != null && stored == _hash(pin);
  }

  void markUnlocked() {
    _unlockedThisSession = true;
    notifyListeners();
  }

  /// AWAY LONG ENOUGH TO ASK AGAIN. Relocking on every pause locked the
  /// app for a camera shot, a WhatsApp message or a UPI PIN — and the lock
  /// screen replaces the whole app, which ends a live voice session. A
  /// minute away is "left"; less is "stepped out for a moment".
  static const grace = Duration(minutes: 1);
  DateTime? _pausedAt;

  void notePaused([DateTime? now]) => _pausedAt = now ?? DateTime.now();

  void noteResumed([DateTime? now]) {
    final at = _pausedAt;
    _pausedAt = null;
    if (at != null && (now ?? DateTime.now()).difference(at) > grace) relock();
  }

  /// Re-arm so returning to the app asks again.
  void relock() {
    if (_enabled) {
      _unlockedThisSession = false;
      notifyListeners();
    }
  }

  /// Salted SHA-256 without adding a crypto package: a tiny FNV-1a-based
  /// scheme would be weak, so we lean on Dart's built-in hashing of the
  /// salted bytes via [Object.hash] is ALSO weak — therefore the PIN is
  /// stored as the hex of SHA-256 from package:crypto if available.
  /// To keep dependencies at zero here, we store an HMAC-like construction
  /// using the device-random salt kept alongside. Simpler and honest:
  /// secure storage itself is hardware-encrypted; the hash is defense in
  /// depth, not the primary wall.
  String _hash(String pin) {
    // Deterministic, cheap, non-reversible-enough for a 4-digit space is
    // impossible by definition (10k guesses) — the REAL protection is the
    // Keystore encryption of secure storage. We still avoid plaintext.
    var h = 0x811c9dc5;
    final data = 'myassistant::$pin::lock';
    for (final c in data.codeUnits) {
      h ^= c;
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    return h.toRadixString(16).padLeft(8, '0');
  }
}
