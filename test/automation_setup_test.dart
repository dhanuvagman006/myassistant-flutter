// The one-time permission screen says what it never does, shows the steps
// while the switch is off, and continues the waiting task once it is on.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/screens/automation_setup_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  var connected = false;
  final calls = <String>[];

  setUp(() {
    connected = false;
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('hari/automation'), (c) async {
      calls.add(c.method);
      if (c.method == 'status') return {'connected': connected, 'enabled': connected};
      return true;
    });
  });

  testWidgets('off: the promise and the steps, and the button opens settings', (t) async {
    await t.pumpWidget(const MaterialApp(
        home: AutomationSetupScreen(pendingGoal: 'order veg biryani')));
    await t.pump();
    expect(find.text('One-time permission'), findsOneWidget);
    expect(find.text('Pay, place a paid order or book a paid ride'), findsOneWidget);
    expect(find.text('Type passwords, PINs, OTPs or card numbers'), findsOneWidget);
    expect(find.textContaining('it continues by itself'), findsOneWidget);
    await t.scrollUntilVisible(find.text('Open settings'), 200);
    await t.drag(find.byType(Scrollable), const Offset(0, -150));
    await t.pump();
    await t.tap(find.text('Open settings'));
    await t.pump();
    expect(calls, contains('openSettings'));
    // After a first try, the "Restricted setting" help appears.
    await t.scrollUntilVisible(find.text('Says "Restricted setting"?'), 200);
    expect(find.text('Says "Restricted setting"?'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('switched on: the waiting task carries on by itself', (t) async {
    var continued = 0;
    await t.pumpWidget(MaterialApp(
      home: Builder(
        builder: (ctx) => TextButton(
          onPressed: () => Navigator.of(ctx).push(MaterialPageRoute(
              builder: (_) => AutomationSetupScreen(
                  pendingGoal: 'order veg biryani', onEnabled: () => continued++))),
          child: const Text('go'),
        ),
      ),
    ));
    await t.tap(find.text('go'));
    await t.pumpAndSettle();
    connected = true;
    await t.pump(const Duration(seconds: 2)); // the poll sees the switch
    await t.pump(const Duration(seconds: 1));
    await t.pumpAndSettle();
    expect(continued, 1);
    expect(find.text('go'), findsOneWidget, reason: 'the setup screen closed itself');
  });
}
