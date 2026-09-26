import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/features/poster/signature/signature_model.dart';
import 'package:myassistant/features/poster/signature/signature_pad.dart';
import 'package:myassistant/features/poster/signature/signature_store.dart';

/// HIS SIGNATURE: drawn once with a finger, kept as lines on this phone
/// only (2026-09-26), redrawn sharp in the card's own ink.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  SignatureData sample() => SignatureData.fromRaw([
        [(p: const Offset(10, 50), t: 0), (p: const Offset(60, 10), t: 30), (p: const Offset(110, 60), t: 60)],
        [(p: const Offset(20, 80), t: 100), (p: const Offset(210, 70), t: 160)],
      ]);

  test('strokes are normalised into their own box, keeping the shape', () {
    final s = sample();
    expect(s.strokes.length, 2);
    expect(s.aspect, closeTo(200 / 70, 0.01));
    for (final st in s.strokes) {
      for (final p in st) {
        expect(p.x, inInclusiveRange(0, 1));
        expect(p.y, inInclusiveRange(0, 1));
      }
    }
    // The very first touch is kept (a Listener, not a drag, records it).
    expect(s.strokes.first.first.x, 0);
    expect(s.strokes.first.first.t, 0);
  });

  test('the vector JSON round-trips exactly (contract §6)', () {
    final s = sample();
    final j = s.toJson();
    expect(j['v'], 1);
    expect(j['kind'], 'drawn');
    final back = SignatureData.decode(s.encode())!;
    expect(back.aspect, closeTo(s.aspect, 1e-4));
    for (var i = 0; i < s.strokes.length; i++) {
      for (var k = 0; k < s.strokes[i].length; k++) {
        expect(back.strokes[i][k].x, closeTo(s.strokes[i][k].x, 1e-4));
        expect(back.strokes[i][k].y, closeTo(s.strokes[i][k].y, 1e-4));
        expect(back.strokes[i][k].t, s.strokes[i][k].t);
      }
    }
    expect(SignatureData.decode(''), isNull);
    expect(SignatureData.decode('not json'), isNull);
  });

  test('kept in secure storage under the contract key; delete removes it', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final store = SignatureStore();
    expect(await store.load(), isNull);
    expect(await store.save(sample()), isTrue);
    final fresh = SignatureStore();
    final loaded = await fresh.load();
    expect(loaded, isNotNull);
    expect(loaded!.strokes.length, 2);
    expect(await const FlutterSecureStorage().read(key: SignatureStore.key), isNotNull);
    await fresh.delete();
    expect(fresh.current, isNull);
    expect(await const FlutterSecureStorage().read(key: SignatureStore.key), isNull);
  });

  Future<List<int>> render(SignatureData s, Color ink) async {
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    c.drawColor(const Color(0xFFFFFFFF), BlendMode.src);
    s.paint(c, const Rect.fromLTWH(0, 0, 300, 100), ink);
    final img = await rec.endRecording().toImage(300, 100);
    final bd = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    return bd!.buffer.asUint8List();
  }

  test('it paints inside its box, in the ink it is given', () async {
    final px = await render(sample(), const Color(0xFFAA0000));
    var inked = 0, reddish = 0;
    for (var i = 0; i < px.length; i += 4) {
      // Ignore the faint antialiased fringe; judge the ink itself.
      if (765 - (px[i] + px[i + 1] + px[i + 2]) > 90) {
        inked++;
        if (px[i] > px[i + 1] + 40) reddish++;
      }
    }
    expect(inked, greaterThan(150));
    expect(reddish / inked, greaterThan(0.9));
    // Deterministic: the same lines always draw the same pixels.
    expect(await render(sample(), const Color(0xFFAA0000)), px);
  });

  testWidgets('the pad records from the first touch, clears, and saves', (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    final store = SignatureStore();
    SignatureData? saved;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async => saved = await SignaturePadScreen.open(context, store: store),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final pad = find.byKey(const Key('signature-pad'));
    final state = tester.state<SignaturePadState>(find.byType(SignaturePadScreen));
    final origin = tester.getTopLeft(pad);

    // One tiny tap is not a signature.
    await tester.tapAt(origin + const Offset(40, 40));
    await tester.pump();
    expect(state.strokes.length, 1);
    expect(state.strokes.first.first.p, const Offset(40, 40));
    expect(state.canSave, isFalse);

    await tester.tap(find.text('Clear'));
    await tester.pump();
    expect(state.strokes, isEmpty);

    // A real stroke: its very first point is kept.
    final g = await tester.startGesture(origin + const Offset(30, 120));
    for (var i = 1; i <= 12; i++) {
      await g.moveTo(origin + Offset(30 + i * 12.0, 120 - (i % 3) * 10.0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await tester.pump();
    expect(state.strokes.first.first.p, const Offset(30, 120));
    expect(state.canSave, isTrue);

    await tester.tap(find.text('Save my signature'));
    await tester.pumpAndSettle();
    expect(saved, isNotNull);
    expect(store.current, isNotNull);
    expect(saved!.strokes.first.length, greaterThan(5));
  });

  testWidgets('a palm or second finger on the pad never joins the signature', (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    await tester.pumpWidget(const MaterialApp(home: SignaturePadScreen()));
    await tester.pumpAndSettle();
    final pad = find.byKey(const Key('signature-pad'));
    final state = tester.state<SignaturePadState>(find.byType(SignaturePadScreen));
    final origin = tester.getTopLeft(pad);

    final pen = await tester.startGesture(origin + const Offset(30, 120), pointer: 1);
    await pen.moveTo(origin + const Offset(40, 115));
    // The palm comes down far away while he signs.
    final palm = await tester.startGesture(origin + const Offset(300, 300), pointer: 2);
    for (var i = 1; i <= 8; i++) {
      await pen.moveTo(origin + Offset(40 + i * 10.0, 115));
      await palm.moveTo(origin + Offset(300 + i * 2.0, 300));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await palm.up();
    await pen.up();
    await tester.pump();

    expect(state.strokes.length, 1, reason: 'the palm starts no stroke');
    for (final pt in state.strokes.single) {
      expect(pt.p.dy, lessThan(200), reason: 'no point from the palm: ${pt.p}');
    }
    // Lifted: the next touch is a new stroke of the pen.
    final again = await tester.startGesture(origin + const Offset(60, 150), pointer: 3);
    await again.moveTo(origin + const Offset(90, 140));
    await again.up();
    await tester.pump();
    expect(state.strokes.length, 2);
  });
}
