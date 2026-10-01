// ONE TOAST POLICY (2026-09-24, the owner's "the toast repeats and is not
// closed"): the same message is shown once, a new message replaces the old
// one instead of queueing behind it, every toast closes on its own and has
// a ✕, an Undo toast closes by itself and then commits, and nothing is
// replayed stale after the app comes back from the background.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/services/app_feedback.dart';

void main() {
  setUp(AppFeedback.resetForTest);
  tearDown(AppFeedback.resetForTest);

  late BuildContext ctx;
  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      scaffoldMessengerKey: AppFeedback.messengerKey,
      navigatorObservers: [AppFeedback.observer],
      home: Scaffold(
        body: Builder(builder: (c) {
          ctx = c;
          return const SizedBox.expand();
        }),
      ),
    ));
  }

  Finder bar() => find.byType(SnackBar);

  testWidgets('the same message twice within 5 s is shown once', (tester) async {
    await pumpApp(tester);
    AppFeedback.show('Saved to your documents.', context: ctx);
    await tester.pump(const Duration(milliseconds: 500));
    AppFeedback.show('Saved to your documents.', context: ctx);
    AppFeedback.toast('Saved to your documents.'); // from a service
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Saved to your documents.'), findsOneWidget);
    // It closes on its own — and nothing queued behind it plays again.
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    expect(bar(), findsNothing);
  });

  testWidgets('a new message replaces the old one; nothing queues', (tester) async {
    await pumpApp(tester);
    for (var i = 1; i <= 5; i++) {
      AppFeedback.show('Message number $i', context: ctx);
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Message number 5'), findsOneWidget);
    for (var i = 1; i <= 4; i++) {
      expect(find.text('Message number $i'), findsNothing);
    }
    // Under the old behaviour this burst covered the screen for ~20 s.
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    expect(bar(), findsNothing, reason: 'the queue is empty once it closes');
  });

  testWidgets('every toast has a close button that works', (tester) async {
    await pumpApp(tester);
    AppFeedback.show("Couldn't save — try again.", context: ctx);
    await tester.pumpAndSettle();
    final close = find.descendant(of: bar(), matching: find.byIcon(Icons.close));
    expect(close, findsOneWidget);
    await tester.tap(close);
    await tester.pumpAndSettle();
    expect(bar(), findsNothing);
    // Asked again after the ✕: it is shown again (not swallowed as a repeat).
    AppFeedback.show("Couldn't save — try again.", context: ctx);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text("Couldn't save — try again."), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
  });

  testWidgets('an Undo toast closes by itself, then the change commits',
      (tester) async {
    await pumpApp(tester);
    SnackBarClosedReason? reason;
    var undone = false;
    AppFeedback.showUndo(ctx, 'Reminder removed', onUndo: () => undone = true)
        .then((r) => reason = r);
    await tester.pumpAndSettle(); // shown; its 4 s clock is running
    expect(find.text('Undo'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('Undo'), findsNothing,
        reason: 'an action toast used to stay until swiped');
    expect(reason, SnackBarClosedReason.timeout);
    expect(undone, isFalse);
  });

  testWidgets('a failure with Try again: the button retries; the toast still closes by itself',
      (tester) async {
    await pumpApp(tester);
    var tries = 0;
    const line = "Couldn't reach the server — check your connection.";
    AppFeedback.showRetry(line, context: ctx, onRetry: () => tries++);
    await tester.pumpAndSettle();
    expect(find.text('Try again'), findsOneWidget);
    expect(find.byIcon(Icons.error_outline_rounded), findsOneWidget, reason: 'reads as an error');
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(tries, 1);
    // The same failure after a retry is shown again — not dropped as a repeat.
    AppFeedback.showRetry(line, context: ctx, onRetry: () => tries++);
    await tester.pumpAndSettle();
    expect(find.text('Try again'), findsOneWidget);
    await tester.pump(const Duration(seconds: 7));
    await tester.pumpAndSettle();
    expect(bar(), findsNothing, reason: 'every toast closes on its own');
    expect(tries, 1);
  });

  testWidgets('tapping Undo undoes and does not commit', (tester) async {
    await pumpApp(tester);
    SnackBarClosedReason? reason;
    var undone = false;
    AppFeedback.showUndo(ctx, 'Marked as kept', onUndo: () => undone = true)
        .then((r) => reason = r);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(undone, isTrue);
    expect(reason, SnackBarClosedReason.action);
  });

  testWidgets('a background message waits behind an Undo, then shows',
      (tester) async {
    await pumpApp(tester);
    AppFeedback.showUndo(ctx, 'Reminder removed', onUndo: () {});
    await tester.pumpAndSettle();
    AppFeedback.toast('Filed under Ravi.');
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Reminder removed'), findsOneWidget,
        reason: 'the Undo is not swept away by a service message');
    expect(find.text('Filed under Ravi.'), findsNothing);
    await tester.pump(const Duration(seconds: 5)); // the Undo times out
    await tester.pumpAndSettle();
    await tester.pump(); // the waiting message goes up
    await tester.pumpAndSettle();
    expect(find.text('Filed under Ravi.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
  });

  testWidgets('in the background: progress notes are dropped, the rest wait',
      (tester) async {
    await pumpApp(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    AppFeedback.toast('Calling Ravi…', tone: FeedbackTone.progress);
    await tester.pump(const Duration(milliseconds: 300));
    expect(bar(), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Calling Ravi…'), findsNothing,
        reason: 'a progress note is stale once the user is back');

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    AppFeedback.toast('Saved to your documents.');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Saved to your documents.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
  });

  testWidgets('a service message waits while a dialog covers the screen',
      (tester) async {
    await pumpApp(tester);
    showDialog<void>(
        context: ctx, builder: (_) => const AlertDialog(content: Text('Sure?')));
    await tester.pumpAndSettle();
    AppFeedback.toast('Translator off.');
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Translator off.'), findsNothing,
        reason: 'it would land under the dialog, unseen');
    Navigator.of(ctx).pop();
    await tester.pumpAndSettle();
    expect(find.text('Translator off.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
  });

  testWidgets('what the assistant says aloud is not repeated during a session',
      (tester) async {
    await pumpApp(tester);
    AppFeedback.sessionVisible = () => true;
    AppFeedback.toast('No clock app on this phone.', spoken: true);
    await tester.pump(const Duration(milliseconds: 300));
    expect(bar(), findsNothing, reason: 'the caption already says it');
    AppFeedback.sessionVisible = () => false;
    AppFeedback.toast('No clock app on this phone.', spoken: true);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('No clock app on this phone.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
  });

  testWidgets('a toast from a page does not follow the user off it',
      (tester) async {
    await pumpApp(tester);
    Navigator.of(ctx).push(MaterialPageRoute<void>(
        builder: (c) => Scaffold(
              body: Builder(builder: (inner) {
                return TextButton(
                  onPressed: () => AppFeedback.show('Copied', context: inner),
                  child: const Text('copy'),
                );
              }),
            )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('copy'));
    await tester.pumpAndSettle();
    expect(find.text('Copied'), findsOneWidget);
    // A toast raised in the same moment as leaving ("Saved", then back) is
    // kept; this one has been up a while.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 900)));
    Navigator.of(ctx).pop();
    await tester.pumpAndSettle();
    expect(find.text('Copied'), findsNothing);
  });

  testWidgets('long messages are capped at three lines and errors read as errors',
      (tester) async {
    await pumpApp(tester);
    AppFeedback.show("Couldn't upload that — ${'check your connection ' * 20}",
        context: ctx);
    await tester.pumpAndSettle();
    final text = tester.widget<Text>(
        find.descendant(of: bar(), matching: find.textContaining("Couldn't upload")));
    expect(text.maxLines, 3);
    expect(find.descendant(of: bar(), matching: find.byIcon(Icons.error_outline_rounded)),
        findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
  });
}
