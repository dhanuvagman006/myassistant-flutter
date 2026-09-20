import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_service.dart';
import 'background_scan.dart';
import 'call_recording_watcher.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  AI CALL ANALYSIS — over the phone's OWN call recorder.
///
///  There is no in-app dialer. The user keeps their normal phone app and
///  switches on ITS call recording (a system app records both sides
///  cleanly — nothing a sideloaded app can do matches that). This service
///  owns the consent toggle, the analysed-call history, and the jump to
///  the system call-settings screen where recording is enabled. The
///  actual pickup of new recording files is CallRecordingWatcher.
/// ─────────────────────────────────────────────────────────────────────────
class CallNotesService extends ChangeNotifier {
  CallNotesService._();
  static final CallNotesService instance = CallNotesService._();

  static const _ch = MethodChannel('hari/callrec');
  static const _prefsKey = 'call_analysis_enabled_v1';

  bool analysisEnabled = false;
  List<Map<String, dynamic>> recent = const [];
  bool _started = false;

  void start() {
    if (_started) return;
    _started = true;
    _hydrate();
  }

  Future<void> _hydrate() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cached = prefs.getBool(_prefsKey);
      if (cached != null) {
        analysisEnabled = cached;
        notifyListeners();
      }
    } catch (_) {}
    try {
      final r = await ApiService.getJson('/calls/analysis');
      if (r != null) {
        analysisEnabled = r['enabled'] == true;
        notifyListeners();
      }
    } catch (_) {}
    if (analysisEnabled) {
      CallRecordingWatcher.instance.start();
      BackgroundScan.setEnabled(true); // survive reinstalls and reboots
    }
    refreshRecent();
  }

  /// Records the user's decision server-side (the consent timestamp lives
  /// there). The caller shows the consent dialog BEFORE calling this.
  Future<bool> setAnalysis(bool on) async {
    final r =
        await ApiService.sendJson('/calls/analysis', body: {'enabled': on});
    if (r == null) return false;
    analysisEnabled = r['enabled'] == true;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefsKey, analysisEnabled);
    } catch (_) {}
    if (analysisEnabled) CallRecordingWatcher.instance.start();
    await BackgroundScan.setEnabled(analysisEnabled);
    notifyListeners();
    return true;
  }

  /// Lands the user on the system call-settings screen, where the
  /// built-in recorder ("Record calls" on Samsung) is switched on.
  Future<bool> openSystemCallSettings() async {
    try {
      return (await _ch.invokeMethod<bool>('openCallSettings')) ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> refreshRecent() async {
    try {
      final r = await ApiService.getJson('/calls/recent');
      recent = ((r?['calls'] as List?) ?? const [])
          .whereType<Map>()
          .map((m) => m.cast<String, dynamic>())
          .toList();
      notifyListeners();
    } catch (_) {}
  }
}
