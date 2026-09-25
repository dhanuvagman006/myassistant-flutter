import 'dart:async';

import 'package:flutter/services.dart';

import '../core/log.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  TASK VOICE — Dart's side of TaskVoiceService (Android).
///
///  Owner, 2026-09-25: "start talk while it works". The plan keeps the voice
///  session open while a task runs in another app, and Android allows a
///  microphone off screen only inside a foreground service of type
///  "microphone". This wraps that service's channel. In this build its only
///  user is the mic test on the Diagnostics screen (MicProbe): the voice
///  session itself still closes before a task runs, exactly as before.
///
///  The service is promoted to the foreground BEFORE [TaskVoice.start]
///  answers, so "started" always means "Android agreed". It stops itself
///  and says why ([TaskVoiceStop]) on a call, when another app takes the
///  microphone, when the screen turns off, after 60 seconds, or on the
///  notification's Stop.
/// ─────────────────────────────────────────────────────────────────────────

/// Why the service stopped. [wire] is the string TaskVoiceService.kt sends
/// (its REASON_* constants); test/task_voice_test.dart holds both sides to
/// the same list.
enum TaskVoiceStop {
  /// The app asked ([TaskVoice.stop]).
  requested('requested', 'the app stopped it'),

  /// Stop on the notification.
  notification('notification', 'Stop was tapped on the notification'),

  /// The probe's 60-second limit.
  timeCap('time_cap', 'the 60-second limit was reached'),

  /// A phone call, or a WhatsApp / Meet / Instagram call (audio mode).
  call('call', 'a call started'),

  /// Another app took the microphone from us.
  silenced('silenced', 'Android gave the microphone to another app'),

  /// The screen turned off.
  screenOff('screen_off', 'the screen turned off'),

  /// The app was swiped away.
  taskRemoved('task_removed', 'the app was swiped away'),

  /// Android ended the service.
  destroyed('destroyed', 'Android ended the service'),

  /// A reason this build does not know (a newer Android half).
  unknown('unknown', 'it stopped for a reason this build does not know');

  const TaskVoiceStop(this.wire, this.words);

  /// The string on the channel.
  final String wire;

  /// Plain words for the Diagnostics screen.
  final String words;

  static TaskVoiceStop fromWire(Object? s) {
    for (final r in values) {
      if (r != unknown && r.wire == s) return r;
    }
    return unknown;
  }
}

/// One event from the service.
class TaskVoiceEvent {
  const TaskVoiceEvent.silenced()
      : silenced = true,
        reason = null,
        modeStart = null,
        modeEnd = null;

  const TaskVoiceEvent.stopped(this.reason, {this.modeStart, this.modeEnd})
      : silenced = false;

  /// Our recording was silenced (another app took the microphone). A
  /// "stopped" event with [TaskVoiceStop.silenced] follows it.
  final bool silenced;

  /// Set on a "stopped" event.
  final TaskVoiceStop? reason;

  /// AudioManager.getMode() when the service started and when it stopped.
  final int? modeStart;
  final int? modeEnd;

  bool get stopped => reason != null;

  /// Null for anything that is not a known event.
  static TaskVoiceEvent? fromWire(Object? m) {
    if (m is! Map) return null;
    switch (m['event']) {
      case 'silenced':
        return const TaskVoiceEvent.silenced();
      case 'stopped':
        return TaskVoiceEvent.stopped(
          TaskVoiceStop.fromWire(m['reason']),
          modeStart: _int(m['modeStart']),
          modeEnd: _int(m['modeEnd']),
        );
    }
    return null;
  }

  static int? _int(Object? v) => v is int ? v : null;
}

/// How a start went.
class TaskVoiceStart {
  const TaskVoiceStart.ok(this.audioMode) : error = null;
  const TaskVoiceStart.failed(this.error) : audioMode = null;

  /// Null when the service is in the foreground.
  final String? error;

  /// AudioManager.getMode() at promotion.
  final int? audioMode;

  bool get ok => error == null;
}

/// What the mic test needs from the service; tests pass a fake.
abstract class TaskVoicePort {
  Future<TaskVoiceStart> start();

  /// Stops it (deferred until promotion when a start is still in flight).
  /// Returns the audio mode at that moment, when known.
  Future<int?> stop();

  /// Service events. Listen BEFORE [start], so a stop that follows
  /// promotion at once is not missed.
  Stream<TaskVoiceEvent> events();
}

class TaskVoice implements TaskVoicePort {
  const TaskVoice({this.startTimeout = defaultStartTimeout});

  static const methods = MethodChannel('hari/task_voice');
  static const eventChannel = EventChannel('hari/task_voice/events');

  /// The plan's limit for promotion (section 3): past it, give up and stop.
  static const defaultStartTimeout = Duration(seconds: 3);

  final Duration startTimeout;

  /// Never throws. A promotion that does not answer within [startTimeout]
  /// is stopped (Android defers that stop until promotion finishes).
  @override
  Future<TaskVoiceStart> start() async {
    try {
      final r = await methods
          .invokeMethod<Object?>('start')
          .timeout(startTimeout);
      final mode = r is Map && r['mode'] is int ? r['mode'] as int : null;
      return TaskVoiceStart.ok(mode);
    } on TimeoutException {
      AppLog.add('taskvoice',
          'start: no answer in ${startTimeout.inMilliseconds} ms');
      unawaited(stop());
      return const TaskVoiceStart.failed('timeout');
    } on PlatformException catch (e) {
      AppLog.add('taskvoice', 'start refused: ${e.code}');
      return TaskVoiceStart.failed(e.code);
    } on MissingPluginException {
      return const TaskVoiceStart.failed('unavailable');
    }
  }

  @override
  Future<int?> stop() async {
    try {
      final r = await methods.invokeMethod<Object?>('stop');
      return r is Map && r['mode'] is int ? r['mode'] as int : null;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// running / starting / mode / sdk, straight from Android.
  static Future<Map<String, Object?>> status() async {
    try {
      final r = await methods.invokeMethod<Object?>('status');
      return r is Map ? r.cast<String, Object?>() : const {};
    } on PlatformException {
      return const {};
    } on MissingPluginException {
      return const {};
    }
  }

  @override
  Stream<TaskVoiceEvent> events() => eventChannel
      .receiveBroadcastStream()
      .map(TaskVoiceEvent.fromWire)
      .where((e) => e != null)
      .cast<TaskVoiceEvent>()
      .handleError((Object _) {});

  /// AudioManager modes by name, for the log and the screen.
  static String modeName(int? mode) => switch (mode) {
        0 => 'NORMAL',
        1 => 'RINGTONE',
        2 => 'IN_CALL',
        3 => 'IN_COMMUNICATION',
        4 => 'CALL_SCREENING',
        5 => 'CALL_REDIRECT',
        6 => 'COMMUNICATION_REDIRECT',
        null => '?',
        _ => 'mode $mode',
      };

  /// The two modes that mean a call owns the audio (plan G6).
  static bool isCallMode(int? mode) => mode == 2 || mode == 3;
}
