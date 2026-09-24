import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/screens/business_card_flow.dart';

void main() {
  testWidgets('a scanned card shows who it is and what to do next',
      (tester) async {
    tester.view.physicalSize = const ui.Size(1080, 2340);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: CardResultSheet(person: {
          'name': 'Priya Sharma',
          'title': 'Head of Sales',
          'company': 'Acme Pvt Ltd',
          'phones': ['+919845012345'],
          'emails': ['priya@acme.in'],
          'website': 'acme.in',
          'address': '',
        }),
      ),
    ));

    expect(find.text('Saved to your people'), findsOneWidget);
    expect(find.text('Priya Sharma'), findsOneWidget);
    expect(find.text('Head of Sales · Acme Pvt Ltd'), findsOneWidget);
    expect(find.text('+919845012345'), findsOneWidget);
    expect(find.text('priya@acme.in'), findsOneWidget);
    expect(find.text('Add to phone contacts'), findsOneWidget);
    expect(find.text('Say hello'), findsOneWidget);
    expect(find.text('Call'), findsOneWidget);
  });

  testWidgets('no phone on the card, no Call button', (tester) async {
    tester.view.physicalSize = const ui.Size(1080, 2340);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: CardResultSheet(person: {
          'name': 'Ravi', 'phones': <String>[], 'emails': ['ravi@x.in'],
        }),
      ),
    ));
    expect(find.text('Call'), findsNothing);
    expect(find.text('Say hello'), findsOneWidget);
  });
}
