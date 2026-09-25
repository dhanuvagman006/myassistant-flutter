// SEND FEEDBACK (owner, 2026-09-25: "yes add the send feedback button").
//
// The client gets the app through Firebase App Distribution; a row on the
// You tab opens that service's own feedback form, and what the client
// writes lands in the Firebase console under the release. Pinned here:
//  * the row is on You, and a tap asks Android ("hari/feedback") to open
//    the form — once, with no toast when it opened;
//  * when the form cannot open, ONE toast says so and nothing crashes, and
//    it asks about the connection only when the connection is the cause
//    (review, 2026-09-25: it used to say "Check your internet" for
//    failures that were never the internet);
//  * a phone with no Android half (MissingPluginException) is the same
//    quiet "unavailable", not an exception;
//  * the SDK's own updater is never called: the app's updater stays the
//    only one; and the form is opened the one way that works in this SDK
//    version (its "no screenshot" null crashes before the form opens);
//  * every build published over the app's own update channel also goes to
//    App Distribution, the same file: the SDK finds the release by hashing
//    the installed APK, so a build App Distribution never saw answers
//    Send feedback with "Release not found".
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:myassistant/features/assistant/state/assistant_engine.dart';
import 'package:myassistant/screens/assistant_settings_screen.dart';
import 'package:myassistant/services/app_feedback.dart';
import 'package:myassistant/services/tester_feedback.dart';
import 'package:shared_preferences/shared_preferences.dart';

const unavailable =
    "Feedback isn't available right now. Please try again later.";
const offlineToast =
    'Feedback needs the internet. Check your connection and try again.';

/// The You tab loads over the network; offline, those loads fail fast and
/// what they throw is ignored (as in the clarity and layout tests).
Future<void> offline(Future<void> Function() body) async {
  final original = FlutterError.onError;
  FlutterError.onError = (d) {
    if (d.exceptionAsString().contains('overflowed')) original?.call(d);
  };
  try {
    await body();
  } finally {
    FlutterError.onError = original;
  }
}

/// The You tab, scrolled down to the Send feedback row.
Future<void> openYouAtFeedback(WidgetTester t) => offline(() async {
      await t.pumpWidget(const MaterialApp(home: AssistantSettingsScreen()));
      for (var i = 0; i < 6; i++) {
        await t.pump(const Duration(milliseconds: 300));
      }
      await t.scrollUntilVisible(find.text('Send feedback'), 300,
          scrollable: find.byType(Scrollable).first);
      await t.pump(const Duration(milliseconds: 300));
    });

Future<void> closeApp(WidgetTester t) => offline(() async {
      await t.pumpWidget(const SizedBox());
      AssistantEngine.instance.cancelReconnect();
      await t.pump(const Duration(seconds: 6));
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppFeedback.resetForTest();
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(TesterFeedback.channel, null);
    AppFeedback.resetForTest();
  });

  void answer(Future<Object?> Function(MethodCall) handler) =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(TesterFeedback.channel, handler);

  testWidgets('You shows Send feedback, and a tap opens the form', (t) async {
    final calls = <MethodCall>[];
    answer((c) async {
      calls.add(c);
      return true;
    });
    await openYouAtFeedback(t);

    expect(find.text('Send feedback'), findsOneWidget);
    expect(find.text('Tell the developer what to improve'), findsOneWidget);
    expect(
        find.descendant(
            of: find
                .ancestor(
                    of: find.text('Send feedback'), matching: find.byType(Row))
                .first,
            matching: find.byIcon(Icons.feedback_outlined)),
        findsOneWidget);

    await offline(() async {
      await t.tap(find.text('Send feedback'));
      await t.pump(const Duration(milliseconds: 300));
    });
    expect(calls.map((c) => c.method), ['start']);
    expect(find.text(unavailable), findsNothing,
        reason: 'the form opened: nothing to say');
    expect(find.text(offlineToast), findsNothing);
    await closeApp(t);
  });

  testWidgets('when the form cannot open, one toast says so', (t) async {
    var asked = 0;
    answer((c) async {
      asked++;
      // What the Android half says when Firebase never started: nothing
      // the user can fix, and nothing to do with the internet.
      throw PlatformException(
          code: 'unavailable', message: 'Default FirebaseApp is not initialized');
    });
    await openYouAtFeedback(t);

    await offline(() async {
      await t.tap(find.text('Send feedback'));
      await t.pump(const Duration(milliseconds: 300));
    });
    expect(asked, 1);
    expect(find.text(unavailable), findsOneWidget);
    expect(find.text(offlineToast), findsNothing,
        reason: 'the internet was not the cause, so it is not blamed');
    expect(t.takeException(), isNull);

    // It closes on its own, like every toast (errors live 5 s).
    await offline(() async {
      for (var i = 0; i < 40; i++) {
        await t.pump(const Duration(milliseconds: 200));
      }
    });
    expect(find.text(unavailable), findsNothing);
    await closeApp(t);
  });

  testWidgets('offline: the toast asks about the connection', (t) async {
    var asked = 0;
    answer((c) async {
      asked++;
      throw PlatformException(
          code: 'offline', message: 'No working internet connection.');
    });
    await openYouAtFeedback(t);

    await offline(() async {
      await t.tap(find.text('Send feedback'));
      await t.pump(const Duration(milliseconds: 300));
    });
    expect(asked, 1);
    expect(find.text(offlineToast), findsOneWidget);
    expect(find.text(unavailable), findsNothing);
    expect(t.takeException(), isNull);
    await closeApp(t);
  });

  // A plain test: a call with no handler goes out to the (absent) platform
  // and its "nobody here" answer only arrives on the real event loop.
  test('no Android half: a quiet "unavailable", not an exception', () async {
    // No handler at all — what an iOS build or a missing channel gives.
    expect(await TesterFeedback.start(), FeedbackStart.unavailable);
    answer((c) async => null);
    expect(await TesterFeedback.start(), FeedbackStart.unavailable,
        reason: 'no answer is not "opened"');
    answer((c) async => true);
    expect(await TesterFeedback.start(), FeedbackStart.opened);
    // Only the Android half's own "offline" code means offline.
    answer((c) async => throw PlatformException(code: 'offline'));
    expect(await TesterFeedback.start(), FeedbackStart.offline);
    answer((c) async =>
        throw PlatformException(code: 'unavailable', message: 'no network'));
    expect(await TesterFeedback.start(), FeedbackStart.unavailable,
        reason: 'a message is not a code: only "offline" blames the internet');
  });

  test('the SDK never updates the app: our updater stays the only one', () {
    final kotlin = Directory('android/app/src/main/kotlin')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.kt'))
        .map((f) => f.readAsStringSync())
        .join('\n');
    // Comments may name them; calls may not.
    for (final api in [
      'updateIfNewReleaseAvailable(',
      'checkForNewRelease(',
      'updateApp(',
    ]) {
      expect(kotlin.contains('.$api'), isFalse, reason: api);
    }
    // The no-screenshot overload with null crashes in this SDK version
    // (uri.getScheme() before its null check): the form would never open.
    expect(kotlin.contains('.startFeedback(R.string.feedback_prompt)'), isTrue);
    expect(RegExp(r'startFeedback\([^)]*,\s*null\)').hasMatch(kotlin), isFalse);
  });

  test('the connection is checked before the form starts', () {
    final bridge = File('android/app/src/main/kotlin/com/myassistant/'
            'myassistant/TesterFeedbackBridge.kt')
        .readAsStringSync();
    final check = bridge.indexOf('if (!hasInternet(activity))');
    expect(check, greaterThan(-1));
    expect(check, lessThan(bridge.indexOf('.startFeedback(')),
        reason: 'after startFeedback() the SDK can no longer tell Dart');
    expect(bridge.contains('result.error("offline"'), isTrue);
    // "Validated": Android's own check that the network reaches the
    // internet, not just that there is a network.
    expect(bridge.contains('NET_CAPABILITY_VALIDATED'), isTrue);
  });

  test('every OTA build goes to App Distribution first, the same file', () {
    final script = File('tool/publish_update.sh').readAsStringSync();
    final distribute =
        script.indexOf(r'firebase appdistribution:distribute "$APK"');
    expect(distribute, greaterThan(-1),
        reason: 'the SDK finds the release by hashing the installed APK: '
            'App Distribution must get THIS file, not a rebuild');
    // Before anything reaches the server: if App Distribution fails,
    // nothing has been published yet.
    for (final upload in [r'rsync -e ssh', r'scp -q "$APK"']) {
      final at = script.indexOf(upload);
      expect(at, greaterThan(-1), reason: upload);
      expect(distribute, lessThan(at), reason: upload);
    }
    // To the client's tester group: the SDK only finds releases the
    // signed-in tester has access to.
    expect(script, contains(r'--groups "$APPDIST_GROUPS"'));
    // Skipping it takes a deliberate SKIP_APPDIST=1, never a missing tool.
    expect(script, contains(r'[ "${SKIP_APPDIST:-}" = "1" ]'));
    expect(script, contains('REFUSING: the Firebase CLI'));
    expect(script, contains('REFUSING: APPDIST_GROUPS'));
  });
}
