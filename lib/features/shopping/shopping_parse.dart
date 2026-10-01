/// ─────────────────────────────────────────────────────────────────────────
///  QUICK ADD — what a typed line means: "2 kg onions", "milk",
///  "blue kurti size M", "Horlicks 500 g", "2 strips of Dolo 650".
///
///  Only the amount is read out of the words (a quantity and, when there is
///  one, a unit the server knows). Everything else stays the name, as typed:
///  sizes, colours and model numbers are never guessed at — "Dolo 650",
///  "iPhone 15 case", "55 inch TV" and "7up" are names, not amounts. The
///  server sorts each line into its category itself.
/// ─────────────────────────────────────────────────────────────────────────
library;

import 'shopping_models.dart';

/// One line to add, as the server takes it.
class ShoppingDraft {
  const ShoppingDraft(this.name, {this.quantity, this.unit});

  final String name;
  final double? quantity;
  final String? unit;

  Map<String, dynamic> toJson() => {
        'name': name,
        if (quantity != null) 'quantity': quantity,
        if (unit != null) 'unit': unit,
      };

  @override
  String toString() => 'ShoppingDraft($name, $quantity, $unit)';
}

/// What a typed line gave: a [draft], or the [error] to show under the box.
class QuickAddResult {
  const QuickAddResult.ok(ShoppingDraft this.draft) : error = null;
  const QuickAddResult.error(String this.error) : draft = null;

  final ShoppingDraft? draft;
  final String? error;
}

/// The longest name the server keeps.
const shoppingNameMax = 80;

/// Units the server knows, by every way people write them (the server's
/// UNIT_ALIASES). These may follow a number directly: "2 kg onions".
const Map<String, String> _coreUnits = {
  'g': 'g', 'gm': 'g', 'gms': 'g', 'gram': 'g', 'grams': 'g', 'gramme': 'g',
  'grammes': 'g', 'gr': 'g', 'grm': 'g', 'grms': 'g',
  'kg': 'kg', 'kgs': 'kg', 'kilo': 'kg', 'kilos': 'kg', 'kilogram': 'kg',
  'kilograms': 'kg', 'kilogramme': 'kg', 'kilogrammes': 'kg',
  'ml': 'ml', 'mls': 'ml', 'millilitre': 'ml', 'millilitres': 'ml',
  'milliliter': 'ml', 'milliliters': 'ml',
  'l': 'l', 'ltr': 'l', 'ltrs': 'l', 'litre': 'l', 'litres': 'l', 'liter': 'l',
  'liters': 'l', 'lt': 'l', 'lit': 'l',
  'tsp': 'tsp', 'tsps': 'tsp', 'teaspoon': 'tsp', 'teaspoons': 'tsp',
  'tbsp': 'tbsp', 'tbsps': 'tbsp', 'tablespoon': 'tbsp', 'tablespoons': 'tbsp',
  'tbs': 'tbsp', 'tblsp': 'tbsp',
  'piece': 'piece', 'pieces': 'piece', 'pc': 'piece', 'pcs': 'piece', 'nos': 'piece',
  'packet': 'packet', 'packets': 'packet', 'pack': 'packet', 'packs': 'packet',
  'pkt': 'packet', 'pkts': 'packet', 'pouch': 'packet', 'pouches': 'packet',
  'sachet': 'packet', 'sachets': 'packet',
  'bunch': 'bunch', 'bunches': 'bunch', 'gaddi': 'bunch', 'katta': 'bunch',
  'dozen': 'dozen', 'dozens': 'dozen', 'doz': 'dozen',
  'm': 'm', 'mtr': 'm', 'mtrs': 'm', 'metre': 'm', 'metres': 'm', 'meter': 'm',
  'meters': 'm',
};

/// Containers. In front of a name they need "of" ("2 bottles of oil"),
/// because the same words start names: "tube light", "can opener",
/// "bar stool", "set top box".
const Map<String, String> _containerUnits = {
  'bottle': 'bottle', 'bottles': 'bottle', 'box': 'box', 'boxes': 'box',
  'can': 'can', 'cans': 'can', 'jar': 'jar', 'jars': 'jar', 'tin': 'tin',
  'tins': 'tin', 'roll': 'roll', 'rolls': 'roll', 'bag': 'bag', 'bags': 'bag',
  'tray': 'tray', 'trays': 'tray', 'strip': 'strip', 'strips': 'strip',
  'tube': 'tube', 'tubes': 'tube', 'bar': 'bar', 'bars': 'bar', 'loaf': 'loaf',
  'loaves': 'loaf', 'pair': 'pair', 'pairs': 'pair', 'set': 'set', 'sets': 'set',
  'cup': 'cup', 'cups': 'cup', 'carton': 'carton', 'cartons': 'carton',
};

/// Words after a number that make it part of the NAME, not an amount:
/// "55 inch TV", "256 GB pen drive", "5 star", "650 mg".
const Set<String> _specWords = {
  'inch', 'inches', 'in', 'cm', 'mm', 'gb', 'tb', 'mb', 'mah', 'w', 'watt',
  'watts', 'kw', 'v', 'volt', 'volts', 'mp', 'hz', 'ton', 'tonne', 'star',
  'rs', 'mg', 'mcg', 'ply', 'seater', 'door',
};

const Map<String, double> _numberWords = {
  'one': 1, 'two': 2, 'three': 3, 'four': 4, 'five': 5, 'six': 6, 'seven': 7,
  'eight': 8, 'nine': 9, 'ten': 10, 'eleven': 11, 'twelve': 12, 'half': 0.5,
  'quarter': 0.25, 'a': 1, 'an': 1,
};

const Map<String, double> _fractions = {'½': 0.5, '¼': 0.25, '¾': 0.75, '⅓': 1 / 3, '⅔': 2 / 3};

const _maxQuantity = 100000.0;

// A number as people type it: 2, 1.5, 1,5, 1/2, 1 1/2, ½, 1½, .5
const _num = r'(\d+\s+\d+/\d+|\d+/\d+|\d*[½¼¾⅓⅔]|\d+(?:[.,]\d+)?|\.\d+)';

final RegExp _unitAlternatives = RegExp(
  '^(${([..._coreUnits.keys, ..._containerUnits.keys]..sort((a, b) => b.length - a.length)).map(RegExp.escape).join('|')})\\.?(?=\\s|\$)',
  caseSensitive: false,
);

/// A quantity from its text; null when it is not a usable one.
double? parseShoppingNumber(String raw) {
  var s = raw.trim().replaceAll(',', '.');
  if (s.isEmpty) return null;
  double? n;
  final word = _numberWords[s.toLowerCase()];
  if (word != null) {
    n = word;
  } else if (_fractions.containsKey(s)) {
    n = _fractions[s];
  } else if (RegExp(r'^(\d+)([½¼¾⅓⅔])$').firstMatch(s) case final m?) {
    n = int.parse(m.group(1)!) + _fractions[m.group(2)]!;
  } else if (RegExp(r'^(\d+)\s+(\d+)/(\d+)$').firstMatch(s) case final m?) {
    final d = int.parse(m.group(3)!);
    if (d == 0) return null;
    n = int.parse(m.group(1)!) + int.parse(m.group(2)!) / d;
  } else if (RegExp(r'^(\d+)/(\d+)$').firstMatch(s) case final m?) {
    final d = int.parse(m.group(2)!);
    if (d == 0) return null;
    n = int.parse(m.group(1)!) / d;
  } else if (RegExp(r'^(\d+(\.\d+)?|\.\d+)$').hasMatch(s)) {
    n = double.tryParse(s.startsWith('.') ? '0$s' : s);
  }
  if (n == null || !n.isFinite || n <= 0 || n > _maxQuantity) return null;
  return (n * 1000).round() / 1000;
}

/// A unit at the start of [s]: (canonical unit, the words after it,
/// whether it is a container), or null.
(String, String, bool)? _unitAt(String s) {
  final m = _unitAlternatives.firstMatch(s);
  if (m == null) return null;
  final word = m.group(1)!;
  final key = word.toLowerCase();
  // "3M tape": a capital M is a brand, not metres.
  if (key == 'm' && word == 'M') return null;
  final rest = s.substring(m.end).trim();
  final core = _coreUnits[key];
  if (core != null) return (core, rest, false);
  return (_containerUnits[key]!, rest, true);
}

String _dropOf(String s) => s.replaceFirst(RegExp(r'^of\s+', caseSensitive: false), '');

String _tidy(String raw) => raw
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim()
    .replaceFirst(RegExp(r'[.,;:!?]+$'), '')
    .trim();

QuickAddResult _named(String name, {double? quantity, String? unit}) {
  final n = cleanItemName(name);
  if (n.isEmpty) {
    return const QuickAddResult.error('Type what to buy — like “milk” or “2 kg onions”.');
  }
  if (n.length > shoppingNameMax) {
    return const QuickAddResult.error('That name is too long — keep it under 80 letters, and put '
        'size or colour in the details.');
  }
  return QuickAddResult.ok(ShoppingDraft(n, quantity: quantity, unit: unit));
}

/// Reads one typed line: the amount at the front ("2 kg onions",
/// "500g paneer", "a dozen eggs", "2 bottles of oil") or at the end
/// ("onions 2 kg", "Horlicks 500 g", "eggs x 12"); the rest is the name.
QuickAddResult parseQuickAdd(String raw) {
  final s = _tidy(raw);
  if (s.isEmpty) return _named('');

  // "half a dozen eggs", "a dozen eggs"
  final dozen = RegExp(r'^(half\s+a\s+dozen|half\s+dozen|a\s+dozen|dozen)\s+(?:of\s+)?(.+)$',
          caseSensitive: false)
      .firstMatch(s);
  if (dozen != null) {
    final half = dozen.group(1)!.toLowerCase().startsWith('half');
    return half
        ? _named(dozen.group(2)!, quantity: 6)
        : _named(dozen.group(2)!, quantity: 1, unit: 'dozen');
  }

  // A number in front: "2 kg onions", "2kg onions", "3 onions".
  final lead = RegExp('^$_num(\\s*)(.*)\$').firstMatch(s);
  if (lead != null) {
    final q = parseShoppingNumber(lead.group(1)!);
    final gap = lead.group(2)!;
    final rest = lead.group(3)!;
    final firstWord = rest.split(' ').first.toLowerCase();
    if (q != null && rest.isNotEmpty && !_specWords.contains(firstWord)) {
      final u = _unitAt(rest);
      if (u != null) {
        final (unit, after, container) = u;
        final ofFollows = RegExp(r'^of\s+', caseSensitive: false).hasMatch(after);
        if (!container || ofFollows) {
          final name = _dropOf(after);
          if (name.isEmpty) return _named('');
          return _named(name, quantity: q, unit: unit);
        }
      }
      // A bare count needs a space: "7up" and "5star" are names.
      if (gap.isNotEmpty && u == null) {
        return _named(rest.replaceFirst(RegExp(r'^[x×]\s+', caseSensitive: false), ''),
            quantity: q);
      }
      if (gap.isNotEmpty && u != null) {
        // A container without "of" ("1 tube light"): the count, and the
        // words as they were.
        return _named(rest, quantity: q);
      }
    }
    if (q != null && rest.isEmpty) return _named('');
  }

  // A number word in front: "two kg onions", "half kg sugar", "a packet
  // of salt". Only with a unit — "two wheeler cover" is a name.
  final word = RegExp(r'^([a-z]+)\s+(.+)$', caseSensitive: false).firstMatch(s);
  if (word != null) {
    final q = _numberWords[word.group(1)!.toLowerCase()];
    if (q != null) {
      final u = _unitAt(word.group(2)!);
      if (u != null) {
        final (unit, after, container) = u;
        final ofFollows = RegExp(r'^of\s+', caseSensitive: false).hasMatch(after);
        if (!container || ofFollows) {
          final name = _dropOf(after);
          if (name.isNotEmpty) return _named(name, quantity: q, unit: unit);
        }
      }
      // "a pen" -> "Pen"
      final article = word.group(1)!.toLowerCase();
      if (article == 'a' || article == 'an') return _named(word.group(2)!);
    }
  }

  // The amount at the end, with its unit: "onions 2 kg", "Fortune oil, 1 L",
  // "Dolo 650 - 2 strips". A bare number at the end stays in the name.
  final tail = RegExp('^(.*?)[\\s,:\\-–]+$_num\\s*([A-Za-z]+)\\.?\$').firstMatch(s);
  if (tail != null) {
    final name = tail.group(1)!.trim();
    final q = parseShoppingNumber(tail.group(2)!);
    final u = _unitAt(tail.group(3)!);
    if (name.isNotEmpty && q != null && u != null && u.$2.isEmpty) {
      return _named(name, quantity: q, unit: u.$1);
    }
  }
  // "eggs x 12"
  final times = RegExp(r'^(.*?)\s*[x×]\s*(\d+)$', caseSensitive: false).firstMatch(s);
  if (times != null && times.group(1)!.trim().isNotEmpty) {
    final q = parseShoppingNumber(times.group(2)!);
    if (q != null) return _named(times.group(1)!, quantity: q);
  }
  return _named(s);
}

/// The amount box in the edit sheet: '' (no amount), "3", "2 kg",
/// "half kg", "1 packet", "2 bottles". Null when it cannot be read.
({double? quantity, String? unit})? parseAmount(String raw) {
  final s = _tidy(raw);
  if (s.isEmpty) return (quantity: null, unit: null);
  if (RegExp(r'^(a\s+)?dozen$', caseSensitive: false).hasMatch(s)) {
    return (quantity: 1, unit: 'dozen');
  }
  final m = RegExp('^($_num|[a-z]+)\\s*([^\\d\\s].*)?\$', caseSensitive: false).firstMatch(s);
  if (m == null) return null;
  final q = parseShoppingNumber(m.group(1)!);
  if (q == null) return null;
  final unitWords = (m.group(3) ?? '').trim();
  if (unitWords.isEmpty) return (quantity: q, unit: null);
  final u = _unitAt(unitWords);
  if (u != null && u.$2.isEmpty) return (quantity: q, unit: u.$1);
  // Any other unit the server takes: one or two words, at most 20 letters.
  final free = unitWords.toLowerCase();
  if (free.length <= 20 && RegExp(r'^\p{L}[\p{L}\p{M} ]*$', unicode: true).hasMatch(free)) {
    return (quantity: q, unit: free);
  }
  return null;
}
