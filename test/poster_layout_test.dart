import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/features/poster/poster_fonts.dart';
import 'package:myassistant/features/poster/poster_layout.dart';
import 'package:myassistant/features/poster/poster_models.dart';
import 'package:myassistant/features/poster/poster_painter.dart';
import 'package:myassistant/features/poster/poster_palettes.dart';
import 'package:myassistant/features/poster/poster_templates.dart';

import 'poster_fakes.dart';

/// HIS WORDS ARE NEVER CUT (2026-09-26). Every line is laid out whole: it
/// shrinks, the photo gives up room, and if it still cannot fit the card
/// says which line to shorten — no ellipsis, no clipping, no word broken.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => PosterFonts.ensureLoaded());

  const longest = PosterSpec(
    name: 'Ananya Lakshmi Narayanan Pillai',
    age: 25,
    message: 'My dearest daughter, on your birthday I want you to know how much joy you have '
        'brought to our home since the day you were born.\nYou are kind, brave and clever.\n'
        'Keep smiling, keep dreaming, and never forget that your mother and I are always with '
        'you.\nGod bless you.\nWith all our love.',
    from: 'Appa, Amma, Ammamma, Appooppan and everyone at home',
    date: '26 September 2026',
    textScale: textScaleMax,
  );

  PosterLayout lay(PosterSpec s, {double? photo, double? sig}) {
    final t = posterTemplate(s.design);
    return layoutPoster(
      spec: s,
      t: t.layout(s.format),
      shapeFor: t.shapeFor,
      palette: posterPalette(s.colour, deep: t.deepFor(s.colour)),
      photoAspect: photo,
      signatureAspect: sig,
    );
  }

  test('the longest message at the largest size is laid out whole, in every design and size', () {
    expect(longest.message.length, lessThanOrEqualTo(300));
    for (final t in posterTemplateList) {
      for (final f in posterFormats) {
        final s = longest.copyWith(design: t.id, format: f);
        final l = lay(s, photo: 0.75, sig: 3);
        final where = '${t.id}/$f';
        expect(l.needs, isEmpty, reason: '$where: fits');
        // Exactly his words, every line of them.
        expect(l.block('message')!.text, s.message, reason: where);
        expect(l.block('name')!.text, s.name, reason: where);
        expect(l.block('from')!.text, s.from, reason: where);
        // Nothing drawn off the card.
        final card = Offset.zero & l.size;
        for (final b in l.blocks) {
          for (final line in b.lines) {
            expect(card.contains(line.topLeft) && card.contains(line.bottomRight), isTrue,
                reason: '$where ${b.field} line $line');
          }
        }
        // Words never overlap the photo's frame or each other.
        for (final b in l.blocks) {
          expect(b.rect.overlaps(l.frame!), isFalse, reason: '$where ${b.field} vs photo');
        }
        for (var i = 1; i < l.blocks.length; i++) {
          expect(l.blocks[i].rect.top, greaterThanOrEqualTo(l.blocks[i - 1].rect.bottom - 0.5),
              reason: '$where ${l.blocks[i].field}');
        }
      }
    }
  });

  test('a painter for any line never ellipsises or exceeds its lines', () {
    final t = posterTemplate('floral_blush');
    final l = lay(longest, photo: 0.75);
    for (final b in l.blocks) {
      final p = buildLinePainter(b.text, b.role, b.fontSize, posterPalette('pink'), prefix: b.prefix)
        ..layout(minWidth: b.width, maxWidth: b.width);
      expect(p.didExceedMaxLines, isFalse);
      expect(p.plainText, '${b.prefix}${b.text}');
      expect(p.minIntrinsicWidth, lessThanOrEqualTo(b.width + 0.5),
          reason: '${b.field}: a word would break in the middle');
    }
    expect(t.layout('portrait').roles.values.every((r) => r.maxLines >= 1), isTrue);
  });

  test('when nothing fits, the card asks — naming the line — instead of cutting', () {
    final tiny = TemplateLayout(
      safe: const EdgeInsets.fromLTRB(100, 400, 100, 400),
      photoMinH: 0.3,
      roles: {
        for (final e in posterTemplate('floral_blush').layout('portrait').roles.entries)
          e.key: RoleStyle(
            family: e.value.family,
            size: e.value.size * 2,
            colour: e.value.colour,
            maxLines: e.value.maxLines,
          ),
      },
    );
    final l = layoutPoster(
      spec: longest,
      t: tiny,
      shapeFor: (_) => FrameShape.rounded,
      palette: posterPalette('pink'),
      photoAspect: 0.75,
    );
    expect(l.needs, isNotEmpty);
    expect(l.needs.first.field, 'message');
    expect(l.needs.first.reason, 'no_room');
    // Still every word, at the floor size, for the screen to show.
    expect(l.block('message')!.text, longest.message);
  });

  test('a long unbreakable word shrinks until it fits; it is never split', () {
    const s = PosterSpec(headline: 'ജന്മദിനാശംസകൾ', language: 'ml', name: 'Supercalifragilisticexpialidocious');
    final l = lay(s, photo: 0.75);
    for (final f in ['headline', 'name']) {
      final b = l.block(f)!;
      final p = buildLinePainter(b.text, b.role, b.fontSize, posterPalette('pink'))
        ..layout(minWidth: b.width, maxWidth: b.width);
      expect(p.computeLineMetrics().length, 1, reason: f);
    }
  });

  test('the frame follows the photo: a landscape group photo is not cropped', () {
    for (final t in posterTemplateList) {
      final l = lay(const PosterSpec(name: 'Ananya').copyWith(design: t.id), photo: 1.25);
      final frameAspect = l.frame!.width / l.frame!.height;
      final allowed = t.layout('portrait');
      final want = 1.25.clamp(allowed.aspectMin, allowed.aspectMax);
      expect(frameAspect, closeTo(want, 0.01), reason: t.id);
    }
  });

  test('a lonely last word is pulled back up', () {
    // Wide enough to wrap "light." alone at full size.
    final p = buildLinePainter('May your year be full of laughter and light.',
        const RoleStyle(family: PosterFonts.display, size: 38), 38, posterPalette('pink'))
      ..layout(minWidth: 700, maxWidth: 700);
    if (hasOrphan(p)) {
      final settled = settleLines('May your year be full of laughter and light.',
          const RoleStyle(family: PosterFonts.display, size: 38), 38, 700, posterPalette('pink'));
      expect(hasOrphan(settled.painter), isFalse);
    }
    final settled = settleLines('A b c d e f g h i j k l m n o p q r s t u v w x y z',
        const RoleStyle(family: PosterFonts.display, size: 38), 38, 300, posterPalette('pink'));
    expect(hasOrphan(settled.painter), isFalse);
  });

  test('a non-English card prints the age as its own numeral', () {
    const s = PosterSpec(language: 'ml', name: 'അഞ്ജലി', age: 25, message: 'എല്ലാ സന്തോഷങ്ങളും നേരുന്നു');
    final l = lay(s, photo: 0.75);
    expect(l.block('age')!.text, '25');
    expect(l.block('headline')!.text, 'ജന്മദിനാശംസകൾ');
    final en = lay(const PosterSpec(name: 'Ananya', age: 25), photo: 0.75);
    expect(en.block('age'), isNull);
    expect(en.block('headline')!.text, 'Happy 25th Birthday');
  });

  testWidgets('the phone\'s text size never changes the card', (tester) async {
    final img = await tester.runAsync(() => tinyImage());
    final scene = PosterScene(spec: const PosterSpec(name: 'Ananya', photoUse: 'enhanced'), photo: img);
    final a = preparePoster(scene).layout;
    late PosterLayout b;
    await tester.pumpWidget(MediaQuery(
      data: const MediaQueryData(textScaler: TextScaler.linear(2.0)),
      child: Builder(builder: (context) {
        b = preparePoster(scene).layout;
        return const SizedBox();
      }),
    ));
    expect(b.blocks.map((x) => x.fontSize), a.blocks.map((x) => x.fontSize));
    expect(b.frame, a.frame);
  });

  for (final t in posterTemplateList) {
    for (final f in posterFormats) {
      test('${t.id} / $f exports the exact pixel size, with and without a photo', () async {
        final img = await tinyImage(w: 60, h: 80);
        for (final withPhoto in [true, false]) {
          final png = await renderPosterPng(PosterScene(
            spec: PosterSpec(
                name: 'Ananya', design: t.id, format: f, photoUse: withPhoto ? 'enhanced' : 'none'),
            photo: withPhoto ? img : null,
          ));
          final bd = ByteData.sublistView(png);
          expect(bd.getUint32(16), 1080);
          expect(bd.getUint32(20), f == 'story' ? 1920 : 1350);
        }
      });
    }
  }

  test('photo framing: the whole photo by default, focus and zoom move it', () async {
    final img = await tinyImage(w: 300, h: 400);
    const frame = Rect.fromLTWH(0, 0, 300, 400);
    expect(photoSourceRect(img, frame, PhotoFocus.centre), const Rect.fromLTWH(0, 0, 300, 400));
    final zoomed = photoSourceRect(img, frame, const PhotoFocus(x: 0.5, y: 0.3, zoom: 2));
    expect(zoomed.width, 150);
    expect(zoomed.center.dy, 120); // 0.3 of the photo's height
    // A tall photo in a squarer frame favours the top, where faces are.
    final tall = photoSourceRect(img, const Rect.fromLTWH(0, 0, 300, 300), PhotoFocus.centre);
    expect(tall.center.dy, lessThan(200));
  });

  test('every palette keeps its words readable (WCAG)', () {
    double contrast(Color a, Color b) {
      final la = a.computeLuminance(), lb = b.computeLuminance();
      return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
    }

    for (final p in allPosterPalettes) {
      for (final ground in [p.bgTop, p.bgBottom]) {
        final where = '${p.colour}${p.deep ? ' deep' : ''}';
        expect(contrast(p.ink, ground), greaterThanOrEqualTo(4.5), reason: '$where ink');
        expect(contrast(p.body, ground), greaterThanOrEqualTo(4.5), reason: '$where body');
        expect(contrast(p.soft, ground), greaterThanOrEqualTo(3.0), reason: '$where soft (large)');
        // Foil words are large (the heading, the from line): 3:1.
        final foil = foilTextColours(p);
        for (final c in foil.sublist(1, foil.length - 1)) {
          expect(contrast(c, ground), greaterThanOrEqualTo(3.0), reason: '$where foil $c');
        }
      }
    }
  });

  test('the fonts ship with the app, with their licence', () async {
    for (final path in [...PosterFonts.files.values, PosterFonts.licence]) {
      final data = await rootBundle.load(path);
      expect(data.lengthInBytes, greaterThan(1000), reason: path);
    }
  });
}

