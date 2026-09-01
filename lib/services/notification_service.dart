import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../models/reminder.dart';
import 'api_service.dart';

/// Turns backend reminders into LOCAL notifications, so "remind me to
/// call amma at 5" actually rings the phone at 5 — even if the app is
/// closed. Strategy: after every sync, cancel our old schedules and
/// re-schedule every future, not-done reminder (idempotent and simple).
///
/// Android manifest additions required (android/ is generated locally):
///   <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
///   <uses-permission android:name="android.permission.SCHEDULE_EXACT_ALARM"/>
///   <receiver android:exported="false" android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationReceiver" />
///   <receiver android:exported="false" android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationBootReceiver">
///     <intent-filter>
///       <action android:name="android.intent.action.BOOT_COMPLETED"/>
///       <action android:name="android.intent.action.QUICKBOOT_POWERON"/>
///     </intent-filter>
///   </receiver>
class ReminderNotifications {
  ReminderNotifications._();
  static final ReminderNotifications instance = ReminderNotifications._();

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;

  static const _channel = AndroidNotificationDetails(
    'hari_reminders',
    'Reminders',
    channelDescription: 'Reminders you asked your assistant to set',
    importance: Importance.high,
    priority: Priority.high,
  );

  Future<void> init() async {
    if (_ready) return;
    try {
      tzdata.initializeTimeZones();
      try {
        tz.setLocalLocation(
            tz.getLocation(await FlutterTimezone.getLocalTimezone()));
      } catch (_) {
        // Unknown zone name — tz.local falls back to UTC; times still fire,
        // just scheduled via absolute UTC instants (we pass exact moments).
      }
      await _plugin.initialize(
        const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(),
        ),
      );
      await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
      _ready = true;
    } catch (_) {
      // Notifications unavailable (e.g. manifest not set up) — reminders
      // still exist on the Today screen; nothing crashes.
    }
  }

  /// Pull reminders from the backend and (re)schedule notifications.
  /// Fire-and-forget safe; call after sign-in, after every assistant
  /// answer, and whenever the Today screen edits a reminder.
  Future<List<Reminder>> sync() async {
    List<Reminder> reminders = const [];
    try {
      reminders = await ApiService.fetchReminders();
    } catch (_) {
      return reminders;
    }
    if (!_ready) await init();
    if (!_ready) return reminders;

    try {
      await _plugin.cancelAll();
      final now = DateTime.now();
      for (final r in reminders) {
        if (r.done || r.dueAt == null || r.dueAt!.isBefore(now)) continue;
        await _plugin.zonedSchedule(
          r.id, // stable id → editing a reminder replaces its notification
          'Reminder',
          r.text,
          tz.TZDateTime.from(r.dueAt!, tz.local),
          const NotificationDetails(
            android: _channel,
            iOS: DarwinNotificationDetails(),
          ),
          androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        );
      }
    } catch (_) {}
    return reminders;
  }
}
