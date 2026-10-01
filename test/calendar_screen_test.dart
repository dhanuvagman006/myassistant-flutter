// Golden path: the Calendar screen (Hub → Calendar) paints the user's own
// month and the world's holidays from the two endpoints it depends on, and
// says so (with a retry) when the holidays cannot be loaded — never a blank
// page. Cheap regression guard for a screen that had no test (2026-10-01).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/features/calendar/calendar_service.dart';
import 'package:myassistant/screens/calendar_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  void phone(WidgetTester t) {
    t.view.devicePixelRatio = 2.625;
    t.view.physicalSize = const Size(1080, 2340);
    addTearDown(t.view.reset);
  }

  Future<void> settle(WidgetTester t) async {
    for (var i = 0; i < 8; i++) {
      await t.pump(const Duration(milliseconds: 250));
    }
  }

  Future<void> leave(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 2));
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    CalendarService.debugReset();
  });

  tearDown(() {
    CalendarService.getJson = (path) => Future.value(null);
    CalendarService.debugReset();
  });

  String iso(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  testWidgets('own month + holidays load from their endpoints and are shown',
      (t) async {
    phone(t);
    final today = DateUtils.dateOnly(DateTime.now());
    final asked = <String>[];
    CalendarService.getJson = (path) async {
      asked.add(path);
      if (path.startsWith('/brief/calendar')) {
        return {
          'days': {
            '${today.day}': [
              {'kind': 'reminder', 'title': 'Pay the electricity bill'}
            ]
          }
        };
      }
      if (path.startsWith('/tools/calendar/extras')) {
        return {
          'region': 'IN-KL',
          'items': [
            {'date': iso(today), 'kind': 'holiday', 'title': 'Test Holiday Day'}
          ]
        };
      }
      return null;
    };
    await t.pumpWidget(const MaterialApp(home: CalendarScreen()));
    await settle(t);
    expect(asked.any((p) => p.startsWith('/brief/calendar?y=')), isTrue,
        reason: 'the month comes from /brief/calendar');
    expect(asked.any((p) => p.startsWith('/tools/calendar/extras?from=')),
        isTrue,
        reason: 'holidays come from /tools/calendar/extras');
    expect(find.textContaining('Pay the electricity bill'), findsWidgets);
    expect(find.textContaining('Test Holiday Day'), findsWidgets);
    expect(find.textContaining("Couldn't load"), findsNothing);
    await leave(t);
  });

  testWidgets('when holidays cannot be loaded the screen says so with a retry',
      (t) async {
    phone(t);
    CalendarService.getJson = (path) async {
      if (path.startsWith('/brief/calendar')) return {'days': {}};
      return null; // extras down
    };
    await t.pumpWidget(const MaterialApp(home: CalendarScreen()));
    await settle(t);
    expect(find.textContaining("Couldn't load"), findsWidgets);
    expect(find.text('Try again'), findsWidgets);
    await leave(t);
  });
}
