// MIC TEST ON THE DIAGNOSTICS SCREEN (owner, 2026-09-25: "start talk while
// it works").
//
// The plan's P1 probe is run by the owner from Diagnostics. Pinned here:
//  * Diagnostics has a "Mic test" row, and opening it starts nothing;
//  * "Start mic test" starts the Android service (through the real
//    channel), counts frames only while the app is away, and coming back
//    ends it with the counts on screen and the service stopped;
//  * a stop from the service (screen off) arrives through the real event
//    channel and ends it;
//  * in all of it, not one byte goes up LiveService's socket and no voice
//    session opens.
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:myassistant/features/assistant/state/assistant_engine.dart';
import 'package:myassistant/screens/diagnostics_screen.dart';
import 'package:myassistant/services/app_feedback.dart';
import 'package:myassistant/services/live_service.dart';
import 'package:myassistant/services/mic_probe.dart';
import 'package:myassistant/services/task_voice.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Diagnostics loads over the network; offline, those loads fail fast and
/// what they throw is ignored (as in the clarity and layout tests).
Future<void> offline(Future<void> Function() body) async {
  final original = FlutterError.onError;
  FlutterError.onError = (d) {
    if (d.exceptionAsString().contains('overflowed')) original?.call(d);
  };
  try {
    await body();
  } finally {
    FlutterError.onError = original;
  }
}

/// One 128 ms frame of quiet-room noise, PCM16 @16 kHz.
Uint8List room(int seed) {
  final r = math.Random(seed);
  final b = ByteData(4096);
  for (var i = 0; i < 2048; i++) {
    b.setInt16(i * 2, r.nextInt(41) - 20, Endian.little);
  }
  return b.buffer.asUint8List();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  // The recorder registers itself with its plugin when LiveService is
  // built; no microphone is used here, so the plugin just says yes.
  messenger.setMockMethodCallHandler(
      const MethodChannel('com.llfbandit.record/messages'),
      (call) async => null);

  final live = LiveService.instance;
  late List<Object> socket;
  late List<String> calls;
  late List<StreamController<Uint8List>> mics;
  MockStreamHandlerEventSink? events;

  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppFeedback.resetForTest();
    socket = [];
    calls = [];
    mics = [];
    events = null;
    live.debugWatchSocket(socket.add);
    live.probeSessionHold = Duration.zero;
    live.debugProbeStream = (cfg) async {
      final c = StreamController<Uint8List>();
      mics.add(c);
      return c.stream;
    };
    messenger.setMockMethodCallHandler(TaskVoice.methods, (c) async {
      calls.add(c.method);
      return c.method == 'start'
          ? {'ok': true, 'mode': 0}
          : {'stopped': true, 'mode': 0};
    });
  });

  // In the test body, not in setUp: the mock's event stream lives in the
  // zone it is made in, and only the test body runs on the fake clock.
  void mockEvents() => messenger.setMockStreamHandler(TaskVoice.eventChannel,
      MockStreamHandler.inline(onListen: (_, sink) => events = sink));

  tearDown(() async {
    await live.stopProbe();
    live.debugProbeStream = null;
    live.debugWatchSocket(null);
    live.probeSessionHold = const Duration(seconds: 1);
    messenger.setMockMethodCallHandler(TaskVoice.methods, null);
    messenger.setMockStreamHandler(TaskVoice.eventChannel, null);
    AppFeedback.resetForTest();
  });

  Future<void> settle(WidgetTester t) => offline(() async {
        for (var i = 0; i < 6; i++) {
          await t.pump(const Duration(milliseconds: 50));
        }
      });

  Future<void> openMicTest(WidgetTester t) => offline(() async {
        mockEvents();
        await t.pumpWidget(const MaterialApp(home: DiagnosticsScreen()));
        await t.pump(const Duration(milliseconds: 300));
        await t.scrollUntilVisible(find.text('Mic test'), 300,
            scrollable: find.byType(Scrollable).first);
        await t.pump(const Duration(milliseconds: 300));
        expect(find.text('TESTS'), findsOneWidget);
        expect(find.text('Does the mic still hear you in another app?'),
            findsOneWidget);
        await t.tap(find.text('Mic test'));
        for (var i = 0; i < 6; i++) {
          await t.pump(const Duration(milliseconds: 100));
        }
      });

  // Android's own order, which the framework checks: out through inactive
  // and hidden to paused, and back the same way.
  void goAway(WidgetTester t) {
    for (final s in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      t.binding.handleAppLifecycleStateChanged(s);
    }
  }

  void comeBack(WidgetTester t) {
    if (t.binding.lifecycleState == AppLifecycleState.resumed) return;
    for (final s in [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      t.binding.handleAppLifecycleStateChanged(s);
    }
  }

  Future<void> closeApp(WidgetTester t) => offline(() async {
        comeBack(t);
        await t.pumpWidget(const SizedBox());
        AssistantEngine.instance.cancelReconnect();
        await t.pump(const Duration(seconds: 6));
      });

  testWidgets(
      'Diagnostics opens the mic test; it counts only while away, and '
      'never touches the socket', (t) async {
    await openMicTest(t);
    expect(find.text('Start mic test'), findsOneWidget);
    expect(find.text('Not run yet.'), findsOneWidget);
    expect(calls, isEmpty, reason: 'opening the screen starts nothing');
    expect(mics, isEmpty);

    await offline(() => t.tap(find.text('Start mic test')));
    await settle(t);
    expect(calls, ['start']);
    expect(MicProbe.instance.phase, MicProbePhase.running);
    expect(find.text('Running. Leave the app now.'), findsOneWidget);
    expect(find.text('Stop'), findsOneWidget);

    // On screen: kept apart. Away for 20 s of quiet room: counted.
    mics.last.add(room(0));
    await settle(t);
    goAway(t);
    for (var i = 1; i <= 157; i++) {
      mics.last.add(room(i));
    }
    await settle(t);
    comeBack(t);
    await settle(t);

    expect(MicProbe.instance.phase, MicProbePhase.done);
    expect(find.text('Finished: you came back to the app.'), findsOneWidget);
    expect(find.textContaining('Time away from the app: 20.1 s (157 frames)'),
        findsOneWidget);
    expect(find.textContaining('Frames with any sound at all: 157 (100%)'),
        findsOneWidget);
    expect(find.textContaining('(not counted above): 1'), findsOneWidget);
    expect(find.textContaining('A1 check: PASS'), findsOneWidget);
    expect(calls, ['start', 'stop'], reason: 'the service is stopped too');
    expect(mics.last.hasListener, isFalse, reason: 'the recorder is let go');

    expect(socket, isEmpty, reason: 'the mic test never sends a byte');
    expect(live.active, isFalse, reason: 'no voice session was opened');
    await closeApp(t);
  });

  testWidgets('a stop from Android (screen off) ends it through the event '
      'channel', (t) async {
    await openMicTest(t);
    await offline(() => t.tap(find.text('Start mic test')));
    await settle(t);
    expect(MicProbe.instance.phase, MicProbePhase.running);
    expect(events, isNotNull, reason: 'listening before the start');

    goAway(t);
    mics.last.add(room(1));
    events!.success({
      'event': 'stopped',
      'reason': 'screen_off',
      'modeStart': 0,
      'modeEnd': 0,
    });
    await settle(t);
    expect(MicProbe.instance.phase, MicProbePhase.done);
    expect(MicProbe.instance.counts.stopCode, 'screen_off');
    comeBack(t);
    await settle(t);
    expect(find.text('Finished: the screen turned off.'), findsOneWidget);
    expect(mics.last.hasListener, isFalse);
    expect(socket, isEmpty);
    await closeApp(t);
  });
}
