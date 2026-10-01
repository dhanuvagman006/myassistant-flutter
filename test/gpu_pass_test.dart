// GPU PASS (2026-09-24). On his phone's Mali-G57 the most expensive things
// the app drew were the always-moving pictures: the voice screen's
// backdrop (an offscreen layer, three big gradient clouds, two stroked
// 121-point paths and a second pass to fade it, every frame of every
// session), the splash/Welcome orb (three blurred paths — each its own
// offscreen blur, nine to twelve render passes a frame) and the ambient
// light behind every tab (four overlapping gradients, redrawn on every
// frame that anything on the page moved).
//
// A phone's GPU time cannot be measured in a unit test (that is what
// integration_test/ux_bench_test.dart is for, on the phone). These pin
// what CAN be pinned:
//   * the three GPU programs are part of the app and load;
//   * with them, each picture is ONE rectangle — no offscreen layer, no
//     paths, no blur — and without them the old painter still draws;
//   * the GPU picture is the same picture (pixel for pixel, within a
//     rounding step or so), so nothing he knows changes;
//   * the captions pay for their fade mask only when they overflow;
//   * the orb keeps its painter across rebuilds and lays its name out once;
//   * the splash rings, Welcome's confetti and the activity pill's spinner
//     repaint on their own layers, not with the page round them.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:myassistant/design/accent_controller.dart';
import 'package:myassistant/design/gpu_programs.dart';
import 'package:myassistant/design/neon_tokens.dart';
import 'package:myassistant/design/orb_rings.dart';
import 'package:myassistant/features/assistant/state/assistant_engine.dart';
import 'package:myassistant/features/assistant/state/assistant_state.dart';
import 'package:myassistant/features/assistant/widgets/siri_orb.dart';
import 'package:myassistant/screens/auth/welcome_screen.dart';
import 'package:myassistant/screens/quick_task_screen.dart';
import 'package:myassistant/screens/splash_screen.dart';
import 'package:myassistant/widgets/activity_pill.dart';
import 'package:myassistant/widgets/ambient_background.dart';
import 'package:myassistant/widgets/inline_voice.dart';
import 'package:myassistant/widgets/caption_scroll.dart';
import 'package:myassistant/widgets/streaming_caption.dart';
import 'package:myassistant/widgets/voice_orb.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A Canvas that only counts what it is asked to do.
class _CountingCanvas implements Canvas {
  final Map<String, int> calls = {};
  final List<Paint> paints = [];

  int operator [](String name) => calls[name] ?? 0;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final name = invocation.memberName.toString();
    final call = name.substring(8, name.length - 2); // Symbol("x") -> x
    calls[call] = (calls[call] ?? 0) + 1;
    for (final a in invocation.positionalArguments) {
      if (a is Paint) paints.add(a);
    }
    return null;
  }
}

/// Runs the painter of the CustomPaint under [of] against a counting
/// canvas, at its laid-out size.
_CountingCanvas _record(WidgetTester tester, Finder of) {
  final ro = tester.renderObject<RenderCustomPaint>(
      find.descendant(of: of, matching: find.byType(CustomPaint)).first);
  final canvas = _CountingCanvas();
  ro.painter!.paint(canvas, ro.size);
  return canvas;
}

RenderRepaintBoundary _layerOf(RenderObject ro) {
  RenderObject? r = ro;
  while (r != null && r is! RenderRepaintBoundary) {
    r = r.parent;
  }
  return r! as RenderRepaintBoundary;
}

int _paints(RenderRepaintBoundary b) =>
    b.debugSymmetricPaintCount + b.debugAsymmetricPaintCount;

Future<ByteData> _pixels(WidgetTester tester, Key key, double ratio) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
  final bytes = await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: ratio);
    return image.toByteData(format: ui.ImageByteFormat.rawRgba);
  });
  return bytes!;
}

/// Mean difference per colour channel (0..255) and the share of pixels
/// that differ by more than a tenth of the range, over [a] and [b].
({double mean, double far}) _compare(ByteData a, ByteData b,
    {int width = 0, int trimRight = 0, int trimBottom = 0}) {
  var sum = 0, n = 0, far = 0;
  final pixels = a.lengthInBytes ~/ 4;
  final height = width == 0 ? 0 : pixels ~/ width;
  for (var p = 0; p < pixels; p++) {
    if (width > 0) {
      final x = p % width, y = p ~/ width;
      if (x >= width - trimRight || y >= height - trimBottom) continue;
    }
    var worst = 0;
    for (var c = 0; c < 3; c++) {
      final d = (a.getUint8(p * 4 + c) - b.getUint8(p * 4 + c)).abs();
      sum += d;
      if (d > worst) worst = d;
    }
    n++;
    if (worst > 24) far++;
  }
  return (mean: sum / (n * 3), far: far / n);
}

const _orbKey = ValueKey('orb-scene');

Widget _orbScene(OrbMood mood) => MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Center(
        child: RepaintBoundary(
          key: _orbKey,
          child: ColoredBox(
            color: const Color(0xFF05070A),
            child: SizedBox(
              width: 411,
              height: 330,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Positioned.fill(
                    child: VoiceOrbBackdrop(orbSize: 168, mood: mood, level: 0.6),
                  ),
                  const VoiceOrb(size: 168, label: 'My Assistant'),
                ],
              ),
            ),
          ),
        ),
      ),
    );

Future<void> _pumpOrbScene(WidgetTester tester, OrbMood mood) async {
  tester.view.physicalSize = const Size(1080, 900);
  tester.view.devicePixelRatio = 2.625;
  addTearDown(tester.view.reset);
  // A fresh scene each time, so two renders show the same moment.
  await tester.pumpWidget(const SizedBox());
  await tester.pumpWidget(_orbScene(mood));
  for (var i = 0; i < 60; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

const _siriKey = ValueKey('siri-scene');

Future<void> _pumpSiri(WidgetTester tester, AssistantPhase phase,
    {bool connected = true}) async {
  tester.view.physicalSize = const Size(700, 700);
  tester.view.devicePixelRatio = 2.625;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(const SizedBox());
  await tester.pumpWidget(MaterialApp(
    debugShowCheckedModeBanner: false,
    home: Center(
      child: RepaintBoundary(
        key: _siriKey,
        child: ColoredBox(
          color: const Color(0xFFF4F4F8),
          child: SizedBox(
            width: 220,
            height: 220,
            child: Center(
              child: SiriOrb(
                  size: 132, phase: phase, level: 0.3, connected: connected),
            ),
          ),
        ),
      ),
    ),
  ));
  for (var i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

const _ambientKey = ValueKey('ambient-scene');

Future<void> _pumpAmbient(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 2.625;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(const SizedBox());
  await tester.pumpWidget(const MaterialApp(
    debugShowCheckedModeBanner: false,
    home: RepaintBoundary(
      key: _ambientKey,
      child: AmbientBackground(child: SizedBox.expand()),
    ),
  ));
  await tester.pump();
}

void main() {
  // No network in tests: fall back to the default font.
  GoogleFonts.config.allowRuntimeFetching = false;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    // Loaded for real, outside any test's fake clock.
    await Future.wait([
      GpuProgram.voiceBackdrop.load(),
      GpuProgram.siriOrb.load(),
      GpuProgram.ambient.load(),
    ]);
  });

  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() {
    GpuProgram.enabled = true;
    Neon.setDark(false);
    AccentController.seed.value = AccentController.defaultSeed;
  });

  testWidgets('the three GPU programs ship with the app and load', (tester) async {
    for (final p in [
      GpuProgram.voiceBackdrop,
      GpuProgram.siriOrb,
      GpuProgram.ambient,
    ]) {
      expect(p.failed, isFalse, reason: '${p.asset} did not load');
      expect(p.program, isNotNull, reason: p.asset);
    }
  });

  group('the voice backdrop', () {
    // 2026-09-25, the client's rings: the GPU program now draws the
    // whole picture, ribbons and sparkles included — the 42 dust motes it
    // used to leave on the Canvas went with the old design. Without the
    // program: one prebuilt mesh per ring and one for the ribbons, and no
    // offscreen layer (the top/bottom melt went with the tunnel). Since the
    // review of 2026-09-25 also one for the picture's teal night laid
    // under the rings (the program draws it in its same one rectangle).
    testWidgets('is one rectangle: no offscreen layer, no paths, no second pass',
        (tester) async {
      await _pumpOrbScene(tester, OrbMood.listening);
      final gpu = _record(tester, find.byType(VoiceOrbBackdrop));
      expect(gpu['saveLayer'], 0, reason: 'an offscreen layer is back');
      expect(gpu['drawPath'], 0, reason: 'something is stroked as paths again');
      expect(gpu['drawRect'], 1, reason: 'one rectangle, drawn by the program');
      expect(gpu['drawCircle'] + gpu['drawVertices'], 0,
          reason: 'nothing is left on the Canvas beside the program');
      expect(gpu.paints.where((p) => p.maskFilter != null), isEmpty);

      // Without the program: the same table, as meshes built once.
      GpuProgram.enabled = false;
      final canvas = _record(tester, find.byType(VoiceOrbBackdrop));
      expect(canvas['saveLayer'], 0);
      expect(canvas['drawPath'], 0);
      expect(canvas['drawVertices'], OrbRings.elements.length + 2,
          reason: 'the wash, each ring, the ribbons');
    });

    for (final mood in [OrbMood.listening, OrbMood.thinking, OrbMood.speaking]) {
      testWidgets('looks the same drawn by the GPU program (${mood.name})',
          (tester) async {
        await _pumpOrbScene(tester, mood);
        final gpu = await _pixels(tester, _orbKey, 2.625);
        GpuProgram.enabled = false;
        await _pumpOrbScene(tester, mood);
        final canvas = await _pixels(tester, _orbKey, 2.625);
        final d = _compare(gpu, canvas);
        expect(d.mean, lessThan(1.5), reason: 'mean difference ${d.mean}');
        expect(d.far, lessThan(0.001),
            reason: '${(d.far * 100).toStringAsFixed(3)}% of pixels differ visibly');
      });
    }

    // Another theme colour moves every hue; both painters take it.
    testWidgets('looks the same drawn by the GPU program (Teal theme)',
        (tester) async {
      AccentController.seed.value = const Color(0xFF3FE0C8);
      await _pumpOrbScene(tester, OrbMood.listening);
      final gpu = await _pixels(tester, _orbKey, 2.625);
      GpuProgram.enabled = false;
      await _pumpOrbScene(tester, OrbMood.listening);
      final canvas = await _pixels(tester, _orbKey, 2.625);
      final d = _compare(gpu, canvas);
      expect(d.mean, lessThan(1.5), reason: 'mean difference ${d.mean}');
      expect(d.far, lessThan(0.001),
          reason: '${(d.far * 100).toStringAsFixed(3)}% of pixels differ visibly');
    });
  });

  group('the Siri orb (splash, Welcome)', () {
    testWidgets('is one rectangle with no blur, and never rebuilds for a frame',
        (tester) async {
      await _pumpSiri(tester, AssistantPhase.listening);
      final gpu = _record(tester, find.byType(SiriOrb));
      expect(gpu['drawRect'], 1);
      expect(gpu['drawPath'], 0, reason: 'the waves are blurred paths again');
      expect(gpu.paints.where((p) => p.maskFilter != null), isEmpty,
          reason: 'a blur on the GPU path costs an offscreen pass per wave');

      // Frames repaint its own layer; the widget is not rebuilt.
      CustomPaint paint() => tester.widget<CustomPaint>(find
          .descendant(of: find.byType(SiriOrb), matching: find.byType(CustomPaint))
          .first);
      final before = paint();
      final layer = _layerOf(tester.renderObject(find
          .descendant(of: find.byType(SiriOrb), matching: find.byType(CustomPaint))
          .first));
      layer.debugResetMetrics();
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(identical(paint(), before), isTrue,
          reason: 'the orb rebuilt its widgets for a frame');
      expect(_paints(layer), greaterThanOrEqualTo(9), reason: 'and it still moves');

      GpuProgram.enabled = false;
      final canvas = _record(tester, find.byType(SiriOrb));
      expect(canvas['drawPath'], 6, reason: 'the old painter still draws');
    });

    for (final (phase, connected) in [
      (AssistantPhase.listening, true), // Welcome
      (AssistantPhase.idle, false), // the splash's "connecting" breath
      (AssistantPhase.speaking, true),
    ]) {
      testWidgets('looks the same drawn by the GPU program (${phase.name}, '
          '${connected ? 'connected' : 'connecting'})', (tester) async {
        await _pumpSiri(tester, phase, connected: connected);
        final gpu = await _pixels(tester, _siriKey, 2.625);
        GpuProgram.enabled = false;
        await _pumpSiri(tester, phase, connected: connected);
        final canvas = await _pixels(tester, _siriKey, 2.625);
        final d = _compare(gpu, canvas);
        expect(d.mean, lessThan(1.5), reason: 'mean difference ${d.mean}');
        expect(d.far, lessThan(0.005),
            reason: '${(d.far * 100).toStringAsFixed(3)}% of pixels differ visibly');
      });
    }
  });

  group('the ambient light', () {
    testWidgets('is one opaque rectangle', (tester) async {
      await _pumpAmbient(tester);
      final canvas = _record(tester, find.byType(AmbientBackground));
      expect(canvas['drawRect'], 1);
      expect(canvas['drawCircle'], 0, reason: 'the pools are gradients again');
      expect(find.descendant(
              of: find.byType(AmbientBackground),
              matching: find.byType(DecoratedBox)),
          findsNothing);
    });

    for (final dark in [false, true]) {
      testWidgets('looks the same drawn by the GPU program (${dark ? 'dark' : 'light'})',
          (tester) async {
        Neon.setDark(dark);
        // The ribbons (dark only) are the program's own; the pools and the
        // wash must match the layers exactly.
        AmbientBackground.ribbons = false;
        addTearDown(() => AmbientBackground.ribbons = true);
        await _pumpAmbient(tester);
        final gpu = await _pixels(tester, _ambientKey, 1);
        GpuProgram.enabled = false;
        await _pumpAmbient(tester);
        expect(find.descendant(
                of: find.byType(AmbientBackground),
                matching: find.byType(DecoratedBox)),
            findsWidgets,
            reason: 'without the program, the layers as before');
        final canvas = await _pixels(tester, _ambientKey, 1);
        // The box is 411.4 x 891.4: the last, partial pixel row and column
        // are edge anti-aliasing, not the light.
        final d = _compare(gpu, canvas, width: 412, trimRight: 1, trimBottom: 1);
        expect(d.mean, lessThan(1.5), reason: 'mean difference ${d.mean}');
        expect(d.far, 0);
      });
    }
  });

  group('the voice screen', () {
    Future<void> openSession(WidgetTester tester) async {
      tester.view.devicePixelRatio = 2.625;
      tester.view.physicalSize = const Size(1080, 1500); // a short phone
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: InlineCaptionOverlay()),
      ));
      AssistantEngine.instance
        ..inlineVoice = true
        ..phase = AssistantPhase.listening
        ..notifyListeners();
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }
    }

    Future<void> closeSession(WidgetTester tester) async {
      AssistantEngine.instance
        ..inlineVoice = false
        ..phase = AssistantPhase.idle
        ..notifyListeners();
      AssistantEngine.instance.caption.value = null;
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }
    }

    int masks(WidgetTester tester) =>
        tester.layers.whereType<ShaderMaskLayer>().length;

    testWidgets('the captions pay for a fade mask only while they overflow',
        (tester) async {
      await openSession(tester);
      final engine = AssistantEngine.instance;
      engine.caption.value = const CaptionLine('you', 'What is on today?');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('What is on today?'), findsOneWidget);
      expect(masks(tester), 0,
          reason: 'a mask over one short line is a full-size layer for nothing');
      final captions = find.byType(CaptionScroll);
      final words = find.descendant(of: captions, matching: find.byType(StreamingCaption));
      final kept = tester.state(words);

      // The same turn going on and on: the words above the view (scrolled
      // past to follow the newest line) fade at the top edge.
      final long = [
        'What is on today?',
        for (var i = 1; i <= 14; i++)
          'Sentence number $i of a long answer that fills the screen.'
      ].join(' ');
      engine.caption.value = CaptionLine('you', long);
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }
      final scroll = tester.state<ScrollableState>(
          find.descendant(of: captions, matching: find.byType(Scrollable)));
      expect(scroll.position.maxScrollExtent, greaterThan(0),
          reason: 'the test needs a reply taller than its space');
      expect(masks(tester), 1,
          reason: 'an overflowing reply fades where there is more to see');
      expect(identical(tester.state(words), kept), isTrue,
          reason: 'the mask coming on rebuilt the captions from nothing');

      // Short again: the mask goes.
      engine.caption.value = const CaptionLine('you', 'Thanks.');
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }
      expect(masks(tester), 0);
      await closeSession(tester);
    });

    // 2026-09-25: the mic is drawn as shapes now (the icon font's mic has
    // no base bar, the client's picture's does); the text laid out once is
    // the assistant's name under it.
    testWidgets('the orb keeps its painter, and lays its name out once',
        (tester) async {
      await openSession(tester);
      final laidOut = debugOrbLabelLayouts;
      CustomPainter painter() => tester
          .widget<CustomPaint>(find
              .descendant(of: find.byType(VoiceOrb), matching: find.byType(CustomPaint))
              .first)
          .painter!;
      final first = painter();
      // The caption pacer and the engine rebuild the screen many times a
      // session.
      for (var i = 0; i < 6; i++) {
        AssistantEngine.instance.notifyListeners();
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(identical(painter(), first), isTrue,
          reason: 'a rebuild gave the disc a new painter, and it built '
              'its gradients again');
      expect(debugOrbLabelLayouts, laidOut,
          reason: 'a rebuild laid the name out again');
      final orb = _record(tester, find.byType(VoiceOrb));
      expect(orb['drawParagraph'], 1, reason: 'the name, and no other text');
      expect(orb.paints.where((p) => p.maskFilter != null), isEmpty,
          reason: 'a blur in the still centre costs a pass on every frame');
      await closeSession(tester);
    });
  });

  // The disc no longer listens at all (2026-09-25: it holds still); the
  // rings round it read the level on their own frames.
  testWidgets('the quick-task orb reads the mic level itself', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: QuickTaskScreen()));
    await tester.pump();
    expect(tester.widget<VoiceOrbBackdrop>(find.byType(VoiceOrbBackdrop)).levelListenable,
        isNotNull, reason: 'each mic reading rebuilt the whole screen');
    await tester.pumpWidget(const SizedBox());
  });

  group('animated painters repaint on their own layers', () {
    testWidgets('the splash: rings, loader and orb move, the page does not',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(home: SplashScreen()));
      // Past the one-off entrance.
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      final page = _layerOf(tester.renderObject(find.text('MyAssistant')));
      // By key (2026-09-30): the splash now stands on the shared sky,
      // whose own CustomPaint comes first under it.
      final rings =
          _layerOf(tester.renderObject(find.byKey(SplashScreen.ringsKey)));
      expect(identical(page, rings), isFalse);
      page.debugResetMetrics();
      rings.debugResetMetrics();
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(_paints(rings), greaterThanOrEqualTo(9));
      expect(_paints(page), 0,
          reason: 'the whole splash was re-recorded with the rings');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets("Welcome: the confetti falls, the page it falls over holds still",
        (tester) async {
      await tester.pumpWidget(MaterialApp(home: WelcomeScreen(onDone: () {})));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      final page = _layerOf(tester.renderObject(find.text('Welcome aboard!')));
      page.debugResetMetrics();
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(_paints(page), 0,
          reason: 'the confetti re-recorded the page under it');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the activity pill: the spinner turns, its label holds still',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: Center(child: AssistantActivityPill())),
      ));
      AssistantEngine.instance.activityLabel.value = 'Searching the web…';
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final label = _layerOf(tester.renderObject(find.text('Searching the web')));
      final spinner = _layerOf(tester.renderObject(find
          .descendant(
              of: find.byType(AssistantActivityPill),
              matching: find.byType(CustomPaint))
          .first));
      expect(identical(label, spinner), isFalse);
      label.debugResetMetrics();
      spinner.debugResetMetrics();
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(_paints(spinner), greaterThanOrEqualTo(9));
      expect(_paints(label), 0,
          reason: 'each spinner frame re-recorded the pill and its label');
      AssistantEngine.instance.activityLabel.value = null;
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpWidget(const SizedBox());
    });
  });
}
