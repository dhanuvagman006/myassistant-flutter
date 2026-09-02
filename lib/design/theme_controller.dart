import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Color, Brightness;
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'neon_tokens.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  THEME CONTROLLER — one switch, the whole app follows.
///
///  The design system (Neon) resolves every token off [Neon.isDark]; this
///  controller owns that flag, persists the choice, keeps the status-bar
///  icons in step, and notifies the root so the entire tree rebuilds.
/// ─────────────────────────────────────────────────────────────────────────
class ThemeController {
  ThemeController._();

  static const _prefsKey = 'theme_dark_v1';

  /// Bumps on every switch; the app root listens and rebuilds.
  static final ValueNotifier<bool> dark = ValueNotifier(false);

  /// Called in main() BEFORE runApp, so the first frame is already right.
  static Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _apply(prefs.getBool(_prefsKey) ?? false);
    } catch (_) {}
  }

  static Future<void> setDark(bool v) async {
    _apply(v);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefsKey, v);
    } catch (_) {}
  }

  static Future<void> toggle() => setDark(!dark.value);

  static void _apply(bool v) {
    Neon.setDark(v);
    dark.value = v;
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
      statusBarColor: const Color(0x00000000),
      statusBarIconBrightness: v ? Brightness.light : Brightness.dark,
      systemNavigationBarColor: Neon.bg,
      systemNavigationBarIconBrightness:
          v ? Brightness.light : Brightness.dark,
    ));
  }
}
