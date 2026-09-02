import 'package:flutter/material.dart';

import '../design/neon_tokens.dart';

/// App-wide feedback from services that have no BuildContext — the engine
/// finishes a scan while the user is on the Home tab, and the confirmation
/// must show WHEREVER they are. Wired to MaterialApp.scaffoldMessengerKey.
class AppFeedback {
  AppFeedback._();

  static final messengerKey = GlobalKey<ScaffoldMessengerState>();

  static void toast(String message) {
    messengerKey.currentState?.showSnackBar(SnackBar(
      behavior: SnackBarBehavior.floating,
      backgroundColor: Neon.textHi,
      content: Text(message,
          style: TextStyle(color: Neon.onInk, fontSize: 13.5)),
      duration: const Duration(seconds: 4),
    ));
  }
}
