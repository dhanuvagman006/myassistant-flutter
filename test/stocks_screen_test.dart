// Markets: a missing field is an empty spot, never a crash; and nothing
// on the screen reads as a recommendation to buy or sell.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/screens/stocks_screen.dart';

void main() {
  Future<void> show(WidgetTester tester, Map<String, dynamic> data) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: StocksScreen(loader: () async => data)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('says plainly that it is not investment advice', (tester) async {
    await show(tester, {
      'invest': [
        {'symbol': 'INFY', 'name': 'Infosys', 'change': '+2.1%', 'reason': 'Strong quarter', 'price': 1500}
      ],
      'sell': [
        {'symbol': 'XYZ', 'name': 'Xyz Ltd', 'change': '-3%', 'reason': 'Weak guidance'}
      ],
      'news': [],
    });
    expect(find.textContaining('not investment advice'), findsOneWidget);
    expect(find.textContaining('(Buy)'), findsNothing);
    expect(find.textContaining('to Sell'), findsNothing);
    expect(find.text('GAINING MOMENTUM'), findsOneWidget); // GroupLabel uppercases
    expect(find.text('INFY'), findsOneWidget);
  });

  testWidgets('fields the server left out do not crash the screen', (tester) async {
    await show(tester, {
      // no 'sell', no 'news', no 'summary'; items missing fields
      'invest': [
        {'symbol': 'TCS'},
        {'name': 'No symbol', 'change': null},
        'not even a map',
      ],
      'indices': [
        {'name': 'NIFTY 50', 'price': 24123.5}
      ],
    });
    expect(tester.takeException(), isNull);
    expect(find.text('TCS'), findsOneWidget);
    expect(find.text('NIFTY 50'), findsOneWidget);
  });
}
