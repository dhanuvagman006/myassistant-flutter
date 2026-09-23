// The voice overlay must say what went wrong. Every phase its caption did
// not name — error included — read "Connecting…", so a denied microphone
// looked like a connection that never finished.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:myassistant/features/assistant/state/assistant_engine.dart';
import 'package:myassistant/features/assistant/state/assistant_state.dart';
import 'package:myassistant/widgets/inline_voice.dart';

void main() {
  // No network in tests: fall back to the bundled/default font.
  GoogleFonts.config.allowRuntimeFetching = false;

  Future<void> showError(WidgetTester tester, String message) async {
    // The test phone: a Samsung SM-E156B (411 × 891 dp).
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    final engine = AssistantEngine.instance
      ..inlineVoice = true
      ..errorMessage = message
      ..phase = AssistantPhase.error;
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: InlineCaptionOverlay()),
    ));
    engine.notifyListeners();
    await tester.pump(const Duration(milliseconds: 400));
  }

  tearDown(() {
    AssistantEngine.instance
      ..inlineVoice = false
      ..errorMessage = null
      ..phase = AssistantPhase.idle;
  });

  testWidgets('a denied microphone says so and offers Settings', (tester) async {
    await showError(tester, 'Microphone permission is needed. Enable it in Settings.');
    expect(find.text('Connecting…'), findsNothing);
    expect(find.text('Microphone permission is needed. Enable it in Settings.'), findsOneWidget);
    expect(find.text('Open settings'), findsOneWidget);
    expect(find.text('Close'), findsOneWidget);
  });

  testWidgets('a network failure says so and offers to try again', (tester) async {
    await showError(tester, "I couldn't upload your audio. Check your connection.");
    expect(find.text('Connecting…'), findsNothing);
    expect(find.text("I couldn't upload your audio. Check your connection."), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    expect(find.text('Open settings'), findsNothing);
  });

  testWidgets('an error with no message still explains itself', (tester) async {
    await showError(tester, '');
    expect(find.text('Something went wrong.'), findsOneWidget);
  });
}
