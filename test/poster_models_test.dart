import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/features/poster/poster_device_actions.dart';
import 'package:myassistant/features/poster/poster_models.dart';
import 'package:myassistant/features/poster/poster_service.dart';
import 'package:myassistant/features/poster/poster_templates.dart';

import 'poster_fakes.dart';

/// THE CONTRACT BOTH SIDES BUILD AGAINST (2026-09-26). The fixture is the
/// backend's own tests/fixtures/posters/contract.json, copied verbatim;
/// every object in it must parse, and every table the app keeps a copy of
/// (headings, designs, limits, the [SYSTEM] lines) must match it, so the
/// two tracks cannot drift apart.
void main() {
  final contract = loadContract();
  final ex = (contract['examples'] as Map).cast<String, dynamic>();

  group('fixture objects parse and round-trip', () {
    for (final k in ['spec', 'spec_ml']) {
      test(k, () {
        final j = (ex[k] as Map).cast<String, dynamic>();
        final s = PosterSpec.fromJson(j);
        // Every field the server sends comes back byte for byte.
        final back = s.toJson();
        for (final e in j.entries) {
          expect(back[e.key], e.value, reason: '$k.${e.key}');
        }
        expect(PosterSpec.fromJson(back), s);
      });
    }

    for (final k in ['poster', 'poster_ml', 'poster_no_photo']) {
      test(k, () {
        final j = (ex[k] as Map).cast<String, dynamic>();
        final p = Poster.fromJson(j);
        expect(p.id, j['id']);
        expect(p.version, j['version']);
        expect(p.canUndo, j['canUndo']);
        expect(p.finalDocumentId, j['finalDocumentId']);
        expect(p.spec.name, (j['spec'] as Map)['name']);
        expect(p.photo?.id, (j['photo'] as Map?)?['id']);
        final again = Poster.fromJson(p.toJson());
        expect(again.spec, p.spec);
        expect(again.photo?.variants, p.photo?.variants);
      });
    }

    test('photo', () {
      final ph = PosterPhoto.fromJson((ex['photo'] as Map).cast<String, dynamic>());
      expect(ph.status, 'ready');
      expect(ph.variants, ['original', 'enhanced']);
      expect(ph.reason, 'off');
      expect(ph.variantFor('enhanced'), 'enhanced');
      expect(ph.variantFor('original'), 'original');
      expect(ph.variantFor('none'), 'none');
      // No enhanced copy (a server without ffmpeg): the original is used.
      final bare = PosterPhoto.fromJson({...ph.toJson(), 'variants': ['original']});
      expect(bare.variantFor('enhanced'), 'original');
    });

    test('contract v2: the card\'s photo colour', () {
      expect(contract['version'], 2);
      final spec = PosterSpec.fromJson((ex['spec'] as Map).cast<String, dynamic>());
      expect(spec.photoColour, 'keep');
      // A card saved before v2 (no photoColour) shows its photo as it is.
      final old = Map<String, dynamic>.of((ex['spec'] as Map).cast<String, dynamic>())
        ..remove('photoColour');
      expect(PosterSpec.fromJson(old).photoColour, 'keep');
      final patch = (ex['patch_photo_colour'] as Map).cast<String, dynamic>();
      final c = PosterChange.fromJson((patch['change'] as Map).cast<String, dynamic>());
      expect(c.photoColour, 'bw');
      expect(c.toJson(), patch['change']);
      final bw = applyChange(spec, c).spec!;
      expect(bw.photoColour, 'bw');
      expect(bw.photoUse, 'enhanced');
      expect(applyChange(bw, const PosterChange(photoColour: 'pink')).spec!.photoColour, 'bw',
          reason: 'only keep / bw / sepia');
    });

    test('change requests', () {
      final patch = (ex['patch_request'] as Map).cast<String, dynamic>();
      final c = PosterChange.fromJson((patch['change'] as Map).cast<String, dynamic>());
      expect(c.toJson(), patch['change']);
      expect(c.design, 'next');
      final undo = PosterChange.fromJson(((ex['patch_undo'] as Map)['change'] as Map).cast<String, dynamic>());
      expect(undo.undo, isTrue);
      expect(undo.toJson(), {'undo': true});
    });

    test('errors', () {
      final need = PosterApiException.fromResponse(422, _json(ex['error_need']));
      expect(need.isNeed, isTrue);
      expect(need.need.single.field, 'message');
      expect(need.need.single.max, 300);
      expect(need.need.single.length, 342);
      final conflict = PosterApiException.fromResponse(409, _json(ex['error_version_conflict']));
      expect(conflict.isConflict, isTrue);
      expect(conflict.poster?.id, 12);
      final off = PosterApiException.fromResponse(503, _json(ex['error_restore_off']));
      expect(off.code, 'off');
      expect(off.message, 'Photo repair is not switched on yet.');
      // Uploads the server refuses: its own words, and not "no internet".
      final big = PosterApiException.fromResponse(413, _json(ex['error_too_many_pixels']));
      expect(big.notAvailable, isFalse);
      expect(big.friendly('x'), (ex['error_too_many_pixels'] as Map)['message']);
      final bad = PosterApiException.fromResponse(415, _json(ex['error_undecodable']));
      expect(bad.code, 'unsupported_type');
      expect(bad.notAvailable, isFalse);
      // A 5xx the server NAMED is its answer, not an outage: queued as
      // "offline" it would block every later change (integration check,
      // 2026-09-26). No answer, a proxy's page, its own "try again" (500
      // 'error'), the rate limit and an older backend are worth retrying.
      expect(const PosterApiException(503, 'unavailable', 'x').notAvailable, isFalse);
      expect(const PosterApiException(507, 'storage_full', 'x').notAvailable, isFalse);
      expect(off.notAvailable, isFalse);
      expect(const PosterApiException(500, 'error', 'x').notAvailable, isTrue);
      expect(const PosterApiException(502, '', '').notAvailable, isTrue);
      expect(const PosterApiException(429, '', '').notAvailable, isTrue);
      expect(const PosterApiException(404, '', '').notAvailable, isTrue);
      expect(const PosterApiException(404, 'not_found', 'x').notAvailable, isFalse);
      // No answer at all: plain words, never the socket error and its URL.
      const gone = PosterApiException(0, 'unreachable',
          'ClientException with SocketException: Failed host lookup, uri=https://example/posters');
      expect(gone.friendly('x'), PosterApiException.noInternet);
    });
  });

  test('device actions parse', () {
    final da = (contract['deviceActions'] as Map).cast<String, dynamic>();
    for (final e in da.values) {
      expect(PosterDeviceActions.types, contains((e as Map)['type']));
    }
    final show = (da['poster_show'] as Map).cast<String, dynamic>();
    final p = Poster.fromJson((show['poster'] as Map).cast<String, dynamic>());
    expect(p.spec.design, 'floral_blush');
    expect(p.spec.signature, isTrue);
  });

  test('the printed words are the server\'s words(spec)', () {
    final en = PosterSpec.fromJson((ex['spec'] as Map).cast<String, dynamic>());
    expect(printedWords(en), ex['words']);
    final ml = PosterSpec.fromJson((ex['spec_ml'] as Map).cast<String, dynamic>());
    expect(printedWords(ml), ex['words_ml']);
    expect(spellName(en.name), ex['spell']);
    expect(spellName('അഞ്ജലി'), isNull);
    expect(spellName('Mary Ann'), 'M-A-R-Y A-N-N');
  });

  test('the card\'s language is counted as the server counts it', () {
    expect(writtenLanguage('Happy birthday അഞ്ജലി'), 'en', reason: 'most letters win');
    expect(writtenLanguage('ജന്മദിനാശംസകൾ Ananya'), 'ml');
    expect(writtenLanguage('🎂 25!'), isNull);
    for (final k in ['spec', 'spec_ml']) {
      final s = PosterSpec.fromJson((ex[k] as Map).cast<String, dynamic>());
      expect(posterLanguageOf(s), s.language, reason: k);
    }
    // English wishes with her Malayalam name: an English card.
    final en = applyChange(const PosterSpec(),
        const PosterChange(set: {'name': 'അനന്യ', 'message': 'Happy birthday my dear അനന്യ'})).spec!;
    expect(en.language, 'en');
    expect(en.printedHeadline, 'Happy Birthday');
    // Wishes with no letters: the name decides.
    final ml = applyChange(const PosterSpec(),
        const PosterChange(set: {'name': 'അനന്യ', 'message': '🎂🎂'})).spec!;
    expect(ml.language, 'ml');
  });

  test('the heading table matches the server\'s, for every language and occasion', () {
    final table = (contract['headlines'] as Map).cast<String, dynamic>();
    for (final lang in posterLanguages) {
      for (final occ in posterOccasions) {
        expect(posterHeadlines[lang]![occ], (table[lang] as Map)[occ], reason: '$lang/$occ');
        expect(defaultHeadline(language: lang, occasion: occ), (table[lang] as Map)[occ]);
      }
    }
    expect(defaultHeadline(language: 'en', occasion: 'birthday', age: 25), 'Happy 25th Birthday');
    expect(defaultHeadline(language: 'en', occasion: 'anniversary', age: 40), 'Happy 40th Anniversary');
    // Other languages carry no ordinal: the age is its own numeral line.
    expect(defaultHeadline(language: 'ml', occasion: 'birthday', age: 25), 'ജന്മദിനാശംസകൾ');
  });

  test('ordinals', () {
    const want = {
      1: '1st', 2: '2nd', 3: '3rd', 4: '4th', 11: '11th', 12: '12th', 13: '13th',
      21: '21st', 22: '22nd', 101: '101st', 111: '111th',
    };
    want.forEach((n, s) => expect(ordinalEn(n), s));
  });

  test('designs, their colours and the occasion defaults match the server', () {
    final designs = (contract['designs'] as List).cast<Map>();
    expect(posterDesigns, [for (final d in designs) d['id']]);
    for (final d in designs) {
      expect(designHomeColour[d['id']], d['defaultColour'], reason: '${d['id']}');
      expect(posterTemplate(d['id'] as String).id, d['id']);
      expect(posterTemplate(d['id'] as String).title, d['label']);
    }
    expect(designForOccasion, (contract['defaultDesign'] as Map).cast<String, String>());
    expect(normalizeDesign('Floral Blush'), 'floral_blush');
    expect(normalizeDesign('royal'), 'royal_mandala');
    expect(normalizeDesign('balloons'), 'balloons_confetti');
    expect(nextDesign('classic_ivory'), 'floral_blush');
  });

  test('enums, limits and text sizes match', () {
    final enums = (contract['enums'] as Map).cast<String, dynamic>();
    expect(posterOccasions, enums['occasion']);
    expect(posterLanguages, enums['language']);
    expect(posterColours, enums['colour']);
    expect(posterFormats, enums['format']);
    expect(posterPhotoUses, enums['photoUse']);
    expect(posterPhotoColours, enums['photoColour']);
    final limits = (contract['limits'] as Map).cast<String, dynamic>();
    posterLimits.forEach((k, v) => expect(limits[k], v, reason: k));
    final ts = (contract['textScale'] as Map).cast<String, dynamic>();
    expect(textScaleMin, ts['min']);
    expect(textScaleMax, ts['max']);
    expect(textScaleStep, ts['step']);
    final formats = (contract['formats'] as Map).cast<String, dynamic>();
    for (final f in posterFormats) {
      final px = posterPixels(f);
      expect(px.w, (formats[f] as Map)['width']);
      expect(px.h, (formats[f] as Map)['height']);
    }
  });

  test('colour words resolve as the server resolves them', () {
    final aliases = (contract['colourAliases'] as Map).cast<String, String>();
    aliases.forEach((word, colour) => expect(resolveColour(word), colour, reason: word));
    for (final c in posterColours) {
      expect(resolveColour(c), c);
    }
    expect(resolveColour('chartreuse'), isNull);
  });

  test('the [SYSTEM] lines are the fixture\'s, word for word', () {
    final lines = (contract['systemLines'] as Map).cast<String, String>();
    expect(PosterLines.photoAddedMissing(12, ['name', 'message']),
        lines['photo_added_missing']!
            .replaceAll('{poster_id}', '12')
            .replaceAll('{missing}', 'the name, the wishes'));
    expect(PosterLines.photoAddedComplete(12),
        lines['photo_added_complete']!.replaceAll('{poster_id}', '12'));
    expect(PosterLines.pickerClosed, lines['picker_closed']);
    expect(PosterLines.photoShown(41), lines['photo_shown']!.replaceAll('{photo_id}', '41'));
    expect(PosterLines.tooLongOnCard('message'),
        lines['too_long_on_card']!.replaceAll('{field_words}', 'the wishes'));
    expect(PosterLines.signatureSaved, lines['signature_saved']);
    expect(PosterLines.shared, lines['shared']);
    expect(PosterLines.shareFallback, lines['share_fallback']);
    for (final l in lines.values) {
      expect(l.toLowerCase(), isNot(contains("it's ready")));
    }
  });

  group('text rules: never cut, never re-cased', () {
    test('words come back exactly', () {
      for (final s in ['Ananya', 'അഞ്ജലി', 'अंजलि', 'ANANYA', 'ananya dsouza', 'Happy birthday 🎂']) {
        final r = applyChange(const PosterSpec(), PosterChange(set: {'name': s}));
        expect(r.spec!.name, s);
      }
    });

    test('over the limit is a need, never a truncation', () {
      final long = 'a' * 301;
      final r = applyChange(const PosterSpec(), PosterChange(set: {'message': long}));
      expect(r.spec, isNull);
      expect(r.needs.single.field, 'message');
      expect(r.needs.single.reason, 'too_long');
      expect(r.needs.single.max, 300);
      // Counted as the server counts — code points — so the phone never
      // passes a line the server then refuses: 'ക്ഷ' is three.
      final ml = 'ക്ഷ' * 20;
      expect(posterTextLength(ml), 60);
      expect(applyChange(const PosterSpec(), PosterChange(set: {'name': ml})).spec?.name, ml);
      final over = applyChange(const PosterSpec(), PosterChange(set: {'name': '$mlക'}));
      expect(over.spec, isNull);
      expect(over.needs.single.max, 60);
      expect(over.needs.single.length, 61);
    });

    test('clean-up keeps four line breaks and every word', () {
      expect(cleanLine('message', 'a\nb\nc\nd\ne\nf\ng'), 'a\nb\nc\nd\ne f g');
      expect(cleanLine('name', '  Ananya   D  '), 'Ananya D');
      expect(cleanLine('name', 'Ana\nnya'), 'Ana nya');
    });
  });

  group('changes', () {
    test('bigger climbs in steps and stops at the top', () {
      var s = const PosterSpec();
      final seen = <double>[];
      for (var i = 0; i < 8; i++) {
        s = applyChange(s, const PosterChange(textSize: 'bigger')).spec!;
        seen.add(s.textScale);
      }
      expect(seen.first, 1.15);
      expect(seen.last, textScaleMax);
      expect(nextTextScale(textScaleMax, 'bigger'), isNull);
      s = applyChange(s, const PosterChange(textSize: 'reset')).spec!;
      expect(s.textScale, 1.0);
      for (var i = 0; i < 5; i++) {
        s = applyChange(s, const PosterChange(textSize: 'smaller')).spec!;
      }
      expect(s.textScale, textScaleMin);
    });

    test('the colour follows the design until he names one', () {
      var s = const PosterSpec();
      s = applyChange(s, const PosterChange(design: 'golden_celebration')).spec!;
      expect(s.colour, 'gold');
      s = applyChange(s, const PosterChange(colour: 'rose')).spec!;
      expect(s.colour, 'pink');
      expect(s.colourCustom, isTrue);
      s = applyChange(s, const PosterChange(design: 'next')).spec!;
      expect(s.design, 'balloons_confetti');
      expect(s.colour, 'pink');
    });

    test('Malayalam wishes move the card to Malayalam and its heading', () {
      final s = applyChange(const PosterSpec(age: 25),
          const PosterChange(set: {'name': 'അഞ്ജലി', 'message': 'എല്ലാ സന്തോഷങ്ങളും നേരുന്നു'})).spec!;
      expect(s.language, 'ml');
      expect(s.printedHeadline, 'ജന്മദിനാശംസകൾ');
      expect(ageLine(s), '25');
    });

    test('the automatic heading is worked out again; his own never is', () {
      // As the server stores it: the automatic heading as text.
      const stored = PosterSpec(age: 25, headline: 'Happy 25th Birthday');
      expect(stored.printedHeadline, 'Happy 25th Birthday');
      final older = applyChange(stored, const PosterChange(set: {'age': 26})).spec!;
      expect(older.printedHeadline, 'Happy 26th Birthday');
      expect(older.headline, 'Happy 26th Birthday', reason: 'as the server normalises it');
      final anniversary = applyChange(older, const PosterChange(set: {'age': null})).spec!;
      expect(anniversary.printedHeadline, 'Happy Birthday');
      final his = applyChange(stored, const PosterChange(set: {'headline': 'For my star'})).spec!;
      expect(his.headlineCustom, isTrue);
      expect(applyChange(his, const PosterChange(set: {'age': 30})).spec!.printedHeadline,
          'For my star');
      // Emptied: back to the automatic one.
      final back = applyChange(his, const PosterChange(set: {'headline': ''})).spec!;
      expect(back.headlineCustom, isFalse);
      expect(back.printedHeadline, 'Happy 25th Birthday');
    });

    test('set changes only the lines given', () {
      const base = PosterSpec(name: 'Ananya', message: 'Hi', from: 'Appa');
      final s = applyChange(base, const PosterChange(set: {'from': 'Amma'})).spec!;
      expect(s.name, 'Ananya');
      expect(s.message, 'Hi');
      expect(s.from, 'Amma');
    });

    test('missing lines, in the server\'s order', () {
      expect(missingLines(const PosterSpec()), ['name', 'age', 'message', 'from']);
      expect(missingLines(const PosterSpec(name: 'A', age: 3, message: 'm', from: 'f')), isEmpty);
    });
  });
}

String _json(Object? v) => jsonEncode(v);
