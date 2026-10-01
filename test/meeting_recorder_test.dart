// The meeting recorder never says "Recording" over a microphone that
// stopped (2026-09-30): a notification cannot pause it, a pause the owner
// did not make shows as Paused with Resume, and a connected call pauses it
// without resuming by itself.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/screens/meetings/meeting_recorder_screen.dart';
import 'package:myassistant/services/recording_guard.dart';
import 'package:record/record.dart';

class _FakeRecorder extends Fake implements AudioRecorder {
  RecordConfig? config;
  int pauses = 0;
  int resumes = 0;
  final states = StreamController<RecordState>.broadcast();

  @override
  Future<bool> hasPermission({bool request = true}) async => true;

  @override
  Future<void> start(RecordConfig config, {required String path}) async {
    this.config = config;
  }

  @override
  Stream<RecordState> onStateChanged() => states.stream;

  @override
  Stream<Amplitude> onAmplitudeChanged(Duration interval) => const Stream.empty();

  @override
  Future<void> pause() async => pauses++;

  @override
  Future<void> resume() async => resumes++;

  @override
  Future<String?> stop() async => null;

  @override
  Future<void> cancel() async {}

  @override
  Future<void> dispose() async => states.close();
}

void main() {
  late _FakeRecorder rec;
  late ValueNotifier<bool> call;

  setUp(() {
    rec = _FakeRecorder();
    call = ValueNotifier(false);
    RecordingGuard.resetForTest();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => '/tmp');
  });

  Future<void> open(WidgetTester t) async {
    await t.pumpWidget(MaterialApp(
      home: MeetingRecorderScreen(recorder: () => rec, callConnected: call),
    ));
    await t.pump();
  }

  Future<void> start(WidgetTester t) async {
    await t.tap(find.byIcon(Icons.fiber_manual_record_rounded));
    await t.pump();
    await t.pump();
    expect(find.text('Recording — keep this screen open.'), findsOneWidget);
  }

  testWidgets('a notification cannot pause it: audio interruptions are off',
      (t) async {
    await open(t);
    await start(t);
    expect(rec.config!.audioInterruption, AudioInterruptionMode.none);
  });

  testWidgets('a pause nobody asked for shows as Paused, and Resume works',
      (t) async {
    await open(t);
    await start(t);

    rec.states.add(RecordState.pause);
    await t.pump();
    expect(find.text('Recording — keep this screen open.'), findsNothing);
    expect(find.textContaining('microphone was interrupted'), findsOneWidget);

    await t.tap(find.byIcon(Icons.play_arrow_rounded));
    await t.pump();
    expect(rec.resumes, 1);
    expect(find.text('Recording — keep this screen open.'), findsOneWidget);
  });

  testWidgets("the owner's own pause stays a plain Paused", (t) async {
    await open(t);
    await start(t);

    await t.tap(find.byIcon(Icons.pause_rounded));
    await t.pump();
    rec.states.add(RecordState.pause); // the recorder's echo of it
    await t.pump();
    expect(rec.pauses, 1);
    expect(find.text('Paused'), findsOneWidget);
  });

  testWidgets('a connected call pauses it and never resumes it by itself',
      (t) async {
    await open(t);
    await start(t);

    call.value = true;
    await t.pump();
    expect(rec.pauses, 1);
    expect(find.textContaining('Paused for your call'), findsOneWidget);

    // Resume during the call is refused.
    await t.tap(find.byIcon(Icons.play_arrow_rounded));
    await t.pump();
    expect(rec.resumes, 0);

    call.value = false;
    await t.pump();
    expect(rec.resumes, 0);
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);

    await t.tap(find.byIcon(Icons.play_arrow_rounded));
    await t.pump();
    expect(rec.resumes, 1);
    expect(find.text('Recording — keep this screen open.'), findsOneWidget);
  });

  testWidgets('it will not start during a call', (t) async {
    call.value = true;
    await open(t);
    await t.tap(find.byIcon(Icons.fiber_manual_record_rounded));
    await t.pump();
    expect(rec.config, isNull);
  });
}
