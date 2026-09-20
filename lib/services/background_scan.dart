import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:workmanager/workmanager.dart';

import 'api_service.dart';
import 'call_recording_watcher.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  BACKGROUND CALL-RECORDING SCAN.
///
///  The user finishes a call and puts the phone down — nobody reopens an
///  app to make analysis happen. WorkManager wakes this dispatcher about
///  every 15 minutes (Android's floor, batched with Doze), the watcher
///  looks for new recordings and uploads them, and the server's push
///  notification is how the result reaches the user. Opening the app
///  still scans immediately; this is the "without opening the app" path.
/// ─────────────────────────────────────────────────────────────────────────

const kCallScanTask = 'call-recording-scan';

/// Runs in ITS OWN isolate: nothing from the main app exists here. The
/// session is rebuilt from storage the same way a cold start does it.
@pragma('vm:entry-point')
void callScanDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    try {
      WidgetsFlutterBinding.ensureInitialized();
      await ApiService.loadServerOverride();
      final token = await const FlutterSecureStorage()
          .read(key: 'session_token')
          .catchError((_) => null);
      if (token == null || token.isEmpty) return true; // signed out — done
      ApiService.sessionToken = token;
      await CallRecordingWatcher.instance.scan();
    } catch (_) {
      // Never fail the task: WorkManager's retry/backoff would just burn
      // battery for a scan the next tick repeats anyway.
    }
    return true;
  });
}

class BackgroundScan {
  /// Called once from main() — cheap, just registers the dispatcher.
  static Future<void> init() async {
    try {
      await Workmanager().initialize(callScanDispatcher);
    } catch (_) {}
  }

  /// Keep the periodic task in step with the consent toggle.
  static Future<void> setEnabled(bool on) async {
    try {
      if (on) {
        await Workmanager().registerPeriodicTask(
          kCallScanTask,
          kCallScanTask,
          frequency: const Duration(minutes: 15),
          existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
          constraints: Constraints(networkType: NetworkType.connected),
          backoffPolicy: BackoffPolicy.linear,
        );
      } else {
        await Workmanager().cancelByUniqueName(kCallScanTask);
      }
    } catch (_) {}
  }
}
