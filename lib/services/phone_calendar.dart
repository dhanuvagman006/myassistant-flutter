import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/log.dart';

/// THE PHONE'S OWN CALENDAR — one event, with the 10-minute alert the
/// native side adds (MainActivity "hari/calendar" insertEvent). Used where
/// the user taps "Add to calendar" on something the assistant read, such
/// as an invite in a screenshot.
class PhoneCalendar {
  PhoneCalendar._();

  static const _channel = MethodChannel('hari/calendar');

  /// Asks for calendar access the first time. False when it was not
  /// allowed or the event was not written; never throws.
  static Future<bool> addEvent({
    required String title,
    required DateTime start,
    int durationMin = 60,
  }) async {
    try {
      final perm = await Permission.calendarFullAccess.request();
      if (!perm.isGranted) return false;
      return await _channel.invokeMethod<bool>('insertEvent', {
            'title': title,
            'startMs': start.millisecondsSinceEpoch,
            'durationMin': durationMin,
          }) ??
          false;
    } catch (e) {
      AppLog.add('calendar', 'insert failed: $e');
      return false;
    }
  }
}
