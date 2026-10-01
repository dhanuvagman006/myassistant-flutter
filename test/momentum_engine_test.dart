// MOMENTUM BY VOICE (2026-09-25): what the server's new device actions do
// on the phone. "Start a 25-minute focus on the report" opens the Focus
// page already running; a voice tick to Today's 3 or a habit redraws Home
// at once.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/features/assistant/state/assistant_engine.dart';
import 'package:myassistant/features/assistant/state/assistant_state.dart';
import 'package:myassistant/screens/focus_screen.dart';
import 'package:myassistant/services/avatar_message_service.dart';
import 'package:myassistant/services/momentum_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    MomentumService.onHabitsChanged = (_) {};
    await MomentumService.instance.reset();
  });
  tearDown(() {
    AssistantEngine.instance.phase = AssistantPhase.idle;
  });

  testWidgets('start_focus opens the Focus page with the minutes and the label',
      (t) async {
    t.view.devicePixelRatio = 2.625;
    t.view.physicalSize = const Size(1080, 2340);
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      navigatorKey: AvatarMessageService.navigatorKey,
      home: const Scaffold(body: Text('home')),
    ));
    AssistantEngine.instance
        .debugHandleEvent({'type': 'start_focus', 'minutes': 15, 'label': 'the report'});
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    final page = t.widget<FocusScreen>(find.byType(FocusScreen));
    expect(page.minutes, 15);
    expect(page.label, 'the report');
    expect(page.autoStart, isTrue, reason: 'asked for by voice: it is already running');
    // Leave nothing running for the next test.
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 1));
  });

  testWidgets('momentum_updated asks nothing of the phone any more', (t) async {
    var gets = 0;
    MomentumService.transport = (method, path, {body}) async {
      gets++;
      return const MomentumReply(500, null);
    };
    AssistantEngine.instance.debugHandleEvent({'type': 'momentum_updated'});
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    expect(gets, 0, reason: 'Momentum is gone from the app');
  });
}
