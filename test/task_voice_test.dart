// TASK VOICE BRIDGE (owner, 2026-09-25: "start talk while it works").
//
// The microphone foreground service (TaskVoiceService.kt) and its Dart
// wrapper (lib/services/task_voice.dart) must agree on every stop reason,
// channel name and event shape. Pinned here:
//  * every REASON_* the service can send is a reason Dart knows, and every
//    reason Dart knows is one the service sends;
//  * the events parse: "silenced", and "stopped" with its reason and the
//    audio mode at start and at the end; anything else is ignored;
//  * start answers only once the service is in the foreground, and a start
//    that never answers gives up after 3 s and asks for a stop (which the
//    service defers until promotion);
//  * the service is started with startService from the resumed activity,
//    promotes as the very first thing, has no content intent, and the
//    manifest declares it the way the plan says.
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/services/task_voice.dart';

const _kt = 'android/app/src/main/kotlin/com/myassistant/myassistant';
String _read(String p) => File(p).readAsStringSync();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(TaskVoice.methods, null));

  group('stop reasons are one list on both sides', () {
    final service = _read('$_kt/TaskVoiceService.kt');
    final kotlinReasons = RegExp(r'const val REASON_\w+ = "([a-z_]+)"')
        .allMatches(service)
        .map((m) => m.group(1)!)
        .toSet();

    test('the service sends reasons', () {
      expect(kotlinReasons, isNotEmpty);
    });

    test('every reason the service sends is known to Dart', () {
      for (final r in kotlinReasons) {
        expect(TaskVoiceStop.fromWire(r), isNot(TaskVoiceStop.unknown),
            reason: '"$r" is sent by TaskVoiceService.kt');
      }
    });

    test('every reason Dart knows is one the service sends', () {
      for (final r in TaskVoiceStop.values) {
        if (r == TaskVoiceStop.unknown) continue;
        expect(kotlinReasons, contains(r.wire), reason: r.name);
      }
    });

    test('the watchers each stop with their own reason', () {
      expect(service, contains('finish(REASON_CALL)'));
      expect(service, contains('finish(REASON_SILENCED)'));
      expect(service, contains('finish(REASON_SCREEN_OFF)'));
      expect(service, contains('finish(REASON_TIME_CAP)'));
      expect(service, contains('requestStop(REASON_NOTIFICATION)'));
      expect(service, contains('MODE_IN_CALL'));
      expect(service, contains('MODE_IN_COMMUNICATION'));
      expect(service, contains('isClientSilenced'));
      expect(service, contains('ACTION_SCREEN_OFF'));
      expect(service, contains('PROBE_CAP_MS = 60_000L'));
    });

    test('an unknown reason is unknown, never a guess', () {
      expect(TaskVoiceStop.fromWire('tea_break'), TaskVoiceStop.unknown);
      expect(TaskVoiceStop.fromWire(null), TaskVoiceStop.unknown);
      expect(TaskVoiceStop.fromWire('unknown'), TaskVoiceStop.unknown);
    });
  });

  group('events', () {
    test('stopped carries the reason and both audio modes', () {
      final e = TaskVoiceEvent.fromWire({
        'event': 'stopped',
        'reason': 'call',
        'modeStart': 0,
        'modeEnd': 3,
      })!;
      expect(e.stopped, isTrue);
      expect(e.silenced, isFalse);
      expect(e.reason, TaskVoiceStop.call);
      expect(e.modeStart, 0);
      expect(e.modeEnd, 3);
    });

    test('each reason arrives as itself', () {
      for (final r in TaskVoiceStop.values) {
        final e =
            TaskVoiceEvent.fromWire({'event': 'stopped', 'reason': r.wire});
        expect(e?.reason, r);
      }
    });

    test('silenced is its own event', () {
      final e = TaskVoiceEvent.fromWire({'event': 'silenced'})!;
      expect(e.silenced, isTrue);
      expect(e.stopped, isFalse);
    });

    test('anything else is ignored', () {
      expect(TaskVoiceEvent.fromWire({'event': 'party'}), isNull);
      expect(TaskVoiceEvent.fromWire('stopped'), isNull);
      expect(TaskVoiceEvent.fromWire(null), isNull);
    });

    test('the service and the bridge send exactly these shapes', () {
      final service = _read('$_kt/TaskVoiceService.kt');
      expect(service, contains('"event" to "stopped"'));
      expect(service, contains('"event" to "silenced"'));
      for (final k in ['"reason" to', '"modeStart" to', '"modeEnd" to']) {
        expect(service, contains(k));
      }
      final bridge = _read('$_kt/TaskVoiceBridge.kt');
      expect(bridge, contains('"${TaskVoice.methods.name}"'));
      expect(bridge, contains('"${TaskVoice.eventChannel.name}"'));
    });
  });

  group('start and stop', () {
    test('start answers with the audio mode once promoted', () async {
      final calls = <String>[];
      messenger.setMockMethodCallHandler(TaskVoice.methods, (c) async {
        calls.add(c.method);
        return {'ok': true, 'mode': 0};
      });
      final r = await const TaskVoice().start();
      expect(r.ok, isTrue);
      expect(r.audioMode, 0);
      expect(calls, ['start']);
    });

    test('a refused start says why and never throws', () async {
      messenger.setMockMethodCallHandler(TaskVoice.methods, (c) async {
        throw PlatformException(code: 'not_resumed');
      });
      final r = await const TaskVoice().start();
      expect(r.ok, isFalse);
      expect(r.error, 'not_resumed');
    });

    test('no Android half is "unavailable"', () async {
      final r = await const TaskVoice().start();
      expect(r.error, 'unavailable');
      expect(await const TaskVoice().stop(), isNull);
    });

    test('a start that never answers gives up and asks for a stop',
        () async {
      final calls = <String>[];
      final never = Completer<Object?>();
      messenger.setMockMethodCallHandler(TaskVoice.methods, (c) {
        calls.add(c.method);
        return c.method == 'start' ? never.future : Future.value({'mode': 0});
      });
      final r = await const TaskVoice(
              startTimeout: Duration(milliseconds: 50))
          .start();
      await Future<void>.delayed(Duration.zero);
      expect(r.error, 'timeout');
      expect(calls, ['start', 'stop']);
    });

    test('the default promotion limit is the plan\'s 3 seconds', () {
      expect(TaskVoice.defaultStartTimeout, const Duration(seconds: 3));
    });

    test('stop answers with the audio mode', () async {
      messenger.setMockMethodCallHandler(TaskVoice.methods,
          (c) async => {'stopped': true, 'mode': 3});
      expect(await const TaskVoice().stop(), 3);
    });
  });

  group('audio modes', () {
    test('by name', () {
      expect(TaskVoice.modeName(0), 'NORMAL');
      expect(TaskVoice.modeName(2), 'IN_CALL');
      expect(TaskVoice.modeName(3), 'IN_COMMUNICATION');
      expect(TaskVoice.modeName(null), '?');
      expect(TaskVoice.modeName(42), 'mode 42');
    });

    test('only IN_CALL and IN_COMMUNICATION are a call', () {
      expect(TaskVoice.isCallMode(2), isTrue);
      expect(TaskVoice.isCallMode(3), isTrue);
      for (final m in [null, -1, 0, 1, 4, 5, 6]) {
        expect(TaskVoice.isCallMode(m), isFalse, reason: '$m');
      }
    });
  });

  group('Android half, as the plan says', () {
    final service = _read('$_kt/TaskVoiceService.kt');
    final bridge = _read('$_kt/TaskVoiceBridge.kt');
    final manifest = _read('android/app/src/main/AndroidManifest.xml');

    test('promotion is the first thing a start does', () {
      final body = RegExp(r'private fun promoteThenWatch\(\) \{([\s\S]*?)\n    \}')
          .firstMatch(service)!
          .group(1)!;
      final firstCode = body
          .split('\n')
          .map((l) => l.trim())
          .firstWhere((l) =>
              l.isNotEmpty && !l.startsWith('//') && !l.startsWith('val '));
      expect(firstCode, startsWith('ServiceCompat.startForeground('));
      expect(body, contains('FOREGROUND_SERVICE_TYPE_MICROPHONE'));
      // Dart hears "started" only after it, and a deferred stop runs then.
      expect(body.indexOf('told?.invoke(true'),
          greaterThan(body.indexOf('ServiceCompat.startForeground(')));
      expect(body, contains('stopPending'));
    });

    test('started with startService, only from the resumed activity', () {
      expect(service, contains('ctx.startService('));
      expect(service, isNot(contains('startForegroundService(')));
      expect(bridge, contains('Lifecycle.State.RESUMED'));
    });

    test('the notification is silent, ongoing, low, with Stop and no '
        'content intent', () {
      expect(service, contains('IMPORTANCE_LOW'));
      expect(service, contains('.setSilent(true)'));
      expect(service, contains('.setOngoing(true)'));
      expect(service, contains('"Mic test running"'));
      expect(service, contains('addAction(0, "Stop"'));
      expect(service, isNot(contains('setContentIntent')));
    });

    test('the manifest declares the permissions and the service', () {
      expect(manifest,
          contains('android.permission.FOREGROUND_SERVICE"'));
      expect(manifest,
          contains('android.permission.FOREGROUND_SERVICE_MICROPHONE"'));
      final decl = RegExp(r'<service\s+android:name="\.TaskVoiceService"[^>]*>')
          .firstMatch(manifest)
          ?.group(0);
      expect(decl, isNotNull);
      expect(decl, contains('android:exported="false"'));
      expect(decl, contains('android:foregroundServiceType="microphone"'));
      expect(decl, contains('android:stopWithTask="true"'));
    });

    test('registered in MainActivity like the other bridges', () {
      expect(_read('$_kt/MainActivity.kt'),
          contains('TaskVoiceBridge.register(flutterEngine.dartExecutor.binaryMessenger, this)'));
    });
  });
}
