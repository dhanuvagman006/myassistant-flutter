// Renders the listening orb to a PNG so the design can be checked against
// the reference WITHOUT taking over somebody's phone to look at it.
//   flutter test test/voice_orb_render_test.dart
// writes build/voice_orb_preview.png (listening) and
// build/voice_orb_thinking.png. (The whole voice screen, state by state:
// test/orb_rings_render_test.dart.)
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/widgets/voice_orb.dart';

Future<void> _render(WidgetTester tester, OrbMood mood, String out) async {
  tester.view.physicalSize = const ui.Size(1080, 900);
  tester.view.devicePixelRatio = 2.625;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Center(
        child: RepaintBoundary(
          key: const ValueKey('orb'),
          child: ColoredBox(
            color: const Color(0xFF05070A),
            child: SizedBox(
              width: 411,
              height: 330,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Positioned.fill(
                    child: VoiceOrbBackdrop(
                      orbSize: 168,
                      mood: mood,
                      level: 0.6,
                    ),
                  ),
                  const VoiceOrb(size: 168, label: 'My Assistant'),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
  // Let the eased mood and level settle, frame by frame.
  for (var i = 0; i < 60; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }

  final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('orb')));
  // toImage/toByteData complete on the real engine, which the fake test
  // clock never advances — awaited directly they hang until the 10-minute
  // timeout. runAsync lets them finish.
  final bytes = await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2.625);
    return image.toByteData(format: ui.ImageByteFormat.png);
  });
  expect(bytes, isNotNull);
  expect(bytes!.lengthInBytes, greaterThan(0));
  Directory('build').createSync(recursive: true);
  File(out).writeAsBytesSync(bytes.buffer.asUint8List());
}

void main() {
  testWidgets('listening orb renders', (tester) async {
    await _render(tester, OrbMood.listening, 'build/voice_orb_preview.png');
  });

  testWidgets('thinking orb renders', (tester) async {
    await _render(tester, OrbMood.thinking, 'build/voice_orb_thinking.png');
  });
}
