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

  // ENTER SENDS (2026-09-24, s5.png): the keyboard's Send key typed a
  // newline — the field told Android it was multi-line — and only the
  // arrow sent. And the screen still said "Listening…" with the mic paused.
  Future<void> openSession(WidgetTester tester) async {
    tester.view.devicePixelRatio = 2.625;
    tester.view.physicalSize = const Size(1080, 2340);
    addTearDown(tester.view.reset);
    final engine = AssistantEngine.instance
      ..inlineVoice = true
      ..phase = AssistantPhase.listening;
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: InlineCaptionOverlay()),
    ));
    engine.notifyListeners();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('the keyboard Send key sends, and the keyboard stays up', (tester) async {
    await openSession(tester);
    final field = find.byType(TextField);
    await tester.showKeyboard(field);
    expect(tester.testTextInput.setClientArgs!['inputType']['name'], 'TextInputType.text',
        reason: "a multi-line field makes the keyboard's Send key type a newline");
    await tester.enterText(field, 'what time is it');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pump();
    expect(find.text('what time is it'), findsNothing, reason: 'sent: the box is cleared');
    final editable = tester.state<EditableTextState>(find.byType(EditableText));
    expect(editable.widget.focusNode.hasFocus, isTrue, reason: 'the keyboard stays up');
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a newline that arrives anyway sends instead of wrapping', (tester) async {
    await openSession(tester);
    final field = find.byType(TextField);
    await tester.showKeyboard(field);
    await tester.enterText(field, 'uninstall instagram');
    tester.testTextInput.updateEditingValue(const TextEditingValue(
        text: 'uninstall instagram\n',
        selection: TextSelection.collapsed(offset: 20)));
    await tester.pump();
    await tester.pump();
    expect(find.text('uninstall instagram'), findsNothing, reason: 'Enter sent it');
    expect(find.textContaining('\n'), findsNothing);
    // Pasted lines become one message, not a four-line box.
    await tester.enterText(field, 'first line\nsecond line');
    await tester.pump();
    expect(find.text('first line second line'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('while typing, the screen says the mic is paused', (tester) async {
    await openSession(tester);
    expect(find.text('Listening…'), findsOneWidget);
    await tester.showKeyboard(find.byType(TextField));
    await tester.pump(const Duration(milliseconds: 400));
    expect(AssistantEngine.instance.micPausedForTyping, isTrue);
    expect(find.text('Mic paused while you type'), findsOneWidget);
    expect(find.text('Listening…'), findsNothing);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('the mic comes back when the session ends or the keyboard closes',
      (tester) async {
    await openSession(tester);
    final engine = AssistantEngine.instance;
    final editable = tester.state<EditableTextState>(find.byType(EditableText));

    // Keyboard closed with Back: the field keeps focus on its own, and the
    // focus is what held the mic paused.
    await tester.showKeyboard(find.byType(TextField));
    tester.view.viewInsets = const FakeViewPadding(bottom: 1190);
    await tester.pump(const Duration(milliseconds: 300));
    expect(engine.micPausedForTyping, isTrue);
    tester.view.resetViewInsets();
    await tester.pump(const Duration(milliseconds: 300));
    expect(editable.widget.focusNode.hasFocus, isFalse);
    expect(engine.micPausedForTyping, isFalse);

    // Session ended while typing: no deaf mic carried into the next one.
    await tester.showKeyboard(find.byType(TextField));
    await tester.pump();
    expect(engine.micPausedForTyping, isTrue);
    engine
      ..inlineVoice = false
      ..phase = AssistantPhase.idle
      ..notifyListeners();
    await tester.pump(const Duration(milliseconds: 400));
    expect(editable.widget.focusNode.hasFocus, isFalse);
    expect(engine.micPausedForTyping, isFalse);
  });
}
