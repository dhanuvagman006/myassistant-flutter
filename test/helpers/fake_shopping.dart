// The /shopping server, small and in memory (the shapes of backend
// src/shopping/routes.js), and the phone's hands for a shopping trip —
// for the shopping list's service, screen and engine tests.
import 'dart:async';

import 'package:myassistant/features/shopping/shop_handoff.dart';
import 'package:myassistant/features/shopping/shopping_service.dart';

const categoriesJson = [
  {'id': 'vegetables_fruit', 'label': 'Vegetables & fruit'},
  {'id': 'dairy_eggs', 'label': 'Dairy & eggs'},
  {'id': 'clothing_footwear', 'label': 'Clothing & footwear'},
  {'id': 'electronics_accessories', 'label': 'Electronics & accessories'},
  {'id': 'other', 'label': 'Other'},
];

Map<String, dynamic> itemJson(
  int id,
  String name, {
  String category = 'other',
  bool checked = false,
  double? quantity,
  String? unit,
  String amountText = '',
  String details = '',
  String? store,
  String? link,
}) =>
    {
      'id': id,
      'name': name,
      'quantity': quantity,
      'unit': unit,
      'amounts': quantity == null ? [] : [{'quantity': quantity, 'unit': unit}],
      'amountText': amountText,
      'details': details,
      'link': link,
      'store': store,
      'note': '',
      'category': category,
      'recipe': null,
      'source': 'manual',
      'checked': checked,
      'createdAt': 1000 + id,
      'updatedAt': 1000 + id,
    };

/// A list with groceries and not-groceries, one of them bought.
List<Map<String, dynamic>> sampleItems() => [
      itemJson(1, 'Onion', category: 'vegetables_fruit', quantity: 2, unit: 'kg', amountText: '2 kg'),
      itemJson(2, 'Curd', category: 'dairy_eggs', quantity: 1, unit: 'packet', amountText: '1 packet'),
      itemJson(3, 'Kurti',
          category: 'clothing_footwear',
          details: 'M, blue floral',
          store: 'Myntra',
          link: 'https://www.myntra.com/kurtas/biba/123'),
      itemJson(4, 'Milk', category: 'dairy_eggs', checked: true),
    ];

class FakeShoppingServer {
  final calls = <(String, String, Map<String, dynamic>?)>[];
  List<Map<String, dynamic>> items = sampleItems();
  int nextId = 100;

  /// Held replies: the test sees the screen BEFORE the server answers.
  Completer<void>? gate;

  /// Answers this instead, when it returns one.
  ShoppingReply? Function(String method, String path, Map<String, dynamic>? body)? override;

  /// Grocery lines have no app until the owner names one.
  bool needsGroceryApp = false;

  String shareText = 'Shopping list\n• Onion — 2 kg\n• Curd — 1 packet\n• Kurti (M, blue floral)';

  List<String> get paths => [for (final c in calls) '${c.$1} ${c.$2}'];

  Map<String, dynamic> _list() => {'items': items, 'updatedAt': 1, 'categories': categoriesJson};

  Future<ShoppingReply> call(String method, String path, {Map<String, dynamic>? body}) async {
    calls.add((method, path, body));
    final g = gate;
    if (g != null) await g.future;
    final o = override?.call(method, path, body);
    if (o != null) return o;
    if (method == 'GET' && path == '') return ShoppingReply(200, _list());
    if (method == 'POST' && path == '/items') {
      final added = <Map<String, dynamic>>[];
      final merged = <Map<String, dynamic>>[];
      for (final raw in (body!['items'] as List).cast<Map<String, dynamic>>()) {
        final name = raw['name'] as String;
        final i = items.indexWhere((x) => (x['name'] as String).toLowerCase() == name.toLowerCase());
        if (i >= 0) {
          items[i] = {...items[i], 'amountText': '2 L'};
          merged.add(items[i]);
        } else {
          final line = itemJson(nextId++, name,
              quantity: (raw['quantity'] as num?)?.toDouble(),
              unit: raw['unit'] as String?,
              amountText: raw['quantity'] == null ? '' : '${raw['quantity']} ${raw['unit'] ?? ''}'.trim(),
              category: name.toLowerCase().contains('onion') ? 'vegetables_fruit' : 'other');
          items.add(line);
          added.add(line);
        }
      }
      return ShoppingReply(200, {'added': added, 'merged': merged, 'items': items});
    }
    final one = RegExp(r'^/items/(\d+)$').firstMatch(path);
    if (one != null) {
      final id = int.parse(one.group(1)!);
      final i = items.indexWhere((x) => x['id'] == id);
      if (i < 0) {
        return const ShoppingReply(
            404, {'ok': false, 'error': 'not_found', 'message': 'That item is not on your list'});
      }
      if (method == 'DELETE') {
        items.removeAt(i);
        return const ShoppingReply(200, {'ok': true});
      }
      items[i] = {...items[i], ...body!};
      return ShoppingReply(200, {'item': items[i]});
    }
    if (method == 'POST' && path == '/clear') {
      final before = items.length;
      items = body!['checkedOnly'] == true
          ? [for (final x in items) if (x['checked'] != true) x]
          : [];
      return ShoppingReply(200, {'removed': before - items.length});
    }
    if (method == 'GET' && path.startsWith('/share-text')) {
      return ShoppingReply(200, {'text': shareText});
    }
    if (method == 'POST' && path == '/handoff') {
      final grocery = body?['groceryApp'] as String?;
      if (needsGroceryApp && grocery == null) {
        return const ShoppingReply(200, {
          'handoff': null,
          'summary': '',
          'needsGroceryApp': ['Onion', 'Curd'],
          'groceryApps': ['Blinkit', 'Zepto', 'Swiggy Instamart'],
          'rememberedGroceryApp': null,
        });
      }
      return ShoppingReply(200, {
        'handoff': handoffJson(grocery: grocery ?? 'Blinkit'),
        'summary': 'onion and curd on ${grocery ?? 'Blinkit'}, then kurti on Myntra',
        'needsGroceryApp': <String>[],
        'groceryApps': ['Blinkit', 'Zepto', 'Swiggy Instamart'],
        'rememberedGroceryApp': grocery,
      });
    }
    return const ShoppingReply(404, {'ok': false, 'error': 'not_found', 'message': 'no route'});
  }
}

/// A shop_handoff: two groceries on [grocery], then the kurti on Myntra.
Map<String, dynamic> handoffJson({String grocery = 'Blinkit'}) => {
      'type': 'shop_handoff',
      'groups': [
        {
          'app': grocery.toLowerCase(),
          'label': grocery,
          'pkg': 'com.grofers.customerapp',
          'items': [
            {'id': 1, 'name': 'Onion', 'quantity': 2, 'unit': 'kg', 'amountText': '2 kg',
              'url': 'https://blinkit.com/s/?q=onion'},
            {'id': 2, 'name': 'Curd', 'quantity': 1, 'unit': 'packet', 'amountText': '1 packet',
              'url': 'https://blinkit.com/s/?q=curd'},
          ],
        },
        {
          'app': 'myntra',
          'label': 'Myntra',
          'pkg': 'com.myntra.android',
          'items': [
            {'id': 3, 'name': 'Kurti', 'details': 'M, blue floral', 'quantity': null, 'unit': null,
              'amountText': '', 'url': 'https://www.myntra.com/kurtas/biba/123'},
          ],
        },
      ],
    };

/// The phone, pretend: which apps are "installed", what opened, and what
/// the notification says.
class FakeShopPorts implements ShopPorts {
  FakeShopPorts({this.installed = const {'com.grofers.customerapp', 'com.myntra.android'}});

  Set<String> installed;
  bool browserWorks = true;
  final opened = <String>[];
  final progress = <ShopProgress>[];
  var cleared = 0;
  bool shown = false;

  ShopProgress? get last => progress.isEmpty ? null : progress.last;

  @override
  Future<bool> openInApp(String url, String pkg) async {
    if (!installed.contains(pkg)) return false;
    opened.add('$pkg $url');
    return true;
  }

  @override
  Future<bool> openInBrowser(String url) async {
    if (!browserWorks) return false;
    opened.add('browser $url');
    return true;
  }

  @override
  Future<void> showProgress(ShopProgress p) async {
    progress.add(p);
    shown = true;
  }

  @override
  Future<void> clearProgress() async {
    cleared++;
    shown = false;
  }

  @override
  Future<bool> progressShown() async => shown;
}
