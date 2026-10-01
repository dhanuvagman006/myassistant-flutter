// PHONE VERIFICATION (2026-09-29): Firebase Phone Number Verification
// instead of the SMS code. The service asks the phone and the server what
// they allow, sends Google's token (never digits) to /phone/verify, and the
// screen offers only what both sides take.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:myassistant/widgets/glow_cta.dart';
import 'package:myassistant/screens/auth/phone_verify_screen.dart';
import 'package:myassistant/services/phone_verify_service.dart';

class _FakeSim implements SimNumberPort {
  _FakeSim({this.isSupported = true, this.result = const SimNumberResult.ok('tok.en.x')});
  bool isSupported;
  SimNumberResult result;
  int verifies = 0;

  @override
  Future<bool> supported() async => isSupported;

  @override
  Future<SimNumberResult> verify() async {
    verifies++;
    return result;
  }
}

class _Harness {
  _Harness({
    this.server = const {'sim': true, 'typed': false},
    this.status = 200,
    this.body = '{"ok":true}',
    _FakeSim? sim,
  }) : sim = sim ?? _FakeSim();

  Map<String, dynamic>? server;
  int status;
  String body;
  final _FakeSim sim;
  final posts = <(String, Map<String, dynamic>)>[];
  int refreshes = 0;

  PhoneVerifyService build() => PhoneVerifyService(
        sim: sim,
        getJson: (path) async {
          expect(path, '/phone/methods');
          if (server == null) throw const SocketException('down');
          return server;
        },
        post: (path, b) async {
          posts.add((path, b));
          return http.Response(body, status);
        },
        refreshUser: () async => refreshes++,
      );
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  group('PhoneVerifyService', () {
    test('the SIM path is offered only when the phone AND the server take it', () async {
      final h = _Harness();
      var m = await h.build().methods();
      expect([m.sim, m.typed, m.reached], [true, false, true]);

      h.sim.isSupported = false; // every Indian SIM in September 2026
      m = await h.build().methods();
      expect([m.sim, m.typed], [false, false]);

      h.server = {'sim': false, 'typed': true};
      h.sim.isSupported = true;
      m = await h.build().methods();
      expect([m.sim, m.typed], [false, true]);

      h.server = null;
      m = await h.build().methods();
      expect([m.sim, m.typed, m.reached], [false, false, false]);
    });

    test("Google's token, never digits, goes to /phone/verify, then the user is refreshed", () async {
      final h = _Harness();
      expect(await h.build().verifyWithSim(), isNull);
      expect(h.posts.single.$1, '/phone/verify');
      expect(h.posts.single.$2, {'pnvToken': 'tok.en.x'});
      expect(h.refreshes, 1);
    });

    test('a number held by another account says so; server words pass through', () async {
      final h = _Harness(status: 409, body: '{"error":"x"}');
      expect(await h.build().verifyWithSim(), 'This number is already registered to another account.');
      h
        ..status = 401
        ..body = jsonEncode({'error': 'That confirmation expired. Tap Confirm again.'});
      expect(await h.build().verifyWithSim(), 'That confirmation expired. Tap Confirm again.');
      h
        ..status = 502
        ..body = '<html>bad gateway</html>';
      expect(await h.build().verifyWithSim(), 'Could not register this number.');
      expect(h.refreshes, 0);
    });

    test('when the phone side does not finish, nothing is sent and the words fit the reason', () async {
      for (final (code, words) in [
        ('cancelled', 'You closed the confirmation. Tap Confirm to try again.'),
        ('unsupported', "Your network can't confirm numbers automatically yet."),
        ('not_enabled', 'Number confirmation is not switched on for this app yet.'),
        ('network', 'No connection. Check your internet and try again.'),
        ('failed', 'Could not confirm your number. Try again.'),
      ]) {
        final h = _Harness(sim: _FakeSim(result: SimNumberResult.failed(code)));
        expect(await h.build().verifyWithSim(), words, reason: code);
        expect(h.posts, isEmpty);
      }
    });

    test('the typed testing path posts the number to /phone/dev-verify', () async {
      final h = _Harness(server: {'sim': false, 'typed': true});
      expect(await h.build().devVerify('+919876543210'), isNull);
      expect(h.posts.single.$1, '/phone/dev-verify');
      expect(h.posts.single.$2, {'phone': '+919876543210'});
    });

    test('the channel name and methods are the ones PhoneNumberVerificationBridge.kt handles', () {
      final kt = File('android/app/src/main/kotlin/com/myassistant/myassistant/'
              'PhoneNumberVerificationBridge.kt')
          .readAsStringSync();
      final dart = File('lib/services/phone_verify_service.dart').readAsStringSync();
      expect(kt, contains('"hari/phone_number"'));
      expect(dart, contains("MethodChannel('hari/phone_number')"));
      for (final m in ['support', 'verify']) {
        expect(kt, contains('"$m" ->'));
        expect(dart, contains("invokeMapMethod<String, dynamic>('$m')"));
      }
      final main = File('android/app/src/main/kotlin/com/myassistant/myassistant/MainActivity.kt')
          .readAsStringSync();
      expect(main, contains('PhoneNumberVerificationBridge.register('));
    });

    // firebase_auth is back (2026-09-29) ONLY for Firebase AI Logic's
    // custom-token identity (lib/ai/identity.dart); phone sign-in is not.
    test('no SMS code is left anywhere in the app', () {
      for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith('.dart')) continue;
        final src = f.readAsStringSync();
        expect(src, isNot(contains('verifyPhoneNumber')), reason: f.path);
        expect(src, isNot(contains('PhoneAuthProvider')), reason: f.path);
        expect(src, isNot(contains('signInWithPhoneNumber')), reason: f.path);
        expect(src, isNot(contains('PhoneAuthCredential')), reason: f.path);
      }
      final kotlin = Directory('android/app/src/main/kotlin')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.kt'))
          .map((f) => f.readAsStringSync())
          .join('\n');
      expect(kotlin, isNot(contains('PhoneAuthProvider')));
    });

    test('firebase_auth is used only for the AI identity (custom token)', () {
      final users = <String>[];
      for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith('.dart')) continue;
        final src = f.readAsStringSync();
        if (src.contains('package:firebase_auth/')) users.add(f.path.replaceAll('\\', '/'));
      }
      expect(users.toSet(), {'lib/ai/identity.dart', 'lib/ai/model_port.dart'});
      final identity = File('lib/ai/identity.dart').readAsStringSync();
      expect(identity, contains('signInWithCustomToken('));
    });
  });

  group('PhoneVerifyScreen', () {
    Future<void> pump(WidgetTester t, _Harness h) async {
      await t.pumpWidget(MaterialApp(home: PhoneVerifyScreen(service: h.build())));
      await t.pumpAndSettle();
    }

    testWidgets('a supported SIM: one button, no number to type', (t) async {
      final h = _Harness();
      await pump(t, h);
      expect(find.text('Confirm with my SIM'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(find.textContaining('no code to type'), findsOneWidget);
      await t.tap(find.text('Confirm with my SIM'));
      await t.pumpAndSettle();
      expect(h.sim.verifies, 1);
      expect(h.posts.single.$2, {'pnvToken': 'tok.en.x'});
    });

    testWidgets('a failure is shown in words, and the button stays', (t) async {
      final h = _Harness(sim: _FakeSim(result: const SimNumberResult.failed('cancelled')));
      await pump(t, h);
      await t.tap(find.text('Confirm with my SIM'));
      await t.pumpAndSettle();
      expect(find.text('You closed the confirmation. Tap Confirm to try again.'), findsOneWidget);
      expect(find.text('Confirm with my SIM'), findsOneWidget);
    });

    testWidgets('an unsupported SIM with the testing switch on: type the number', (t) async {
      final h = _Harness(server: {'sim': true, 'typed': true}, sim: _FakeSim(isSupported: false));
      await pump(t, h);
      expect(find.text('Confirm with my SIM'), findsNothing);
      expect(find.text('Use this number (testing)'), findsOneWidget);
      await t.enterText(find.byType(TextField).last, '98765 43210');
      await t.tap(find.text('Use this number (testing)'));
      await t.pumpAndSettle();
      expect(h.posts.single.$1, '/phone/dev-verify');
      expect(h.posts.single.$2, {'phone': '+919876543210'});
    });

    testWidgets('an unsupported SIM and no testing switch: said plainly, nothing to press but Check again', (t) async {
      final h = _Harness(sim: _FakeSim(isSupported: false));
      await pump(t, h);
      expect(find.textContaining("can't confirm numbers automatically yet"), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(find.text('Check again'), findsOneWidget);
      expect(find.text('Sign out'), findsOneWidget);
    });

    testWidgets('no server: the one way forward is a primary Try again button', (t) async {
      final h = _Harness(server: null);
      await pump(t, h);
      expect(find.text('Could not reach the server. Check your connection.'), findsOneWidget);
      // The page's one lit action (2026-09-30: GlowCta, was ApplePrimaryButton).
      expect(find.widgetWithText(GlowCta, 'Try again'), findsOneWidget);
      h.server = {'sim': true, 'typed': false};
      await t.tap(find.text('Try again'));
      await t.pumpAndSettle();
      expect(find.text('Confirm with my SIM'), findsOneWidget);
    });
  });
}
