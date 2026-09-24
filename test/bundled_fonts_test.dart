import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:myassistant/core/bundled_fonts.dart';

/// Pins the "fonts ship inside the app" fix (2026-09-24): every weight the
/// app can ask for is bundled under the name google_fonts looks for, the
/// folder is declared as an asset, and fetching stays off.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('every weight of both families is bundled, with its licence', () {
    for (final e in bundledFontFamilies.entries) {
      for (final weight in e.value) {
        final f = File('assets/google_fonts/${e.key}-$weight.ttf');
        expect(f.existsSync(), isTrue, reason: '${f.path} is missing');
        expect(f.lengthSync(), greaterThan(50000), reason: '${f.path} looks truncated');
      }
      expect(File('assets/google_fonts/OFL-${e.key}.txt').existsSync(), isTrue);
    }
  });

  test('the folder is an asset and main() turns fetching off first', () {
    expect(File('pubspec.yaml').readAsStringSync(), contains('- assets/google_fonts/'));
    final main = File('lib/main.dart').readAsStringSync();
    expect(main, contains('WidgetsFlutterBinding.ensureInitialized();\n  useBundledFonts();'));
    GoogleFonts.config.allowRuntimeFetching = true;
    useBundledFonts();
    expect(GoogleFonts.config.allowRuntimeFetching, isFalse);
  });

  test('every weight the code asks for maps onto a bundled Manrope file', () {
    const names = {
      200: 'ExtraLight', 300: 'Light', 400: 'Regular', 500: 'Medium',
      600: 'SemiBold', 700: 'Bold', 800: 'ExtraBold',
    };
    final src = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .map((f) => f.readAsStringSync())
        .join('\n');
    // Neither family has 100 or 900 (and Space Grotesk stops at 300-700):
    // google_fonts then uses the nearest bundled weight, never the network.
    final used = RegExp(r'FontWeight\.w(\d)00')
        .allMatches(src)
        .map((m) => int.parse(m.group(1)!) * 100)
        .where((w) => w != 100 && w != 900)
        .toSet();
    for (final w in used) {
      expect(bundledFontFamilies['Manrope'], contains(names[w]), reason: 'w$w');
    }
  });
}
