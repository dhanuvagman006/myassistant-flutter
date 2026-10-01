import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/features/poster_studio/studio_fonts.dart';
import 'package:myassistant/features/poster_studio/studio_layout.dart';
import 'package:myassistant/features/poster_studio/studio_models.dart';
import 'package:myassistant/features/poster_studio/studio_painter.dart';
import 'package:myassistant/features/poster_studio/studio_palettes.dart';
import 'package:myassistant/features/poster_studio/studio_templates.dart';

/// A picture of one flat colour, or a checkerboard (a busy picture).
Future<ui.Image> picture(Color a, {Color? b, int w = 400, int h = 500, double cell = 12}) {
  final rec = ui.PictureRecorder();
  final c = Canvas(rec);
  c.drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..color = a);
  if (b != null) {
    final p = Paint()..color = b;
    for (var y = 0.0; y < h; y += cell) {
      for (var x = ((y / cell).round().isEven ? 0.0 : cell); x < w; x += cell * 2) {
        c.drawRect(Rect.fromLTWH(x, y, cell, cell), p);
      }
    }
  }
  return rec.endRecording().toImage(w, h);
}

/// THE POSTER'S WORDS ARE NEVER CUT, AND ALWAYS READ (2026-09-30).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => StudioFonts.ensureLoaded());

  const full = EventDesign(
    title: 'Annual Day Celebration 2026',
    subtitle: 'An evening of music, dance and food with the whole family',
    dateText: 'Saturday, 4 October',
    timeText: '6:30 PM',
    location: 'Kerala Samajam Hall, 12th Main Road, Indiranagar, Bengaluru',
    cta: 'Register at the front desk',
    details: ['Entry free for members', 'Dinner served from 8 pm', 'Call 98450 12345'],
  );
  const longTitle = EventDesign(
    title: 'The Grand Neighbourhood Onam Sadya and Cultural Evening for Families, Friends and Everyone Nearby',
    dateText: 'Sunday',
    location: 'Our building terrace',
    cta: 'All welcome',
  );
  const oneWord = EventDesign(title: 'Supercalifragilisticexpialidocious', dateText: 'Tomorrow');

  void expectWhole(StudioLayout l, EventDesign d, String where) {
    final title = l.block(StudioField.title)!;
    expect(title.text, d.title, reason: '$where: every word of the title');
    // No word broken across lines, and no line ever cut.
    expect(studioWordsFit(d.title, title.style, title.layoutWidth), isTrue, reason: '$where: word broken');
    final p = studioPainter(title.text, title.style, title.align)
      ..layout(minWidth: title.layoutWidth, maxWidth: title.layoutWidth);
    expect(p.didExceedMaxLines, isFalse, reason: where);
    expect((p.height - (title.box.height)).abs() < 1, isTrue, reason: '$where: painted height');
    final poster = Offset.zero & l.size;
    for (final b in l.blocks) {
      expect(poster.contains(b.box.topLeft) && poster.contains(b.box.bottomRight - const Offset(0.01, 0.01)),
          isTrue,
          reason: '$where ${b.field} ${b.box} inside the poster');
      expect(b.box.width <= l.column.width + 1, isTrue, reason: '$where ${b.field} fits the column');
      // The title is the biggest thing on the poster.
      if (b.field != StudioField.title) {
        expect(title.fontSize, greaterThan(b.fontSize), reason: '$where: title outranks ${b.field}');
      }
    }
    for (var i = 1; i < l.blocks.length; i++) {
      expect(l.blocks[i].box.top, greaterThanOrEqualTo(l.blocks[i - 1].box.bottom - 0.5),
          reason: '$where: ${l.blocks[i].field} below ${l.blocks[i - 1].field}');
    }
  }

  test('the title is whole, unbroken and the largest line — every template, size and arrangement', () {
    for (final t in studioTemplates) {
      for (final f in StudioFormat.values) {
        for (var v = 0; v < t.variants; v++) {
          for (final logo in [false, true]) {
            for (final d in [full, longTitle, oneWord]) {
              final l = layoutStudio(design: d, template: t, format: f, variant: v, logo: logo);
              final where = '${t.id}/${f.name}/v$v/logo=$logo/"${d.title.substring(0, 8)}"';
              expectWhole(l, d, where);
              expect(l.needs, isEmpty, reason: '$where fits');
              if (logo) {
                for (final b in l.blocks) {
                  expect(b.box.overlaps(l.zones.logo!), isFalse, reason: '$where ${b.field} vs logo');
                }
              }
            }
          }
        }
      }
    }
  });

  test('a long title shrinks to fit instead of being cut; a short one stays big', () {
    final t = studioTemplate('neon_night');
    final short = layoutStudio(design: const EventDesign(title: 'Jam Night'), template: t);
    final long = layoutStudio(design: longTitle, template: t);
    expect(short.block(StudioField.title)!.fontSize, greaterThan(long.block(StudioField.title)!.fontSize));
    expect(long.block(StudioField.title)!.text, longTitle.title);
  });

  test('words that cannot fit are named, never cut', () {
    final tooMuch = full.copyWith(details: [for (var i = 0; i < 60; i++) 'Detail line number $i with a few more words']);
    final l = layoutStudio(design: tooMuch, template: studioTemplate('corporate_clean'));
    expect(l.needs, [StudioField.details]);
    expect(l.block(StudioField.title)!.text, tooMuch.title);
    expect(l.block(StudioField.details)!.text.split('\n').length, 60);
  });

  test('the exact words are drawn: date and time share one chip, details keep their order', () {
    final l = layoutStudio(design: full, template: studioTemplate('festive'));
    expect(l.block(StudioField.date)!.text, 'Saturday, 4 October  ·  6:30 PM');
    expect(l.block(StudioField.location)!.text, full.location);
    expect(l.block(StudioField.cta)!.text, full.cta);
    expect(l.block(StudioField.details)!.text, '•  Entry free for members\n•  Dinner served from 8 pm\n•  Call 98450 12345');
    expect(l.block(StudioField.location)!.icon, isNotNull, reason: 'the pin');
  });

  group('contrast', () {
    Future<PreparedStudio> prep(String template, ui.Image? img, {int variant = 0, String palette = ''}) {
      final t = studioTemplate(template);
      return prepareStudio(StudioScene(
        design: full,
        template: t,
        palette: studioPalette(palette.isEmpty ? t.palette : palette),
        image: img,
        variant: variant,
      ));
    }

    void expectReadable(PreparedStudio p, String where) {
      for (final b in p.layout.blocks) {
        expect(p.contrast[b.field], isNotNull, reason: '$where ${b.field} measured');
        expect(p.contrast[b.field]!, greaterThanOrEqualTo(4.5), reason: '$where ${b.field}: ${p.contrast[b.field]}');
      }
    }

    test('over a bright picture a scrim goes behind the words, and they reach 4.5:1', () async {
      final white = await picture(const Color(0xFFFFFFFF));
      for (var v = 0; v < 3; v++) {
        final p = await prep('neon_night', white, variant: v);
        expect(p.panels, isNotEmpty, reason: 'v$v: a panel over white');
        final covered = p.panels.expand((x) => x.fields).toSet();
        expect(covered, contains(StudioField.title), reason: 'v$v');
        expectReadable(p, 'neon/white/v$v');
      }
    });

    test('over a busy picture the panel is frosted (blurred)', () async {
      final busy = await picture(const Color(0xFF000000), b: const Color(0xFFFFFFFF));
      final p = await prep('festive', busy);
      expect(p.panels, isNotEmpty);
      expect(p.panels.every((x) => x.blur), isTrue);
      expectReadable(p, 'festive/busy');
    });

    test('over a dark picture no scrim is needed on the night template', () async {
      final night = await picture(const Color(0xFF05060F));
      final p = await prep('neon_night', night);
      expect(p.panels, isEmpty);
      expectReadable(p, 'neon/dark');
    });

    test('every template reads over bright, dark and busy pictures and its own art, in every palette', () async {
      final pics = <String, ui.Image?>{
        'white': await picture(const Color(0xFFFFFFFF)),
        'yellow': await picture(const Color(0xFFFFE14D)),
        'dark': await picture(const Color(0xFF101010)),
        'busy': await picture(const Color(0xFF202020), b: const Color(0xFFF0F0F0)),
        'art': null,
      };
      for (final t in studioTemplates) {
        for (final pal in studioPalettes) {
          for (final e in pics.entries) {
            for (var v = 0; v < t.variants; v++) {
              final p = await prep(t.id, e.value, variant: v, palette: pal.id);
              expectReadable(p, '${t.id}/${pal.id}/${e.key}/v$v');
            }
          }
        }
      }
    });

    test('the poster renders to a PNG of the full size', () async {
      final p = await prep('bold_minimal', await picture(const Color(0xFF3366AA)));
      final png = await renderStudioPng(p);
      expect(png.length, greaterThan(1000));
      final codec = await ui.instantiateImageCodec(png);
      final frame = await codec.getNextFrame();
      expect(frame.image.width, 1080);
      expect(frame.image.height, 1350);
    });
  });
}
