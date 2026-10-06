import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:myassistant/screens/splash_screen.dart';

/// The splash paints every frame of its entrance and loop without an
/// error (2026-10-06: a gradient given three colours and no stops threw
/// mid-paint, and everything after the capsule silently went missing).
void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  Future<void> pumpSplash(WidgetTester tester, {bool still = false}) async {
    await tester.pumpWidget(MediaQuery(
      data: MediaQueryData(size: const Size(400, 860), disableAnimations: still),
      child: const MaterialApp(home: SplashScreen()),
    ));
  }

  testWidgets('entrance and loop paint without errors', (tester) async {
    await pumpSplash(tester);
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 80));
      expect(tester.takeException(), isNull, reason: 'frame $i');
    }
    expect(find.text('My Assistant'), findsOneWidget);
  });

  testWidgets('with animations off, the finished logo stands still', (tester) async {
    await pumpSplash(tester, still: true);
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });
}
