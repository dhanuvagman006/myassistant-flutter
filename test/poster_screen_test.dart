import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/features/poster/poster_controller.dart';
import 'package:myassistant/features/poster/poster_fonts.dart';
import 'package:myassistant/features/poster/poster_models.dart';
import 'package:myassistant/features/poster/poster_screen.dart';
import 'package:myassistant/features/poster/signature/signature_store.dart';

import 'poster_fakes.dart';

/// THE CARD SCREEN AT HIS TEXT SIZE (2026-09-26). An elderly father runs
/// the phone's text large: nothing may overflow, and every control must be
/// a real target — at least 64 dp, with words on it, not just an icon.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakePosterApi api;
  late PosterController c;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    api = FakePosterApi();
    c = PosterController(api: api, sharer: ShareSpy().install(), signatures: SignatureStore());
  });

  Future<void> pump(WidgetTester tester, {double scale = 2.0}) async {
    await tester.runAsync(() async {
      await PosterFonts.ensureLoaded();
      api.photoPng = await tinyPng();
      await c.startNew();
      c.apply(const PosterChange(set: {
        'name': 'Ananya',
        'message': 'May your year be full of laughter and light.',
        'from': 'Appa',
      }));
      await c.addPhoto(PickedPhoto(await tinyPng()));
      await c.settle();
    });
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
          size: const Size(1080 / 2.75, 2400 / 2.75),
          textScaler: TextScaler.linear(scale),
        ),
        child: PosterScreen(controller: c, voiceBar: false),
      ),
    ));
    await tester.pump();
  }

  testWidgets('at 2× text nothing overflows and every button is big, with words', (tester) async {
    await pump(tester);
    // Scroll the whole page so every section is built and checked.
    final list = find.byType(Scrollable).first;
    for (var i = 0; i < 30; i++) {
      expect(tester.takeException(), isNull);
      for (final e in find.byWidgetPredicate((w) => w is ButtonStyleButton).evaluate()) {
        final box = e.renderObject as RenderBox;
        if (!box.hasSize || !box.attached) continue;
        expect(box.size.height, greaterThanOrEqualTo(64), reason: '${e.widget}');
        expect(box.size.width, greaterThanOrEqualTo(64), reason: '${e.widget}');
        final texts = find.descendant(of: find.byWidget(e.widget), matching: find.byType(Text));
        expect(texts, findsWidgets, reason: 'a button with no words: ${e.widget}');
      }
      await tester.drag(list, const Offset(0, -300));
      await tester.pump();
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('the Send on WhatsApp button is there, and tapping a line edits it', (tester) async {
    await pump(tester, scale: 1.0);
    expect(find.text('Send on WhatsApp'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Appa'), 200,
        scrollable: find.byType(Scrollable).first);
    await tester.ensureVisible(find.text('Appa'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Appa'));
    await tester.pumpAndSettle();
    expect(find.text('Who it is from'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Amma and Appa');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(c.spec.from, 'Amma and Appa');
  });

  testWidgets('saving the automatic heading untouched does not freeze it', (tester) async {
    await pump(tester, scale: 1.0);
    c.apply(const PosterChange(set: {'age': 25}));
    await tester.pump();
    await tester.scrollUntilVisible(find.text('Heading'), 200,
        scrollable: find.byType(Scrollable).first);
    await tester.ensureVisible(find.text('Heading'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Heading'));
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, '', reason: 'the automatic heading is a hint, not his words');
    expect(field.decoration!.hintText, 'Happy 25th Birthday');
    final before = api.calls.length;
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(c.spec.headlineCustom, isFalse);
    expect(api.calls.skip(before).where((x) => x.contains('headline')), isEmpty);
    // She turns 26: the heading follows.
    c.apply(const PosterChange(set: {'age': 26}));
    await tester.pump();
    expect(c.spec.printedHeadline, 'Happy 26th Birthday');
  });

  testWidgets('photo colour chips follow the CARD\'s photo colour', (tester) async {
    await pump(tester, scale: 1.0);
    await tester.scrollUntilVisible(find.text('Black & white'), 200,
        scrollable: find.byType(Scrollable).first);
    await tester.ensureVisible(find.text('Black & white'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Black & white'));
    await tester.pump();
    expect(c.spec.photoColour, 'bw');
    await tester.runAsync(() => c.settle());
    expect(api.calls, contains('patch:{"photoColour":"bw"}'));
    expect(api.calls.where((x) => x.startsWith('colour:')), isEmpty);
  });

  testWidgets('a design tile changes the design; a colour chip the colour', (tester) async {
    await pump(tester, scale: 1.0);
    await tester.scrollUntilVisible(find.text('Golden Celebration'), 200,
        scrollable: find.byType(Scrollable).first);
    await tester.ensureVisible(find.text('Golden Celebration'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Golden Celebration'));
    await tester.pump();
    expect(c.spec.design, 'golden_celebration');
    expect(c.spec.colour, 'gold');
    await tester.scrollUntilVisible(find.text('Purple'), 200,
        scrollable: find.byType(Scrollable).first);
    await tester.ensureVisible(find.text('Purple'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Purple'));
    await tester.pump();
    expect(c.spec.colour, 'purple');
    expect(c.spec.colourCustom, isTrue);
  });
}
