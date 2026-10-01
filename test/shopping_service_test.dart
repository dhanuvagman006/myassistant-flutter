// THE SHOPPING LIST SERVICE (build 124): a tap shows at once and is taken
// back if the server says no (with a line and, when it can help, Try
// again); requests go out one at a time, in order; a read never paints
// over an edit made after it; the last list opens instantly; sign-out
// forgets it.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/features/shopping/shopping_models.dart';
import 'package:myassistant/features/shopping/shopping_parse.dart';
import 'package:myassistant/features/shopping/shopping_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/fake_shopping.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final svc = ShoppingService.instance;
  late FakeShoppingServer server;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    server = FakeShoppingServer();
    ShoppingService.transport = server.call;
    await svc.reset();
  });

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

  ShoppingItem item(int id) => svc.items.firstWhere((i) => i.id == id);

  test('load: the saved list at once, then the server’s', () async {
    SharedPreferences.setMockInitialValues({
      ShoppingService.cacheKey: jsonEncode({
        'items': [itemJson(9, 'Saved bread', category: 'other')],
        'categories': categoriesJson,
      }),
    });
    await svc.reset();
    SharedPreferences.setMockInitialValues({
      ShoppingService.cacheKey: jsonEncode({
        'items': [itemJson(9, 'Saved bread', category: 'other')],
        'categories': categoriesJson,
      }),
    });
    server.gate = Completer<void>();
    final done = svc.load();
    await settle();
    expect(svc.loaded, isTrue);
    expect(svc.items.map((i) => i.name), ['Saved bread'], reason: 'the saved copy, instantly');
    server.gate!.complete();
    await done;
    expect(svc.items.map((i) => i.name), ['Onion', 'Curd', 'Kurti', 'Milk']);
    expect(svc.labelOf('clothing_footwear'), 'Clothing & footwear');
    expect(svc.toBuyCount, 3, reason: 'the bought milk is not counted');
    final saved = jsonDecode((await SharedPreferences.getInstance()).getString(ShoppingService.cacheKey)!);
    expect((saved['items'] as List).length, 4, reason: 'kept for the next open');
  });

  test('offline with nothing saved: failed, nothing to show', () async {
    server.override = (m, p, b) => const ShoppingReply(0, null);
    await svc.load();
    expect(svc.loaded, isFalse);
    expect(svc.failed, isTrue);
  });

  test('add: shown at once ("Adding…"), then in its place; the body is what was typed', () async {
    await svc.load();
    server.gate = Completer<void>();
    final f = svc.add(parseQuickAdd('2 kg tomatoes').draft!);
    await settle();
    final temp = svc.items.first;
    expect(temp.pending, isTrue);
    expect(temp.name, 'Tomatoes');
    expect(temp.amountText, '2 kg', reason: 'reads the same before and after the server');
    server.gate!.complete();
    final r = await f;
    expect(r.ok, isTrue);
    expect(svc.items.any((i) => i.pending), isFalse);
    expect(svc.items.map((i) => i.name), contains('Tomatoes'));
    final post = server.calls.lastWhere((c) => c.$2 == '/items');
    expect(post.$3, {
      'items': [
        {'name': 'Tomatoes', 'quantity': 2.0, 'unit': 'kg'}
      ],
      'source': 'manual',
    });
  });

  test('an add that goes onto a line already there says so', () async {
    await svc.load();
    final r = await svc.add(const ShoppingDraft('Milk', quantity: 1, unit: 'l'));
    expect(r.ok, isTrue);
    expect(r.merged?.name, 'Milk');
    expect(r.merged?.amountText, '2 L');
  });

  test('an add with no connection is taken back, and may be tried again', () async {
    await svc.load();
    server.override = (m, p, b) => p == '/items' ? const ShoppingReply(0, null) : null;
    final r = await svc.add(const ShoppingDraft('Bread'));
    expect(r.ok, isFalse);
    expect(r.canRetry, isTrue);
    expect(r.error, contains('connection'));
    expect(svc.items.any((i) => i.pending || i.name == 'Bread'), isFalse);
  });

  test('an add the server refuses says why and is not offered again', () async {
    await svc.load();
    server.override = (m, p, b) => p == '/items'
        ? const ShoppingReply(400, {
            'ok': false,
            'error': 'list_full',
            'message': 'The shopping list is full (300 items). Clear the bought items or remove some first'
          })
        : null;
    final r = await svc.add(const ShoppingDraft('Bread'));
    expect(r.ok, isFalse);
    expect(r.canRetry, isFalse);
    expect(r.error, contains('full'));
  });

  test('tick: at once; a failure takes it back', () async {
    await svc.load();
    server.gate = Completer<void>();
    final f = svc.setChecked(item(1), true);
    await settle();
    expect(item(1).checked, isTrue, reason: 'optimistic');
    server.override = (m, p, b) => m == 'PATCH' ? const ShoppingReply(503, null) : null;
    server.gate!.complete();
    final r = await f;
    expect(r.ok, isFalse);
    expect(r.canRetry, isTrue);
    expect(item(1).checked, isFalse, reason: 'taken back');
  });

  test('a quick tick-untick lands in the order it was made', () async {
    await svc.load();
    server.gate = Completer<void>();
    final a = svc.setChecked(item(1), true);
    final b = svc.setChecked(item(1), false);
    await settle();
    server.gate!.complete();
    await Future.wait([a, b]);
    final patches = [for (final c in server.calls) if (c.$1 == 'PATCH') c.$3];
    expect(patches, [
      {'checked': true},
      {'checked': false},
    ]);
    expect(item(1).checked, isFalse);
    expect(server.items.firstWhere((x) => x['id'] == 1)['checked'], isFalse);
  });

  test('a read that started before an edit never paints over it', () async {
    await svc.load();
    server.calls.clear();
    server.gate = Completer<void>();
    final read = svc.refresh();
    final tick = svc.setChecked(item(2), true);
    await settle();
    server.gate!.complete();
    await Future.wait([read, tick]);
    await settle();
    expect(item(2).checked, isTrue);
    expect(server.paths, ['GET ', 'PATCH /items/2', 'GET '],
        reason: 'the old read is dropped and the list read again after the edit');
  });

  test('a line the server no longer has is taken off, with no retry', () async {
    await svc.load();
    server.items.removeWhere((x) => x['id'] == 1);
    final r = await svc.setChecked(item(1), true);
    expect(r.ok, isFalse);
    expect(r.canRetry, isFalse);
    expect(svc.items.any((i) => i.id == 1), isFalse);
  });

  test('remove: gone at once; Undo brings it back and sends nothing', () async {
    await svc.load();
    final p = svc.removeLater(item(3));
    expect(svc.items.any((i) => i.id == 3), isFalse);
    p.cancel();
    expect(svc.items.any((i) => i.id == 3), isTrue);
    await p.commit();
    expect(server.paths, isNot(contains('DELETE /items/3')));
  });

  test('remove: after the Undo closes the server is told; a failure brings it back', () async {
    await svc.load();
    final ok = await svc.removeLater(item(3)).commit();
    expect(ok.ok, isTrue);
    expect(server.paths, contains('DELETE /items/3'));
    expect(server.items.any((x) => x['id'] == 3), isFalse);

    server.override = (m, p, b) => m == 'DELETE' ? const ShoppingReply(0, null) : null;
    final fail = await svc.removeLater(item(2)).commit();
    expect(fail.ok, isFalse);
    expect(fail.canRetry, isTrue);
    expect(svc.items.any((i) => i.id == 2), isTrue, reason: 'back on the list');
  });

  test('clear bought: hidden at once, then POST /clear {checkedOnly: true}', () async {
    await svc.load();
    final p = svc.clearBoughtLater();
    expect(svc.items.any((i) => i.checked), isFalse);
    await p.commit();
    final clear = server.calls.lastWhere((c) => c.$2 == '/clear');
    expect(clear.$3, {'checkedOnly': true});
    expect(svc.items.map((i) => i.id), [1, 2, 3]);
  });

  test('clear all: at once; put back when the server cannot', () async {
    await svc.load();
    server.override = (m, p, b) => p == '/clear' ? const ShoppingReply(500, null) : null;
    final r = await svc.clearAll();
    expect(r.ok, isFalse);
    expect(r.canRetry, isTrue);
    expect(svc.items.length, 4, reason: 'nothing lost');
    server.override = null;
    expect((await svc.clearAll()).ok, isTrue);
    expect(svc.items, isEmpty);
    expect(server.calls.last.$3, {'checkedOnly': false});
  });

  test('edit: only what changed is sent; shown at once', () async {
    await svc.load();
    final r = await svc.update(item(3), {'details': 'L, blue floral', 'store': null});
    expect(r.ok, isTrue);
    expect(server.calls.last.$3, {'details': 'L, blue floral', 'store': null});
    expect(item(3).details, 'L, blue floral');
    expect(item(3).store, isNull);
    final amount = await svc.update(item(1), {'quantity': 3.0, 'unit': 'kg'});
    expect(amount.ok, isTrue);
    expect(item(1).quantity, 3.0);
  });

  test('share text: for one kind when asked', () async {
    await svc.load();
    final all = await svc.shareText();
    expect(all.text, startsWith('Shopping list'));
    expect(server.calls.last.$2, '/share-text');
    await svc.shareText(category: 'clothing_footwear');
    expect(server.calls.last.$2, '/share-text?category=clothing_footwear');
    server.override = (m, p, b) => const ShoppingReply(0, null);
    final off = await svc.shareText();
    expect(off.text, isNull);
    expect(off.canRetry, isTrue);
  });

  test('hand-off: the grocery-app question, then the trip', () async {
    await svc.load();
    server.needsGroceryApp = true;
    final ask = await svc.handoff();
    expect(ask.handoff, isNull);
    expect(ask.needsGroceryApp, ['Onion', 'Curd']);
    expect(ask.groceryApps, contains('Blinkit'));
    final go = await svc.handoff(groceryApp: 'Zepto');
    expect(server.calls.last.$3, {'groceryApp': 'Zepto'});
    expect(go.handoff!.groups.first.label, 'Zepto');
    expect(go.handoff!.total, 3);
    expect(go.rememberedGroceryApp, 'Zepto');
    await svc.handoff(ids: [3]);
    expect(server.calls.last.$3, {
      'ids': [3]
    });
  });

  test('sign-out forgets the list and its saved copy', () async {
    await svc.load();
    await svc.reset();
    expect(svc.items, isEmpty);
    expect(svc.loaded, isFalse);
    expect((await SharedPreferences.getInstance()).getString(ShoppingService.cacheKey), isNull);
  });

  test('the server’s refusals in plain words', () {
    String line(int status, [String? code, String? message]) => ShoppingService.lineFor(
        ShoppingReply(status, code == null ? null : {'ok': false, 'error': code, 'message': message}));
    expect(line(0), contains('connection'));
    expect(line(429), contains('wait a moment'));
    expect(line(502), contains('our side'));
    expect(line(400, 'bad_link'), contains('https://'));
    expect(line(400, 'money_app', 'Google Pay is a payment app — shopping lists open shopping apps only'),
        contains('payment app'),
        reason: "the server's own sentence for a refusal it explained");
    expect(ShoppingService.retryable(const ShoppingReply(400, null)), isFalse);
    expect(ShoppingService.retryable(const ShoppingReply(0, null)), isTrue);
  });
}
