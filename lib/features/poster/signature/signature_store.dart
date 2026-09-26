import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../core/log.dart';
import 'signature_model.dart';

/// HIS SIGNATURE STAYS ON HIS PHONE.
///
/// Kept in the Keystore (flutter_secure_storage) under the contract's key,
/// as the pen's lines — never uploaded on its own, never sent to any model.
/// The server only knows whether the card shows it. A signature can be
/// cropped out of any shared picture, so he is asked to sign the way he
/// signs a greeting card, and can delete or redo it at any time.
class SignatureStore extends ChangeNotifier {
  SignatureStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  static const key = 'poster.signature.v1';

  static SignatureStore instance = SignatureStore();

  final FlutterSecureStorage _storage;

  SignatureData? _cached;
  bool _read = false;

  SignatureData? get current => _cached;

  Future<SignatureData?> load() async {
    if (_read) return _cached;
    try {
      _cached = SignatureData.decode(await _storage.read(key: key));
    } catch (e) {
      AppLog.add('poster', 'signature read failed: $e');
      _cached = null;
    }
    _read = true;
    return _cached;
  }

  Future<bool> save(SignatureData s) async {
    try {
      await _storage.write(key: key, value: s.encode());
      _cached = s;
      _read = true;
      notifyListeners();
      return true;
    } catch (e) {
      AppLog.add('poster', 'signature save failed: $e');
      return false;
    }
  }

  Future<void> delete() async {
    try {
      await _storage.delete(key: key);
    } catch (e) {
      AppLog.add('poster', 'signature delete failed: $e');
    }
    _cached = null;
    _read = true;
    notifyListeners();
  }

  @visibleForTesting
  void resetCache() {
    _cached = null;
    _read = false;
  }
}
