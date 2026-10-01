// QUICK ADD (build 124): what a typed line means. The amount is read out of
// the words; everything else stays the name as typed — sizes, colours and
// model numbers are never mistaken for an amount.
import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/features/shopping/shopping_models.dart';
import 'package:myassistant/features/shopping/shopping_parse.dart';

void main() {
  (String, double?, String?) read(String s) {
    final r = parseQuickAdd(s);
    expect(r.error, isNull, reason: s);
    final d = r.draft!;
    return (d.name, d.quantity, d.unit);
  }

  group('an amount in front', () {
    test('number, unit, name', () {
      expect(read('2 kg onions'), ('Onions', 2.0, 'kg'));
      expect(read('2kg onions'), ('Onions', 2.0, 'kg'));
      expect(read('500g paneer'), ('Paneer', 500.0, 'g'));
      expect(read('1.5 l milk'), ('Milk', 1.5, 'l'));
      expect(read('1,5 L milk'), ('Milk', 1.5, 'l'));
      expect(read('2 packets of biscuits'), ('Biscuits', 2.0, 'packet'));
      expect(read('1 bunch coriander'), ('Coriander', 1.0, 'bunch'));
      expect(read('3 pcs lemons'), ('Lemons', 3.0, 'piece'));
      expect(read('2 kg of rice'), ('Rice', 2.0, 'kg'));
    });

    test('fractions and mixed numbers', () {
      expect(read('½ kg paneer'), ('Paneer', 0.5, 'kg'));
      expect(read('1½ kg rice'), ('Rice', 1.5, 'kg'));
      expect(read('1 1/2 kg rice'), ('Rice', 1.5, 'kg'));
      expect(read('1/2 kg dal'), ('Dal', 0.5, 'kg'));
    });

    test('a count with no unit', () {
      expect(read('3 onions'), ('Onions', 3.0, null));
      expect(read('12 eggs'), ('Eggs', 12.0, null));
      expect(read('2 x milk'), ('Milk', 2.0, null));
      expect(read('2 lemons'), ('Lemons', 2.0, null), reason: '"l" is not litres here');
      expect(read('1 medium onion'), ('Medium onion', 1.0, null));
    });

    test('containers need "of" — "tube light" is a thing, not a tube of light', () {
      expect(read('2 bottles of oil'), ('Oil', 2.0, 'bottle'));
      expect(read('2 strips of Dolo 650'), ('Dolo 650', 2.0, 'strip'));
      expect(read('1 pair of socks'), ('Socks', 1.0, 'pair'));
      expect(read('1 tube light'), ('Tube light', 1.0, null));
      expect(read('1 can opener'), ('Can opener', 1.0, null));
    });

    test('number words only with a unit', () {
      expect(read('two kg onions'), ('Onions', 2.0, 'kg'));
      expect(read('half kg sugar'), ('Sugar', 0.5, 'kg'));
      expect(read('a packet of salt'), ('Salt', 1.0, 'packet'));
      expect(read('a dozen eggs'), ('Eggs', 1.0, 'dozen'));
      expect(read('dozen bananas'), ('Bananas', 1.0, 'dozen'));
      expect(read('half a dozen eggs'), ('Eggs', 6.0, null));
      expect(read('two wheeler cover'), ('Two wheeler cover', null, null));
      expect(read('a pen'), ('Pen', null, null));
    });
  });

  group('an amount at the end', () {
    test('with its unit', () {
      expect(read('onions 2 kg'), ('Onions', 2.0, 'kg'));
      expect(read('onions 2kg'), ('Onions', 2.0, 'kg'));
      expect(read('Horlicks 500 g'), ('Horlicks', 500.0, 'g'));
      expect(read('Fortune oil, 1 L'), ('Fortune oil', 1.0, 'l'));
      expect(read('Dolo 650 - 2 strips'), ('Dolo 650', 2.0, 'strip'));
      expect(read('eggs x 12'), ('Eggs', 12.0, null));
    });
  });

  group('names that only look like amounts stay names', () {
    test('models, sizes, specs and brands', () {
      expect(read('Dolo 650'), ('Dolo 650', null, null));
      expect(read('Dolo 650 mg'), ('Dolo 650 mg', null, null));
      expect(read('iPhone 15 case'), ('iPhone 15 case', null, null));
      expect(read('55 inch TV'), ('55 inch TV', null, null));
      expect(read('Samsung 55 inch TV'), ('Samsung 55 inch TV', null, null));
      expect(read('256 GB pen drive'), ('256 GB pen drive', null, null));
      expect(read('2 in 1 shampoo'), ('2 in 1 shampoo', null, null));
      expect(read('7up'), ('7up', null, null));
      expect(read('3M tape'), ('3M tape', null, null));
      expect(read('5 star chocolate'), ('5 star chocolate', null, null));
      expect(read('3 seater sofa'), ('3 seater sofa', null, null));
    });

    test('the words people use for clothes and things', () {
      expect(read('milk'), ('Milk', null, null));
      expect(read('blue kurti size M'), ('Blue kurti size M', null, null));
      expect(read('kurti M'), ('Kurti M', null, null));
      expect(read('shoes size 9'), ('Shoes size 9', null, null));
      expect(read('  phone charger.  '), ('Phone charger', null, null));
    });
  });

  group('what cannot be added says why', () {
    test('no name', () {
      expect(parseQuickAdd('').error, contains('Type what to buy'));
      expect(parseQuickAdd('2 kg').error, contains('Type what to buy'));
      expect(parseQuickAdd('   ').draft, isNull);
    });

    test('too long a name', () {
      final r = parseQuickAdd('a' * 90);
      expect(r.draft, isNull);
      expect(r.error, contains('80'));
    });

    test('the body the server gets carries only what was said', () {
      expect(parseQuickAdd('milk').draft!.toJson(), {'name': 'Milk'});
      expect(parseQuickAdd('2 kg onions').draft!.toJson(),
          {'name': 'Onions', 'quantity': 2.0, 'unit': 'kg'});
    });
  });

  group('the amount box (edit sheet)', () {
    test('reads what people type', () {
      expect(parseAmount(''), (quantity: null, unit: null));
      expect(parseAmount('3'), (quantity: 3.0, unit: null));
      expect(parseAmount('2 kg'), (quantity: 2.0, unit: 'kg'));
      expect(parseAmount('2kg'), (quantity: 2.0, unit: 'kg'));
      expect(parseAmount('half kg'), (quantity: 0.5, unit: 'kg'));
      expect(parseAmount('1 packet'), (quantity: 1.0, unit: 'packet'));
      expect(parseAmount('2 bottles'), (quantity: 2.0, unit: 'bottle'));
      expect(parseAmount('a dozen'), (quantity: 1.0, unit: 'dozen'));
      expect(parseAmount('3 boxes'), (quantity: 3.0, unit: 'box'));
      expect(parseAmount('2 sarees'), (quantity: 2.0, unit: 'sarees'),
          reason: 'any word unit the server takes');
    });

    test('refuses what it cannot read', () {
      expect(parseAmount('kg'), isNull);
      expect(parseAmount('lots'), isNull);
      expect(parseAmount('0 kg'), isNull);
      expect(parseAmount('1.5 kg + 2 pcs'), isNull);
      expect(parseAmount('999999 kg'), isNull);
    });
  });

  group('numbers and amounts as the server writes them', () {
    test('parseShoppingNumber', () {
      expect(parseShoppingNumber('2'), 2);
      expect(parseShoppingNumber('.5'), 0.5);
      expect(parseShoppingNumber('⅓'), closeTo(0.333, 0.001));
      expect(parseShoppingNumber('1/0'), isNull);
      expect(parseShoppingNumber('0'), isNull);
      expect(parseShoppingNumber('abc'), isNull);
    });

    test('amountTextOf matches the server', () {
      expect(amountTextOf(2, 'kg'), '2 kg');
      expect(amountTextOf(1.5, 'l'), '1.5 L');
      expect(amountTextOf(1, 'piece'), '1 pc');
      expect(amountTextOf(3, 'piece'), '3 pcs');
      expect(amountTextOf(2, 'packet'), '2 packets');
      expect(amountTextOf(2, 'box'), '2 boxes');
      expect(amountTextOf(1, 'strip'), '1 strip');
      expect(amountTextOf(3, null), '3');
      expect(amountTextOf(null, 'kg'), '');
      expect(amountTextOf(0.333, 'kg'), '0.33 kg');
    });

    test('cleanItemName tidies like the server', () {
      expect(cleanItemName('  onion. '), 'Onion');
      expect(cleanItemName('- milk'), 'Milk');
      expect(cleanItemName('iPhone charger'), 'iPhone charger');
      expect(cleanItemName('Dolo   650'), 'Dolo 650');
    });
  });
}
