// TELEMETRY NEVER BREAKS THE THING IT WATCHES (2026-10-01): off until
// Firebase is up, and every call is harmless without it.
import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/core/log.dart';
import 'package:myassistant/services/telemetry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('off by default; logging, events, errors and traces are no-ops', () {
    final t = Telemetry.instance;
    expect(t.enabled, isFalse);
    t.log('a line');
    t.event('tab', {'name': 'hub'});
    t.error(StateError('x'), StackTrace.current, reason: 'test');
    final span = t.trace('assistant_turn')
      ..attribute('engine', 'cloud')
      ..metric('tools', 2)
      ..stop();
    span.stop(); // twice is fine
    AppLog.add('test', 'a breadcrumb that goes nowhere'); // mirrored, harmlessly
  });

  test('enabling without Firebase fails closed, not loudly', () async {
    final ok = await Telemetry.instance.enable();
    expect(ok, isFalse);
    expect(Telemetry.instance.enabled, isFalse);
  });
}
