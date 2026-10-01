import 'dart:async';

import 'package:flutter/material.dart';

import '../screens/focus_screen.dart';
import '../services/auth_service.dart';
import '../services/avatar_message_service.dart';

/// Opens Focus from its notification once the app has a navigator and a
/// signed-in user (it may still be starting up); never a second copy.
abstract final class FocusNav {
  static Future<void> open() async {
    for (var i = 0; i < 24; i++) {
      final nav = AvatarMessageService.navigatorKey.currentState;
      if (nav != null && AuthService.instance.user != null) {
        if (FocusScreen.showing == 0) {
          unawaited(nav.push(MaterialPageRoute(builder: (_) => const FocusScreen())));
        }
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }
}
