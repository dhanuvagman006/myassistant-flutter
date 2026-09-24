// Only the microphone may lock the app. Turning the camera off in Settings
// used to bring back a screen that would not let the user in.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:myassistant/screens/auth/permissions_screen.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('flutter.baseflow.com/permissions/methods');

  /// Fakes the platform: [granted] permissions report granted, all others denied.
  void phoneWith(Set<Permission> granted) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'checkPermissionStatus') {
        final p = Permission.values.firstWhere((x) => x.value == call.arguments);
        return granted.contains(p)
            ? PermissionStatus.granted.index
            : PermissionStatus.denied.index;
      }
      return null;
    });
  }

  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, null));

  test('with the microphone allowed, the app opens — whatever else is off', () async {
    phoneWith({Permission.microphone});
    expect(await allRequiredPermissionsGranted(), isTrue,
        reason: 'a user without camera/contacts/location was locked out');
  });

  test('without the microphone, the gate stays', () async {
    phoneWith({
      Permission.contacts, Permission.phone, Permission.notification,
      Permission.camera, Permission.locationWhenInUse,
    });
    expect(await allRequiredPermissionsGranted(), isFalse);
  });

  // READ_CALL_LOG in the manifest folds call history into
  // permission_handler's Permission.phone. Setup must not ask for it: call
  // history is asked the first time the owner asks about his calls.
  group('the Phone row at setup', () {
    const calls = MethodChannel('hari/calls');
    late List<int> groupAsks; // permission_handler values requested
    late int phoneAsks;
    late bool phoneOn;

    setUp(() {
      GoogleFonts.config.allowRuntimeFetching = false;
      groupAsks = [];
      phoneAsks = 0;
      phoneOn = false;
      final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      m.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'checkPermissionStatus':
            return PermissionStatus.denied.index;
          case 'requestPermissions':
            final asked = (call.arguments as List).cast<int>();
            groupAsks.addAll(asked);
            // The microphone stays off, so setup does not finish here.
            return {for (final v in asked) v: PermissionStatus.denied.index};
        }
        return null;
      });
      m.setMockMethodCallHandler(calls, (call) async {
        switch (call.method) {
          case 'permissions':
            return {'callLog': false, 'phoneState': phoneOn, 'callPhone': phoneOn};
          case 'requestPhone':
            phoneAsks++;
            phoneOn = true;
            return 'granted';
          case 'requestCallLog':
            fail('setup must never ask for call history');
        }
        return null;
      });
    });

    tearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(calls, null));

    testWidgets('"Allow all" asks for the phone natively, never the group',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 2.625;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
          MaterialApp(home: PermissionsScreen(onDone: () {})));
      await tester.pumpAndSettle();
      expect(find.text('To place the calls you ask for.'), findsOneWidget,
          reason: 'the one-line explainer is about calls only');

      await tester.ensureVisible(find.text('Allow all'));
      await tester.tap(find.text('Allow all'));
      await tester.pumpAndSettle();

      expect(phoneAsks, 1);
      expect(groupAsks, isNot(contains(Permission.phone.value)),
          reason: 'Permission.phone now carries the call-history dialog');
      expect(groupAsks, contains(Permission.contacts.value),
          reason: 'the other rows still ask as before');
    });

    testWidgets('the row reads the exact phone permissions', (tester) async {
      phoneOn = true; // phone allowed, call history not
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 2.625;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
          MaterialApp(home: PermissionsScreen(onDone: () {})));
      await tester.pumpAndSettle();
      // Phone is ticked even though the group (with call history) is not.
      expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
    });
  });
}
