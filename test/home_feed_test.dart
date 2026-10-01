import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/features/home/home_feed.dart';
import 'package:myassistant/models/brief.dart';
import 'package:myassistant/services/call_history.dart';

/// Home's ranking (2026-09-29): one Now card, two Also cards, three lines
/// of the day, quick actions — by plain rules over the brief and the
/// missed calls. See lib/features/home/home_feed.dart for the table.

final afternoon = DateTime(2026, 9, 29, 14, 35);
final evening = DateTime(2026, 9, 29, 19, 10);

int at(DateTime t) => t.millisecondsSinceEpoch;

AgendaItem meeting(String title, DateTime t) =>
    AgendaItem(kind: 'meeting', title: title, atMs: at(t));
AgendaItem reminder(int id, String title, DateTime? t) =>
    AgendaItem(kind: 'reminder', id: id, title: title, atMs: t == null ? null : at(t));

HomeFeed rank(TodayBrief b,
        {DateTime? now,
        List<CallEntry> missed = const [],
        Set<String> hidden = const {},
        bool newUser = false}) =>
    HomeRanker.rank(
        brief: b,
        now: now ?? afternoon,
        missed: missed,
        hidden: hidden,
        newUser: newUser);

void main() {
  group('the Now card', () {
    test('a meeting within the hour comes first, with how long until it', () {
      final f = rank(TodayBrief(agenda: [
        reminder(1, 'Pick up medicines', afternoon.add(const Duration(minutes: 40))),
        meeting('Design review', afternoon.add(const Duration(minutes: 25))),
      ]));
      expect(f.now!.kind, HomeCardKind.meeting);
      expect(f.now!.reason, 'In 25 min');
      expect(f.now!.detail, 'At 3:00 pm');
      expect(f.also.single.title, 'Pick up medicines');
      expect(f.also.single.reason, 'In 40 min');
    });

    test('one Now and at most two Also, most urgent first', () {
      final f = rank(TodayBrief(
        agenda: [reminder(1, 'Call the bank', afternoon.add(const Duration(minutes: 10)))],
        promises: [
          PromiseItem(id: 7, text: 'To Ravi: Send the quote', owedTo: 'Ravi',
              dueAtMs: at(afternoon.add(const Duration(hours: 3)))),
        ],
        messages: const [BriefMessage(from: 'Priya', text: 'Lunch tomorrow?')],
        dates: const [DateItem(kind: 'payment', title: 'Home loan EMI · ₹12000', when: 'today')],
      ));
      expect(f.now!.title, 'Call the bank');
      expect([for (final c in f.also) c.title], ['Send the quote', 'Home loan EMI · ₹12000'],
          reason: 'the message (600) waits behind a promise due today (420) and a bill (430)');
    });

    test('a reminder rung and not ticked is a card for three hours, then Reminders keeps it', () {
      final f = rank(TodayBrief(agenda: [
        reminder(1, 'Water the plants', afternoon.subtract(const Duration(minutes: 50))),
        reminder(2, 'Morning pills', afternoon.subtract(const Duration(hours: 5))),
      ]));
      expect(f.now!.title, 'Water the plants');
      expect(f.now!.reason, 'Was due 1:45 pm');
      expect(f.also, isEmpty, reason: 'five hours ago is not nagged about');
    });

    test('a meeting two hours out is only an Also card', () {
      final f = rank(TodayBrief(agenda: [
        meeting('Board call', afternoon.add(const Duration(minutes: 100))),
      ]));
      expect(f.now!.reason, 'At 4:15 pm');
      expect(f.now!.score, greaterThanOrEqualTo(500));
    });
  });

  group('missed calls, promises, messages, dates', () {
    test('a missed call says who, when and how many', () {
      final c1 = CallEntry(name: 'Amma', number: '+919800000001', type: 'missed',
          at: afternoon.subtract(const Duration(minutes: 10)));
      final c2 = CallEntry(name: 'Amma', number: '+919800000001', type: 'missed',
          at: afternoon.subtract(const Duration(minutes: 30)));
      final f = rank(const TodayBrief(), missed: [c1, c2]);
      expect(f.now!.kind, HomeCardKind.missedCall);
      expect(f.now!.title, 'Amma');
      expect(f.now!.reason, '10 min ago');
      expect(f.now!.detail, '2 missed calls');
    });

    test('a promise names who is waiting, not "To Ravi:" twice', () {
      final f = rank(TodayBrief(promises: [
        PromiseItem(id: 7, text: 'To Ravi: Send the quote', owedTo: 'Ravi',
            dueAtMs: at(afternoon.subtract(const Duration(hours: 20)))),
      ]));
      expect(f.now!.title, 'Send the quote');
      expect(f.now!.reason, 'Overdue');
      expect(f.now!.detail, 'You promised Ravi');
    });

    test('an older server sends only the label; one undated promise at most', () {
      final f = rank(const TodayBrief(promises: [
        PromiseItem(id: 1, text: 'Book the tickets', dueLabel: 'due today'),
        PromiseItem(id: 2, text: 'Fix the tap'),
        PromiseItem(id: 3, text: 'Return the book'),
      ]));
      expect(f.now!.reason, 'Due today');
      expect([for (final c in f.also) c.title], ['Fix the tap']);
    });

    test('messages are one card, however many', () {
      final f = rank(const TodayBrief(messages: [
        BriefMessage(from: 'Priya', text: 'Lunch tomorrow?'),
        BriefMessage(from: 'Ravi', text: 'Call me'),
      ]));
      expect(f.now!.title, 'Message from Priya');
      expect(f.now!.reason, '2 waiting');
      expect(f.also, isEmpty);
    });

    test("tomorrow's birthday waits for the evening, and never makes Home busy", () {
      const b = TodayBrief(dates: [
        DateItem(kind: 'birthday', title: "Amma's birthday", person: 'Amma', when: 'tomorrow'),
      ]);
      expect(rank(b).also, isEmpty, reason: 'nothing to do about it at 2 pm');
      final f = rank(b, now: evening);
      expect(f.allClear, isTrue, reason: 'tomorrow is not now');
      expect(f.also.single.title, "Amma's birthday");
      expect(f.also.single.reason, 'Tomorrow');
    });
  });

  group('all clear, Not now, a newcomer', () {
    test('nothing time-critical: all clear, with what is left as Also', () {
      final f = rank(const TodayBrief(promises: [PromiseItem(id: 2, text: 'Fix the tap')]));
      expect(f.allClear, isTrue);
      expect(f.also.single.reason, 'No date set');
    });

    test('"Not now" hides a card; the next one takes its place', () {
      final b = TodayBrief(agenda: [
        meeting('Design review', afternoon.add(const Duration(minutes: 25))),
        reminder(1, 'Call the bank', afternoon.add(const Duration(minutes: 30))),
      ]);
      final first = rank(b).now!;
      final f = rank(b, hidden: {first.id});
      expect(f.now!.title, 'Call the bank');
    });

    test('a moved reminder is a new card: "Not now" on the old time does not hide it', () {
      final r = reminder(1, 'Call the bank', afternoon.add(const Duration(minutes: 30)));
      final old = rank(TodayBrief(agenda: [r])).now!.id;
      final moved = reminder(1, 'Call the bank', afternoon.add(const Duration(minutes: 50)));
      expect(rank(TodayBrief(agenda: [moved]), hidden: {old}).now, isNotNull);
    });

    test('a newcomer with nothing yet is asked to talk; not once there is something', () {
      expect(rank(const TodayBrief(), newUser: true).now!.kind, HomeCardKind.getStarted);
      expect(rank(const TodayBrief(), newUser: false).allClear, isTrue);
      final f = rank(const TodayBrief(promises: [PromiseItem(id: 2, text: 'Fix the tap')]), newUser: true);
      expect(f.now, isNull);
      expect(f.also.single.kind, HomeCardKind.promise);
    });
  });

  group('the day', () {
    test('the next three, never what is already a card, then undated ones', () {
      final f = rank(TodayBrief(agenda: [
        meeting('Design review', afternoon.add(const Duration(minutes: 25))),
        reminder(1, 'Pick up medicines', afternoon.add(const Duration(hours: 4))),
        reminder(2, 'Plan tomorrow', afternoon.add(const Duration(hours: 5, minutes: 25))),
        reminder(3, 'Buy stamps', null),
        reminder(4, 'Old one', afternoon.subtract(const Duration(hours: 6))),
      ]));
      expect(f.dayLabel, 'Today');
      expect([for (final l in f.day) l.item.title], ['Pick up medicines', 'Plan tomorrow', 'Buy stamps']);
      expect([for (final l in f.day) l.time], ['6:35 pm', '8:00 pm', 'Anytime']);
    });

    test('in the evening, with nothing left today, it is tomorrow', () {
      final f = rank(TodayBrief(
        agenda: [reminder(1, 'Lunch', evening.subtract(const Duration(hours: 6)))],
        tomorrow: [reminder(5, 'Dentist', DateTime(2026, 9, 30, 9, 30))],
      ), now: evening);
      expect(f.dayLabel, 'Tomorrow');
      expect(f.day.single.time, '9:30 am');
    });
  });

  group('quick actions', () {
    test('three, the first following a promise on screen', () {
      final f = rank(TodayBrief(promises: [
        PromiseItem(id: 7, text: 'To Ravi: Send the quote', owedTo: 'Ravi',
            dueAtMs: at(afternoon.add(const Duration(hours: 1)))),
      ]));
      expect(f.asks, hasLength(3));
      expect(f.asks.first.label, 'Help with my promise');
      expect(f.asks.first.request, contains('"Send the quote"'));
      expect(f.asks.first.request, contains('ask me before sending'));
    });

    test('otherwise the ones that fit the hour', () {
      expect(rank(const TodayBrief(), now: DateTime(2026, 9, 29, 9)).asks.first.label,
          'Brief me for today');
      expect(rank(const TodayBrief(), now: evening).asks.first.label, 'Summarise my day');
    });
  });

  test('the brief reads tomorrow, dates and promise details, and tolerates their absence', () {
    final b = TodayBrief.fromJson({
      'agenda': [],
      'tomorrow': [
        {'kind': 'reminder', 'id': 5, 'title': 'Dentist', 'at': 1790742600000},
      ],
      'dates': [
        {'kind': 'birthday', 'title': "Amma's birthday", 'person': 'Amma', 'when': 'tomorrow'},
      ],
      'promises': [
        {'id': 7, 'text': 'To Ravi: Send the quote', 'due_label': 'due today', 'due_at': 1790700000000, 'owed_to': 'Ravi'},
        {'id': 8, 'text': 'Fix the tap', 'owed_to': ''},
      ],
    });
    expect(b.tomorrow.single.title, 'Dentist');
    expect(b.dates.single.person, 'Amma');
    expect(b.promises.first.owedTo, 'Ravi');
    expect(b.promises.first.dueAtMs, 1790700000000);
    expect(b.promises.last.owedTo, isNull);
    final old = TodayBrief.fromJson({'agenda': [], 'promises': []});
    expect(old.tomorrow, isEmpty);
    expect(old.dates, isEmpty);
  });
}
