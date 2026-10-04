import 'package:flutter/foundation.dart' show ValueNotifier, visibleForTesting;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../features/shopping/shop_handoff.dart';
import '../models/momentum.dart';
import '../models/reminder.dart';
import '../core/log.dart';
import 'api_service.dart';
import 'focus_service.dart';
import 'habit_alarms.dart';

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
  // WAKE-UP reminders: the alarm stream (audible on a muted phone), max
  // importance, and a full-screen intent so a locked or sleeping phone
  // shows the alarm instead of a banner nobody sees. Reserved for
  // reminders the user explicitly asked to be woken for.
  static const _alarmChannel = AndroidNotificationDetails(
    'hari_reminders_alarm',
    'Wake-up reminders',
    channelDescription: 'Reminders you asked to be woken for',
    importance: Importance.max,
    priority: Priority.high,
    category: AndroidNotificationCategory.alarm,
    audioAttributesUsage: AudioAttributesUsage.alarm,
    fullScreenIntent: true,
  );

  // ORDINARY reminders: a normal notification on the notification stream.
  // An app that blares an alarm for "buy milk" gets uninstalled, so this
  // is the default and the loud channel is opt-in.
  static const _softChannel = AndroidNotificationDetails(
    'hari_reminders_soft',
    'Reminders',
    channelDescription: 'Everyday reminders you asked your assistant to set',
    importance: Importance.defaultImportance,
    priority: Priority.defaultPriority,
    category: AndroidNotificationCategory.reminder,
  );

  // MOMENTUM (2026-09-25). Habit reminders get their own channel, so they
  // can be quietened without silencing real reminders; the focus countdown
  // is LOW importance (it sits in the shade, it never pops or sounds), and
  // only its end rings.
  static const _habitChannel = AndroidNotificationDetails(
    'hari_habits',
    'Habit reminders',
    channelDescription: 'The daily nudge for a habit you track',
    importance: Importance.defaultImportance,
    priority: Priority.defaultPriority,
    category: AndroidNotificationCategory.reminder,
  );
  static const int focusCountdownId = 0x3F0F0C01;
  static const int focusDoneId = 0x3F0F0C02;

  /// The shopping trip's "Shopping · 1 of 7 · Next: curd" (build 124).
  static const int shoppingId = 0x3F0F0C03;
  static const String shoppingPayload = 'shopping';

  /// A reminder's own payload, "reminder:<id>" (2026-09-30): its tap opens
  /// the reminder pop-up.
  static const String reminderPayload = 'reminder:';

  /// The reminders as last fetched: the pop-up watches for the next one
  /// due while the app is open.
  final ValueNotifier<List<Reminder>> synced = ValueNotifier(const []);

  /// Where a tapped notification goes ('momentum', 'focus'). The shell sets
  /// it once it can navigate; a tap that launched the app waits for it.
  static void Function(String payload)? _onOpen;
  static String? _launchPayload;
  static set onOpen(void Function(String payload)? f) {
    _onOpen = f;
    final p = _launchPayload;
    if (f != null && p != null) {
      _launchPayload = null;
      f(p);
    }
  }

  /// A tap's destination: the notification's payload, and for a tap on one
  /// of its buttons, "payload:button" ('shopping:next').
  @visibleForTesting
  static String? destinationOf(NotificationResponse r) {
    final p = r.payload;
    if (p == null || p.isEmpty) return null;
    final action = r.actionId;
    return action == null || action.isEmpty ? p : '$p:$action';
  }

  static void _tapped(NotificationResponse r) {
    final p = destinationOf(r);
    if (p == null) return;
    route(p);
  }

  /// Opens a payload's destination now, or once the shell can navigate
  /// (a push that launched the app).
  static void route(String p) {
    final f = _onOpen;
    if (f != null) {
      f(p);
    } else {
      _launchPayload = p;
    }
  }

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
        // A tap on a habit reminder or the focus timer opens its screen.
        onDidReceiveNotificationResponse: _tapped,
      );
      try {
        final launch = await _plugin.getNotificationAppLaunchDetails();
        final r = launch?.notificationResponse;
        if (launch?.didNotificationLaunchApp == true && r != null) _tapped(r);
      } catch (_) {}
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      await android?.requestNotificationsPermission();
      // The channel FCM banners land in (see manifest meta-data): named
      // and user-tunable instead of an auto-created "Miscellaneous".
      // Both reminder channels are created up front so their names and
      // importance are what the user sees in Android's settings — and so
      // the loud one can be turned down there without losing the quiet one.
      await android?.createNotificationChannel(const AndroidNotificationChannel(
        'hari_reminders_soft',
        'Reminders',
        description: 'Everyday reminders you asked your assistant to set',
        importance: Importance.defaultImportance,
      ));
      await android?.createNotificationChannel(const AndroidNotificationChannel(
        'hari_reminders_alarm',
        'Wake-up reminders',
        description: 'Reminders you asked to be woken for — these ring like an alarm',
        importance: Importance.max,
      ));
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

  /// Show a notification RIGHT NOW on the general channel. Used for
  /// pushes that arrive while the app is in the foreground — Android
  /// hands those to the app instead of displaying them, and swallowing
  /// them made every admin/server notification invisible whenever the
  /// app was open (which is exactly when people test).
  Future<void> showNow(String title, String body, {String? payload}) async {
    if (!_ready) await init();
    if (!_ready) return;
    try {
      await _plugin.show(
        // Below the habit and focus ids, whatever the clock says.
        DateTime.now().millisecondsSinceEpoch & 0x3EFFFFFF,
        title,
        body,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'hari_default',
            'Messages & alerts',
            channelDescription:
                'Messages from your circle, call prompts and updates',
            importance: Importance.high,
            priority: Priority.high,
          ),
          iOS: DarwinNotificationDetails(),
        ),
        payload: payload,
      );
    } catch (_) {}
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
    synced.value = reminders;
    if (!_ready) await init();
    if (!_ready) return reminders;

    try {
      // A shopping trip's notification is not a reminder: it goes with the
      // rest below and is put back — unless the owner swiped it away.
      final shopTrip = await ShopHandoffRunner.instance.hasTrip();
      final shopShown = shopTrip && await shoppingShown();
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
            NotificationDetails(
              android: r.isAlarm ? _alarmChannel : _softChannel,
              iOS: const DarwinNotificationDetails(),
            ),
            androidScheduleMode: mode,
            // A tap opens the reminder's pop-up (reminder_popup.dart).
            payload: '$reminderPayload${r.id}',
          );
          scheduled++;
        } catch (e) {
          failedCount++;
          AppLog.add('remind', 'schedule failed for #${r.id}: $e');
        }
      }
      AppLog.add('remind',
          'scheduled $scheduled reminder alarm(s)${failedCount > 0 ? ", $failedCount failed" : ""} (${mode == AndroidScheduleMode.exactAllowWhileIdle ? "exact" : "inexact"})');
      // cancelAll() above also took a running focus countdown: put it back.
      await FocusService.instance.rearm();
      if (shopTrip) await ShopHandoffRunner.instance.rearm(stillShown: shopShown);
    } catch (e) {
      AppLog.add('remind', 'sync failed: $e');
    }
    return reminders;
  }

  Future<AndroidScheduleMode> _scheduleMode() async {
    try {
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      if (android != null && await android.canScheduleExactNotifications() != true) {
        return AndroidScheduleMode.inexactAllowWhileIdle;
      }
    } catch (_) {}
    return AndroidScheduleMode.exactAllowWhileIdle;
  }

  /// Re-arms every habit reminder after the habits (or today's ticks)
  /// changed, without touching reminders or the focus timer.
  Future<void> armHabits(List<MomentumHabit> habits) async {
    if (!_ready) await init();
    if (!_ready) return;
    try {
      for (final p in await _plugin.pendingNotificationRequests()) {
        if (HabitAlarms.isHabitAlarm(p.id)) await _plugin.cancel(p.id);
      }
      await _armHabits(habits, await _scheduleMode());
    } catch (e) {
      AppLog.add('habit', 'arm failed: $e');
    }
  }

  Future<void> _armHabits(List<MomentumHabit> habits, AndroidScheduleMode mode) async {
    var armed = 0;
    for (final a in HabitAlarms.plan(habits, DateTime.now())) {
      try {
        await _plugin.zonedSchedule(
          a.id,
          a.title,
          a.body,
          tz.TZDateTime.from(a.at, tz.local),
          const NotificationDetails(android: _habitChannel, iOS: DarwinNotificationDetails()),
          androidScheduleMode: mode,
          payload: 'momentum',
        );
        armed++;
      } catch (e) {
        AppLog.add('habit', 'schedule failed for ${a.id}: $e');
      }
    }
    if (armed > 0) AppLog.add('habit', 'armed $armed habit reminder(s)');
  }

  static String _clock(DateTime t) {
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    return '$h:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'am' : 'pm'}';
  }

  /// The focus countdown in the notification shade (a count-down
  /// chronometer the system keeps ticking, so the app needs no timer of
  /// its own) and the "Focus done — take 5?" alert at [endsAt].
  Future<void> showFocus({required DateTime endsAt, required String label, required bool rest}) async {
    if (!_ready) await init();
    if (!_ready) return;
    final left = endsAt.difference(DateTime.now());
    if (left <= Duration.zero) return;
    try {
      await _plugin.show(
        focusCountdownId,
        rest ? 'Break' : (label.isEmpty ? 'Focusing' : 'Focusing on $label'),
        'Ends at ${_clock(endsAt)}',
        NotificationDetails(
          android: AndroidNotificationDetails(
            'hari_focus',
            'Focus timer',
            channelDescription: 'The countdown while a focus session runs',
            importance: Importance.low,
            priority: Priority.low,
            ongoing: true,
            autoCancel: false,
            onlyAlertOnce: true,
            silent: true,
            showWhen: true,
            when: endsAt.millisecondsSinceEpoch,
            usesChronometer: true,
            chronometerCountDown: true,
            timeoutAfter: left.inMilliseconds,
            category: AndroidNotificationCategory.stopwatch,
          ),
        ),
        payload: 'focus',
      );
      await _plugin.zonedSchedule(
        focusDoneId,
        rest ? 'Break over' : 'Focus done — take 5?',
        rest
            ? 'Ready for another focus?'
            : label.isEmpty
                ? 'Nice work. Stretch, breathe, then back to it.'
                : 'Nice work on $label. Stretch, breathe, then back to it.',
        tz.TZDateTime.from(endsAt, tz.local),
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'hari_focus_done',
            'Focus finished',
            channelDescription: 'When a focus session or a break ends',
            importance: Importance.high,
            priority: Priority.high,
            category: AndroidNotificationCategory.reminder,
          ),
          iOS: DarwinNotificationDetails(),
        ),
        androidScheduleMode: await _scheduleMode(),
        payload: 'focus',
      );
    } catch (e) {
      AppLog.add('focus', 'notification failed: $e');
    }
  }

  /// Takes the countdown away, and the end alert too unless [keepAlert].
  Future<void> cancelFocus({bool keepAlert = false}) async {
    try {
      await _plugin.cancel(focusCountdownId);
      if (!keepAlert) await _plugin.cancel(focusDoneId);
    } catch (_) {}
  }

  /// THE SHOPPING TRIP (build 124): "Shopping · 1 of 7", "Next: curd", with
  /// Next and Done. Quiet (it sits in the shade while they shop, like the
  /// focus countdown). Both buttons bring the app to the front first:
  /// Android lets an app open another only while it is on screen, so Next
  /// opens the following thing from there.
  Future<void> showShopping(String title, String body, {required bool hasNext}) async {
    if (!_ready) await init();
    if (!_ready) return;
    try {
      await _plugin.show(
        shoppingId,
        title,
        body,
        NotificationDetails(
          android: AndroidNotificationDetails(
            'hari_shopping',
            'Shopping',
            channelDescription: 'The next thing on your list while you shop',
            importance: Importance.low,
            priority: Priority.low,
            ongoing: true,
            autoCancel: false,
            onlyAlertOnce: true,
            silent: true,
            showWhen: false,
            category: AndroidNotificationCategory.status,
            styleInformation: BigTextStyleInformation(body),
            actions: [
              if (hasNext)
                const AndroidNotificationAction('next', 'Next',
                    showsUserInterface: true, cancelNotification: false),
              const AndroidNotificationAction('done', 'Done', showsUserInterface: true),
            ],
          ),
        ),
        payload: shoppingPayload,
      );
    } catch (e) {
      AppLog.add('shop', 'notification failed: $e');
    }
  }

  Future<void> cancelShopping() async {
    try {
      await _plugin.cancel(shoppingId);
    } catch (e) {
      AppLog.add('shop', 'could not take the notification away: $e');
    }
  }

  /// Is the trip's notification still in the shade? When the phone cannot
  /// say, it is assumed to be (a trip is never ended on a guess).
  Future<bool> shoppingShown() async {
    try {
      final active = await _plugin.getActiveNotifications();
      return active.any((n) => n.id == shoppingId);
    } catch (_) {
      return true;
    }
  }
}
