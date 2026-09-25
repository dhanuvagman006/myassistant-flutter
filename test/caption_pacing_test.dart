import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/features/assistant/state/assistant_engine.dart';
import 'package:myassistant/features/assistant/state/assistant_state.dart';
import 'package:myassistant/widgets/inline_voice.dart';

/// Her words on the voice screen, released as she says them (2026-09-25,
/// streaming captions: "when user speaks or agent speaks update the
/// caption appearing style need streaming style").
void main() {
  const reply = 'Sure Sir, I have set a reminder for five in the evening. '
      'I will call you then, and again ten minutes later if you miss it.';

  Future<void> speak(WidgetTester tester, {required bool complete}) async {
    tester.view.devicePixelRatio = 2.625;
    tester.view.physicalSize = const Size(1080, 2340);
    addTearDown(tester.view.reset);
    final engine = AssistantEngine.instance;
    addTearDown(() {
      engine
        ..inlineVoice = false
        ..phase = AssistantPhase.idle
        ..replyComplete = false;
      engine.caption.value = null;
    });
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: InlineCaptionOverlay())));
    engine
      ..inlineVoice = true
      ..phase = AssistantPhase.speaking
      ..replyComplete = complete
      ..notifyListeners();
    engine.caption.value = const CaptionLine('hari', reply);
    await tester.pump();
  }

  /// Everything shown of her reply right now, fading words included.
  String shown(WidgetTester tester) => [
        for (final e in find.byType(Text).evaluate())
          if ((e.widget as Text).style?.fontFamily?.startsWith('SpaceGrotesk') ?? false)
            (e.widget as Text).data ?? (e.widget as Text).textSpan!.toPlainText(),
      ].join(' ');

  testWidgets('while her voice plays, her words are released at speaking pace',
      (tester) async {
    await speak(tester, complete: false);
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    final after1s = shown(tester).length;
    expect(after1s, greaterThan(5), reason: 'nothing was released while she spoke');
    expect(after1s, lessThan(40), reason: 'the words ran ahead of the voice');
  });

  testWidgets('once the whole reply is in, the words catch up with the voice',
      (tester) async {
    await speak(tester, complete: true);
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(shown(tester).length, greaterThan(40),
        reason: 'the rest waited for the silence and then landed all at once');
  });

  testWidgets('the rest lands when she stops', (tester) async {
    await speak(tester, complete: false);
    await tester.pump(const Duration(milliseconds: 400));
    AssistantEngine.instance
      ..phase = AssistantPhase.listening
      ..notifyListeners();
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(shown(tester), contains('if you miss it.'));
  });
}
