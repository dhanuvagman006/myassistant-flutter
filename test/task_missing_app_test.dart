import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/features/assistant/state/assistant_engine.dart';
import 'package:myassistant/services/automation_runner.dart';

/// A task's app is not on the phone (owner, 2026-09-26: "if I say order
/// something from Amazon… it should click on the install and it should
/// install the app… my assistant should be that much smart"): the
/// conversation is told it is being installed and the task carries on —
/// one line to say, no question, no tool.
void main() {
  const amazon = AutomationDirective(
      runId: 33, goal: 'order a guitar on Amazon', app: 'Amazon', appName: 'amazon',
      pkg: 'in.amazon.mShop.android.shopping', category: 'shopping');

  test('it says it is installing and carrying on — never asks', () {
    final note = AssistantEngine.installingNote(amazon);
    expect(note, startsWith('[SYSTEM] Amazon is not installed'));
    expect(note, contains('being installed from the app store right now'));
    expect(note, contains("Amazon isn't on your phone, so I'm installing it now"));
    expect(note, contains('Do not ask anything and do not call any tool'));
    expect(note, isNot(contains('open_named_app')));
    expect(note, isNot(contains('question')));
  });

  test("the server's own pick missing, another of its kind here: the task starts again there", () {
    final note = AssistantEngine.useInsteadNote(amazon, 'Flipkart');
    expect(note, contains('Flipkart (the same kind of app) is'));
    expect(note, contains('Call do_task_in_app again now with app "Flipkart"'));
    expect(note, contains('Do not ask anything first'));
  });

  test('a missing money app is left to the owner, in one line', () {
    const pay = AutomationDirective(runId: 35, goal: 'pay the bill', app: 'PhonePe');
    final note = AssistantEngine.moneyAppNote(pay);
    expect(note, contains("PhonePe isn't on your phone — money apps are yours to install"));
    expect(note, contains('Do not call any tool'));
  });

  test('the directive carries its kind of task from the server', () {
    final d = AutomationDirective.fromEvent({
      'run_id': 3, 'goal': 'order biryani', 'app': 'Zomato', 'category': 'food',
    });
    expect(d!.category, 'food');
    expect(AutomationDirective.fromEvent({'run_id': 4, 'goal': 'x'})!.category, '',
        reason: 'an older server sends none');
  });
}
