import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../models/reminder.dart';
import '../core/log.dart';
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

  // v2 channel: reminders play on the ALARM stream, like a clock app —
  // the first live test fired silently because the phone was on mute and
  // the old channel used the notification stream, which mute silences.
  // (A new id is required: Android freezes a channel's audio attributes
  // at creation, so the old 'hari_reminders' can never be upgraded.)
  static const _channel = AndroidNotificationDetails(
    'hari_reminders_alarm',
    'Reminders',
    channelDescription: 'Reminders you asked your assistant to set',
    importance: Importance.max,
    priority: Priority.high,
    category: AndroidNotificationCategory.alarm,
    audioAttributesUsage: AudioAttributesUsage.alarm,
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
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      await android?.requestNotificationsPermission();
      // The channel FCM banners land in (see manifest meta-data): named
      // and user-tunable instead of an auto-created "Miscellaneous".
      await android?.createNotificationChannel(const AndroidNotificationChannel(
        'hari_default',
        'Messages & alerts',
        description: 'Messages from your circle, call prompts and updates',
        importance: Importance.high,
      ));
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
      // Android 14+ never auto-grants exact alarms; scheduling in exact
      // mode without the grant THROWS. Detect once and fall back to
      // inexact (fires within a minute or so — late beats never).
      var mode = AndroidScheduleMode.exactAllowWhileIdle;
      try {
        final android = _plugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
        if (android != null &&
            await android.canScheduleExactNotifications() != true) {
          mode = AndroidScheduleMode.inexactAllowWhileIdle;
        }
      } catch (_) {}
      final now = DateTime.now();
      var scheduled = 0, failedCount = 0;
      for (final r in reminders) {
        if (r.done || r.dueAt == null || r.dueAt!.isBefore(now)) continue;
        // PER-REMINDER isolation: one bad row must not abort the loop —
        // the old whole-loop try ran after cancelAll(), so a single throw
        // silently destroyed every scheduled reminder.
        try {
          await _plugin.zonedSchedule(
            r.id, // stable id → editing a reminder replaces its notification
            'Reminder',
            r.text,
            tz.TZDateTime.from(r.dueAt!, tz.local),
            const NotificationDetails(
              android: _channel,
              iOS: DarwinNotificationDetails(),
            ),
            androidScheduleMode: mode,
          );
          scheduled++;
        } catch (e) {
          failedCount++;
          AppLog.add('remind', 'schedule failed for #${r.id}: $e');
        }
      }
      AppLog.add('remind',
          'scheduled $scheduled reminder alarm(s)${failedCount > 0 ? ", $failedCount failed" : ""} (${mode == AndroidScheduleMode.exactAllowWhileIdle ? "exact" : "inexact"})');
    } catch (e) {
      AppLog.add('remind', 'sync failed: $e');
    }
    return reminders;
  }
}
