import 'dart:async';

import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:firebase_performance/firebase_performance.dart';
import 'package:flutter/foundation.dart';

/// FIREBASE'S EYES ON THE APP (2026-10-01, the owner: "integrate the
/// useful tools from Firebase"). Three of them, one door:
///
///  * Crashlytics — every crash and every unhandled error, with the last
///    AppLog lines as breadcrumbs, so a tester's "it closed" is a stack
///    trace in the console the next morning.
///  * Performance — a trace around every assistant turn (engine, tool
///    count) and the app's own start-up, so slowness is measured on real
///    phones, not guessed from one.
///  * Analytics — which tab, which feature, which engine answered: what
///    people actually use, to decide what to build next.
///
/// Everything here is a no-op until [enable] runs after Firebase is up,
/// and every call swallows its own failure: telemetry never breaks the
/// thing it watches, and the test runner never has Firebase.
class Telemetry {
  Telemetry._();
  static final Telemetry instance = Telemetry._();

  bool _on = false;
  bool get enabled => _on;

  /// After Firebase.initializeApp: crashes on, the two error hooks set.
  /// Returns false when Firebase is not there (tests, a bad config).
  Future<bool> enable() async {
    try {
      await FirebaseCrashlytics.instance.setCrashlyticsCollectionEnabled(!kDebugMode);
      final previous = FlutterError.onError;
      FlutterError.onError = (details) {
        previous?.call(details);
        FirebaseCrashlytics.instance.recordFlutterFatalError(details);
      };
      PlatformDispatcher.instance.onError = (error, stack) {
        FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
        return true;
      };
      await FirebasePerformance.instance.setPerformanceCollectionEnabled(!kDebugMode);
      _on = true;
    } catch (e) {
      debugPrint('telemetry off: $e');
      _on = false;
    }
    return _on;
  }

  /// Who this is, in crash reports and usage — the app's own user id,
  /// never a name or a number.
  Future<void> setUser(Object? userId) async {
    if (!_on) return;
    final id = userId == null ? '' : '$userId';
    try {
      await FirebaseCrashlytics.instance.setUserIdentifier(id);
      await FirebaseAnalytics.instance.setUserId(id: id.isEmpty ? null : id);
    } catch (_) {}
  }

  /// One AppLog line as a breadcrumb: the last of these come with a crash.
  void log(String line) {
    if (!_on) return;
    try {
      FirebaseCrashlytics.instance.log(line);
    } catch (_) {}
  }

  /// An error the app survived (a failed upload, a refused call).
  void error(Object e, StackTrace? st, {String? reason}) {
    if (!_on) return;
    try {
      FirebaseCrashlytics.instance.recordError(e, st, reason: reason, fatal: false);
    } catch (_) {}
  }

  /// A thing that happened: `tab`, `turn`, `feature`. Values are short.
  void event(String name, [Map<String, Object> params = const {}]) {
    if (!_on) return;
    try {
      unawaited(FirebaseAnalytics.instance.logEvent(name: name, parameters: params));
    } catch (_) {}
  }

  /// A stretch of time worth measuring on real phones. Stop it with the
  /// handle; attributes name what kind of stretch it was.
  TelemetryTrace trace(String name) => TelemetryTrace._(_on ? name : null);
}

class TelemetryTrace {
  TelemetryTrace._(String? name) : _trace = name == null ? null : _start(name);
  final Trace? _trace;
  bool _done = false;

  static Trace? _start(String name) {
    try {
      final t = FirebasePerformance.instance.newTrace(name);
      unawaited(t.start());
      return t;
    } catch (_) {
      return null;
    }
  }

  void attribute(String key, String value) {
    try {
      _trace?.putAttribute(key, value.length > 100 ? value.substring(0, 100) : value);
    } catch (_) {}
  }

  void metric(String key, int value) {
    try {
      _trace?.setMetric(key, value);
    } catch (_) {}
  }

  void stop() {
    if (_done) return;
    _done = true;
    try {
      unawaited(_trace?.stop() ?? Future<void>.value());
    } catch (_) {}
  }
}
