// The Reminders screen: sections a busy day reads in, labels a person
// reads, and a tick that can be taken back.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/models/reminder.dart';
import 'package:myassistant/screens/reminders_screen.dart';

void main() {
  final now = DateTime(2026, 9, 23, 14, 0); // a Wednesday afternoon

  test('reminders are grouped the way a day is read', () {
    Reminder r(int id, DateTime? at, {bool done = false}) =>
        Reminder(id: id, text: 'r$id', dueAt: at, done: done);
    final g = groupReminders([
      r(1, DateTime(2026, 9, 23, 9)), // this morning, missed
      r(2, DateTime(2026, 9, 23, 18)), // tonight
      r(3, DateTime(2026, 9, 24, 9)), // tomorrow
      r(4, DateTime(2026, 9, 30, 9)), // next week
      r(5, null), // no time
      r(6, DateTime(2026, 9, 22), done: true),
      r(7, DateTime(2026, 9, 23, 16)), // later today, sorts before 18:00
    ], now);
    List<int> ids(String k) => g[k]!.map((x) => x.id).toList();
    expect(ids('Overdue'), [1]);
    expect(ids('Today'), [7, 2]);
    expect(ids('Tomorrow'), [3]);
    expect(ids('Later'), [4]);
    expect(ids('Anytime'), [5]);
    expect(ids('Done'), [6]);
  });

  test('due labels read like a person wrote them', () {
    expect(dueLabel(DateTime(2026, 9, 23, 17, 0), now), 'Today, 5:00 pm');
    expect(dueLabel(DateTime(2026, 9, 24, 9, 5), now), 'Tomorrow, 9:05 am');
    expect(dueLabel(DateTime(2026, 9, 26, 12, 30), now), 'Sat, 12:30 pm');
    expect(dueLabel(DateTime(2026, 10, 3, 0, 15), now), '3 Oct, 12:15 am');
  });

  testWidgets('shows the list, which ones will phone you, and ticks with Undo',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    final later = DateTime.now().add(const Duration(days: 3));
    await tester.pumpWidget(MaterialApp(
      home: RemindersScreen(loader: () async => [
            Reminder(id: 1, text: 'Call the auditor', dueAt: later, done: false, deliver: 'call'),
            const Reminder(id: 2, text: 'Buy stamps', done: false),
          ]),
    ));
    await tester.pump();
    expect(find.text('Call the auditor'), findsOneWidget);
    expect(find.text('Buy stamps'), findsOneWidget);
    expect(find.byTooltip('Your assistant will call you'), findsOneWidget);
    expect(find.text('LATER'), findsOneWidget); // GroupLabel uppercases
    expect(find.text('ANYTIME'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.radio_button_unchecked_rounded).first);
    await tester.pump();
    expect(find.text('Done — nice.'), findsOneWidget);
    expect(find.text('Undo'), findsOneWidget);
  });
}
