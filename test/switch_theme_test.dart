// ONE SWITCH (UI pass, 2026-09-29). Six switches painted themselves green
// and two violet, while "Theme colour" promises to paint every highlight:
// on the same You tab one switch ignored the owner's colour and the next
// followed it. Every switch now takes the app theme's switchTheme (the
// accent, so it follows the chosen colour); this keeps new ones from
// drifting back to a colour of their own.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('no switch paints itself — the theme decides', () {
    final offenders = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart')) continue;
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (!RegExp(r'\bSwitch(\.adaptive)?\($').hasMatch(lines[i].trimRight())) continue;
        for (var j = i + 1; j < lines.length && j <= i + 14; j++) {
          if (RegExp(r'^\s*\)').hasMatch(lines[j])) break;
          if (RegExp(r'^\s*(activeColor|activeThumbColor|activeTrackColor|inactiveThumbColor|inactiveTrackColor|thumbColor|trackColor):')
              .hasMatch(lines[j])) {
            offenders.add('${f.path}:${j + 1}');
          }
        }
      }
    }
    expect(offenders, isEmpty);
  });

  test('the theme gives switches the accent', () {
    final theme = File('lib/theme/app_theme.dart').readAsStringSync();
    expect(theme, contains('switchTheme: SwitchThemeData('));
    expect(RegExp(r'switchTheme: SwitchThemeData\([\s\S]{0,400}Neon\.violet').hasMatch(theme), isTrue);
  });
}
