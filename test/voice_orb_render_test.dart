// Renders the listening orb to a PNG so the design can be checked against
// the reference WITHOUT taking over somebody's phone to look at it.
//   flutter test test/voice_orb_render_test.dart
// writes build/voice_orb_preview.png
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/widgets/voice_orb.dart';

void main() {
  testWidgets('listening orb renders', (tester) async {
    tester.view.physicalSize = const ui.Size(1080, 900);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Center(
          child: RepaintBoundary(
            key: ValueKey('orb'),
            child: ColoredBox(
              color: Color(0xFF05070A),
              child: SizedBox(
                width: 411,
                height: 330,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Positioned.fill(
                      child: VoiceOrbBackdrop(
                        orbSize: 168,
                        mood: OrbMood.listening,
                        level: 0.55,
                      ),
                    ),
                    VoiceOrb(size: 168, mood: OrbMood.listening, level: 0.55),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 600));

    final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('orb')));
    final image = await boundary.toImage(pixelRatio: 2.625);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    Directory('build').createSync(recursive: true);
    File('build/voice_orb_preview.png')
        .writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}
