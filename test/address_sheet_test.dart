import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:myassistant/features/people/address_sheet.dart';
import 'package:myassistant/services/app_feedback.dart';
import 'package:myassistant/services/avatar_message_service.dart';

// 2026-09-30: "remember Ravi's house address" … "what's Ravi's address" —
// the server's show_address directive opens this sheet.
const _addr = '12, 3rd Cross, Indiranagar, Bengaluru 560038';

Future<void> _app(WidgetTester t) async {
  await t.pumpWidget(MaterialApp(
    navigatorKey: AvatarMessageService.navigatorKey,
    scaffoldMessengerKey: AppFeedback.messengerKey,
    home: const Scaffold(body: SizedBox()),
  ));
}

Future<void> _open(WidgetTester t, Map<String, dynamic> directive) async {
  await _app(t);
  // The engine's own entry (the 'show_address' case calls it unawaited).
  AddressSheet.fromDirective(directive);
  await t.pumpAndSettle();
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  final launched = <Uri>[];
  final shared = <String>[];
  setUp(() {
    launched.clear();
    shared.clear();
    AddressSheet.launch = (u) async {
      launched.add(u);
      return true;
    };
    AddressSheet.share = (s) async => shared.add(s);
  });

  testWidgets('the directive opens the sheet: name, label and address', (t) async {
    await _open(t, {
      'type': 'show_address',
      'name': 'Ravi Kumar',
      'label': 'home',
      'address': _addr,
      'saved': false,
    });
    expect(AddressSheet.isOpen, isTrue);
    expect(find.text('Ravi Kumar'), findsOneWidget);
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Address'), findsOneWidget);
    expect(find.text(_addr), findsOneWidget);
    expect(find.byType(SelectableText), findsOneWidget);
    expect(find.text('Open in Maps'), findsOneWidget);
    expect(find.text('Share'), findsOneWidget);
    expect(find.text('Copy'), findsOneWidget);
    expect(find.textContaining('Call'), findsNothing, reason: 'no phone on file');
  });

  testWidgets('saved shows "Saved", and a phone on file adds Call <first name>', (t) async {
    await _open(t, {
      'type': 'show_address',
      'name': 'Ravi Kumar',
      'label': 'office',
      'address': _addr,
      'phone': '+91 98450 12345',
      'saved': true,
    });
    expect(find.text('Saved'), findsOneWidget);
    expect(find.text('Office'), findsOneWidget);
    expect(find.text('Call Ravi'), findsOneWidget);
    await t.tap(find.text('Call Ravi'));
    await t.pump();
    expect(launched.single, Uri.parse('tel:+919845012345'));
  });

  testWidgets('Open in Maps searches Google Maps for the address', (t) async {
    await _open(t, {'name': 'Ravi', 'label': 'home', 'address': _addr});
    await t.tap(find.text('Open in Maps'));
    await t.pump();
    expect(launched.single.toString(),
        'https://www.google.com/maps/search/?api=1&query=${Uri.encodeComponent(_addr)}');
    expect(launched.single.queryParameters['query'], _addr);
  });

  testWidgets('Copy puts the address on the clipboard; Share sends name and address',
      (t) async {
    String? copied;
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (c) async {
      if (c.method == 'Clipboard.setData') copied = (c.arguments as Map)['text'] as String;
      return null;
    });
    addTearDown(() =>
        t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await _open(t, {'name': 'Ravi', 'label': 'home', 'address': _addr});
    await t.tap(find.text('Copy'));
    await t.pump();
    expect(copied, _addr);
    expect(find.text('Copied'), findsOneWidget);
    await t.tap(find.text('Share'));
    await t.pump();
    expect(shared.single, 'Ravi — Home address:\n$_addr');
    await t.pump(const Duration(seconds: 3));
  });

  testWidgets('a second address while the sheet is up replaces it in place', (t) async {
    await _open(t, {'name': 'Ravi', 'label': 'home', 'address': _addr});
    AddressSheet.fromDirective({'name': 'Meena', 'label': 'shop', 'address': '4 MG Road'});
    await t.pumpAndSettle();
    expect(find.text('Meena'), findsOneWidget);
    expect(find.text('4 MG Road'), findsOneWidget);
    expect(find.text('Ravi'), findsNothing);
  });

  testWidgets('no address, no sheet', (t) async {
    await _open(t, {'name': 'Ravi', 'label': 'home', 'address': ''});
    expect(AddressSheet.isOpen, isFalse);
    expect(find.text('Open in Maps'), findsNothing);
  });

  testWidgets('large text: the buttons wrap instead of overflowing', (t) async {
    t.view.devicePixelRatio = 2.625;
    t.view.physicalSize = const Size(1080, 2340);
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      navigatorKey: AvatarMessageService.navigatorKey,
      builder: (c, child) => MediaQuery(
          data: MediaQuery.of(c).copyWith(textScaler: const TextScaler.linear(1.6)),
          child: child!),
      home: const Scaffold(body: SizedBox()),
    ));
    AddressSheet.fromDirective(
        {'name': 'Ravi Kumar', 'label': 'home', 'address': _addr, 'phone': '9845012345'});
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    expect(find.text('Call Ravi'), findsOneWidget);
    for (final label in ['Open in Maps', 'Share', 'Copy', 'Call Ravi']) {
      final size = t.getSize(find.ancestor(
              of: find.text(label), matching: find.byType(GestureDetector))
          .first);
      expect(size.height, greaterThanOrEqualTo(48), reason: label);
    }
  });
}
