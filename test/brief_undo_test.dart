// A swipe on Home can be undone, and the card comes back where it was.
import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/models/brief.dart';
import 'package:myassistant/services/brief_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('an undone reminder returns to its own place', () {
    const a = AgendaItem(kind: 'reminder', id: 1, title: 'Call the bank');
    const b = AgendaItem(kind: 'reminder', id: 2, title: 'Pay rent');
    const c = AgendaItem(kind: 'reminder', id: 3, title: 'Gym');
    final svc = BriefService.instance
      ..brief = TodayBrief(agenda: [a, b, c]);
    final at = svc.hideReminder(b);
    expect(svc.brief.agenda, [a, c]);
    svc.restoreReminder(b, at);
    expect(svc.brief.agenda, [a, b, c]);
    svc.restoreReminder(b, at); // a second Undo must not duplicate it
    expect(svc.brief.agenda, [a, b, c]);
  });

  test('an undone promise returns to its own place', () {
    const p = PromiseItem(id: 7, text: 'Send Ravi the proposal');
    const q = PromiseItem(id: 8, text: 'Review the lease');
    final svc = BriefService.instance
      ..brief = TodayBrief(promises: [p, q]);
    final at = svc.hidePromise(p);
    expect(svc.brief.promises, [q]);
    svc.restorePromise(p, at);
    expect(svc.brief.promises, [p, q]);
  });
}
