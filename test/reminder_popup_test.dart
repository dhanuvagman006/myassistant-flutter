import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/features/reminders/reminder_popup.dart';
import 'package:myassistant/models/reminder.dart';
import 'package:myassistant/services/avatar_message_service.dart';
import 'package:myassistant/services/notification_service.dart';
import 'package:myassistant/shell/home_shell.dart';

/// The reminder pop-up (owner, 2026-09-30: "need reminder pop up like this
/// style").

final now = DateTime(2026, 9, 30, 15, 5); // a Wednesday

final focus = Reminder(id: 5, text: 'Call the bank about the loan', dueAt: now.add(const Duration(minutes: 25)), done: false);
final all = [
  Reminder(id: 1, text: 'Morning walk', dueAt: DateTime(2026, 9, 30, 7), done: true),
  focus,
  Reminder(id: 6, text: 'Pick up the cake', dueAt: DateTime(2026, 9, 30, 18, 30), done: false),
  Reminder(id: 7, text: 'Pay electricity bill', dueAt: DateTime(2026, 10, 2, 10), done: false),
];

class FakeApi extends ReminderPopupApi {
  Completer<bool>? doneGate;
  final snoozed = <DateTime>[];
  int changes = 0;

  @override
  Future<bool> done(Reminder r) => (doneGate = Completer<bool>()).future;

  @override
  Future<bool> snooze(Reminder r, DateTime to) async {
    snoozed.add(to);
    return true;
  }

  @override
  void changed() => changes++;
}

Future<FakeApi> sheet(WidgetTester t) async {
  final api = FakeApi();
  t.view.physicalSize = const Size(400, 900);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.bottomCenter,
        child: ReminderPopupSheet(focus: focus, all: all, api: api, clock: () => now),
      ),
    ),
  ));
  await t.pump();
  return api;
}

void main() {
  testWidgets('the day, the reminder, what is next, the week', (t) async {
    await sheet(t);
    expect(find.text('1 of 3 done today'), findsOneWidget);
    expect(find.text('33%'), findsOneWidget);
    expect(find.text('Call the bank about the loan'), findsOneWidget);
    expect(find.text('In 25 minutes'), findsOneWidget);
    expect(find.text('3:30 pm'), findsOneWidget);
    expect(find.text('Next up'), findsOneWidget);
    expect(find.text('Pick up the cake'), findsOneWidget);
    expect(find.text('This week'), findsOneWidget);
    expect(find.text('Sep 28 – Oct 4'), findsOneWidget);
    expect(find.text('Mark done'), findsOneWidget);
    expect(find.text('Snooze'), findsOneWidget);
  });

  testWidgets('Mark done answers on the touch; a failure puts it back', (t) async {
    final api = await sheet(t);
    await t.tap(find.text('Mark done'));
    await t.pump();
    expect(find.text('Done'), findsOneWidget, reason: 'before the server answers');
    expect(find.text('2 of 3 done today'), findsOneWidget);
    api.doneGate!.complete(false);
    await t.pump();
    expect(find.text('Mark done'), findsOneWidget, reason: 'the server said no');
    expect(api.changes, 0);
    await t.pump(const Duration(seconds: 6));
  });

  testWidgets('Next up becomes the reminder on a tap', (t) async {
    await sheet(t);
    await t.tap(find.text('Pick up the cake'));
    await t.pump();
    expect(find.text('Pick up the cake'), findsOneWidget);
    expect(find.text('In 3 hours'), findsOneWidget);
  });

  testWidgets('Snooze moves it ten minutes on', (t) async {
    final api = await sheet(t);
    await t.tap(find.text('Snooze'));
    await t.pump();
    expect(api.snoozed.single, now.add(const Duration(minutes: 10)));
    await t.pump(const Duration(seconds: 6));
  });

  testWidgets("a reminder notification's tap opens its pop-up", (t) async {
    ReminderPopup.api = FakeApi();
    ReminderNotifications.instance.synced.value = all;
    await t.pumpWidget(MaterialApp(
      navigatorKey: AvatarMessageService.navigatorKey,
      home: const Scaffold(body: SizedBox()),
    ));
    unawaited(openNotificationPayload('${ReminderNotifications.reminderPayload}5'));
    await t.pumpAndSettle();
    expect(find.text('Call the bank about the loan'), findsOneWidget);
    ReminderNotifications.instance.synced.value = const [];
  });
}
