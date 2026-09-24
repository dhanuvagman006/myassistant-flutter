// With the keyboard open, the voice screen's text box must still take a
// tap on its send arrow. It overflowed on a real phone (2026-09-24): the
// fixed-size orb and dock space did not fit above the keyboard, and the
// arrow was drawn outside the area that receives taps — visible, but dead.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/features/assistant/state/assistant_engine.dart';
import 'package:myassistant/features/assistant/state/assistant_state.dart';
import 'package:myassistant/widgets/inline_voice.dart';

void main() {
  tearDown(() {
    AssistantEngine.instance
      ..inlineVoice = false
      ..phase = AssistantPhase.idle;
  });

  testWidgets('keyboard up on a phone-sized screen: the arrow takes the tap', (tester) async {
    WidgetController.hitTestWarningShouldBeFatal = true;
    addTearDown(() => WidgetController.hitTestWarningShouldBeFatal = false);
    // The owner's phone: 1080x2340 at 2.625, keyboard 1190 px tall.
    tester.view.devicePixelRatio = 2.625;
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.viewInsets = FakeViewPadding(bottom: 1190);
    addTearDown(tester.view.reset);

    final engine = AssistantEngine.instance
      ..inlineVoice = true
      ..phase = AssistantPhase.listening;
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: InlineCaptionOverlay()),
    ));
    engine.notifyListeners();
    await tester.pump(const Duration(milliseconds: 400));

    // Laid out without overflowing (an overflow fails the test by itself).
    await tester.enterText(find.byType(TextField), 'what time is it');
    await tester.pump();
    final arrow = find.byIcon(Icons.arrow_upward_rounded);
    final box = tester.getRect(arrow);
    final screen = tester.getRect(find.byType(InlineCaptionOverlay));
    expect(box.bottom <= screen.bottom, isTrue, reason: 'the arrow is inside the space above the keyboard');

    await tester.tap(arrow); // fatal if the tap would miss
    await tester.pump();
    expect(find.text('what time is it'), findsNothing, reason: 'sent: the box is cleared');
    await tester.pump(const Duration(seconds: 1));
  });
}
