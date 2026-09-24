// Keeps the toast policy from eroding: every message goes through
// AppFeedback (one slot, no repeats, always closes), and no SnackBar with
// an action is ever left to its default persist: true — the Undo toast that
// never closed and held every later toast behind it (2026-09-24).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final sources = Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList();
  String rel(File f) => f.path.replaceAll('\\', '/');

  test('no screen calls showSnackBar itself', () {
    final offenders = [
      for (final f in sources)
        if (!rel(f).endsWith('lib/services/app_feedback.dart') &&
            f.readAsStringSync().contains('showSnackBar('))
          rel(f),
    ];
    expect(offenders, isEmpty,
        reason: 'use AppFeedback.show / showUndo / copied instead');
  });

  test('every SnackBar with an action closes on its own', () {
    final offenders = [
      for (final f in sources)
        if (f.readAsStringSync().contains('SnackBarAction(') &&
            !f.readAsStringSync().contains('persist: false'))
          rel(f),
    ];
    expect(offenders, isEmpty,
        reason: 'an action SnackBar defaults to persist: true and never times out');
  });
}
