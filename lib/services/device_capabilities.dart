import 'package:package_info_plus/package_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/log.dart';

/// WHAT THIS PHONE CAN ACTUALLY DO.
///
/// The server used to know only the app's build number. It had no idea
/// whether the user had granted contacts, the phone, or SMS — so it would
/// offer a capability, the assistant would say it was doing it, and the
/// permission denial surfaced afterwards as a failure the user had
/// already been promised wouldn't happen.
///
/// This is reported once per assistant session. The server filters the
/// tools it offers the model against it, and when something is genuinely
/// blocked the assistant can say which permission is missing and offer to
/// open the settings page — instead of trying and failing.
class DeviceCapabilities {
  DeviceCapabilities._();

  /// Which Android permission each capability actually needs. The names
  /// are the server's, so one map is the whole contract.
  static const _checks = <String, Permission>{
    'contacts': Permission.contacts,
    'phone': Permission.phone,
    'sms': Permission.sms,
    'microphone': Permission.microphone,
    'camera': Permission.camera,
    'location': Permission.locationWhenInUse,
    'notifications': Permission.notification,
    'install_packages': Permission.requestInstallPackages,
  };

  /// Collected fresh each time: a permission the user revoked in Settings
  /// must not be remembered as granted.
  static Future<Map<String, dynamic>> collect() async {
    final granted = <String>[];
    final denied = <String>[];
    for (final entry in _checks.entries) {
      try {
        final status = await entry.value.status;
        (status.isGranted ? granted : denied).add(entry.key);
      } catch (_) {
        // Unknowable counts as denied: promising a capability we cannot
        // confirm is the failure mode being fixed here.
        denied.add(entry.key);
      }
    }
    int build = 0;
    try {
      final info = await PackageInfo.fromPlatform();
      build = int.tryParse(info.buildNumber) ?? 0;
    } catch (_) {}
    return {
      'platform': 'android',
      'build': build,
      'granted': granted,
      'denied': denied,
    };
  }

  /// Report to the server, never throwing: a session must open whether or
  /// not this lands.
  static Future<void> report(
      Future<void> Function(Map<String, dynamic>) send) async {
    try {
      final caps = await collect();
      await send(caps);
      AppLog.add('caps',
          'reported build ${caps['build']}, granted ${(caps['granted'] as List).join(",")}');
    } catch (e) {
      AppLog.add('caps', 'report failed: $e');
    }
  }
}
