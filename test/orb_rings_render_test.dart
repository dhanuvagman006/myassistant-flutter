// THE CLIENT'S RINGS, RENDERED (2026-09-25) — so the new voice screen can
// be held up against his reference picture without taking over anybody's
// phone to look at it.
//
//   flutter test test/orb_rings_render_test.dart
//       --dart-define=ORB_RENDERS=<folder>
//
// draws the whole voice screen at the owner's phone's size (1080 x 2340 at
// 2.625, 411 x 891 dp) and writes, for each state, the full screen and a
// crop round the orb (default folder: build/orb_renders):
//   * idle (connecting) — completely still, the picture itself;
//   * listening, his mic quiet (0.2) — the rings a little way out;
//   * listening, loud (0.8) — caught at the top of a push;
//   * speaking (0.6) — her voice moving them;
//   * the dark and the light app theme (the voice screen is night in
//     both; only its ground takes the theme's ink);
//   * and, beyond those, thinking and the Teal theme colour.
// Drawn with the Canvas painter (the fallback) and, for comparison, with
// the GPU program.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:myassistant/design/accent_controller.dart';
import 'package:myassistant/design/gpu_programs.dart';
import 'package:myassistant/design/neon_tokens.dart';
import 'package:myassistant/features/assistant/state/assistant_engine.dart';
import 'package:myassistant/features/assistant/state/assistant_state.dart';
import 'package:myassistant/widgets/inline_voice.dart';
import 'package:myassistant/widgets/voice_orb.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _out = String.fromEnvironment('ORB_RENDERS', defaultValue: 'build/orb_renders');
const _screen = ValueKey('voice-screen');

Future<void> _open(WidgetTester tester) async {
  tester.view.devicePixelRatio = 2.625;
  tester.view.physicalSize = const Size(1080, 2340);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(const SizedBox());
  await tester.pumpWidget(const MaterialApp(
    debugShowCheckedModeBanner: false,
    home: RepaintBoundary(
      key: _screen,
      child: Scaffold(body: InlineCaptionOverlay()),
    ),
  ));
}

void _phase(AssistantPhase p, {double level = 0}) {
  AssistantEngine.instance
    ..inlineVoice = true
    ..phase = p
    ..notifyListeners();
  AssistantEngine.instance.micLevelListenable.value = level;
}

Future<void> _frames(WidgetTester tester, int n) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// Writes the screen, and a crop round the orb, as `<name>.png` and
/// `<name>_orb.png`.
Future<void> _save(WidgetTester tester, String name) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(_screen));
  final orb = tester.getRect(find.byType(VoiceOrb));
  final png = await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2.625);
    final full = await image.toByteData(format: ui.ImageByteFormat.png);
    // 1080 wide, 1000 high round the disc's middle — about the
    // reference's own framing.
    final cy = orb.center.dy * 2.625;
    final src = Rect.fromLTWH(0, (cy - 500).clamp(0, image.height - 1000.0), 1080, 1000);
    final rec = ui.PictureRecorder();
    Canvas(rec).drawImageRect(image, src, const Rect.fromLTWH(0, 0, 1080, 1000), Paint());
    final crop = await rec.endRecording().toImage(1080, 1000);
    final cropped = await crop.toByteData(format: ui.ImageByteFormat.png);
    return (full!, cropped!);
  });
  Directory(_out).createSync(recursive: true);
  File('$_out/$name.png').writeAsBytesSync(png!.$1.buffer.asUint8List());
  File('$_out/${name}_orb.png').writeAsBytesSync(png.$2.buffer.asUint8List());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The engine's audio plugins register when it is first built; nothing
  // here plays or records, so their channels just say yes.
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  for (final name in [
    'com.llfbandit.record/messages',
    'xyz.luan/audioplayers.global',
    'xyz.luan/audioplayers',
  ]) {
    messenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null);
  }

  setUpAll(() async {
    // The bundled Manrope, for real, so the name is drawn in its font.
    GoogleFonts.config.allowRuntimeFetching = false;
    for (final w in NeonType.weights) {
      GoogleFonts.manrope(fontWeight: w);
    }
    await GoogleFonts.pendingFonts();
    // And the icon font, so the Sound button and the text box's icons are
    // drawn as icons, not as the test font's boxes.
    await (FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
        .load();
    await GpuProgram.voiceBackdrop.load();
    // Build the engine here, once: its audio players ask their plugins for
    // event streams nobody here needs, and say so loudly.
    final report = FlutterError.onError;
    FlutterError.onError = (_) {};
    AssistantEngine.instance;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    FlutterError.onError = report;
  });

  setUp(() {
    messenger.setMockStreamHandler(
        const EventChannel('xyz.luan/audioplayers.global/events'),
        MockStreamHandler.inline(onListen: (_, __) {}));
    SharedPreferences.setMockInitialValues({});
    VoiceOrbBackdrop.debugPush = 0;
    // What a phone starts with: the default theme colour, applied.
    Neon.setAccent(AccentController.defaultSeed);
  });
  tearDown(() {
    AssistantEngine.instance.debugStarting = false;
    GpuProgram.enabled = true;
    Neon.setDark(false);
    Neon.setAccent(null);
    AssistantEngine.instance
      ..inlineVoice = false
      ..phase = AssistantPhase.idle;
    AssistantEngine.instance.micLevelListenable.value = 0;
  });

  for (final gpu in [false, true]) {
    final tag = gpu ? 'gpu' : 'canvas';

    // 2026-09-30, the six states: idle is the picture in a dim cyan light,
    // breathing slowly (a push of under 2%).
    testWidgets('idle: calm, dim, a slow breath ($tag)', (tester) async {
      GpuProgram.enabled = gpu;
      await _open(tester);
      // Connecting: the session is up, nothing is heard yet.
      AssistantEngine.instance.debugStarting = true;
      _phase(AssistantPhase.idle);
      await _frames(tester, 60);
      expect(find.text('One moment…'), findsWidgets);
      expect(VoiceOrbBackdrop.debugPush.abs(), lessThan(0.02));
      await _save(tester, '1_idle_$tag');
    });

    testWidgets('listening, quiet (0.2) ($tag)', (tester) async {
      GpuProgram.enabled = gpu;
      await _open(tester);
      _phase(AssistantPhase.listening, level: 0.2);
      await _frames(tester, 90);
      expect(VoiceOrbBackdrop.debugPush, greaterThan(0.005));
      await _save(tester, '2_listening_quiet_$tag');
    });

    testWidgets('listening, loud (0.8), at the top of a push ($tag)', (tester) async {
      GpuProgram.enabled = gpu;
      await _open(tester);
      _phase(AssistantPhase.listening);
      await _frames(tester, 40); // bloomed in, at rest
      AssistantEngine.instance.micLevelListenable.value = 0.8;
      // Frame by frame until the push stops growing: its peak.
      var last = -1.0;
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 8));
        final now = VoiceOrbBackdrop.debugPush;
        if (now < last) break;
        last = now;
      }
      expect(last, greaterThan(0.05));
      await _save(tester, '3_listening_loud_peak_$tag');
    });

    testWidgets('speaking (0.6) ($tag)', (tester) async {
      GpuProgram.enabled = gpu;
      await _open(tester);
      _phase(AssistantPhase.speaking, level: 0.6);
      await _frames(tester, 90);
      expect(VoiceOrbBackdrop.debugPush, greaterThan(0.03));
      await _save(tester, '4_speaking_$tag');
    });

    for (final dark in [true, false]) {
      testWidgets('${dark ? 'dark' : 'light'} app theme ($tag)', (tester) async {
        GpuProgram.enabled = gpu;
        Neon.setDark(dark);
        await _open(tester);
        _phase(AssistantPhase.listening, level: 0.2);
        await _frames(tester, 90);
        await _save(tester, '5_theme_${dark ? 'dark' : 'light'}_$tag');
      });
    }
  }

  // Beyond the four states asked for: thinking (a slow breath), and the
  // rings in another theme colour.
  testWidgets('thinking (canvas)', (tester) async {
    GpuProgram.enabled = false;
    await _open(tester);
    _phase(AssistantPhase.thinking);
    await _frames(tester, 110); // near the top of a breath
    await _save(tester, '6_thinking_canvas');
  });

  // 2026-09-30: a tool at work — magenta into orange, and the working
  // light running round the inner ring.
  for (final gpu in [false, true]) {
    final tag = gpu ? 'gpu' : 'canvas';
    testWidgets('responding ($tag)', (tester) async {
      GpuProgram.enabled = gpu;
      await _open(tester);
      _phase(AssistantPhase.responding);
      await _frames(tester, 60);
      expect(VoiceOrbBackdrop.debugArc, greaterThan(0.95));
      await _save(tester, '8_responding_$tag');
    });
  }

  testWidgets('Teal theme colour (canvas)', (tester) async {
    GpuProgram.enabled = false;
    const teal = Color(0xFF3FE0C8);
    AccentController.seed.value = teal;
    Neon.setAccent(teal);
    addTearDown(() => AccentController.seed.value = AccentController.defaultSeed);
    await _open(tester);
    _phase(AssistantPhase.listening, level: 0.2);
    await _frames(tester, 90);
    await _save(tester, '7_theme_teal_canvas');
  });
}
