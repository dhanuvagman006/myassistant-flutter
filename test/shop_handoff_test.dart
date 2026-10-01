// THE SHOPPING TRIP (build 124): "Shop these" / "order these" opens the
// first thing in its app (the browser when the app is not installed) and
// keeps a notification — "Shopping · 1 of 3 · Next: Curd" — whose Next
// opens the following one, crossing from one app to the next; Done ends
// it. Never a payment app. Kept across a restart; put back after the
// reminders' re-sync unless the owner swiped it away.
import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/features/shopping/shop_handoff.dart';
import 'package:myassistant/features/shopping/shopping_list_screen.dart';
import 'package:myassistant/services/notification_service.dart';
import 'package:myassistant/shell/home_shell.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/fake_shopping.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final runner = ShopHandoffRunner.instance;
  late FakeShopPorts ports;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    ports = FakeShopPorts();
    ShopHandoffRunner.ports = ports;
    ShopHandoffRunner.clock = DateTime.now;
    await runner.reset();
  });

  ShopHandoff trip() => ShopHandoff.fromJson(handoffJson())!;

  group('the hand-off', () {
    test("reads the server's shape; anything else is not one", () {
      final h = trip();
      expect(h.groups.map((g) => g.label), ['Blinkit', 'Myntra']);
      expect(h.total, 3);
      expect(h.groups.last.items.single.details, 'M, blue floral');
      expect(ShopHandoff.fromJson({'type': 'open_url', 'url': 'https://x.in'}), isNull);
      expect(ShopHandoff.fromJson({'type': 'shop_handoff', 'groups': []}), isNull);
      expect(
          ShopHandoff.fromJson({
            'type': 'shop_handoff',
            'groups': [
              {'app': 'amazon', 'label': 'Amazon', 'pkg': '', 'items': [{'id': 1, 'name': 'Charger'}]}
            ],
          }),
          isNull,
          reason: 'a line with no link opens nothing');
    });
  });

  group('the trip', () {
    test('the first thing opens in its app; the notification says what is next', () async {
      final r = await runner.start(trip());
      expect(r.opened, isTrue);
      expect(r.inApp, isTrue);
      expect(r.position, 1);
      expect(r.total, 3);
      expect(ports.opened, ['com.grofers.customerapp https://blinkit.com/s/?q=onion']);
      expect(ports.last!.title, 'Shopping · 1 of 3');
      expect(ports.last!.body, 'Next: Curd');
      expect(ports.last!.hasNext, isTrue);
      expect(await runner.hasTrip(), isTrue);
    });

    test('an app that is not installed: the browser', () async {
      ports.installed = {};
      final r = await runner.start(trip());
      expect(r.opened, isTrue);
      expect(r.inApp, isFalse);
      expect(ports.opened, ['browser https://blinkit.com/s/?q=onion']);
    });

    test('Next walks the list and crosses to the next app; the last has only Done', () async {
      await runner.start(trip());
      final two = await runner.next();
      expect(two.opened, isTrue);
      expect(ports.opened.last, 'com.grofers.customerapp https://blinkit.com/s/?q=curd');
      expect(ports.last!.title, 'Shopping · 2 of 3');
      expect(ports.last!.body, 'Next: Kurti on Myntra', reason: 'the next one is in another app');
      final three = await runner.next();
      expect(three.opened, isTrue);
      expect(ports.opened.last, 'com.myntra.android https://www.myntra.com/kurtas/biba/123');
      expect(ports.last!.title, 'Shopping · 3 of 3');
      expect(ports.last!.hasNext, isFalse);
      expect(ports.last!.body, contains("That's the last one"));
      final beyond = await runner.next();
      expect(beyond.opened, isFalse);
      expect(beyond.finished, isTrue);
      expect(ports.opened.length, 3, reason: 'nothing more opened');
    });

    test('Done ends the trip and takes the notification away', () async {
      await runner.start(trip());
      await runner.end();
      expect(ports.cleared, greaterThanOrEqualTo(1));
      expect(ports.shown, isFalse);
      expect(await runner.hasTrip(), isFalse);
      final r = await runner.next();
      expect(r.opened, isFalse);
      expect(r.step, isNull, reason: 'no trip: nothing to open');
    });

    test('nothing could open: said, and no trip is kept', () async {
      ports.installed = {};
      ports.browserWorks = false;
      final r = await runner.start(trip());
      expect(r.opened, isFalse);
      expect(r.step?.item.name, 'Onion');
      expect(ports.progress, isEmpty, reason: 'no notification for a trip that never began');
      expect(await runner.hasTrip(), isFalse);
    });

    test('kept across a restart: Next still opens the next thing', () async {
      await runner.start(trip());
      runner.forgetInMemory(); // the app was closed; a tap on Next starts it
      final r = await runner.next();
      expect(r.opened, isTrue);
      expect(r.step!.item.name, 'Curd');
      expect(ports.last!.title, 'Shopping · 2 of 3');
    });

    test('a trip nobody touched for half a day is over', () async {
      final start = DateTime(2026, 9, 29, 10);
      ShopHandoffRunner.clock = () => start;
      await runner.start(trip());
      ShopHandoffRunner.clock = () => start.add(const Duration(hours: 13));
      final r = await runner.next();
      expect(r.opened, isFalse);
      expect(await runner.hasTrip(), isFalse);
    });

    test("put back after the reminders' re-sync — unless it was swiped away", () async {
      await runner.start(trip());
      expect(ports.progress.length, 1);
      await runner.rearm(stillShown: true);
      expect(ports.progress.length, 2);
      expect(ports.last!.title, 'Shopping · 1 of 3');
      await runner.rearm(stillShown: false);
      expect(await runner.hasTrip(), isFalse, reason: 'swiped away means done');
      expect(ports.shown, isFalse);
    });
  });

  group('never a payment app', () {
    test('a payment app is never the target; a payment or non-https link is left out', () async {
      final h = ShopHandoff.fromJson({
        'type': 'shop_handoff',
        'groups': [
          {
            'app': 'x',
            'label': 'PhonePe',
            'pkg': 'com.phonepe.app',
            'items': [
              {'id': 1, 'name': 'Pay link', 'url': 'upi://pay?pa=x@y&am=100'},
              {'id': 2, 'name': 'Wallet page', 'url': 'https://paytm.com/offer'},
              {'id': 3, 'name': 'Soap', 'url': 'https://www.amazon.in/s?k=soap'},
            ],
          },
        ],
      })!;
      ports.installed = {'com.phonepe.app'};
      final r = await runner.start(h);
      expect(r.opened, isTrue);
      expect(r.skipped, 2);
      expect(ports.opened, ['browser https://www.amazon.in/s?k=soap'],
          reason: 'not opened in the payment app, even though it is installed');
      expect(ports.last!.total, 1);
    });

    test('only unsafe links: nothing opens, nothing is kept', () async {
      final h = ShopHandoff.fromJson({
        'type': 'shop_handoff',
        'groups': [
          {
            'app': 'x',
            'label': 'X',
            'pkg': '',
            'items': [
              {'id': 1, 'name': 'Pay', 'url': 'upi://pay?pa=x@y'},
              {'id': 2, 'name': 'Http', 'url': 'http://shop.example/x'},
            ],
          },
        ],
      })!;
      final r = await runner.start(h);
      expect(r.opened, isFalse);
      expect(r.step, isNull);
      expect(r.skipped, 2);
      expect(ports.opened, isEmpty);
    });

    test('the link is opened by the app itself, through an intent', () {
      expect(shopIntentUri('https://www.myntra.com/kurtas/biba/123?x=1', 'com.myntra.android'),
          'intent://www.myntra.com/kurtas/biba/123?x=1#Intent;scheme=https;package=com.myntra.android;'
          'action=android.intent.action.VIEW;end');
      expect(shopIntentUri('https://www.myntra.com/x', 'com.google.android.apps.nbu.paisa.user'), isNull);
      expect(shopIntentUri('https://www.myntra.com/x', 'com.myassistant.myassistant'), isNull);
      expect(shopIntentUri('http://www.myntra.com/x', 'com.myntra.android'), isNull);
      expect(shopIntentUri('https://www.myntra.com/x', 'not a package'), isNull);
      expect(ShopSafety.safeUrl('https://pay.google.com/x'), isFalse);
      expect(ShopSafety.safeUrl('https://blinkit.com/s/?q=curd'), isTrue);
    });
  });

  group('the notification', () {
    test('its buttons reach the trip: "shopping:next", "shopping:done"', () {
      expect(
          ReminderNotifications.destinationOf(const NotificationResponse(
              notificationResponseType: NotificationResponseType.selectedNotificationAction,
              actionId: 'next',
              payload: 'shopping')),
          'shopping:next');
      expect(
          ReminderNotifications.destinationOf(const NotificationResponse(
              notificationResponseType: NotificationResponseType.selectedNotification,
              payload: 'shopping')),
          'shopping');
      expect(
          ReminderNotifications.destinationOf(const NotificationResponse(
              notificationResponseType: NotificationResponseType.selectedNotification,
              payload: 'momentum')),
          'momentum',
          reason: 'the other notifications are unchanged');
    });

    test('a tap on Next goes through the shell to the trip', () async {
      await runner.start(trip());
      await openNotificationPayload('shopping:next');
      expect(ports.opened.last, 'com.grofers.customerapp https://blinkit.com/s/?q=curd');
      await ShoppingNav.fromNotification('shopping:next');
      expect(ports.opened.last, 'com.myntra.android https://www.myntra.com/kurtas/biba/123');
    });

    test('the trip notification is quiet, ongoing, and its buttons open the app', () {
      final src = File('lib/services/notification_service.dart')
          .readAsStringSync()
          .replaceAll('\r\n', '\n');
      final shop = src.substring(src.indexOf('Future<void> showShopping('));
      expect(shop, contains('ongoing: true'));
      expect(shop, contains('importance: Importance.low'));
      expect(shop,
          contains(RegExp(r"AndroidNotificationAction\('next', 'Next',\s+showsUserInterface: true")),
          reason: 'Android lets an app open another only while it is on screen');
      expect(shop, contains("AndroidNotificationAction('done', 'Done', showsUserInterface: true)"));
      // The reminders' re-sync (cancelAll) puts the trip back.
      final sync = src.substring(src.indexOf('Future<List<Reminder>> sync()'));
      expect(sync.indexOf('shoppingShown()'), lessThan(sync.indexOf('cancelAll()')));
      expect(sync, contains('ShopHandoffRunner.instance.rearm(stillShown: shopShown)'));
    });
  });
}
