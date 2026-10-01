// THE SHOPPING LIST SCREEN (build 124): every state (a slow load's
// skeleton, empty, offline, offline with the saved list, filled), tick with
// its moment of grace, swipe-to-remove with Undo, hold-to-edit, quick add,
// Clear all behind a question, Share list, and "Shop these" with its one
// question about the grocery app — with the owner's targets and words for
// TalkBack.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/features/shopping/shop_handoff.dart';
import 'package:myassistant/features/shopping/shopping_list_screen.dart';
import 'package:myassistant/features/shopping/shopping_service.dart';
import 'package:myassistant/services/app_feedback.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/fake_shopping.dart';

void main() {
  late FakeShoppingServer server;
  late FakeShopPorts ports;
  late List<String> shared;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    AppFeedback.resetForTest();
    server = FakeShoppingServer();
    ShoppingService.transport = server.call;
    await ShoppingService.instance.reset();
    ports = FakeShopPorts();
    ShopHandoffRunner.ports = ports;
    await ShopHandoffRunner.instance.reset();
    shared = [];
    ShoppingListScreen.share = (t) async => shared.add(t);
  });
  tearDown(AppFeedback.resetForTest);

  Future<void> open(WidgetTester t, {String? category, bool settle = true}) async {
    t.view.devicePixelRatio = 2.625;
    t.view.physicalSize = const Size(1080, 2340);
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      scaffoldMessengerKey: AppFeedback.messengerKey,
      navigatorObservers: [AppFeedback.observer],
      home: ShoppingListScreen(category: category),
    ));
    if (settle) {
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
    }
  }

  Future<void> close(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 7));
  }

  group('states', () {
    testWidgets('a slow first load: a skeleton after a moment, never a flash', (t) async {
      final semantics = t.ensureSemantics();
      server.gate = Completer<void>();
      await open(t, settle: false);
      await t.pump(const Duration(milliseconds: 100));
      expect(find.bySemanticsLabel('Loading your shopping list'), findsNothing,
          reason: 'a fast load shows nothing in between');
      await t.pump(const Duration(milliseconds: 400));
      await t.pump(const Duration(milliseconds: 300)); // its fade in
      expect(find.bySemanticsLabel('Loading your shopping list'), findsOneWidget);
      server.gate!.complete();
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(find.text('Onion'), findsOneWidget);
      semantics.dispose();
      await close(t);
    });

    testWidgets('empty: says how to add, by voice or typing', (t) async {
      server.items = [];
      await open(t);
      expect(find.text('Nothing to buy yet'), findsOneWidget);
      expect(find.textContaining('add milk to my shopping list'), findsOneWidget);
      expect(find.byKey(const Key('shop_these')), findsNothing, reason: 'nothing to shop for');
      await close(t);
    });

    testWidgets('offline with nothing saved: said plainly, with Try again', (t) async {
      server.override = (m, p, b) => const ShoppingReply(0, null);
      await open(t);
      expect(find.text("Couldn't load your list"), findsOneWidget);
      server.override = null;
      await t.tap(find.descendant(
          of: find.byKey(const Key('shopping_error')), matching: find.text('Try again')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(find.text('Onion'), findsOneWidget);
      await close(t);
    });

    testWidgets('offline with a saved list: the list, and a note that it is the last one', (t) async {
      SharedPreferences.setMockInitialValues({
        ShoppingService.cacheKey: jsonEncode({'items': sampleItems(), 'categories': categoriesJson}),
      });
      server.override = (m, p, b) => const ShoppingReply(0, null);
      await open(t);
      expect(find.text('Onion'), findsOneWidget);
      expect(find.textContaining('last saved list'), findsOneWidget);
      await close(t);
    });

    testWidgets("filled: grouped by kind in the server's words; amount, details, where from",
        (t) async {
      await open(t);
      expect(find.text('VEGETABLES & FRUIT'), findsOneWidget);
      expect(find.text('DAIRY & EGGS'), findsOneWidget);
      expect(find.text('CLOTHING & FOOTWEAR'), findsOneWidget);
      expect(find.text('2 kg'), findsOneWidget);
      expect(find.text('M, blue floral · From Myntra · myntra.com'), findsOneWidget);
      expect(find.text('Bought (1)'), findsOneWidget);
      expect(find.text('Milk'), findsNothing, reason: 'bought lines are folded away');
      await t.tap(find.byKey(const Key('bought_toggle')));
      await t.pump();
      expect(find.text('Milk'), findsOneWidget);
      expect(find.byKey(const Key('shop_these')), findsOneWidget);
      await close(t);
    });

    testWidgets('opened for one kind: only that kind, and a way back to everything', (t) async {
      await open(t, category: 'clothing_footwear');
      expect(find.textContaining('Only Clothing & footwear'), findsOneWidget);
      expect(find.text('Kurti'), findsOneWidget);
      expect(find.text('Onion'), findsNothing);
      await t.tap(find.byKey(const Key('show_everything')));
      await t.pump();
      expect(find.text('Onion'), findsOneWidget);
      await close(t);
    });
  });

  group('changes', () {
    testWidgets('a tap ticks; the line waits a moment, then folds into Bought', (t) async {
      await open(t);
      await t.tap(find.text('Onion'));
      await t.pump();
      expect(server.calls.last.$1, 'PATCH');
      expect(server.calls.last.$3, {'checked': true});
      expect(find.text('Onion'), findsOneWidget, reason: 'still where the finger was');
      await t.pump(const Duration(seconds: 2));
      expect(find.text('Bought (2)'), findsOneWidget);
      expect(find.text('Onion'), findsNothing);
      await close(t);
    });

    testWidgets('a tick that fails is taken back, with Try again that works', (t) async {
      await open(t);
      server.override = (m, p, b) => m == 'PATCH' ? const ShoppingReply(503, null) : null;
      await t.tap(find.text('Curd'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      expect(find.text('Try again'), findsOneWidget);
      expect(find.textContaining('our side'), findsOneWidget);
      server.override = null;
      await t.tap(find.text('Try again'));
      await t.pump();
      await t.pump(const Duration(seconds: 2));
      expect(server.items.firstWhere((x) => x['id'] == 2)['checked'], isTrue);
      await close(t);
    });

    testWidgets('swipe removes; Undo brings it back; otherwise the server is told', (t) async {
      await open(t);
      await t.drag(find.text('Kurti'), const Offset(-700, 0));
      await t.pumpAndSettle();
      expect(find.text('Kurti'), findsNothing);
      expect(find.text('Removed Kurti'), findsOneWidget);
      await t.tap(find.text('Undo'));
      await t.pumpAndSettle();
      expect(find.text('Kurti'), findsOneWidget);
      expect(server.paths, isNot(contains('DELETE /items/3')));
      await t.drag(find.text('Kurti'), const Offset(-700, 0));
      await t.pumpAndSettle();
      await t.pump(const Duration(seconds: 5));
      await t.pumpAndSettle();
      expect(server.paths, contains('DELETE /items/3'));
      await close(t);
    });

    testWidgets('hold opens the edit sheet; Save sends only what changed', (t) async {
      await open(t);
      await t.longPress(find.text('Kurti'));
      await t.pumpAndSettle();
      expect(find.text('Edit'), findsOneWidget);
      await t.enterText(find.byKey(const Key('edit_details')), 'L, blue floral');
      await t.ensureVisible(find.byKey(const Key('edit_save')));
      await t.tap(find.byKey(const Key('edit_save')));
      await t.pumpAndSettle();
      expect(server.calls.last.$1, 'PATCH');
      expect(server.calls.last.$2, '/items/3');
      expect(server.calls.last.$3, {'details': 'L, blue floral'});
      expect(find.text('L, blue floral · From Myntra · myntra.com'), findsOneWidget);
      await close(t);
    });

    testWidgets('the edit sheet refuses a link that is not https, in words', (t) async {
      await open(t);
      await t.longPress(find.text('Kurti'));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const Key('edit_link')), 'http://biba.in/x');
      await t.ensureVisible(find.byKey(const Key('edit_save')));
      await t.tap(find.byKey(const Key('edit_save')));
      await t.pump();
      expect(find.text('Use a web address starting with https://'), findsOneWidget);
      expect(server.paths.where((p) => p.startsWith('PATCH')), isEmpty);
      await close(t);
    });

    testWidgets('quick add understands "2 kg tomatoes" and keeps the keyboard for the next',
        (t) async {
      await open(t);
      server.gate = Completer<void>();
      await t.enterText(find.byKey(const Key('shopping_quick_add')), '2 kg tomatoes');
      await t.testTextInput.receiveAction(TextInputAction.done);
      await t.pump();
      expect(find.text('Adding…'), findsOneWidget, reason: 'shown at once');
      expect(find.text('2 kg'), findsNWidgets(2), reason: 'with its amount, beside the onions’');
      server.gate!.complete();
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      final post = server.calls.lastWhere((c) => c.$2 == '/items');
      expect(post.$3, {
        'items': [
          {'name': 'Tomatoes', 'quantity': 2.0, 'unit': 'kg'}
        ],
        'source': 'manual',
      });
      expect(find.text('Tomatoes'), findsOneWidget);
      final box = t.widget<TextField>(find.byKey(const Key('shopping_quick_add')));
      expect(box.controller!.text, isEmpty);
      expect(box.focusNode!.hasFocus, isTrue);
      await close(t);
    });

    testWidgets('added while showing one kind, and it went under another: said where', (t) async {
      await open(t, category: 'clothing_footwear');
      await t.enterText(find.byKey(const Key('shopping_quick_add')), '2 kg onions');
      await t.testTextInput.receiveAction(TextInputAction.done);
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      expect(find.text('Added Onions — it is under Vegetables & fruit.'), findsOneWidget);
      await close(t);
    });

    testWidgets('quick add with no name says what to type, and sends nothing', (t) async {
      await open(t);
      await t.enterText(find.byKey(const Key('shopping_quick_add')), '2 kg');
      await t.testTextInput.receiveAction(TextInputAction.done);
      await t.pump();
      expect(find.textContaining('Type what to buy'), findsOneWidget);
      expect(server.paths.where((p) => p == 'POST /items'), isEmpty);
      await close(t);
    });

    testWidgets('an add that fails keeps the words in the box, with Try again', (t) async {
      await open(t);
      server.override = (m, p, b) => p == '/items' ? const ShoppingReply(0, null) : null;
      await t.enterText(find.byKey(const Key('shopping_quick_add')), 'bread');
      await t.testTextInput.receiveAction(TextInputAction.done);
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      final box = t.widget<TextField>(find.byKey(const Key('shopping_quick_add')));
      expect(box.controller!.text, 'bread');
      expect(find.text('Try again'), findsOneWidget);
      await close(t);
    });

    testWidgets('Clear bought: at once, with Undo', (t) async {
      await open(t);
      await t.tap(find.byKey(const Key('clear_bought')));
      await t.pumpAndSettle();
      expect(find.text('Cleared 1 bought thing'), findsOneWidget);
      expect(find.byKey(const Key('bought_toggle')), findsNothing);
      expect(server.paths, isNot(contains('POST /clear')), reason: 'not until the Undo closes');
      await t.pump(const Duration(seconds: 5));
      await t.pumpAndSettle();
      expect(server.calls.lastWhere((c) => c.$2 == '/clear').$3, {'checkedOnly': true});
      await close(t);
    });

    testWidgets('Clear all asks first; Keep keeps everything', (t) async {
      await open(t);
      await t.tap(find.byKey(const Key('shopping_menu')));
      await t.pumpAndSettle();
      await t.tap(find.text('Clear all…'));
      await t.pumpAndSettle();
      expect(find.text('Clear the whole list?'), findsOneWidget);
      expect(find.textContaining('All 4 things'), findsOneWidget);
      await t.tap(find.text('Keep'));
      await t.pumpAndSettle();
      expect(server.paths, isNot(contains('POST /clear')));
      expect(find.text('Onion'), findsOneWidget);

      await t.tap(find.byKey(const Key('shopping_menu')));
      await t.pumpAndSettle();
      await t.tap(find.text('Clear all…'));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('confirm_clear_all')));
      await t.pumpAndSettle();
      expect(server.calls.lastWhere((c) => c.$2 == '/clear').$3, {'checkedOnly': false});
      expect(find.text('Nothing to buy yet'), findsOneWidget);
      await close(t);
    });

    testWidgets('Share list hands the WhatsApp-ready text to the share sheet', (t) async {
      await open(t, category: 'dairy_eggs');
      await t.tap(find.byKey(const Key('shopping_menu')));
      await t.pumpAndSettle();
      await t.tap(find.text('Share list'));
      await t.pumpAndSettle();
      expect(shared, [server.shareText]);
      expect(server.paths.last, 'GET /share-text?category=dairy_eggs',
          reason: 'the kind on screen is the kind shared');
      await close(t);
    });
  });

  group('Shop these', () {
    testWidgets('asks once which app is for groceries, then opens the first thing', (t) async {
      server.needsGroceryApp = true;
      await open(t);
      await t.tap(find.byKey(const Key('shop_these')));
      await t.pumpAndSettle();
      expect(find.text('Which app do you use for groceries?'), findsOneWidget);
      expect(find.textContaining('For Onion and Curd.'), findsOneWidget);
      await t.tap(find.byKey(const Key('grocery_app_Zepto')));
      await t.pumpAndSettle();
      expect(server.calls.last.$3, {'groceryApp': 'Zepto'});
      expect(ports.opened, ['com.grofers.customerapp https://blinkit.com/s/?q=onion']);
      expect(ports.last!.title, 'Shopping · 1 of 3');
      await close(t);
    });

    testWidgets('the question closed: nothing opens', (t) async {
      server.needsGroceryApp = true;
      await open(t);
      await t.tap(find.byKey(const Key('shop_these')));
      await t.pumpAndSettle();
      await t.tap(find.text('Not now'));
      await t.pumpAndSettle();
      expect(server.paths.where((p) => p == 'POST /handoff').length, 1);
      expect(ports.opened, isEmpty);
      await close(t);
    });

    testWidgets('for one kind: only its lines are sent', (t) async {
      await open(t, category: 'clothing_footwear');
      await t.tap(find.byKey(const Key('shop_these')));
      await t.pumpAndSettle();
      expect(server.calls.lastWhere((c) => c.$2 == '/handoff').$3, {
        'ids': [3]
      });
      await close(t);
    });

    testWidgets('nothing could open: said, with Try again', (t) async {
      ports.installed = {};
      ports.browserWorks = false;
      await open(t);
      await t.tap(find.byKey(const Key('shop_these')));
      await t.pumpAndSettle();
      expect(find.textContaining("Couldn't open the shopping app"), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
      await close(t);
    });
  });

  group('for everyone', () {
    testWidgets('a line tells TalkBack what it is, whether it is bought, and what it can do',
        (t) async {
      final semantics = t.ensureSemantics();
      await open(t);
      final onion = find.bySemanticsLabel(RegExp(r'^Onion, 2 kg'));
      expect(onion, findsOneWidget);
      expect(
          t.getSemantics(onion),
          isSemantics(
            hasCheckedState: true,
            isChecked: false,
            hasTapAction: true,
            hasLongPressAction: true,
          ));
      final data = t.getSemantics(onion).getSemanticsData();
      final actions = [
        for (final id in data.customSemanticsActionIds ?? const <int>[])
          CustomSemanticsAction.getAction(id)
      ];
      expect(actions.map((a) => a?.label), containsAll(['Edit', 'Remove']),
          reason: 'swipe and hold have TalkBack actions too');
      expect(actions.map((a) => a?.hint), containsAll(['tick as bought', 'edit']));
      semantics.dispose();
      await close(t);
    });

    testWidgets('every tap target is at least 48 dp', (t) async {
      final semantics = t.ensureSemantics();
      await open(t);
      await t.tap(find.byKey(const Key('bought_toggle')));
      await t.pump();
      await expectLater(t, meetsGuideline(androidTapTargetGuideline));
      semantics.dispose();
      await close(t);
    });
  });
}
