import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/design/accent_controller.dart';

/// Owner, 2026-09-25: "set indigo as default theme".
void main() {
  test('Indigo is the theme colour everyone gets until they choose', () {
    final indigo = AccentController.swatches.firstWhere((s) => s.$1 == 'Indigo').$2;
    expect(AccentController.defaultSeed, indigo);
    expect(AccentController.seed.value, indigo);
  });
}
