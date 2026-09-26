import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/features/assistant/state/assistant_engine.dart';
import 'package:myassistant/services/automation_runner.dart';

/// A task's app is not on the phone (owner, 2026-09-26: "it's saying Zomato
/// is not present, but it should ask should I install it"): the
/// conversation is asked to put ONE question — install it, or use the app of
/// the same kind that is here — and told which tool does each.
void main() {
  const zomato = AutomationDirective(
      runId: 28, goal: 'Order biryani on Zomato', app: 'Zomato', appName: 'zomato',
      pkg: 'com.application.zomato', category: 'food');

  test('with an app of the same kind on the phone: offer it, or the install', () {
    final note = AssistantEngine.notInstalledNote(zomato, ['Swiggy']);
    expect(note, startsWith('[SYSTEM] Zomato is not installed'));
    expect(note, contains('nothing was opened'));
    expect(note, contains('ONE short question'));
    expect(note, contains('do it in Swiggy instead'));
    expect(note, contains('misheard'), reason: 'a misheard name is the usual cause');
    expect(note, contains('do_task_in_app again with app "Swiggy"'));
    expect(note, contains('open_named_app with the name "Zomato" and install true'));
  });

  test('with nothing else of its kind: offer the install', () {
    final note = AssistantEngine.notInstalledNote(zomato, const []);
    expect(note, contains('whether to install Zomato from the app store'));
    expect(note, isNot(contains('instead')));
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
