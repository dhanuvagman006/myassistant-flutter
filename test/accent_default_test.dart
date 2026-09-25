import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/design/accent_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Owner, 2026-09-25: "set indigo as default theme". The client, the same
/// day: "These colors are not good; use some nice fluorescent colors."
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Indigo is the theme colour everyone gets until they choose', () {
    final indigo = AccentController.swatches.firstWhere((s) => s.$1 == 'Indigo').$2;
    expect(AccentController.defaultSeed, indigo);
    expect(AccentController.seed.value, indigo);
  });

  test('twelve distinct fluorescent swatches: vivid, bright, all different', () {
    const s = AccentController.swatches;
    expect(s.length, 12);
    expect(s.map((e) => e.$1).toSet().length, 12, reason: 'names repeat');
    expect(s.map((e) => e.$2.toARGB32()).toSet().length, 12, reason: 'colours repeat');
    for (final (name, c) in s) {
      final h = HSLColor.fromColor(c);
      // Highlighter-bright: fully saturated and lit — the pastel row they
      // replace sat at 0.4–0.9 saturation.
      expect(h.saturation, greaterThanOrEqualTo(0.95), reason: '$name is not vivid');
      // Indigo and Violet sit a little lighter so they stay readable as
      // text on the dark theme.
      expect(h.lightness, inInclusiveRange(0.5, 0.75), reason: '$name is not lit like a highlighter');
    }
  });

  test('a colour chosen from the old pastel row becomes its fluorescent twin', () {
    const pairs = {
      0xFFC77DFF: 'Violet', 0xFF8B9CFF: 'Indigo', 0xFF4FC3F7: 'Blue', 0xFF3FE0C8: 'Aqua',
      0xFF6EE7A8: 'Mint', 0xFFBDF64B: 'Lime', 0xFFFFC24B: 'Lemon', 0xFFFF8A65: 'Orange',
      0xFFFF7BA3: 'Pink', 0xFFFF6FD8: 'Magenta', 0xFFFF6B6B: 'Red', 0xFF9FB3C8: 'Blue',
    };
    final byName = {for (final (n, c) in AccentController.swatches) n: c};
    pairs.forEach((old, name) {
      expect(AccentController.migrate(Color(old)), byName[name], reason: 'old ${old.toRadixString(16)}');
    });
    // Anything else stays exactly as it was.
    expect(AccentController.migrate(const Color(0xFF123456)), const Color(0xFF123456));
    for (final (_, c) in AccentController.swatches) {
      expect(AccentController.migrate(c), c, reason: 'a new swatch is never moved');
    }
  });

  test('load() moves a saved pastel to its twin and stores it once', () async {
    SharedPreferences.setMockInitialValues({'accent_seed_v1': 0xFFFF8A65}); // Coral
    await AccentController.load();
    final orange = AccentController.swatches.firstWhere((s) => s.$1 == 'Orange').$2;
    expect(AccentController.seed.value, orange);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('accent_seed_v1'), orange.toARGB32());
    // Put the default back for the other tests in this process.
    await AccentController.set(AccentController.defaultSeed);
  });
}
