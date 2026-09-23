// Offline is not "no chats yet".
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:myassistant/screens/chat_screen.dart';

void main() {
  GoogleFonts.config.allowRuntimeFetching = false;

  testWidgets('with the server unreachable, Chat says so and offers a retry',
      (tester) async {
    // flutter_test answers every real HTTP request with 400: no server.
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: ChatScreen())));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.textContaining('No chats yet'), findsNothing,
        reason: 'being offline looked like an empty inbox');
    expect(find.textContaining("Couldn't load your chats"), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    await tester.pumpWidget(const SizedBox()); // dispose: stops the poll timer
  });
}
