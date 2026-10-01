import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'neon_tokens.dart';

/// The three choices a user has.
enum ThemeMode3 {
  /// Follows the clock: light through the day, dark in the evening and
  /// night. The default, and what most people mean by "just do the right
  /// thing".
  adaptive,
  light,
  dark,
}

/// ─────────────────────────────────────────────────────────────────────────
///  THEME CONTROLLER — one switch, the whole app follows.
///
///  The design system (Neon) resolves every token off [Neon.isDark]; this
///  controller owns that flag, persists the choice, keeps the status-bar
///  icons in step, and notifies the root so the entire tree rebuilds.
///
///  ADAPTIVE mode turns the app dark at dusk and light again in the
///  morning, on its own, and re-checks as the hours pass — including
///  while the app sits open across sunset. Choosing Light or Dark
///  explicitly pins it; nothing overrides the user's own choice.
/// ─────────────────────────────────────────────────────────────────────────
class ThemeController {
  ThemeController._();

  static const _prefsKey = 'theme_dark_v1'; // legacy boolean, still honoured
  static const _modeKey = 'theme_mode_v1';

  /// Evening starts at 19:00 and morning at 06:00 local time.
  static const _darkFromHour = 19;
  static const _lightFromHour = 6;

  /// Bumps on every switch; the app root listens and rebuilds.
  static final ValueNotifier<bool> dark = ValueNotifier(false);

  /// The chosen mode, for settings to render.
  // DARK UNLESS CHOSEN (2026-09-30): the product is a night-sky design
  // (the client's reference). Adaptive and Light stay one tap away in
  // You → Appearance; a saved choice is kept.
  static final ValueNotifier<ThemeMode3> mode =
      ValueNotifier(ThemeMode3.dark);

  static Timer? _clock;

  /// True when the clock says it is evening or night.
  static bool darkHourNow([DateTime? now]) {
    final h = (now ?? DateTime.now()).hour;
    return h >= _darkFromHour || h < _lightFromHour;
  }

  /// Called in main() BEFORE runApp, so the first frame is already right.
  static Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_modeKey);
      if (saved != null) {
        mode.value = ThemeMode3.values.firstWhere(
          (m) => m.name == saved,
          orElse: () => ThemeMode3.adaptive,
        );
      } else if (prefs.containsKey(_prefsKey)) {
        // Someone who already chose a theme before adaptive existed keeps
        // exactly what they chose.
        mode.value =
            (prefs.getBool(_prefsKey) ?? false) ? ThemeMode3.dark : ThemeMode3.light;
        await prefs.setString(_modeKey, mode.value.name);
      }
    } catch (_) {}
    _applyForMode();
    _startClock();
  }

  /// Pick a mode. Light and Dark pin the app; adaptive hands it back to
  /// the clock and takes effect immediately.
  static Future<void> setMode(ThemeMode3 m) async {
    mode.value = m;
    _applyForMode();
    _startClock();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_modeKey, m.name);
      // Keep the legacy key in step for anything still reading it.
      await prefs.setBool(_prefsKey, dark.value);
    } catch (_) {}
  }

  /// The old one-tap switch: flips to the opposite fixed theme (leaving
  /// adaptive, because the user has just made an explicit choice).
  static Future<void> toggle() =>
      setMode(dark.value ? ThemeMode3.light : ThemeMode3.dark);

  /// Re-evaluate now — called by the hourly tick and on app resume, so an
  /// app left open through sunset does not stay bright.
  static void refresh() {
    if (mode.value == ThemeMode3.adaptive) _applyForMode();
  }

  /// ONE DESIGN (owner, 2026-09-30: "need exact same design even in light
  /// and dark theme"). The product is the client's night-sky neon; there
  /// is no pale version of it, so every mode draws it.
  static void _applyForMode() => _apply(true);

  /// In adaptive mode the theme must change AT dusk and dawn even if
  /// nobody touches the phone, so tick at the top of each hour.
  static void _startClock() {
    _clock?.cancel();
    _clock = null;
    if (mode.value != ThemeMode3.adaptive) return;
    final now = DateTime.now();
    final nextHour = DateTime(now.year, now.month, now.day, now.hour)
        .add(const Duration(hours: 1));
    _clock = Timer(nextHour.difference(now) + const Duration(seconds: 2), () {
      refresh();
      _startClock();
    });
  }

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
