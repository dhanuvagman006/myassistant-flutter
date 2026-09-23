import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/screens/phone/call_notes_screen.dart';
import 'package:myassistant/services/call_recording_watcher.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> call(int id, DateTime at, String status,
        {String name = 'Amma'}) =>
    {
      'id': id,
      'peer_name': name,
      'peer_number': '',
      'started_at': at.millisecondsSinceEpoch,
      'status': status,
      'summary': '',
    };

void main() {
  final now = DateTime(2026, 9, 23, 17, 0);

  group('call list', () {
    test('groups by day, newest first', () {
      final groups = groupCalls([
        call(1, DateTime(2026, 9, 21, 22, 21), 'done'),
        call(2, DateTime(2026, 9, 23, 16, 8), 'done', name: 'Vaishak'),
        call(3, DateTime(2026, 9, 22, 9, 0), 'failed', name: 'Manish'),
      ], now);
      expect(groups.map((g) => g.label),
          ['Today', 'Yesterday', 'Mon, 21 Sep']);
      expect(groups.first.calls.single['id'], 2);
    });

    test('the same recording uploaded twice shows once — the analysed copy',
        () {
      final at = DateTime(2026, 9, 20, 18, 39);
      final groups = groupCalls([
        call(57, at, 'failed'),
        call(58, at, 'done'),
        call(59, at, 'duplicate'),
      ], now);
      final all = groups.expand((g) => g.calls).toList();
      expect(all, hasLength(1));
      expect(all.single['id'], 58);
    });

    test('times read like a phone', () {
      expect(clockLabel(DateTime(2026, 9, 23, 16, 8)), '4:08 pm');
      expect(clockLabel(DateTime(2026, 9, 23, 0, 5)), '12:05 am');
    });
  });

  group('which recordings the watcher may send', () {
    test('a fresh install never reaches back past its first scan', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final consentAt =
          now.subtract(const Duration(days: 6)).millisecondsSinceEpoch;
      final cut = await CallRecordingWatcher.recordingCutoff(
          prefs, consentAt, now);
      expect(cut, now.millisecondsSinceEpoch,
          reason: 'recordings made before this install are not re-sent');
    });

    test('an existing install still ignores anything over a day old',
        () async {
      final firstScan = now.subtract(const Duration(days: 5));
      SharedPreferences.setMockInitialValues(
          {'call_recordings_since_v1': firstScan.millisecondsSinceEpoch});
      final prefs = await SharedPreferences.getInstance();
      final cut = await CallRecordingWatcher.recordingCutoff(prefs, 1, now);
      expect(cut,
          now.subtract(const Duration(hours: 24)).millisecondsSinceEpoch);
    });

    test('nothing from before consent, however recent', () async {
      SharedPreferences.setMockInitialValues({
        'call_recordings_since_v1':
            now.subtract(const Duration(days: 2)).millisecondsSinceEpoch
      });
      final prefs = await SharedPreferences.getInstance();
      final consentAt =
          now.subtract(const Duration(hours: 2)).millisecondsSinceEpoch;
      expect(await CallRecordingWatcher.recordingCutoff(prefs, consentAt, now),
          consentAt);
    });
  });
}
