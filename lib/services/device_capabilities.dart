import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import 'call_history.dart';
import 'audio/mic_stats.dart';

/// WHAT THIS PHONE CAN ACTUALLY DO.
///
/// The server used to know only the app's build number. It had no idea
/// whether the user had granted contacts, the phone, or SMS — so it would
/// offer a capability, the assistant would say it was doing it, and the
/// permission denial surfaced afterwards as a failure the user had
/// already been promised wouldn't happen.
///
/// Every turn carries it (the brain's /ai/context). The server filters the
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
    // "phone" means placing calls: READ_PHONE_STATE and CALL_PHONE, asked
    // one by one. permission_handler's phone group now also contains call
    // history (2026-09-24) and reports the strictest of the three, which
    // would tell the server "phone denied" — and take calling away — for
    // everyone who has not shared their call log.
    final exact = await CallHistory.permissions();
    for (final entry in _checks.entries) {
      try {
        if (entry.key == 'phone' && exact != null) {
          final ok = exact['phoneState'] == true && exact['callPhone'] == true;
          (ok ? granted : denied).add(entry.key);
          continue;
        }
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
    // WHAT THE MICROPHONE ACTUALLY DELIVERED last session. The S24
    // Ultra bug was invisible from here precisely because these numbers
    // never left the handset.
    final mic = MicStats.snapshot();
    // Audio hardware, battery policy, memory, ABIs — collected natively
    // because none of it is reachable from Dart.
    Map<String, dynamic> diag = {};
    try {
      final r = await const MethodChannel('hari/device')
          .invokeMethod<Map<Object?, Object?>>('diagnostics');
      if (r != null) {
        diag = r.map((k, v) => MapEntry(k.toString(), v));
      }
    } catch (_) {}

    // WHICH PHONE THIS IS. Without it, "works on mine, breaks on his" is
    // guesswork: a mic threshold that suits one handset can be wrong on
    // another (S24 Ultra, 2026-09-20), and nobody could tell from here.
    String model = '';
    String osVersion = '';
    try {
      final d = await DeviceInfoPlugin().androidInfo;
      model = '${d.manufacturer} ${d.model}'.trim();
      osVersion = 'Android ${d.version.release} (SDK ${d.version.sdkInt})';
    } catch (_) {}
    return {
      'platform': 'android',
      'build': build,
      'model': model,
      'osVersion': osVersion,
      'granted': granted,
      'denied': denied,
      'diag': {
        ...diag,
        if (mic.isNotEmpty) ...mic,
        'locale': WidgetsBinding.instance.platformDispatcher.locale.toString(),
        'tzOffsetMin': DateTime.now().timeZoneOffset.inMinutes,
      },
    };
  }
}
