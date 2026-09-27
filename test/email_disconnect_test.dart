// "Disconnect" on the Email screen says unlinked only when the server did
// unlink (audit, 2026-09-27). Every error used to be swallowed and the
// screen showed "disconnected" while the server kept the Google grant or
// the mail password and the assistant went on reading mail.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:myassistant/screens/email_setup_screen.dart';

/// The server, as the screen sees it.
bool password = false;
bool google = false;
int deleteStatus = 200;
final deletes = <String>[];

final _server = MockClient((req) async {
  final path = req.url.path;
  if (req.method == 'DELETE') {
    deletes.add(path);
    if (deleteStatus == 200) {
      if (path.endsWith('/email/account')) password = false;
      if (path.endsWith('/google')) google = false;
    }
    return http.Response(jsonEncode({'ok': deleteStatus == 200}), deleteStatus);
  }
  if (path.endsWith('/email/account')) {
    return http.Response(
        jsonEncode({'connected': password, 'address': 'ravi@example.in'}), 200);
  }
  if (path.endsWith('/google/status')) {
    return http.Response(jsonEncode({'connected': google}), 200);
  }
  return http.Response(jsonEncode({'items': []}), 200);
});

void main() {
  // No network in tests: fall back to the bundled/default font.
  GoogleFonts.config.allowRuntimeFetching = false;

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: EmailSetupScreen()));
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> disconnect(WidgetTester tester) async {
    await tester.scrollUntilVisible(find.text('Disconnect'), 200);
    await tester.tap(find.text('Disconnect'));
    await tester.pump(const Duration(milliseconds: 400));
    // The dialog's own button.
    await tester.tap(find.text('Disconnect').last);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('a failed disconnect keeps the mailbox shown as linked, and says so',
      (tester) async {
    await http.runWithClient(() async {
      password = true;
      google = false;
      deleteStatus = 500;
      deletes.clear();
      await open(tester);
      expect(find.textContaining('ravi@example.in is linked'), findsOneWidget);

      await disconnect(tester);
      expect(deletes, ['/email/account']);
      expect(find.textContaining('ravi@example.in is linked'), findsOneWidget,
          reason: 'shown unlinked while the server still holds the password');
      expect(find.text("Couldn't disconnect — try again."), findsOneWidget);

      // A retry that works unlinks it.
      deleteStatus = 200;
      await disconnect(tester);
      expect(find.textContaining('is linked'), findsNothing);
      expect(find.text("Couldn't disconnect — try again."), findsNothing);
    }, () => _server);
  });

  testWidgets('Google: a 5xx is a failure; after a success the screen asks the server again',
      (tester) async {
    await http.runWithClient(() async {
      // A mail password AND a Google link: unlinking one leaves the other.
      password = false;
      google = true;
      deleteStatus = 503;
      deletes.clear();
      await open(tester);
      expect(find.textContaining('Your mailbox is linked'), findsOneWidget);

      await disconnect(tester);
      expect(deletes, ['/google']);
      expect(find.textContaining('Your mailbox is linked'), findsOneWidget);
      expect(find.text("Couldn't disconnect — try again."), findsOneWidget);

      deleteStatus = 200;
      password = true; // linked from another phone meanwhile
      await disconnect(tester);
      expect(deletes, ['/google', '/google']);
      expect(find.textContaining('ravi@example.in is linked'), findsOneWidget,
          reason: 'the mail password is still linked; the screen must say so');
    }, () => _server);
  });
}
