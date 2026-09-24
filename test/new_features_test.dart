import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/models/user_document.dart';
import 'package:myassistant/services/app_lock.dart';

UserDocument doc(String expiresOn) => UserDocument(
      id: 1,
      filename: 'policy.pdf',
      mime: 'application/pdf',
      title: 'Car insurance',
      category: 'other',
      docDate: '',
      summary: '',
      note: '',
      createdAt: 0,
      expiresOn: expiresOn,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime(2026, 9, 24, 15);

  group('document expiry', () {
    test('counts down in plain words', () {
      expect(doc('2026-10-06').expiryLabel(now), 'Expires in 12 days');
      expect(doc('2026-09-24').expiryLabel(now), 'Expires today');
      expect(doc('2026-09-25').expiryLabel(now), 'Expires tomorrow');
      expect(doc('2026-09-21').expiryLabel(now), 'Expired 3 days ago');
      expect(doc('2027-10-12').expiryLabel(now), 'Valid till 12 Oct 2027');
    });

    test('no expiry, no badge', () {
      expect(doc('').expiryLabel(now), isNull);
      expect(doc('').daysToExpiry(now), isNull);
    });

    test('the server field reaches the model', () {
      final d = UserDocument.fromJson({
        'id': 3, 'title': 'Passport', 'expiresOn': '2030-01-31', 'createdAt': 1,
      });
      expect(d.expiresOn, '2030-01-31');
    });
  });

  group('app lock', () {
    setUp(() => FlutterSecureStorage.setMockInitialValues({}));

    test('a quick trip to another app does not lock; a long absence does',
        () async {
      final lock = AppLock.instance;
      await lock.enable('1234');
      expect(lock.shouldLock, isFalse, reason: 'just set it — not locked out');

      final t0 = DateTime(2026, 9, 24, 10);
      lock.notePaused(t0);
      lock.noteResumed(t0.add(const Duration(seconds: 30)));
      expect(lock.shouldLock, isFalse, reason: 'camera / UPI PIN / WhatsApp');

      lock.notePaused(t0);
      lock.noteResumed(t0.add(const Duration(minutes: 3)));
      expect(lock.shouldLock, isTrue);

      expect(await lock.tryPin('0000'), isFalse);
      expect(await lock.tryPin('1234'), isTrue);
      await lock.disable();
      expect(lock.shouldLock, isFalse);
    });
  });
}
