// THE ON-PHONE FRAME BENCHMARK (2026-09-24, GPU pass).
//
// The unit tests pin the CAUSES of dropped frames (no ticker at rest, the
// orb on its own layer, no offscreen layers where none are needed); only
// the phone itself can say how long its frames actually take. This drives
// the four moments that matter most — opening the voice screen, the
// keyboard coming up in it, switching tabs, scrolling Home — and records
// every frame's build (UI thread) and raster (GPU thread) time for each.
//
// RUN IT IN PROFILE MODE (debug-mode timings mean nothing), phone
// connected, from the repo root:
//
//   flutter drive --profile \
//     --driver=test_driver/perf_driver.dart \
//     --target=integration_test/ux_bench_test.dart
//
// Results: build/ux_bench.json, and a table of p50 / p90 / p99 / worst
// per moment printed at the end. At 60 Hz a frame has 16.7 ms; at 90 Hz,
// 11.1 ms. Compare two builds on the same phone, same settings, same
// battery state — one run is a sample, not a verdict.
//
// READ BEFORE RUNNING ON A PHONE WITH THE REAL APP. `flutter drive`
// installs a profile build under the same package name. The installed
// app is signed with the release key and a profile build with the debug
// key (android/app/build.gradle.kts), so Flutter UNINSTALLS the installed
// app first — taking its data (sign-in, settings, caches) with it. Use a
// spare phone, or one whose app was installed from a debug/profile build.
//
// It never signs in, never speaks to the server on purpose and never
// uses the microphone: Home is built directly (as the widget tests do),
// and the voice screen is opened the way the widget tests open it, by
// setting the session state — the picture and the frames are the real
// ones, the conversation is not.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:myassistant/features/assistant/state/assistant_engine.dart';
import 'package:myassistant/features/assistant/state/assistant_state.dart';
import 'package:myassistant/screens/home_dashboard.dart';
import 'package:myassistant/services/brief_service.dart';
import 'package:myassistant/shell/home_shell.dart';
import 'package:myassistant/theme/app_theme.dart';
import 'package:myassistant/widgets/inline_voice.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // Real frames, driven by the phone's own display — not a fake clock.
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  Future<void> hold(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

  void session({required bool open}) {
    AssistantEngine.instance
      ..inlineVoice = open
      ..phase = open ? AssistantPhase.listening : AssistantPhase.idle
      ..notifyListeners();
  }

  testWidgets('UX bench: voice screen, keyboard, tabs, Home scroll',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      home: const HomeShell(),
    ));
    // Home paints the last brief it cached; give it a moment, and never
    // measure the loading shimmer.
    for (var i = 0; i < 10 && !BriefService.instance.loaded; i++) {
      await hold(500);
    }
    BriefService.instance.loaded = true;
    await hold(2000);

    // 1. OPENING THE VOICE SCREEN: the fade in, the orb, the backdrop's
    // bloom, then a second and a half of listening.
    await binding.watchPerformance(() async {
      session(open: true);
      await hold(2500);
    }, reportKey: 'voice_open');

    // 2. THE KEYBOARD, up and down again, with the session open.
    await binding.watchPerformance(() async {
      await tester.tap(find.descendant(
          of: find.byType(InlineCaptionOverlay),
          matching: find.byType(TextField)));
      await hold(1500);
      FocusManager.instance.primaryFocus?.unfocus();
      await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
      await hold(1500);
    }, reportKey: 'keyboard');

    session(open: false);
    await hold(1500);

    // 3. SWITCHING TABS from the dock, round all four and back.
    await binding.watchPerformance(() async {
      for (final tab in ['Hub', 'Chat', 'You', 'Home']) {
        await tester.tap(find.descendant(
            of: find.byType(BottomAppBar), matching: find.text(tab)));
        await hold(900);
      }
    }, reportKey: 'tab_switch');

    // 4. SCROLLING HOME: a fling down the feed and back up.
    await binding.watchPerformance(() async {
      final feed = find
          .descendant(
              of: find.byType(HomeDashboard), matching: find.byType(Scrollable))
          .first;
      await tester.fling(feed, const Offset(0, -700), 2400);
      await hold(1200);
      await tester.fling(feed, const Offset(0, 700), 2400);
      await hold(1200);
    }, reportKey: 'home_scroll');

    AssistantEngine.instance.cancelReconnect();
  });
}
