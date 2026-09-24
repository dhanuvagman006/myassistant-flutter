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
    tester.view.viewInsets = const FakeViewPadding(bottom: 1190);
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

  testWidgets('a long reply while typing stays above the text box, never over it', (tester) async {
    tester.view.devicePixelRatio = 2.625;
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.viewInsets = const FakeViewPadding(bottom: 1190);
    addTearDown(tester.view.reset);

    final engine = AssistantEngine.instance
      ..inlineVoice = true
      ..phase = AssistantPhase.speaking;
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: InlineCaptionOverlay()),
    ));
    await tester.showKeyboard(find.byType(TextField));
    engine.caption.value = const CaptionLine('you',
        'Sorry Sir, that took longer than expected. Shall I open the app for you so you can '
        'check the order yourself? Otherwise I can try again in a moment, or tell you what '
        'I found so far. I will wait for your answer before doing anything else.');
    engine.notifyListeners();
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 250)); // let the words release
    }
    final bar = tester.getRect(find.byType(TextField));
    var checked = 0;
    for (final e in find.byType(Text).evaluate()) {
      final t = (e.widget as Text).data ?? '';
      if (t.length < 30) continue; // the long caption lines only
      checked++;
      final r = tester.getRect(find.byWidget(e.widget));
      // Clipped to its own area: visible part ends above the text box.
      final clip = tester.getRect(find.ancestor(of: find.byWidget(e.widget), matching: find.byType(ClipRect)).first);
      expect(clip.bottom <= bar.top, isTrue, reason: 'the caption area ends above the text box');
      expect(r.top < bar.top, isTrue);
    }
    expect(checked, greaterThan(0), reason: 'the long reply was on screen');
    engine.caption.value = null;
  });
}
