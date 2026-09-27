// The app lock must cover a screen that is already open (audit,
// 2026-09-27). It used to be the first route's child: relocking after a
// minute away swapped only that route, and Email, a patient's case file or
// a screen opened by voice stayed on top of the lock, readable and usable.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/screens/lock_screen.dart';
import 'package:myassistant/services/app_lock.dart';

class _CaseFile extends StatefulWidget {
  const _CaseFile();

  @override
  State<_CaseFile> createState() => _CaseFileState();
}

class _CaseFileState extends State<_CaseFile> {
  static int shared = 0;
  static final focus = FocusNode();

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Column(children: [
          const Text('Patient case file'),
          TextField(focusNode: focus),
          TextButton(
              onPressed: () => shared++, child: const Text('Share report')),
        ]),
      );
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  final lock = AppLock.instance;

  Widget app() => MaterialApp(
        builder: (context, child) => LockLayer(
            locked: () => lock.shouldLock, changes: lock, child: child!),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(builder: (_) => const _CaseFile())),
                child: const Text('Open case file'),
              ),
            ),
          ),
        ),
      );

  void awayThreeMinutes() {
    final t0 = DateTime(2026, 9, 27, 10);
    lock.notePaused(t0);
    lock.noteResumed(t0.add(const Duration(minutes: 3)));
  }

  testWidgets('relocking covers a screen already open, and back does not walk it',
      (tester) async {
    // Asked before the app's Navigator, as main() adds it before runApp.
    final guard = LockBackGuard(() => lock.shouldLock);
    WidgetsBinding.instance.addObserver(guard);
    addTearDown(() => WidgetsBinding.instance.removeObserver(guard));
    final platform = <String>[];
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      platform.add(call.method);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    await lock.enable('1234');
    addTearDown(lock.disable);
    await tester.pumpWidget(app());
    await tester.tap(find.text('Open case file'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(_CaseFileState.focus.hasFocus, isTrue);

    awayThreeMinutes();
    await tester.pump(); // one frame: the lock is up at once, no fade in

    expect(find.text('MyAssistant is locked'), findsOneWidget);
    expect(find.text('Patient case file'), findsNothing,
        reason: 'the open screen shows over (or through) the lock');
    expect(find.text('Patient case file', skipOffstage: false), findsOneWidget,
        reason: 'kept, so the owner is back there after unlocking');
    expect(_CaseFileState.focus.hasFocus, isFalse,
        reason: 'typing would go into the hidden field');
    await tester.tap(find.text('Share report', skipOffstage: false),
        warnIfMissed: false);
    expect(_CaseFileState.shared, 0, reason: 'the screen under the lock is usable');

    // Back leaves the app; it does not pop the hidden screen.
    expect(await tester.binding.handlePopRoute(), isTrue);
    await tester.pump();
    expect(platform, contains('SystemNavigator.pop'));
    expect(find.text('Patient case file', skipOffstage: false), findsOneWidget);
    expect(find.text('MyAssistant is locked'), findsOneWidget);

    // The PIN opens it, onto the same screen.
    for (final d in ['1', '2', '3', '4']) {
      await tester.tap(find.text(d));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(lock.shouldLock, isFalse);
    expect(find.text('MyAssistant is locked'), findsNothing);
    expect(find.text('Patient case file'), findsOneWidget);
    await tester.tap(find.text('Share report'));
    expect(_CaseFileState.shared, 1);

    // Unlocked, back is the app's own again.
    platform.clear();
    expect(await tester.binding.handlePopRoute(), isTrue);
    await tester.pumpAndSettle();
    expect(platform, isNot(contains('SystemNavigator.pop')));
    expect(find.text('Open case file'), findsOneWidget);
  });

  testWidgets('a toast a hidden screen raises does not show on the lock',
      (tester) async {
    await lock.enable('1234');
    addTearDown(lock.disable);
    await tester.pumpWidget(app());
    await tester.tap(find.text('Open case file'));
    await tester.pumpAndSettle();
    final hidden = tester.element(find.text('Patient case file'));

    awayThreeMinutes();
    await tester.pump();
    final undone = <bool>[];
    ScaffoldMessenger.of(hidden).showSnackBar(SnackBar(
      content: const Text('Biopsy report shared with Ravi'),
      action: SnackBarAction(label: 'Undo', onPressed: () => undone.add(true)),
    ));
    await tester.pumpAndSettle();

    expect(find.text('MyAssistant is locked'), findsOneWidget);
    expect(find.text('Biopsy report shared with Ravi'), findsNothing,
        reason: "a hidden screen's words show on the lock");
    expect(find.text('Undo'), findsNothing,
        reason: 'an action under the lock can be used');
    ScaffoldMessenger.of(hidden).removeCurrentSnackBar();
    await tester.pumpAndSettle();
    expect(undone, isEmpty);
  });

  testWidgets('with the lock off nothing is covered', (tester) async {
    await tester.pumpWidget(app());
    awayThreeMinutes();
    await tester.pump();
    expect(find.text('MyAssistant is locked'), findsNothing);
    expect(find.text('Open case file'), findsOneWidget);
  });
}
