// THE CLIENT'S RINGS (2026-09-25). The client, about the voice screen:
// "Change outer rendering to other style", then his picture and "Make it
// something like this, when it's on, only the speaker should move forward
// and backwards". The owner: "the exact same surrounding design around the
// orb as this, with animation while speaking and listening, moving forward
// and backward".
//
// These pin what that means in code:
//   * the GPU program and the Canvas painter draw ONE table — the shader
//     carries a copy of every number, and this reads it back;
//   * the default theme is the picture's own colours, and another theme
//     colour moves every hue toward itself;
//   * the rings push out with his voice while listening and with hers
//     while speaking (never with the wrong one) — far enough that an
//     ordinary voice reads as a push, not a shimmer — breathe while
//     thinking, and hold completely still — no ticker — at rest;
//   * "Remove animations" holds them still;
//   * the whole ring system fits its slot on the voice screen, at rest and
//     with the keyboard up, so it never runs under the words or the bar.
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:myassistant/design/accent_controller.dart';
import 'package:myassistant/design/orb_rings.dart';
import 'package:myassistant/features/assistant/state/assistant_engine.dart';
import 'package:myassistant/features/assistant/state/assistant_state.dart';
import 'package:myassistant/widgets/inline_voice.dart';
import 'package:myassistant/widgets/voice_orb.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Every number in a call like `lens(acc, r1, a1, 1.207, 0.006, ...)`.
List<double> _numbers(String args) => RegExp(r'-?\d+\.\d+|-?\d+(?=\s*[,)])')
    .allMatches(args)
    .map((m) => double.parse(m.group(0)!))
    .toList();

Widget _rings(OrbMood mood,
        {ValueNotifier<double>? level,
        double Function()? speaker,
        bool still = false}) =>
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: still),
        child: Center(
          child: SizedBox(
            width: 411,
            height: 330,
            child: VoiceOrbBackdrop(
              orbSize: 168,
              mood: mood,
              levelListenable: level,
              speakerLevel: speaker,
            ),
          ),
        ),
      ),
    );

/// Pumps [n] frames of 16 ms and returns the largest push seen.
Future<double> _run(WidgetTester tester, int n) async {
  var most = 0.0;
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 16));
    most = most > VoiceOrbBackdrop.debugPush ? most : VoiceOrbBackdrop.debugPush;
  }
  return most;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    VoiceOrbBackdrop.debugPush = 0;
  });

  group('one table, two painters', () {
    final frag = File('shaders/voice_backdrop.frag').readAsStringSync();

    test('the GPU program carries every ring number the Canvas painter uses', () {
      final calls = RegExp(r'acc = (lens|ring)\(acc, r(\d), a(\d), ([^;]*)\);')
          .allMatches(frag)
          .toList();
      expect(calls, hasLength(OrbRings.elements.length),
          reason: 'the program draws a different number of elements');
      for (var i = 0; i < calls.length; i++) {
        final el = OrbRings.elements[i];
        final m = calls[i];
        final n = _numbers(m.group(4)!.split(', u').first);
        expect(m.group(1), el.lens ? 'lens' : 'ring', reason: el.name);
        expect(int.parse(m.group(2)!), el.tier, reason: '${el.name}: its push');
        expect(m.group(4), contains('uC$i.rgb'), reason: '${el.name}: its colour');
        final want = el.lens
            ? [el.r0, el.drift, el.h, el.e, el.g, el.a0, el.a1, el.tip, el.fade0, el.fade1]
            : [el.r0, el.h, el.e, el.g, el.a0, el.a1, el.side];
        expect(n, want, reason: '${el.name} differs between the two painters');
        if (!el.lens) expect(m.group(4), contains('uS$i.rgb'));
      }
    });

    test('...and every ribbon number', () {
      expect(frag, contains('for (int j = 0; j < ${OrbRings.strands}; j++)'));
      expect(frag, contains('TAU * float(j) / ${OrbRings.strands}.0'));
      expect(frag, contains('TAU * ${OrbRings.twist} * u'));
      expect(frag, contains('TAU * ${OrbRings.accentTwist} * u'));
      expect(frag, contains('${OrbRings.strandHalf}, a, col)'));
      expect(RegExp('${OrbRings.accentHalf}, aa, uRibAccent').allMatches(frag),
          hasLength(OrbRings.accents));
      final sparkles = RegExp(r'sparkle\(acc, rp, side, ([^;]*)\);')
          .allMatches(frag)
          .map((m) => _numbers(m.group(1)!))
          .toList();
      final want = [
        for (final (x, dy, r, a) in [...OrbRings.sparklesRight, ...OrbRings.sparklesLeft])
          [x, dy, r, a],
      ];
      expect(sparkles, want);
      // The ribbons' shape: the program's functions against the table's,
      // sampled along the ribbon (the same polynomials, so they agree).
      double poly(String body, double u) {
        final t = _numbers(body);
        return t[0] + t[1] * u + t[2] * u * u;
      }

      final mid = RegExp(r'side > 0\.0 \? (-?[\d.]+ \+ [\d.]+ \* u \+ [\d.]+ \* u \* u)\s*'
              r': (-?[\d.]+ - [\d.]+ \* u \+ [\d.]+ \* u \* u);')
          .firstMatch(frag)!;
      for (var u = 0.0; u <= 1.0; u += 0.1) {
        expect(poly(mid.group(1)!, u), closeTo(OrbRings.ribbonMid(u, 1), 1e-9));
        final left = _numbers(mid.group(2)!);
        expect(left[0] - left[1] * u + left[2] * u * u,
            closeTo(OrbRings.ribbonMid(u, -1), 1e-9));
      }
    });

    // 2026-09-25, review: the ribbons' fade, the sheet over the lenses, the
    // strands' strength and the teal wash under the rings are copies too.
    test('...and the fade, the sheet, the strengths and the wash', () {
      String body(String head) =>
          RegExp(RegExp.escape(head) + r'\s*\{([^}]*)\}').firstMatch(frag)!.group(1)!;
      expect(_numbers(body('float ribbonEnvelope(float u)')), [
        OrbRings.fadeIn0, OrbRings.fadeIn1, 1.0, OrbRings.fadeOut0, OrbRings.fadeOut1,
      ]);
      expect(_numbers(body('float sheetAlpha(float u)')), [
        OrbRings.sheetFloor, OrbRings.sheetNear, 1.0, OrbRings.sheetThin0,
        OrbRings.sheetThin1,
      ]);
      double strength(String name) => double.parse(
          RegExp('float $name' r' = ([\d.]+) \* env').firstMatch(frag)!.group(1)!);
      expect(strength('a'), OrbRings.strandStrength);
      expect(strength('aa'), OrbRings.accentStrength);
      expect(_numbers(RegExp(r'if \(X > ([\d.]+) && X < ([\d.]+)\)').firstMatch(frag)!.group(0)!),
          [OrbRings.ribbonFrom, OrbRings.ribbonTo]);
      expect(_numbers(body('vec4 wash(vec2 q, float R, float halfHeight)')), [
        OrbRings.washGone, 0.5, 1.0, 1.0, OrbRings.washFull, OrbRings.washGone,
      ]);
      // The squash the program works out is the table's.
      for (final half in [1.0, 1.85, 1.96, 3.0]) {
        expect(OrbRings.washSquash(half), (half / 2.7).clamp(0.5, 1.0));
      }
    });

    test('the ribbons are gone before the screen edge, past the outer ring', () {
      // The picture's ends are faint and gone by about 2 R (2026-09-25,
      // review: ours ran on to 2.25 R, twice as bright past the ring).
      expect(OrbRings.ribbonEnvelope(OrbRings.ribbonU(OrbRings.ribbonTo)), 0);
      expect(OrbRings.ribbonTo, lessThanOrEqualTo(2.1));
      // ...but the sheet still washes the lenses at 1.6 R (it was 0.135).
      expect(OrbRings.sheetAlpha(OrbRings.ribbonU(1.62)), greaterThan(0.25));
    });

    test('the teal wash ends at its box, top and bottom, never in a line', () {
      // The slot reaches 1.85-1.96 R above and below the middle on the
      // phones the layout sweep uses; the wash must be nothing there.
      for (final half in [1.85, 1.96, 2.2]) {
        final squash = OrbRings.washSquash(half);
        expect(OrbRings.washAlpha(half / squash), closeTo(0, 1e-9), reason: '$half R');
        expect(OrbRings.washAlpha(0.8 * half / squash), greaterThan(0.3));
      }
      expect(OrbPalette.of(AccentController.defaultSeed).wash, const Color(0xFF0B1E20),
          reason: "the picture's own night");
    });

    test('at the top of a full push, overshoot and all, the rings stay inside the frame',
        () {
      // An under-damped spring overshoots a step by this much.
      const z = OrbRings.damping;
      final overshoot = 1 + math.exp(-z * math.pi / math.sqrt(1 - z * z));
      final frame = OrbRings.elements.firstWhere((e) => e.tier == OrbRings.frame);
      for (final el in OrbRings.elements) {
        if (el.tier == OrbRings.frame) continue;
        final out = (el.r0 + el.drift + el.h + el.e) *
            (1 + OrbRings.push[el.tier] * overshoot);
        expect(out, lessThan(frame.r0 - frame.h), reason: el.name);
      }
    });

    test('the whole system fits the reach a slot is sized by', () {
      for (final el in OrbRings.elements) {
        expect(el.reach, lessThanOrEqualTo(OrbRings.reach), reason: el.name);
      }
      expect(VoiceOrbBackdrop.reach, OrbRings.reach);
    });
  });

  group('the colours', () {
    test("the default theme colour is the picture's own", () {
      final p = OrbPalette.of(AccentController.defaultSeed);
      expect(p.elements[5], const Color(0xFF10FCD1), reason: 'the mint lens');
      expect(p.elements[9], const Color(0xFF16DEBA), reason: 'the mint ring');
      expect(p.rim, const Color(0xFFD5FFFD));
      expect(p.disc.first, const Color(0xFF0B0C28));
      expect(identical(OrbPalette.of(AccentController.defaultSeed), p), isTrue,
          reason: 'worked out once, not per frame');
    });

    test('another theme colour moves every hue toward itself', () {
      const teal = Color(0xFF3FE0C8);
      final home = OrbPalette.of(AccentController.defaultSeed);
      final p = OrbPalette.of(teal);
      final tealHue = HSLColor.fromColor(teal).hue;
      double gap(double a, double b) {
        final d = (a - b).abs() % 360;
        return d > 180 ? 360 - d : d;
      }

      for (var i = 0; i < home.elements.length; i++) {
        final a = HSLColor.fromColor(home.elements[i]);
        final b = HSLColor.fromColor(p.elements[i]);
        expect(b.lightness, closeTo(a.lightness, 0.01),
            reason: 'element $i: the light stays the picture\'s');
        expect(gap(b.hue, tealHue), lessThan(60), reason: 'element $i');
      }
      // The violet lens is the far end of the picture's hues: it moves
      // most, and ends up near the chosen colour.
      expect(gap(HSLColor.fromColor(p.elements[8]).hue, tealHue),
          lessThan(gap(HSLColor.fromColor(home.elements[8]).hue, tealHue)));
    });

    test('the name in the disc', () {
      expect(orbLabelFor('Assistant'), 'My Assistant');
      expect(orbLabelFor(''), 'My Assistant');
      expect(orbLabelFor('Maya'), 'Maya');
    });
  });

  group('only the speaker moves', () {
    testWidgets('listening: his voice pushes the rings out, silence brings them back',
        (tester) async {
      final level = ValueNotifier<double>(0);
      await tester.pumpWidget(_rings(OrbMood.listening, level: level));
      await _run(tester, 40); // bloomed in
      expect(VoiceOrbBackdrop.debugPush.abs(), lessThan(1e-3));

      level.value = 0.8;
      final pushed = await _run(tester, 9); // ~150 ms
      expect(pushed, greaterThan(0.03), reason: 'a loud word must move them at once');

      level.value = 0;
      await _run(tester, 60);
      expect(VoiceOrbBackdrop.debugPush.abs(), lessThan(0.002),
          reason: 'and they come back when he stops');
      expect(SchedulerBinding.instance.transientCallbackCount, greaterThan(0),
          reason: 'still listening: ready for the next word');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('an ordinary voice is a push you can see, not a shimmer', (tester) async {
      // 2026-09-25, review: the mic reads speech at about 0.2-0.4, and at
      // the first pushes that moved the inner ring 2-3 dp at the sides —
      // a shimmer at arm's length — and a quiet word looked like the
      // thinking breath (which stays under 0.022, see below).
      final level = ValueNotifier<double>(0);
      await tester.pumpWidget(_rings(OrbMood.listening, level: level));
      await _run(tester, 40);
      final ring = OrbRings.elements.firstWhere((e) => e.name == 'ring-mint');
      // On his phone the disc is 168 dp across: R is 84 dp.
      double dp(double push) => push * ring.r0 * 84;
      level.value = 0.3;
      await _run(tester, 40);
      expect(dp(VoiceOrbBackdrop.debugPush), greaterThan(4.0),
          reason: 'an ordinary voice barely moved the speaker');
      level.value = 0.2;
      await _run(tester, 40);
      expect(VoiceOrbBackdrop.debugPush, greaterThan(0.03),
          reason: 'a quiet word looks like the thinking breath');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('speaking: her voice moves them, his mic does not', (tester) async {
      final mic = ValueNotifier<double>(0.9);
      var hers = 0.0;
      await tester.pumpWidget(
          _rings(OrbMood.speaking, level: mic, speaker: () => hers));
      final ignored = await _run(tester, 40);
      expect(ignored, lessThan(1e-3),
          reason: 'the mic (her own voice coming back in) moved the rings');
      hers = 0.8;
      expect(await _run(tester, 9), greaterThan(0.03));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('thinking: a slow, small breath', (tester) async {
      await tester.pumpWidget(_rings(OrbMood.thinking));
      var most = 0.0, least = 1.0;
      for (var i = 0; i < 300; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        final x = VoiceOrbBackdrop.debugPush;
        if (i > 60) {
          most = x > most ? x : most;
          least = x < least ? x : least;
        }
      }
      expect(most, greaterThan(0.008), reason: 'it breathes');
      expect(most, lessThan(0.022), reason: 'gently');
      expect(least, greaterThan(-0.004));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('at rest: exactly the picture, and no ticker', (tester) async {
      await tester.pumpWidget(_rings(OrbMood.idle, level: ValueNotifier(0.9)));
      await _run(tester, 60);
      expect(VoiceOrbBackdrop.debugPush, 0);
      expect(SchedulerBinding.instance.transientCallbackCount, 0,
          reason: 'a resting orb must not tick');
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('"Remove animations": the rings hold still, even while he talks',
        (tester) async {
      await tester.pumpWidget(
          _rings(OrbMood.listening, level: ValueNotifier(0.8), still: true));
      final most = await _run(tester, 40); // past the 0.47 s fade
      expect(most, 0, reason: 'the rings moved with animations off');
      expect(SchedulerBinding.instance.transientCallbackCount, 0,
          reason: 'faded in, nothing left to animate');
    });
  });

  group('on the voice screen', () {
    // The engine's audio plugins register when it is first built.
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in [
      'com.llfbandit.record/messages',
      'xyz.luan/audioplayers.global',
      'xyz.luan/audioplayers',
    ]) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null);
    }
    setUpAll(() async {
      final report = FlutterError.onError;
      FlutterError.onError = (_) {};
      AssistantEngine.instance;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      FlutterError.onError = report;
    });
    tearDown(() {
      AssistantEngine.instance
        ..inlineVoice = false
        ..phase = AssistantPhase.idle;
      AssistantEngine.instance.micLevelListenable.value = 0;
    });

    // The layout sweep's phones (the owner's, and a small one, each with
    // its keyboard), and the short phone the GPU tests use.
    for (final (name, w, h, dpr, kb) in [
      ("the owner's phone", 1080.0, 2340.0, 2.625, 1190.0),
      ('a small phone', 720.0, 1280.0, 2.0, 560.0),
      ('a short phone', 1080.0, 1500.0, 2.625, 0.0),
    ]) {
      testWidgets('the whole ring system fits its slot on $name', (tester) async {
        tester.view.devicePixelRatio = dpr;
        tester.view.physicalSize = Size(w, h);
        addTearDown(tester.view.reset);
        await tester.pumpWidget(const MaterialApp(
          home: Scaffold(body: InlineCaptionOverlay()),
        ));
        AssistantEngine.instance
          ..inlineVoice = true
          ..phase = AssistantPhase.listening
          ..notifyListeners();
        await tester.pump(const Duration(milliseconds: 400));

        void fits(String when) {
          final slot = tester.getRect(find.byType(VoiceOrbBackdrop));
          final orb = tester.getRect(find.byType(VoiceOrb));
          final disc = orb.width / 1.08;
          final rings = disc * VoiceOrbBackdrop.reach;
          expect(rings, lessThanOrEqualTo(slot.height + 0.5),
              reason: '$when: the rings run out of their slot');
          expect(orb.center.dy, moreOrLessEquals(slot.center.dy, epsilon: 0.5));
        }

        fits('at rest');
        if (kb > 0) {
          await tester.showKeyboard(find.byType(TextField));
          tester.view.viewInsets = FakeViewPadding(bottom: kb);
          await tester.pump(const Duration(milliseconds: 400));
          fits('typing');
          tester.view.resetViewInsets();
        }
        AssistantEngine.instance
          ..inlineVoice = false
          ..phase = AssistantPhase.idle
          ..notifyListeners();
        for (var i = 0; i < 4; i++) {
          await tester.pump(const Duration(milliseconds: 300));
        }
      });
    }
  });
}
