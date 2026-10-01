import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/ai/identity.dart';
import 'package:myassistant/ai/tool_server.dart';

class _AppCheck implements AppCheckPort {
  final tokens = <String>[];
  bool fail = false;

  @override
  Future<void> activate({required String debugToken}) async {
    if (fail) throw Exception('no play services');
    tokens.add(debugToken);
  }
}

class _Auth implements FirebaseAuthPort {
  @override
  String? uid;
  final signIns = <String>[];
  var signOuts = 0;
  bool refuse = false;

  @override
  Future<String?> signInWithCustomToken(String token) async {
    if (refuse) throw Exception('invalid-custom-token');
    signIns.add(token);
    uid = 'u42';
    return uid;
  }

  @override
  Future<void> signOut() async {
    signOuts++;
    uid = null;
  }
}

void main() {
  late _AppCheck appCheck;
  late _Auth auth;
  late int mints;
  FirebaseTokenResult? minted;
  String? expected;

  AiIdentity identity({String debugToken = ''}) => AiIdentity(
        appCheck: appCheck,
        auth: auth,
        mintToken: () async {
          mints++;
          return minted;
        },
        expectedUid: () => expected,
        debugToken: debugToken,
      );

  setUp(() {
    appCheck = _AppCheck();
    auth = _Auth();
    mints = 0;
    minted = const FirebaseTokenResult(token: 'custom.jwt', uid: 'u42');
    expected = 'u42';
  });

  group('App Check', () {
    test('an App Distribution build uses the debug provider with its token', () async {
      final id = identity(debugToken: 'registered-debug-token');
      expect(id.appCheckProvider, 'debug');
      expect(await id.activateAppCheck(), isTrue);
      expect(appCheck.tokens, ['registered-debug-token']);
    });

    test('without the define: Play Integrity (empty token)', () async {
      final id = identity();
      expect(id.appCheckProvider, 'playIntegrity');
      await id.activateAppCheck();
      expect(appCheck.tokens, ['']);
    });

    test('activated once; a failure is false, never a crash', () async {
      final id = identity();
      await id.activateAppCheck();
      await id.activateAppCheck();
      expect(appCheck.tokens.length, 1);
      expect(id.appCheckActive, isTrue);

      appCheck.fail = true;
      final broken = identity();
      expect(await broken.activateAppCheck(), isFalse);
      expect(broken.appCheckActive, isFalse);
    });

    test('the compiled-in define is what the default reads (empty in tests)', () {
      expect(AiIdentity(appCheck: appCheck, auth: auth).debugToken, '');
    });
  });

  group('Firebase user (custom token)', () {
    test('signs in with the token the backend mints', () async {
      final id = identity();
      expect(await id.signIn(), isTrue);
      expect(mints, 1);
      expect(auth.signIns, ['custom.jwt']);
      expect(id.uid, 'u42');
    });

    test('kept when this account is already signed in; re-minted for another', () async {
      auth.uid = 'u42';
      final id = identity();
      expect(await id.signIn(), isTrue);
      expect(mints, 0);

      auth.uid = 'u7'; // the previous account's user
      expect(await id.signIn(), isTrue);
      expect(auth.signOuts, 1);
      expect(mints, 1);
      expect(id.uid, 'u42');

      expect(await id.signIn(force: true), isTrue);
      expect(mints, 2);
    });

    test('unknown account (restored session): any Firebase user is kept', () async {
      expected = null;
      auth.uid = 'u42';
      expect(await identity().signIn(), isTrue);
      expect(mints, 0);
    });

    test('backend unavailable or Firebase refusing: false, never a crash', () async {
      minted = null;
      expect(await identity().signIn(), isFalse);
      minted = const FirebaseTokenResult(token: 'bad', uid: 'u42');
      auth.refuse = true;
      expect(await identity().signIn(), isFalse);
    });

    test('one sign-in at a time', () async {
      final id = identity();
      final results = await Future.wait([id.signIn(), id.signIn(), id.signIn()]);
      expect(results, [true, true, true]);
      expect(mints, 1);
    });

    test('sign-out signs the Firebase user out', () async {
      final id = identity();
      await id.signIn();
      await id.signOut();
      expect(id.uid, isNull);
    });
  });
}
