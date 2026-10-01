import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/services/call_history.dart';
import 'package:myassistant/services/missed_calls_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Calls (owner, 2026-09-24): "the calls should be connected — it should
/// report when we have any missed calls, or any info if user asks about
/// calls". The phone reads its own call history and tells the assistant
/// ONE short line; missed calls also get a Home card and one mention.

final now = DateTime(2026, 9, 24, 18, 0);

CallEntry call(String type, DateTime at,
        {String name = '', String number = '', int dur = 0}) =>
    CallEntry(
        name: name, number: number, type: type, at: at, durationSec: dur);

final ravi1 = call('missed', DateTime(2026, 9, 24, 15, 10),
    name: 'Ravi Kumar', number: '+91 98765 43210');
final ravi0 = call('missed', DateTime(2026, 9, 24, 14, 0),
    name: 'Ravi Kumar', number: '09876543210');
final stranger = call('missed', DateTime(2026, 9, 24, 17, 2),
    number: '+919876545678');

void main() {
  group('the one line for the assistant', () {
    test('missed calls: counts, names, local times, offer to call back', () {
      final line = CallHistory.summaryLine(
        calls: [stranger, ravi1, ravi0], // newest first, as the phone gives
        filter: 'missed',
        sinceHours: 24,
        now: now,
      );
      expect(
          line,
          '[SYSTEM] Missed calls in the last 24 hours: '
          '+91 98765 45678 (not in contacts) at 5:02 pm, Ravi Kumar at 3:10 pm '
          '(2 times). Say this in one or two short sentences and offer to call '
          'back. A number marked (not in contacts) is not saved on their phone: '
          "say you can't find it in their contacts instead of reading its "
          'digits, unless they ask for the number.');
    });

    test('at most five people; the rest are counted, never dumped', () {
      final calls = [
        for (var i = 0; i < 9; i++)
          call('missed', now.subtract(Duration(minutes: 10 * (i + 1))),
              name: 'Person $i', number: '98450000${10 + i}'),
      ];
      final line = CallHistory.summaryLine(
          calls: calls, filter: 'missed', sinceHours: 24, now: now);
      expect('Person'.allMatches(line).length, 5);
      expect(line, contains(', and 4 more calls.'));
    });

    test('a person, a longer span, yesterday and a date', () {
      final line = CallHistory.summaryLine(
        calls: [
          call('incoming', DateTime(2026, 9, 23, 21, 5),
              name: 'Mom', number: '9845012345', dur: 250),
          call('missed', DateTime(2026, 9, 20, 9, 30),
              name: 'Mom', number: '9845012345'),
        ],
        filter: 'incoming',
        person: 'mom',
        sinceHours: 720,
        now: now,
      );
      expect(
          line,
          '[SYSTEM] Incoming calls from mom in the last 30 days: '
          'Mom yesterday at 9:05 pm (4 min), Mom on 20 Sep at 9:30 am '
          '(missed). Say this in one or two short sentences and offer to '
          'call back.');
    });

    test('all calls say their kind', () {
      final line = CallHistory.summaryLine(
        calls: [
          call('outgoing', DateTime(2026, 9, 24, 11, 0),
              name: 'Ravi Kumar', number: '9876543210'),
          call('rejected', DateTime(2026, 9, 24, 10, 0), number: ''),
        ],
        filter: 'all',
        sinceHours: 12,
        now: now,
      );
      expect(
          line,
          '[SYSTEM] Calls in the last 12 hours: Ravi Kumar at 11:00 am '
          '(outgoing), a private number at 10:00 am (rejected). Say this in '
          'one or two short sentences.');
    });

    test('nothing found is said plainly, never guessed', () {
      final line = CallHistory.summaryLine(
          calls: const [],
          filter: 'missed',
          person: 'Ravi',
          sinceHours: 24,
          now: now);
      expect(
          line,
          "[SYSTEM] The phone's call history shows no missed calls from Ravi "
          'in the last 24 hours. Say that in one short sentence — do not '
          'guess any calls.');
    });
  });

  group('wording helpers', () {
    test('times are the owner\'s local clock', () {
      expect(CallHistory.clock(DateTime(2026, 9, 24, 0, 5)), '12:05 am');
      expect(CallHistory.clock(DateTime(2026, 9, 24, 12, 0)), '12:00 pm');
      expect(CallHistory.when(DateTime(2026, 9, 24, 15, 10), now),
          'at 3:10 pm');
      expect(CallHistory.when(DateTime(2026, 9, 23, 23, 59), now),
          'yesterday at 11:59 pm');
      expect(CallHistory.when(DateTime(2026, 9, 2, 8, 0), now),
          'on 2 Sep at 8:00 am');
    });

    test('numbers and names', () {
      expect(CallHistory.formatNumber('+919876545678'), '+91 98765 45678');
      expect(CallHistory.formatNumber('9876545678'), '98765 45678');
      expect(CallHistory.formatNumber('121'), '121');
      expect(CallHistory.shortName('Ravi Kumar'), 'Ravi');
      expect(CallHistory.shortName('Dr Shah Mehta'), 'Dr Shah');
      expect(stranger.shortLabel, 'a number ending 5678');
      expect(ravi1.caller, ravi0.caller, reason: 'same last ten digits');
    });

    test('the greeting mention', () {
      expect(
          CallHistory.greetingMention([ravi1, ravi0],
              honorific: 'Sir', hello: true, now: now),
          'Hello Sir! You missed 2 calls — Ravi at 3:10 pm.');
      expect(
          CallHistory.greetingMention([ravi1],
              honorific: "Ma'am", hello: false, now: now),
          'You missed a call — Ravi at 3:10 pm.',
          reason: 'greeted a moment ago: the title is not said twice');
      final many = [
        stranger,
        ravi1,
        call('missed', DateTime(2026, 9, 24, 9, 0),
            name: 'Anita Rao', number: '9900112233'),
      ];
      expect(
          CallHistory.greetingMention(many,
              honorific: 'Sir', hello: true, now: now),
          'Hello Sir! You missed 3 calls — Ravi at 3:10 pm, Anita at 9:00 am '
          "and 1 from a number I can't find in your contacts.");
    });

    test('a number not in the contacts is never read out as digits (2026-09-26)',
        () {
      expect(
          CallHistory.greetingMention([stranger],
              honorific: 'Sir', hello: true, now: now),
          "Hello Sir! You missed a call at 5:02 pm. I can't find that number "
          'in your contacts.');
      final again = call('missed', DateTime(2026, 9, 24, 17, 20),
          number: '+91 98765 45678');
      final other = call('missed', DateTime(2026, 9, 24, 17, 40),
          number: '9811122233');
      expect(
          CallHistory.greetingMention([again, stranger],
              honorific: 'Sir', hello: false, now: now),
          "You missed 2 calls, the last at 5:20 pm. I can't find that number "
          'in your contacts.',
          reason: 'the same number twice is one number');
      expect(
          CallHistory.greetingMention([other, stranger],
              honorific: 'Sir', hello: false, now: now),
          "You missed 2 calls, the last at 5:40 pm. I can't find those "
          'numbers in your contacts.');
      for (final said in [
        CallHistory.greetingMention([stranger, ravi1],
            honorific: 'Sir', hello: true, now: now),
        CallHistory.greetingMention([other, again],
            honorific: 'Sir', hello: true, now: now),
      ]) {
        expect(said, isNot(contains('ending')));
        expect(said, isNot(contains('5678')));
      }
    });

    test("the assistant's line marks a number that is not saved, and says how to say it",
        () {
      final line = CallHistory.summaryLine(
          calls: [stranger, ravi1], filter: 'missed', sinceHours: 24, now: now);
      expect(line, contains('+91 98765 45678 (not in contacts) at 5:02 pm'));
      expect(line, contains("say you can't find it in their contacts instead of "
          'reading its digits'));
      final named = CallHistory.summaryLine(
          calls: [ravi1], filter: 'missed', sinceHours: 24, now: now);
      expect(named, isNot(contains('not in contacts')));
    });
  });

  group('missed calls since the last look', () {
    final checked = DateTime(2026, 9, 24, 16, 0);

    List<CallEntry> merge(List<CallEntry> pending, List<CallEntry> recent,
            {int dismissed = 0}) =>
        MissedCallsService.merge(
          pending: pending,
          recent: recent,
          checkedAt: checked,
          dismissedUpTo: dismissed,
          now: now,
        );

    test('new missed calls join the card, newest first', () {
      final out = merge(const [], [stranger, ravi1]);
      // Ravi at 15:10 is before the last look (16:00): already seen.
      expect(out, [stranger]);
    });

    test('a call logged late (it rang across the last look) still counts',
        () {
      final rang = call('missed', DateTime(2026, 9, 24, 15, 59),
          name: 'Anita', number: '9900112233');
      expect(merge(const [], [rang]), [rang]);
    });

    test('calling back, or picking up a later call, clears the caller', () {
      final back = call('outgoing', DateTime(2026, 9, 24, 17, 30),
          number: '9876545678');
      expect(merge([stranger], [back, stranger]), isEmpty);
      final answered = call('incoming', DateTime(2026, 9, 24, 17, 40),
          number: '+91 98765 45678', dur: 30);
      expect(merge([stranger], [answered, stranger]), isEmpty);
    });

    test('dismissed and duplicate calls never come back; old ones go', () {
      expect(
          merge(const [], [stranger],
              dismissed: stranger.at.millisecondsSinceEpoch),
          isEmpty);
      expect(merge([stranger], [stranger]), [stranger]);
      final old = call('missed', now.subtract(const Duration(hours: 50)),
          number: '9811111111');
      expect(merge([old], const []), isEmpty);
    });

    test('mentioned once, then never again', () {
      SharedPreferences.setMockInitialValues({});
      final svc = MissedCallsService.instance..debugReset();
      svc.pending.value = [ravi1, ravi0];
      expect(svc.takeMention(honorific: 'Sir', hello: true, now: now),
          'Hello Sir! You missed 2 calls — Ravi at 3:10 pm.');
      expect(svc.takeMention(honorific: 'Sir', hello: true, now: now), isNull);
      // A new one: only it is mentioned.
      svc.pending.value = [stranger, ravi1, ravi0];
      expect(svc.takeMention(honorific: 'Sir', hello: false, now: now),
          "You missed a call at 5:02 pm. I can't find that number in your contacts.");
      // Heard in an answer to "any missed calls?" counts as mentioned.
      final later = call('missed', DateTime(2026, 9, 24, 17, 50),
          name: 'Anita', number: '9900112233');
      svc.pending.value = [later, ...svc.pending.value];
      svc.markMentioned([later]);
      expect(svc.hasUnmentioned, isFalse);
      svc.debugReset();
    });
  });
  // The Missed calls card became a card in Home's feed (2026-09-29):
  // test/home_feed_test.dart and test/home_cards_test.dart.
}
