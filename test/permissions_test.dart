// Only the microphone may lock the app. Turning the camera off in Settings
// used to bring back a screen that would not let the user in.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
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
}
