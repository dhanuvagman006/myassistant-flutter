// SMOOTHNESS (2026-09-24). Measured on his phone (SM-E156B, 60 Hz): the
// idle Home drew 60 frames a second, opening the voice screen cost one
// 67 ms frame, and bringing the keyboard up cost one 83 ms frame while the
// orb resized under it. "Need more smoothness while using the app."
//
// A phone's frame times cannot be measured in a unit test, so these pin
// the causes instead, by counting what the framework is asked to do:
//   * an idle Home asks for NO frames (no ticker left running);
//   * a session's animation stops when the session does, and rests while
//     he types;
//   * the orb is drawn smaller for the keyboard, never laid out again,
//     and the spoken line is laid out once at its new size, then only
//     drawn smaller;
//   * the animated parts repaint on their own layers, not with the words
//     or the page;
//   * the voice screen's heaviest layer is not drawn on its first frames;
//   * keyboard frames do not rebuild the shell or re-lay out the tabs the
//     session covers;
//   * pages move at one pace (240 ms in, 200 ms back).
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:myassistant/features/assistant/state/assistant_engine.dart';
import 'package:myassistant/features/assistant/state/assistant_state.dart';
import 'package:myassistant/services/brief_service.dart';
import 'package:myassistant/shell/home_shell.dart';
import 'package:myassistant/theme/app_theme.dart';
import 'package:myassistant/widgets/call_led.dart';
import 'package:myassistant/widgets/inline_voice.dart';
import 'package:myassistant/widgets/voice_orb.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The owner's phone: 1080 x 2340 at 2.625 (411 x 891 dp).
void _ownersPhone(WidgetTester tester) {
  tester.view.devicePixelRatio = 2.625;
  tester.view.physicalSize = const Size(1080, 2340);
  addTearDown(tester.view.reset);
}

/// Home with its feed loaded (the loading shimmer is allowed to move —
/// something IS happening then).
Future<void> _pumpHome(WidgetTester tester) async {
  BriefService.instance.loaded = true;
  await tester.pumpWidget(const MaterialApp(home: HomeShell()));
  await _settle(tester);
}

Future<void> _settle(WidgetTester tester, [int steps = 8]) async {
  for (var i = 0; i < steps; i++) {
    await tester.pump(const Duration(milliseconds: 300));
  }
}

Future<void> _teardownShell(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  // The assistant keeps retrying its server offline (by design).
  AssistantEngine.instance.cancelReconnect();
  await tester.pump(const Duration(seconds: 5));
  tester.takeException();
}

void _openSession() {
  AssistantEngine.instance
    ..inlineVoice = true
    ..phase = AssistantPhase.listening
    ..notifyListeners();
}

void _closeSession() {
  AssistantEngine.instance
    ..inlineVoice = false
    ..phase = AssistantPhase.idle
    ..notifyListeners();
}

/// The nearest RepaintBoundary a render object is painted under (the
/// ones that count their paints).
RenderRepaintBoundary _layerOf(RenderObject ro) {
  RenderObject? r = ro;
  while (r != null && r is! RenderRepaintBoundary) {
    r = r.parent;
  }
  expect(r, isNotNull);
  return r! as RenderRepaintBoundary;
}

int _paints(RenderRepaintBoundary b) =>
    b.debugSymmetricPaintCount + b.debugAsymmetricPaintCount;

/// How much is actually drawn in a layer: the sum of its pixels' alpha.
Future<int> _inkIn(WidgetTester tester, RenderRepaintBoundary b) async {
  final bytes = await tester.runAsync(() async {
    final image = await b.toImage(pixelRatio: 0.5);
    return image.toByteData(format: ui.ImageByteFormat.rawRgba);
  });
  var sum = 0;
  for (var i = 3; i < bytes!.lengthInBytes; i += 4) {
    sum += bytes.getUint8(i);
  }
  return sum;
}

void main() {
  // No network in tests: fall back to the default font.
  GoogleFonts.config.allowRuntimeFetching = false;

  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() {
    AssistantEngine.instance
      ..inlineVoice = false
      ..phase = AssistantPhase.idle
      ..callStatus = null;
    AssistantEngine.instance.caption.value = null;
    AssistantEngine.instance.micLevelListenable.value = 0;
    BriefService.instance.loaded = false;
    HomeShell.lastTab = 0;
  });

  group('nothing ticks when nothing happens', () {
    testWidgets('idle Home asks for no frames at all', (tester) async {
      _ownersPhone(tester);
      await _pumpHome(tester);
      expect(SchedulerBinding.instance.transientCallbackCount, 0,
          reason: 'a ticker is still running on the idle Home');
      expect(tester.binding.hasScheduledFrame, isFalse,
          reason: 'the idle Home asked for another frame (it drew 60 a second)');
      await _teardownShell(tester);
    });

    testWidgets('a session animates, and Home is still again once it closes',
        (tester) async {
      _ownersPhone(tester);
      await _pumpHome(tester);

      _openSession();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.binding.hasScheduledFrame, isTrue,
          reason: 'listening: the orb moves');

      _closeSession();
      await _settle(tester, 2); // the 240 ms fade, and no more
      expect(SchedulerBinding.instance.transientCallbackCount, 0);
      expect(tester.binding.hasScheduledFrame, isFalse,
          reason: 'the closed session left something running behind Home');
      await _teardownShell(tester);
    });

    testWidgets('paused while he types, the orb and its backdrop come to rest',
        (tester) async {
      _ownersPhone(tester);
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: InlineCaptionOverlay()),
      ));
      _openSession();
      await tester.pump(const Duration(milliseconds: 400));
      expect(SchedulerBinding.instance.transientCallbackCount, greaterThan(0),
          reason: 'listening: the orb moves');

      // Focus the text box: the mic pauses and the orb rests.
      await tester.showKeyboard(find.byType(TextField));
      expect(AssistantEngine.instance.micPausedForTyping, isTrue);
      await _settle(tester, 10);
      expect(SchedulerBinding.instance.transientCallbackCount, 0,
          reason: 'a resting orb must not tick');

      // The assistant answers: it moves again.
      AssistantEngine.instance
        ..phase = AssistantPhase.speaking
        ..notifyListeners();
      await tester.pump(const Duration(milliseconds: 100));
      expect(SchedulerBinding.instance.transientCallbackCount, greaterThan(0));
      _closeSession();
      await _settle(tester);
    });

    testWidgets('the call light breathes only while a call is on',
        (tester) async {
      final engine = AssistantEngine.instance;
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: CallLed())));
      await tester.pump();
      expect(tester.binding.hasScheduledFrame, isFalse);

      engine
        ..callStatus = const CallStatusInfo(status: 'dialing', contactName: 'Ravi Kumar')
        ..notifyListeners();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Calling Ravi'), findsOneWidget);
      expect(tester.binding.hasScheduledFrame, isTrue, reason: 'the light breathes');

      // The call ends: it used to keep ticking behind an empty light.
      engine
        ..callStatus = null
        ..notifyListeners();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Calling Ravi'), findsNothing);
      expect(SchedulerBinding.instance.transientCallbackCount, 0);
      expect(tester.binding.hasScheduledFrame, isFalse);
    });
  });

  group('the voice screen', () {
    testWidgets('keyboard up and down: the orb is drawn smaller, never laid out again',
        (tester) async {
      _ownersPhone(tester);
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: InlineCaptionOverlay()),
      ));
      _openSession();
      await tester.pump(const Duration(milliseconds: 400));

      RenderBox orb() => tester.renderObject<RenderBox>(find.byType(VoiceOrb));
      final restConstraints = orb().constraints;
      final restSize = orb().size;
      final restRect = tester.getRect(find.byType(VoiceOrb));

      // The keyboard slides in over ~250 ms: a new inset every frame.
      for (var i = 1; i <= 15; i++) {
        tester.view.viewInsets = FakeViewPadding(bottom: 1190 * i / 15);
        await tester.pump(const Duration(milliseconds: 16));
        expect(orb().constraints, restConstraints,
            reason: 'keyboard frame $i gave the orb new constraints: a relayout');
        expect(orb().size, restSize);
      }
      await tester.pump(const Duration(milliseconds: 400));
      final typingRect = tester.getRect(find.byType(VoiceOrb));
      expect(typingRect.height, lessThan(restRect.height * 0.8),
          reason: 'while typing the orb is drawn smaller');
      final scale = tester.widget<Transform>(find.byKey(const ValueKey('orb-scale')));
      expect(scale.transform.storage[0], lessThan(1.0), // x scale
          reason: 'by a transform');
      expect(orb().constraints, restConstraints);

      // And back down.
      for (var i = 14; i >= 0; i--) {
        tester.view.viewInsets = FakeViewPadding(bottom: 1190 * i / 15);
        await tester.pump(const Duration(milliseconds: 16));
        expect(orb().constraints, restConstraints,
            reason: 'keyboard-down frame $i gave the orb new constraints');
      }
      await tester.pump(const Duration(milliseconds: 400));
      final backRect = tester.getRect(find.byType(VoiceOrb));
      expect(backRect.height, moreOrLessEquals(restRect.height, epsilon: 0.5),
          reason: 'full size again once the keyboard is down');
      _closeSession();
      await _settle(tester);
    });

    // 2026-09-24, review: the spoken line eased from 19/24 pt to 17 pt by
    // tweening its font size, which laid it out again at a new size on
    // every one of these same keyboard frames.
    testWidgets('keyboard up: the spoken line is laid out once at its new size, then only drawn smaller',
        (tester) async {
      _ownersPhone(tester);
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: InlineCaptionOverlay()),
      ));
      _openSession();
      await tester.pump(const Duration(milliseconds: 400));
      const said = 'Remind me to call Ravi at five';
      AssistantEngine.instance.caption.value = const CaptionLine('you', said);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final line = find.text(said);
      double fontSize() => tester.widget<Text>(line).style!.fontSize!;
      RenderBox box() => tester.renderObject<RenderBox>(line);
      // How much larger it is drawn than it is laid out.
      double drawn() => tester.getRect(line).height / box().size.height;
      expect(fontSize(), 19);
      expect(drawn(), moreOrLessEquals(1.0, epsilon: 1e-6));

      final sizes = <double>{};
      final scales = <double>[];
      BoxConstraints? first;
      for (var i = 1; i <= 15; i++) {
        tester.view.viewInsets = FakeViewPadding(bottom: 1190 * i / 15);
        await tester.pump(const Duration(milliseconds: 16));
        sizes.add(fontSize());
        scales.add(drawn());
        if (i == 1) {
          first = box().constraints;
        } else {
          expect(box().constraints, first,
              reason: 'keyboard frame $i gave the line new constraints: a relayout');
        }
      }
      expect(sizes, {17.0},
          reason: 'the line was laid out at a new font size on the keyboard frames');
      expect(scales.first, greaterThan(1.05),
          reason: 'it jumped to the new size instead of easing to it');
      for (var i = 1; i < scales.length; i++) {
        expect(scales[i], lessThanOrEqualTo(scales[i - 1] + 1e-9));
      }
      await tester.pump(const Duration(milliseconds: 400));
      expect(drawn(), moreOrLessEquals(1.0, epsilon: 1e-6));
      final picture = tester.widget<Transform>(
          find.ancestor(of: line, matching: find.byType(Transform)).first);
      expect(picture.filterQuality, isNull,
          reason: 'a snapshot left on once it came to rest');
      _closeSession();
      await _settle(tester);
    });

    // 2026-09-25, the client's rings: "only the speaker should move". The
    // disc in the middle (VoiceOrb) used to breathe and swell every frame;
    // now it holds still and only the rings round it (the backdrop) move.
    testWidgets('the rings repaint on their own layer; the disc and the words hold still',
        (tester) async {
      _ownersPhone(tester);
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: InlineCaptionOverlay()),
      ));
      _openSession();
      await _settle(tester, 2); // faded all the way in
      expect(find.text('Listening…'), findsOneWidget);

      final disc = _layerOf(tester.renderObject(find.byType(VoiceOrb)));
      final backdrop = _layerOf(tester.renderObject(find.byType(VoiceOrbBackdrop)));
      final words = _layerOf(tester.renderObject(find.text('Listening…')));
      expect(identical(words, disc) || identical(words, backdrop), isFalse);
      for (final b in [disc, backdrop, words]) {
        b.debugResetMetrics();
      }

      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(identical(disc, backdrop), isFalse);
      expect(_paints(disc), 0,
          reason: 'the disc was redrawn for a frame of the rings: it must hold still');
      expect(_paints(backdrop), greaterThanOrEqualTo(9), reason: 'the rings moved');
      expect(_paints(words), 0,
          reason: 'the layer holding the words was redrawn with the orb');
      _closeSession();
      await _settle(tester);
    });

    testWidgets('opening: the backdrop is not drawn on the first frames, then blooms in',
        (tester) async {
      _ownersPhone(tester);
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: InlineCaptionOverlay()),
      ));
      await tester.pump();
      // Built before the session, so opening does not build it from nothing.
      expect(find.byType(VoiceOrbBackdrop), findsOneWidget);

      _openSession();
      await tester.pump(); // the tap's frame: the fade starts at 0
      await tester.pump(const Duration(milliseconds: 16)); // first visible frame
      final backdrop = _layerOf(tester.renderObject(find.byType(VoiceOrbBackdrop)));
      expect(await _inkIn(tester, backdrop), 0,
          reason: 'the heaviest layer was drawn on the first frame of the screen');

      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(await _inkIn(tester, backdrop), greaterThan(0),
          reason: 'it blooms in right after');
      _closeSession();
      await _settle(tester);
    });

    testWidgets('the answer card fades out with its words instead of blinking out',
        (tester) async {
      final engine = AssistantEngine.instance;
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: Stack(children: [AnswerAfterglow()])),
      ));
      engine
        ..inlineVoice = true
        ..phase = AssistantPhase.speaking
        ..notifyListeners();
      await tester.pump();
      const answer = 'Your meeting with Ravi is at five this evening.';
      engine.caption.value = const CaptionLine('hari', answer);
      await tester.pump();
      _closeSession();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text(answer), findsOneWidget);

      await tester.tap(find.byTooltip('Dismiss'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text(answer), findsOneWidget, reason: 'still fading, words and all');
      final fade = tester.widget<AnimatedOpacity>(find
          .ancestor(of: find.text(answer), matching: find.byType(AnimatedOpacity))
          .first);
      expect(fade.opacity, 0);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text(answer), findsNothing, reason: 'gone once faded');
    });
  });

  group('closed for a task', () {
    testWidgets('"On it…" leaves no answer card behind (2026-09-26)', (tester) async {
      final engine = AssistantEngine.instance;
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: Stack(children: [AnswerAfterglow()])),
      ));
      engine
        ..inlineVoice = true
        ..phase = AssistantPhase.speaking
        ..notifyListeners();
      await tester.pump();
      const said = 'On it, doing this in Swiggy. I will stop before any payment.';
      engine.caption.value = const CaptionLine('hari', said);
      await tester.pump();
      engine.debugMarkQuietEnd();
      _closeSession();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text(said), findsNothing);

      // The next conversation, closed by the owner, still keeps its answer.
      engine
        ..inlineVoice = true
        ..phase = AssistantPhase.speaking
        ..notifyListeners();
      await tester.pump();
      const answer = 'Your meeting with Ravi is at five this evening.';
      engine.caption.value = const CaptionLine('hari', answer);
      await tester.pump();
      _closeSession();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text(answer), findsOneWidget);
    });
  });

  group('the shell under the session', () {
    Scaffold shellScaffold(WidgetTester tester) => tester.widget<Scaffold>(find
        .descendant(of: find.byType(HomeShell), matching: find.byType(Scaffold))
        .first);

    testWidgets('keyboard frames do not rebuild the shell or re-lay out the covered tabs',
        (tester) async {
      _ownersPhone(tester);
      await _pumpHome(tester);
      _openSession();
      await _settle(tester, 3);
      expect(InlineCaptionOverlay.covering.value, isTrue,
          reason: 'faded all the way in, the session covers the page');

      final tabs = tester.renderObject<RenderBox>(find.byType(IndexedStack));
      final held = tabs.constraints;
      Scaffold? last;
      for (var i = 1; i <= 15; i++) {
        tester.view.viewInsets = FakeViewPadding(bottom: 1190 * i / 15);
        await tester.pump(const Duration(milliseconds: 16));
        final now = shellScaffold(tester);
        // Frame 1 flips "keyboard up" (the dock mic hides): one rebuild.
        if (i > 1) {
          expect(identical(now, last), isTrue,
              reason: 'keyboard frame $i rebuilt the whole shell');
        }
        last = now;
        expect(tabs.constraints, held,
            reason: 'keyboard frame $i laid the covered tabs out again');
      }

      // Session over: the tabs make room for the keyboard again, and are
      // painted again from the first frame of the fade-out.
      _closeSession();
      await tester.pump();
      expect(InlineCaptionOverlay.covering.value, isFalse);
      await tester.pump(const Duration(milliseconds: 300));
      expect(tabs.constraints.maxHeight, lessThan(held.maxHeight));
      tester.view.resetViewInsets();
      await _settle(tester, 2);
      await _teardownShell(tester);
    });

    testWidgets('the page under an open session is not painted with the orb',
        (tester) async {
      _ownersPhone(tester);
      await _pumpHome(tester);
      _openSession();
      await _settle(tester, 3);

      final page = _layerOf(tester.renderObject(find.byType(IndexedStack)));
      // The rings: the part of the orb that moves (2026-09-25; the disc
      // holds still).
      final rings = _layerOf(tester.renderObject(find.byType(VoiceOrbBackdrop)));
      page.debugResetMetrics();
      rings.debugResetMetrics();
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(_paints(rings), greaterThanOrEqualTo(9));
      expect(_paints(page), 0, reason: 'the covered tabs were redrawn with the orb');

      _closeSession();
      await _settle(tester);
      // Visible and painted again.
      expect(InlineCaptionOverlay.covering.value, isFalse);
      final vis = tester.widget<Visibility>(find
          .ancestor(of: find.byType(IndexedStack), matching: find.byType(Visibility))
          .first);
      expect(vis.visible, isTrue);
      await _teardownShell(tester);
    });
  });

  group('pages move at one pace', () {
    test('240 ms in, 200 ms back, from the app theme', () {
      const b = AppPageTransitions();
      expect(b.transitionDuration, const Duration(milliseconds: 240));
      expect(b.reverseTransitionDuration, const Duration(milliseconds: 200));
    });

    testWidgets('every MaterialPageRoute takes its timing from the theme',
        (tester) async {
      final theme = AppTheme.light();
      expect(theme.pageTransitionsTheme.builders[TargetPlatform.android],
          isA<AppPageTransitions>());
      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(pageTransitionsTheme: theme.pageTransitionsTheme),
        navigatorKey: nav,
        home: const SizedBox(),
      ));
      final route = MaterialPageRoute<void>(builder: (_) => const Text('page'));
      nav.currentState!.push(route);
      await tester.pump();
      expect(route.transitionDuration, const Duration(milliseconds: 240));
      await tester.pump(const Duration(milliseconds: 230));
      expect(route.animation!.isCompleted, isFalse);
      await tester.pump(const Duration(milliseconds: 20));
      expect(route.animation!.isCompleted, isTrue);
      nav.currentState!.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 210));
      expect(find.text('page'), findsNothing, reason: 'back in 200 ms');
    });
  });
}
