/// ─────────────────────────────────────────────────────────────────────────
///  THE SHOPPING LIST'S SHAPES (build 124) — exactly what /shopping sends
///  (backend src/shopping, 2026-09-29). One list for anything to buy:
///  groceries, a dress, a charger, medicines, a gift.
/// ─────────────────────────────────────────────────────────────────────────
library;

/// One kind of thing to buy, as the server names it.
class ShoppingCategory {
  const ShoppingCategory(this.id, this.label);

  final String id;
  final String label;

  static ShoppingCategory? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = (j['id'] ?? '').toString();
    if (id.isEmpty) return null;
    final label = (j['label'] ?? '').toString();
    return ShoppingCategory(id, label.isEmpty ? id : label);
  }

  Map<String, dynamic> toJson() => {'id': id, 'label': label};
}

/// The server's categories in its own order — what the list is grouped by
/// until GET /shopping has answered (its labels win from then on).
const shoppingCategories = <ShoppingCategory>[
  ShoppingCategory('vegetables_fruit', 'Vegetables & fruit'),
  ShoppingCategory('dairy_eggs', 'Dairy & eggs'),
  ShoppingCategory('meat_fish', 'Meat & fish'),
  ShoppingCategory('rice_atta_dal', 'Rice, atta & dal'),
  ShoppingCategory('spices_masala', 'Spices & masala'),
  ShoppingCategory('oils', 'Oils & ghee'),
  ShoppingCategory('bakery', 'Bakery'),
  ShoppingCategory('snacks_drinks', 'Snacks & drinks'),
  ShoppingCategory('household_cleaning', 'Household & cleaning'),
  ShoppingCategory('personal_care_beauty', 'Personal care & beauty'),
  ShoppingCategory('health_medicines', 'Health & medicines'),
  ShoppingCategory('clothing_footwear', 'Clothing & footwear'),
  ShoppingCategory('electronics_accessories', 'Electronics & accessories'),
  ShoppingCategory('home_kitchen', 'Home & kitchen'),
  ShoppingCategory('stationery_books', 'Stationery & books'),
  ShoppingCategory('baby_kids', 'Baby & kids'),
  ShoppingCategory('pets', 'Pets'),
  ShoppingCategory('gifts', 'Gifts'),
  ShoppingCategory('other', 'Other'),
];

/// One line on the list. A negative [id] is a line typed here that the
/// server has not confirmed yet.
class ShoppingItem {
  const ShoppingItem({
    required this.id,
    required this.name,
    this.quantity,
    this.unit,
    this.amountText = '',
    this.details = '',
    this.link,
    this.store,
    this.note = '',
    this.category = 'other',
    this.recipe,
    this.source = 'manual',
    this.checked = false,
    this.createdAt = 0,
    this.updatedAt = 0,
  });

  final int id;
  final String name;
  final double? quantity;
  final String? unit;

  /// "2 kg", "1.5 kg + 2 pcs", or '' when no amount was said.
  final String amountText;

  /// Size, colour, brand or model: "M, blue floral".
  final String details;

  /// The product's own page (https), when there is one.
  final String? link;

  /// The shop or app they want it from ("Myntra", "the kirana").
  final String? store;
  final String note;
  final String category;
  final String? recipe;

  /// "voice" | "recipe" | "plan" | "manual".
  final String source;

  /// Ticked as bought.
  final bool checked;
  final int createdAt;
  final int updatedAt;

  /// Typed here, still on its way to the server.
  bool get pending => id < 0;

  /// "myntra.com" for a line with a link.
  String? get linkHost {
    final l = link;
    if (l == null || l.isEmpty) return null;
    final host = Uri.tryParse(l)?.host ?? '';
    if (host.isEmpty) return null;
    return host.startsWith('www.') ? host.substring(4) : host;
  }

  static String? _text(Object? v) {
    final s = (v ?? '').toString().trim();
    return s.isEmpty ? null : s;
  }

  static ShoppingItem? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = (raw['id'] as num?)?.toInt();
    final name = (raw['name'] ?? '').toString().trim();
    if (id == null || name.isEmpty) return null;
    return ShoppingItem(
      id: id,
      name: name,
      quantity: (raw['quantity'] as num?)?.toDouble(),
      unit: _text(raw['unit']),
      amountText: (raw['amountText'] ?? '').toString(),
      details: (raw['details'] ?? '').toString(),
      link: _text(raw['link']),
      store: _text(raw['store']),
      note: (raw['note'] ?? '').toString(),
      category: _text(raw['category']) ?? 'other',
      recipe: _text(raw['recipe']),
      source: _text(raw['source']) ?? 'manual',
      checked: raw['checked'] == true,
      createdAt: (raw['createdAt'] as num?)?.toInt() ?? 0,
      updatedAt: (raw['updatedAt'] as num?)?.toInt() ?? 0,
    );
  }

  /// Every well-formed line in [raw] (a malformed one is left out, never
  /// allowed to blank the whole list).
  static List<ShoppingItem> listFrom(Object? raw) => raw is List
      ? [
          for (final r in raw)
            if (ShoppingItem.fromJson(r) case final i?) i,
        ]
      : const [];

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'quantity': quantity,
        'unit': unit,
        'amountText': amountText,
        'details': details,
        'link': link,
        'store': store,
        'note': note,
        'category': category,
        'recipe': recipe,
        'source': source,
        'checked': checked,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
      };

  static const Object _keep = Object();

  /// A copy with some fields changed. [quantity], [unit], [link] and
  /// [store] may be set to null (cleared); leaving them out keeps them.
  ShoppingItem copyWith({
    String? name,
    Object? quantity = _keep,
    Object? unit = _keep,
    String? amountText,
    String? details,
    Object? link = _keep,
    Object? store = _keep,
    String? note,
    String? category,
    bool? checked,
  }) =>
      ShoppingItem(
        id: id,
        name: name ?? this.name,
        quantity: identical(quantity, _keep) ? this.quantity : quantity as double?,
        unit: identical(unit, _keep) ? this.unit : unit as String?,
        amountText: amountText ?? this.amountText,
        details: details ?? this.details,
        link: identical(link, _keep) ? this.link : link as String?,
        store: identical(store, _keep) ? this.store : store as String?,
        note: note ?? this.note,
        category: category ?? this.category,
        recipe: recipe,
        source: source,
        checked: checked ?? this.checked,
        createdAt: createdAt,
        updatedAt: updatedAt,
      );
}

/// A number as the server writes it: 2, 1.5, 0.33.
String formatQuantity(double q) {
  if (q == q.roundToDouble()) return q.toInt().toString();
  return ((q * 100).round() / 100).toString();
}

/// A unit as the server writes it beside [q]: pc/pcs, packets, L, strips.
String unitText(String? unit, double q) {
  if (unit == null || unit.isEmpty) return '';
  const plural = {
    'piece': ['pc', 'pcs'],
    'packet': ['packet', 'packets'],
    'bunch': ['bunch', 'bunches'],
    'cup': ['cup', 'cups'],
    'dozen': ['dozen', 'dozen'],
  };
  final p = plural[unit];
  if (p != null) return q == 1 ? p[0] : p[1];
  if (unit == 'l') return 'L';
  if (const {'g', 'kg', 'ml', 'tsp', 'tbsp', 'm'}.contains(unit)) return unit;
  if (q == 1 || unit.endsWith('s')) return unit;
  return RegExp(r'(ch|sh|x|z)$').hasMatch(unit) ? '${unit}es' : '${unit}s';
}

/// "2 kg", "3", or '' — the server's amountText for one amount, so a line
/// typed here reads the same before and after the server confirms it.
String amountTextOf(double? q, String? unit) {
  if (q == null) return '';
  final u = unitText(unit, q);
  return u.isEmpty ? formatQuantity(q) : '${formatQuantity(q)} $u';
}

/// A name as the server keeps it: tidy spaces, no bullet in front or full
/// stop behind, "onion" -> "Onion" (but "iPhone charger" stays).
String cleanItemName(String raw) {
  var s = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  s = s.replaceFirst(RegExp(r'^[-–—•*·>\s]+'), '').replaceFirst(RegExp(r'[.,;:!?]+$'), '').trim();
  if (s.isNotEmpty && RegExp(r'^[a-z]').hasMatch(s) && !RegExp(r'^[a-z][A-Z]').hasMatch(s)) {
    s = s[0].toUpperCase() + s.substring(1);
  }
  return s;
}
