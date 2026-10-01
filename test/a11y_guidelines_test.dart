// ACCESSIBILITY GUIDELINES (2026-09-29, UI pass) — Flutter's own checks
// on the screens where the audit found a tap target a screen reader could
// not name (the Lock backspace, the voice and Quick task orbs, the news
// scrim, the password eye, the record button, the group chat switch and
// the send arrows) or one smaller than 48 dp (Momentum's "Add a habit").
// Every button says what it does, and every tap target is 48 dp or more.
//
// The screens are the layout sweep's, rendered offline as it renders them.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:myassistant/features/assistant/state/assistant_engine.dart';
import 'package:myassistant/features/assistant/state/assistant_state.dart';
import 'package:myassistant/services/momentum_service.dart';
import 'package:myassistant/theme/app_theme.dart';
import 'package:myassistant/widgets/inline_voice.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'layout_sweep_test.dart' as sweep;

const _screens = [
  'Lock',
  'Voice screen (long reply)',
  'Voice screen (in the shell)',
  'Quick task',
  'News deck (voice, in the shell)',
  'Sign in',
  'Meeting recorder',
  'Group chat',
  'Chat thread',
  'Finance',
];

/// Renders [home] on the owner's phone, offline: loaders fail fast and
/// report it, which is not what this test is about.
Future<void> _check(WidgetTester tester, Widget Function() home,
    [Future<void> Function()? extra]) async {
  tester.view.devicePixelRatio = 2.625;
  tester.view.physicalSize = const Size(1080, 2340);
  addTearDown(tester.view.reset);
  tester.platformDispatcher.accessibilityFeaturesTestValue =
      const FakeAccessibilityFeatures(disableAnimations: true);
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
  final original = FlutterError.onError;
  FlutterError.onError = (_) {};
  try {
    await tester.pumpWidget(MaterialApp(theme: AppTheme.light(), home: home()));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await extra?.call();
    await tester.pumpWidget(const SizedBox());
    AssistantEngine.instance.cancelReconnect();
    await tester.pump(const Duration(seconds: 5));
  } finally {
    FlutterError.onError = original;
  }
  tester.takeException();
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    MomentumService.transport = (method, path, {body}) async =>
        MomentumReply(200, sweep.momentumJsonForTests());
  });

  for (final name in _screens) {
    testWidgets('$name: every tap target is named and 48 dp', (tester) async {
      await _check(tester, sweep.screens[name]!);
    });
  }

  testWidgets('the names say what a tap does', (tester) async {
    await _check(tester, sweep.screens['Lock']!, () async {
      expect(find.bySemanticsLabel('Delete last digit'), findsOneWidget);
    });
    await _check(tester, sweep.screens['Quick task']!, () async {
      expect(find.bySemanticsLabel('Speak your task'), findsOneWidget);
      expect(find.byTooltip('Close'), findsOneWidget);
    });
    await _check(tester, sweep.screens['Meeting recorder']!, () async {
      expect(find.bySemanticsLabel('Start recording'), findsOneWidget);
    });
    await _check(tester, sweep.screens['Sign in']!, () async {
      expect(find.byTooltip('Show password'), findsOneWidget);
    });
  });

  testWidgets('while she speaks, the orb is a button that stops the conversation',
      (tester) async {
    final engine = AssistantEngine.instance
      ..inlineVoice = true
      ..phase = AssistantPhase.speaking;
    addTearDown(() => engine
      ..inlineVoice = false
      ..phase = AssistantPhase.idle);
    await _check(
        tester,
        () => const Scaffold(body: InlineCaptionOverlay()),
        () async => expect(
            find.bySemanticsLabel('Stop and go back'), findsOneWidget));
  });
}
