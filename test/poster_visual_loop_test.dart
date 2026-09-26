import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/features/poster/poster_fonts.dart';
import 'package:myassistant/features/poster/poster_models.dart';
import 'package:myassistant/features/poster/poster_painter.dart';
import 'package:myassistant/features/poster/poster_templates.dart';
import 'package:myassistant/features/poster/signature/signature_model.dart';

import 'poster_test_photos.dart';

/// THE VISUAL QUALITY LOOP (2026-09-26). The owner wants the card to look
/// like a real gift card, so every design is rendered with the real
/// bundled fonts and a synthetic photo, in English, Malayalam and with a
/// long message — and LOOKED AT, not only asserted on.
///
/// Always runs as a smoke test (every design × sample renders, the PNG is
/// 1080 wide, and the words fit). To write the PNGs for a human to look at:
///   flutter test test/poster_visual_loop_test.dart \
///     --dart-define=POSTER_RENDERS=<folder>
/// → <folder>/<design>_<sample>.png
const _out = String.fromEnvironment('POSTER_RENDERS');

const english = PosterSpec(
  name: 'Ananya',
  age: 25,
  headline: 'Happy 25th Birthday',
  message: 'May your year be full of laughter and light.\nWe are so proud of you, always.',
  from: 'Appa',
  date: '26 September 2026',
  signature: true,
  photoUse: 'enhanced',
);

const malayalam = PosterSpec(
  language: 'ml',
  name: 'അനന്യ',
  age: 25,
  headline: 'ജന്മദിനാശംസകൾ',
  message: 'നിനക്ക് എല്ലാ സന്തോഷവും ഐശ്വര്യവും നേരുന്നു.\nഎന്നും ഞങ്ങളുടെ അഭിമാനം നീ.',
  from: 'അച്ഛൻ',
  signature: true,
  photoUse: 'enhanced',
);

// 300 characters and four line breaks: the longest the contract allows.
final long = english.copyWith(
  message: 'My dearest daughter, on your birthday I want you to know how much '
      'joy you have brought to our home since the day you were born.\n'
      'You are kind, brave and clever.\nKeep smiling, keep dreaming, and '
      'never forget that your mother and I are always with you.\nGod bless you.\n'
      'With all our love.',
);

// The longest ordinary date: it ran into the Floral bouquet's leaves.
final longDate = english.copyWith(date: 'Wednesday, 26 September 2026');

/// A signature drawn in code: a tall first letter, looping cursive (a
/// prolate cycloid) and an underline flourish — shaped like a real
/// greeting-card signature, belonging to nobody.
SignatureData sampleSignature() {
  var t = 0;
  List<({ui.Offset p, int t})> stroke(Iterable<ui.Offset> pts) =>
      [for (final p in pts) (p: p, t: t += 14)];
  final strokes = <List<({ui.Offset p, int t})>>[
    stroke([
      for (var i = 0; i <= 20; i++) ui.Offset(18 + i * 1.3, 96 - i * 4.4),
      for (var i = 0; i <= 20; i++) ui.Offset(44 + i * 1.2, 8 + i * 4.2),
    ]),
    stroke([
      for (var th = 0.0; th <= 6 * math.pi; th += 0.12)
        ui.Offset(52 + 13 * th - 20 * math.sin(th),
            64 - 24 * math.cos(th) * (0.75 + 0.25 * math.sin(th / 3))),
    ]),
    stroke([
      for (var i = 0; i <= 30; i++)
        ui.Offset(10 + i * 10.5, 112 + 6 * math.sin(i / 5) - i * 0.3),
    ]),
  ];
  return SignatureData.fromRaw(strokes);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ui.Image portrait;
  late ui.Image group;
  late ui.Image wide;
  final signature = sampleSignature();

  setUpAll(() async {
    await PosterFonts.ensureLoaded();
    portrait = await syntheticPortrait();
    group = await syntheticGroup();
    wide = await syntheticWideGroup();
    if (_out.isNotEmpty) Directory(_out).createSync(recursive: true);
  });

  final samples = <String, PosterSpec>{
    'en': english,
    'ml': malayalam,
    'long': long,
    'date': longDate,
  };

  Future<void> render(String name, PosterScene scene) async {
    final png = await renderPosterPng(scene);
    expect(png.sublist(1, 4), [0x50, 0x4E, 0x47], reason: 'a PNG');
    final bd = ByteData.sublistView(png);
    expect(bd.getUint32(16), 1080, reason: 'width');
    expect(bd.getUint32(20), scene.spec.format == 'story' ? 1920 : 1350, reason: 'height');
    final prepared = preparePoster(scene);
    expect(prepared.needs, isEmpty, reason: '$name: every word fits');
    if (_out.isNotEmpty) File('$_out/$name.png').writeAsBytesSync(png);
  }

  for (final t in posterTemplateList) {
    for (final e in samples.entries) {
      test('${t.id} × ${e.key}', () async {
        final spec = e.value.copyWith(design: t.id, colour: designHomeColour[t.id]);
        await render('${t.id}_${e.key}',
            PosterScene(spec: spec, photo: portrait, signature: signature, seed: 7));
      });
    }
    test('${t.id} × story', () async {
      final spec = english.copyWith(
          design: t.id, colour: designHomeColour[t.id], format: 'story');
      await render('${t.id}_story',
          PosterScene(spec: spec, photo: portrait, signature: signature, seed: 7));
    });
    test('${t.id} × landscape group photo', () async {
      final spec = english.copyWith(design: t.id, colour: designHomeColour[t.id]);
      await render('${t.id}_group',
          PosterScene(spec: spec, photo: group, signature: signature, seed: 7));
    });
    test('${t.id} × no photo', () async {
      final spec = english.copyWith(
          design: t.id, colour: designHomeColour[t.id], photoUse: 'none');
      await render('${t.id}_nophoto', PosterScene(spec: spec, signature: signature, seed: 7));
    });

    // A 16:9 family photo: by default every face shows, the ones at the
    // very ends included — inside the frame's own shape, not only its box.
    for (final f in posterFormats) {
      test('${t.id} × 16:9 family in a row ($f): no face cut by default', () async {
        final spec = english.copyWith(design: t.id, colour: designHomeColour[t.id], format: f);
        final scene = PosterScene(spec: spec, photo: wide, signature: signature, seed: 7);
        await render('${t.id}_wide${f == 'story' ? '_story' : ''}', scene);
        final prepared = preparePoster(scene);
        final frame = prepared.layout.frame!;
        final clip = framePath(prepared.layout.shape, frame);
        final place = photoPlacement(wide, frame, spec.photoFocus);
        for (var i = 0; i < wideGroupFaces.length; i++) {
          final fx = wideGroupFaces[i] * wide.width;
          final fy = (0.36 + (i % 2) * 0.04) * wide.height;
          final half = wide.width * 0.034; // the face's own half-width
          for (final px in [fx - half, fx, fx + half]) {
            expect(px, greaterThanOrEqualTo(place.src.left), reason: 'face $i cut at the left');
            expect(px, lessThanOrEqualTo(place.src.right), reason: 'face $i cut at the right');
            final on = Offset(
              place.dst.left + (px - place.src.left) / place.src.width * place.dst.width,
              place.dst.top + (fy - place.src.top) / place.src.height * place.dst.height,
            );
            expect(clip.contains(on), isTrue, reason: 'face $i outside the ${prepared.layout.shape}');
          }
        }
        // "Closer" still crops in, from the whole photo.
        final closer = photoPlacement(wide, frame, const PhotoFocus(zoom: 2));
        expect(closer.src.width, lessThan(place.src.width));
      });
    }

    // No flower, balloon, garland or sparkle ever lies on a word: every
    // design drawn with and without its ornaments must be the same, pixel
    // for pixel, inside every line of text.
    for (final e in {
      ...samples,
      'story': english.copyWith(format: 'story'),
      'group': english,
      'wide': english,
      'nophoto': english.copyWith(photoUse: 'none'),
    }.entries) {
      test('${t.id} × ${e.key}: no ornament on any word', () async {
        final spec = e.value.copyWith(design: t.id, colour: designHomeColour[t.id]);
        final photo = switch (e.key) {
          'group' => group,
          'wide' => wide,
          'nophoto' => null,
          _ => portrait,
        };
        final r = preparePoster(
            PosterScene(spec: spec, photo: photo, signature: signature, seed: 7));
        final w = r.size.width.round(), h = r.size.height.round();
        Future<Uint8List> raw({required bool ornaments}) async {
          final rec = ui.PictureRecorder();
          paintPoster(Canvas(rec, Offset.zero & r.size), r, ornaments: ornaments, words: false);
          final img = await rec.endRecording().toImage(w, h);
          final bd = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
          img.dispose();
          return bd!.buffer.asUint8List();
        }

        final plain = await raw(ornaments: false);
        final full = await raw(ornaments: true);
        final hits = <String>[];
        for (final b in r.layout.blocks) {
          for (final line in b.lines) {
            final box = line.deflate(1);
            var n = 0;
            for (var y = math.max(0, box.top.floor()); y < math.min(h, box.bottom.ceil()); y++) {
              for (var x = math.max(0, box.left.floor()); x < math.min(w, box.right.ceil()); x++) {
                final i = (y * w + x) * 4;
                if ((plain[i] - full[i]).abs() > 24 ||
                    (plain[i + 1] - full[i + 1]).abs() > 24 ||
                    (plain[i + 2] - full[i + 2]).abs() > 24) {
                  n++;
                }
              }
            }
            if (n > 0) hits.add('${b.field} "${b.text}" ($n px)');
          }
        }
        expect(hits, isEmpty, reason: 'ornaments over words');
      });
    }
  }

  // Every colour in the designs where foil words and flowers meet, to judge
  // the palettes side by side (blue and purple once turned the gold grey).
  for (final t in [
    'floral_blush',
    'royal_mandala',
    'garden_green',
    'classic_ivory',
    'balloons_confetti',
  ]) {
    for (final colour in posterColours) {
      test('$t in $colour', () async {
        final spec = english.copyWith(design: t, colour: colour);
        await render('${t}_colour_$colour',
            PosterScene(spec: spec, photo: portrait, signature: signature, seed: 7));
      });
    }
  }
}
