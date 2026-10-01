// THE SIX STATES (2026-09-30). The client wants the assistant to be the most
// obviously "AI" part of the app: idle, listening, thinking, responding (a
// tool at work), speaking and done must each look different — in colour
// AND in motion — and read by colour and words alone with "Remove
// animations" on. This pins that, the six-state caption words, the lit
// controls on the voice screen and the assistant's lit cards.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:myassistant/design/gpu_programs.dart';
import 'package:myassistant/design/neon_tokens.dart';
import 'package:myassistant/design/neon_widgets.dart';
import 'package:myassistant/features/assistant/state/assistant_engine.dart';
import 'package:myassistant/features/assistant/state/assistant_state.dart';
import 'package:myassistant/features/assistant/widgets/action_cards.dart';
import 'package:myassistant/models/user_document.dart';
import 'package:myassistant/models/vision_result.dart';
import 'package:myassistant/widgets/inline_voice.dart';
import 'package:myassistant/widgets/voice_orb.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _sceneKey = ValueKey('orb-scene');

Widget _rings(OrbMood mood,
        {ValueNotifier<double>? level, double Function()? speaker}) =>
    MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Center(
        child: RepaintBoundary(
          key: _sceneKey,
          child: ColoredBox(
            color: Neon.bg,
            child: SizedBox(
              width: 411,
              height: 330,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Positioned.fill(
                    child: VoiceOrbBackdrop(
                      orbSize: 168,
                      mood: mood,
                      levelListenable: level,
                      speakerLevel: speaker,
                    ),
                  ),
                  const VoiceOrb(size: 168, label: 'My Assistant'),
                ],
              ),
            ),
          ),
        ),
      ),
    );

/// Pumps [n] 16 ms frames; returns the largest push seen.
Future<double> _run(WidgetTester tester, int n) async {
  var most = 0.0;
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 16));
    final x = VoiceOrbBackdrop.debugPush;
    if (x > most) most = x;
  }
  return most;
}

Future<ByteData> _pixels(WidgetTester tester) async {
  final boundary =
      tester.renderObject<RenderRepaintBoundary>(find.byKey(_sceneKey));
  final bytes = await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2.625);
    return image.toByteData(format: ui.ImageByteFormat.rawRgba);
  });
  return bytes!;
}

double _meanDiff(ByteData a, ByteData b) {
  var sum = 0, n = 0;
  for (var i = 0; i < a.lengthInBytes; i += 4) {
    for (var c = 0; c < 3; c++) {
      sum += (a.getUint8(i + c) - b.getUint8(i + c)).abs();
    }
    n += 3;
  }
  return sum / n;
}

/// The average colour of the ring zone (a band round the disc), as rgb.
Future<List<double>> _ringTint(WidgetTester tester) async {
  final px = await _pixels(tester);
  final w = (411 * 2.625).round(), h = (330 * 2.625).round();
  final cx = w / 2, cy = h / 2, r = 84 * 2.625;
  final sum = [0.0, 0.0, 0.0];
  var n = 0;
  for (var y = 0; y < h; y += 3) {
    for (var x = 0; x < w; x += 3) {
      final d = Offset(x - cx, y - cy).distance / r;
      if (d < 1.15 || d > 1.75) continue;
      final i = (y * w + x) * 4;
      for (var c = 0; c < 3; c++) {
        sum[c] += px.getUint8(i + c);
      }
      n++;
    }
  }
  return [for (final s in sum) s / n];
}

void _phone(WidgetTester tester) {
  tester.view.devicePixelRatio = 2.625;
  tester.view.physicalSize = const Size(1080, 2340);
  addTearDown(tester.view.reset);
}

void main() {
  GoogleFonts.config.allowRuntimeFetching = false;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await GpuProgram.voiceBackdrop.load();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Neon.setDark(true); // the app is always dark now
  });

  tearDown(() {
    GpuProgram.enabled = true;
    Neon.setDark(false);
    final e = AssistantEngine.instance
      ..inlineVoice = false
      ..phase = AssistantPhase.idle
      ..debugVoiceOn = false
      ..speakerMuted = false;
    e.activityLabel.value = null;
    e.caption.value = null;
    e.micLevelListenable.value = 0;
  });

  group('six states, each its own colour', () {
    test('six colours, and paused wears idle\'s', () {
      final six = [
        OrbMood.idle,
        OrbMood.listening,
        OrbMood.thinking,
        OrbMood.responding,
        OrbMood.speaking,
        OrbMood.done,
      ].map(orbMoodColor).toSet();
      expect(six, hasLength(6));
      expect(orbMoodColor(OrbMood.paused), orbMoodColor(OrbMood.idle));
      // The app's semantic neon: done is the success tone, working the
      // act-on tone, the assistant's own cyan at rest.
      expect(orbMoodColor(OrbMood.done), NeonTone.success.rim.first);
      expect(orbMoodColor(OrbMood.responding), NeonTone.action.rim.first);
      expect(orbMoodColor(OrbMood.idle), NeonTone.tip.rim.first);
    });

    test('what the engine is doing picks the state', () {
      final e = AssistantEngine.instance;
      OrbMood at(AssistantPhase p, {bool live = false, bool paused = false}) {
        e
          ..phase = p
          ..debugVoiceOn = live;
        return orbMoodFor(e, micPaused: paused);
      }

      expect(at(AssistantPhase.idle), OrbMood.idle);
      expect(at(AssistantPhase.listening), OrbMood.listening);
      expect(at(AssistantPhase.thinking), OrbMood.thinking);
      expect(at(AssistantPhase.transcribing), OrbMood.thinking);
      expect(at(AssistantPhase.responding), OrbMood.responding);
      expect(at(AssistantPhase.searching), OrbMood.responding);
      expect(at(AssistantPhase.speaking), OrbMood.speaking);
      expect(at(AssistantPhase.completed, live: true), OrbMood.done);
      expect(at(AssistantPhase.listening, paused: true), OrbMood.paused);
      expect(at(AssistantPhase.idle, live: true), OrbMood.listening);
    });

    testWidgets('the rings take each state\'s light (GPU program)',
        (tester) async {
      Future<List<double>> tint(OrbMood m) async {
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(_rings(m));
        await _run(tester, 90);
        return _ringTint(tester);
      }

      final idle = await tint(OrbMood.idle);
      final listening = await tint(OrbMood.listening);
      final thinking = await tint(OrbMood.thinking);
      final responding = await tint(OrbMood.responding);
      final done = await tint(OrbMood.done);
      double lum(List<double> c) => c[0] + c[1] + c[2];
      expect(lum(idle), lessThan(lum(listening)), reason: 'idle is dim');
      expect(thinking[2], greaterThan(thinking[1]),
          reason: 'thinking is violet: more blue than green');
      expect(responding[0], greaterThan(listening[0] + 10),
          reason: 'working is magenta-orange: redder than listening');
      expect(done[1], greaterThan(responding[1] + 10),
          reason: 'done is green');
      await tester.pumpWidget(const SizedBox());
    });

    for (final mood in [OrbMood.idle, OrbMood.done]) {
      testWidgets('the Canvas painter draws the same light (${mood.name})',
          (tester) async {
        await tester.pumpWidget(_rings(mood));
        await _run(tester, 90);
        final gpu = await _pixels(tester);
        GpuProgram.enabled = false;
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(_rings(mood));
        await _run(tester, 90);
        final canvas = await _pixels(tester);
        expect(_meanDiff(gpu, canvas), lessThan(1.5));
        await tester.pumpWidget(const SizedBox());
      });
    }
  });

  group('six states, each its own motion', () {
    testWidgets('responding: the working light runs, and goes with the tool',
        (tester) async {
      await tester.pumpWidget(_rings(OrbMood.responding));
      await _run(tester, 60);
      expect(VoiceOrbBackdrop.debugArc, greaterThan(0.95));
      expect(SchedulerBinding.instance.transientCallbackCount, greaterThan(0),
          reason: 'a running light keeps moving');
      await tester.pumpWidget(_rings(OrbMood.listening));
      await _run(tester, 60);
      expect(VoiceOrbBackdrop.debugArc, lessThan(0.02));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('done: one outward pulse, then rest', (tester) async {
      await tester.pumpWidget(_rings(OrbMood.listening));
      await _run(tester, 40);
      expect(VoiceOrbBackdrop.debugPush.abs(), lessThan(1e-3));
      await tester.pumpWidget(_rings(OrbMood.done));
      final pulse = await _run(tester, 30);
      expect(pulse, greaterThan(0.03), reason: 'the pulse is seen');
      await _run(tester, 90);
      expect(VoiceOrbBackdrop.debugPush.abs(), lessThan(0.003),
          reason: 'one pulse, not a loop');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('speaking sways the ribbons; listening does not',
        (tester) async {
      await tester.pumpWidget(_rings(OrbMood.speaking, speaker: () => 0.4));
      var sway = 0.0;
      for (var i = 0; i < 200; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        sway = VoiceOrbBackdrop.debugSway.abs() > sway
            ? VoiceOrbBackdrop.debugSway.abs()
            : sway;
      }
      expect(sway, greaterThan(0.01));
      await tester.pumpWidget(_rings(OrbMood.listening));
      await _run(tester, 150);
      expect(VoiceOrbBackdrop.debugSway.abs(), lessThan(1e-3));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('"Remove animations": the colour and the words, nothing moving',
        (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
      await tester.pumpWidget(_rings(OrbMood.responding));
      await _run(tester, 40); // past the fade-in
      expect(VoiceOrbBackdrop.debugArc, 1.0,
          reason: 'the working light stands, lit, in its colour');
      expect(SchedulerBinding.instance.transientCallbackCount, 0,
          reason: 'and nothing ticks');
      await tester.pumpWidget(_rings(OrbMood.done));
      expect(await _run(tester, 30), 0, reason: 'no pulse');
      expect(SchedulerBinding.instance.transientCallbackCount, 0);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('the voice screen', () {
    Future<void> open(WidgetTester tester, AssistantPhase p) async {
      _phone(tester);
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: InlineCaptionOverlay()),
      ));
      AssistantEngine.instance
        ..inlineVoice = true
        ..phase = p
        ..notifyListeners();
      await tester.pump(const Duration(milliseconds: 400));
    }

    Future<void> close(WidgetTester tester) async {
      AssistantEngine.instance
        ..inlineVoice = false
        ..phase = AssistantPhase.idle
        ..debugVoiceOn = false
        ..notifyListeners();
      await tester.pumpWidget(const SizedBox());
      AssistantEngine.instance.cancelReconnect();
      await tester.pump(const Duration(seconds: 1));
    }

    testWidgets('a running tool says what it is doing, in the working colour',
        (tester) async {
      await open(tester, AssistantPhase.responding);
      AssistantEngine.instance.activityLabel.value = 'Checking your calendar…';
      await tester.pump(const Duration(milliseconds: 400));
      final words = find.text('Checking your calendar…');
      expect(words, findsOneWidget);
      final style = tester.widget<Text>(words).style!;
      expect(style.color,
          Color.lerp(NeonTone.action.rim.first, Neon.textHi, 0.35));
      expect(tester.widget<VoiceOrbBackdrop>(find.byType(VoiceOrbBackdrop)).mood,
          OrbMood.responding);
      await close(tester);
    });

    testWidgets('a landed turn on the fast voice is Done, not Listening',
        (tester) async {
      AssistantEngine.instance.debugVoiceOn = true;
      await open(tester, AssistantPhase.completed);
      await tester.pump(const Duration(milliseconds: 300)); // the cross-fade
      expect(find.text('Done'), findsOneWidget);
      expect(find.text('Listening…'), findsNothing);
      expect(tester.widget<VoiceOrbBackdrop>(find.byType(VoiceOrbBackdrop)).mood,
          OrbMood.done);
      await close(tester);
    });

    testWidgets('muted lights amber (the warning tone); sound on is a quiet rim',
        (tester) async {
      await open(tester, AssistantPhase.listening);
      expect(tester.widget<Text>(find.text('Sound on')).style!.color,
          Neon.textLo);
      AssistantEngine.instance
        ..speakerMuted = true
        ..notifyListeners();
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.widget<Text>(find.text('Muted')).style!.color,
          NeonTone.warning.ink);
      await close(tester);
    });

    test('no raw colours: tokens only', () {
      for (final f in [
        'lib/widgets/inline_voice.dart',
        'lib/widgets/caption_scroll.dart',
        'lib/features/assistant/widgets/action_cards.dart',
      ]) {
        final src = File(f).readAsStringSync();
        expect(RegExp(r'\bColors\.').hasMatch(src), isFalse, reason: f);
        expect(RegExp(r'\bColor\(0x').hasMatch(src), isFalse, reason: f);
        expect(src.contains('AppColors'), isFalse, reason: f);
        expect(src.contains('CircularProgressIndicator'), isFalse, reason: f);
      }
    });
  });

  group('the assistant\'s cards', () {
    Widget host(Widget card) => MaterialApp(
          home: Scaffold(
            backgroundColor: Neon.bg,
            body: Center(
              child: Padding(padding: const EdgeInsets.all(16), child: card),
            ),
          ),
        );

    List<BoxShadow>? shadowsOf(WidgetTester tester, String label) {
      final box = find
          .ancestor(of: find.text(label), matching: find.byType(Container))
          .first;
      final d = tester.widget<Container>(box).decoration as BoxDecoration?;
      return d?.boxShadow;
    }

    testWidgets('a decision: amber, the way forward glows, Cancel is a rim, '
        'and a yes lands with the lit tick', (tester) async {
      _noSensors(tester);
      final said = <bool>[];
      await tester.pumpWidget(host(ConfirmationCard(
        pending: const PendingConfirmation(
            action: 'place_call', question: 'Call Priya?'),
        onDecision: said.add,
      )));
      expect(tester.widget<GlowCard>(find.byType(GlowCard)).tone,
          NeonTone.warning);
      expect(shadowsOf(tester, 'Place call'), isNotEmpty,
          reason: 'the primary action glows');
      expect(shadowsOf(tester, 'Cancel'), isNull, reason: 'Cancel is a rim only');
      expect(tester.getSize(find.ancestor(
              of: find.text('Cancel'), matching: find.byType(Container)).first)
          .height, greaterThanOrEqualTo(48));

      await tester.tap(find.text('Place call'));
      await tester.pump();
      expect(said, [true]);
      expect(find.byType(NeonSuccess), findsOneWidget);
      expect(find.text('Placing the call'), findsOneWidget);
      expect(find.text('Place call'), findsNothing, reason: 'no second yes');
      await tester.pump(NeonSuccess.duration);
    });

    testWidgets('an offer that worked says so with the lit tick', (tester) async {
      _noSensors(tester);
      await tester.pumpWidget(host(EventOfferCard(
        event: _event(),
        onRemind: () async => true,
        onCalendar: () async => true,
        onClose: () {},
      )));
      expect(tester.widget<GlowCard>(find.byType(GlowCard)).tone, NeonTone.tip);
      await tester.tap(find.text('Remind me'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Reminder set'), findsOneWidget);
      expect(find.byType(NeonSuccess), findsOneWidget);
      await tester.pump(NeonSuccess.duration);
    });

    testWidgets('a call: green going well, the danger tone when it failed',
        (tester) async {
      _noSensors(tester);
      await tester.pumpWidget(host(const CallStatusCard(
          status: CallStatusInfo(status: 'dialing', contactName: 'Priya'))));
      expect(tester.widget<GlowCard>(find.byType(GlowCard)).tone,
          NeonTone.success);
      await tester.pumpWidget(host(const CallStatusCard(
          status: CallStatusInfo(status: 'failed', contactName: 'Priya'))));
      expect(tester.widget<GlowCard>(find.byType(GlowCard)).tone,
          NeonTone.danger);
    });

    testWidgets('a tool at work: the neon loader, then the lit tick',
        (tester) async {
      _noSensors(tester);
      await tester.pumpWidget(host(ToolCard(
          activity: ToolActivity(tool: 'calendar', label: 'Checking…'))));
      expect(find.byType(NeonLoader), findsOneWidget);
      await tester.pumpWidget(host(ToolCard(
          activity: ToolActivity(
              tool: 'calendar', label: 'Checked', completed: true))));
      expect(find.byType(NeonSuccess), findsOneWidget);
      await tester.pump(NeonSuccess.duration);
    });

    testWidgets('the gallery sits on the navy night, not black', (tester) async {
      await tester.pumpWidget(MaterialApp(
          home: DocumentGalleryScreen(documents: [_doc()])));
      await tester.pump();
      expect(tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
          Neon.bg);
    });
  });
}

UserDocument _doc() => const UserDocument(
      id: 7,
      filename: '',
      mime:
          'application/vnd.openxmlformats-officedocument.presentationml.presentation',
      title: 'Deck',
      category: 'other',
      docDate: '',
      summary: '',
      note: '',
      createdAt: 0,
    );

VisionAction _event() => VisionAction.fromJson({
      'type': 'calendar',
      'title': "Priya's wedding",
      'startIso': '2026-10-04T11:00:00+05:30',
      'location': 'Mysuru',
    })!;

/// The lit cards tilt with the gyroscope; the test has none.
void _noSensors(WidgetTester tester) {
  final m = tester.binding.defaultBinaryMessenger;
  const methods = MethodChannel('dev.fluttercommunity.plus/sensors/method');
  const gyro = EventChannel('dev.fluttercommunity.plus/sensors/gyroscope');
  m.setMockMethodCallHandler(methods, (_) async => null);
  m.setMockStreamHandler(gyro, MockStreamHandler.inline(onListen: (_, __) {}));
  addTearDown(() {
    m.setMockMethodCallHandler(methods, null);
    m.setMockStreamHandler(gyro, null);
  });
}
