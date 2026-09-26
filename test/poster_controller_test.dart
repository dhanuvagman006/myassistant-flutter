import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/features/poster/poster_controller.dart';
import 'package:myassistant/features/poster/poster_models.dart';
import 'package:myassistant/features/poster/poster_service.dart';
import 'package:myassistant/features/poster/poster_share.dart';
import 'package:myassistant/features/poster/signature/signature_model.dart';
import 'package:myassistant/features/poster/signature/signature_store.dart';

import 'poster_fakes.dart';

/// THE CARD ON SCREEN: every change shows at once and reaches the server
/// in order; the server's answer wins; a line that is too long is asked
/// about, never cut; with no server the card still works on the phone.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakePosterApi api;
  late ShareSpy spy;
  late PosterController c;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    api = FakePosterApi()..photoPng = await tinyPng();
    spy = ShareSpy();
    c = PosterController(api: api, sharer: spy.install(), signatures: SignatureStore());
  });

  test('a new card starts on the server with the occasion\'s design', () async {
    await c.startNew();
    expect(c.poster!.id, greaterThan(0));
    expect(c.spec.design, 'floral_blush');
    expect(c.spec.colour, 'pink');
    expect(c.offline, isFalse);
  });

  test('bigger shows at once, reaches the server, and undo takes it back', () async {
    await c.startNew();
    expect(c.apply(const PosterChange(textSize: 'bigger')), isTrue);
    expect(c.spec.textScale, 1.15, reason: 'shown before the server answers');
    await c.settle();
    expect(api.posters[c.poster!.id]!.spec.textScale, 1.15);
    expect(c.poster!.version, 2);
    expect(c.canUndo, isTrue);

    c.undo();
    expect(c.spec.textScale, 1.0, reason: 'undo is instant');
    await c.settle();
    expect(api.posters[c.poster!.id]!.spec.textScale, 1.0);
    expect(api.calls.where((x) => x.startsWith('patch')).last, 'patch:{"undo":true}');
  });

  test('a version conflict adopts the server\'s copy', () async {
    await c.startNew();
    final id = c.poster!.id;
    api.conflictWith = api.posters[id]!.copyWith(
        version: 9, spec: api.posters[id]!.spec.copyWith(name: 'From the other phone'));
    c.apply(const PosterChange(set: {'name': 'Ananya'}));
    expect(c.spec.name, 'Ananya');
    await c.settle();
    expect(c.spec.name, 'From the other phone');
    expect(c.poster!.version, 9);
    expect(c.notice, isNotNull);
  });

  test('wishes over the limit are asked about — nothing is cut or sent', () async {
    await c.startNew();
    final before = c.spec;
    final ok = c.apply(PosterChange(set: {'message': 'x' * 301}));
    expect(ok, isFalse);
    expect(c.needs.single.field, 'message');
    expect(c.needs.single.max, 300);
    expect(c.spec, before);
    await c.settle();
    expect(api.calls.where((x) => x.startsWith('patch')), isEmpty);
    // Shortening it clears the question.
    expect(c.apply(PosterChange(set: {'message': 'x' * 300})), isTrue);
    expect(c.needs, isEmpty);
  });

  test('a photo shows at once, then the cleaned-up copy; a second pick meanwhile is ignored',
      () async {
    await c.startNew();
    api.uploadDelay = const Duration(milliseconds: 150);
    final png = await tinyPng();
    final first = c.addPhoto(PickedPhoto(png));
    final second = await c.addPhoto(PickedPhoto(png));
    expect(second, isFalse);
    expect(await first, isTrue);
    expect(api.calls.where((x) => x.startsWith('upload')).length, 1);
    expect(c.poster!.photo!.id, greaterThan(0));
    expect(c.spec.photoUse, 'enhanced');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(api.calls, contains('bytes:${c.poster!.photo!.id}:enhanced:keep'));
    expect(c.photo, isNotNull);
  });

  test('with no server the card lives on the phone and still draws and shares', () async {
    api.reachable = false;
    await c.startNew();
    expect(c.poster!.isLocal, isTrue);
    expect(c.offline, isTrue);
    expect(await c.addPhoto(PickedPhoto(await tinyPng())), isTrue);
    expect(c.photo, isNotNull);
    expect(c.apply(const PosterChange(set: {'name': 'Ananya'})), isTrue);
    expect(c.spec.name, 'Ananya');
    final out = await c.share();
    expect(out, ShareOutcome.whatsapp);
  });

  test('share: WhatsApp first; the finished card is saved to his documents', () async {
    await c.startNew();
    c.apply(const PosterChange(set: {'name': 'Ananya', 'from': 'Appa'}));
    final out = await c.share();
    expect(out, ShareOutcome.whatsapp);
    final call = spy.native.singleWhere((m) => m.method == 'shareImageTo');
    expect((call.arguments as Map)['pkg'], 'com.whatsapp');
    expect((call.arguments as Map)['mime'], 'image/png');
    expect((call.arguments as Map)['path'], endsWith('Happy Birthday Ananya.png'));
    for (var i = 0; i < 50 && api.finals.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(api.finals, hasLength(1));
  });

  test('no WhatsApp: the share menu opens instead', () async {
    spy.reply = 'not_installed';
    await c.startNew();
    expect(await c.share(), ShareOutcome.sheet);
    expect(spy.sheets, hasLength(1));
  });

  test('bigger at the top is reported honestly', () async {
    await c.startNew();
    for (var i = 0; i < 6; i++) {
      c.apply(const PosterChange(textSize: 'bigger'));
    }
    expect(c.spec.textScale, textScaleMax);
    expect(c.limitReached, isTrue);
  });

  test('photo colour is part of the card: one PATCH, drawn from that colour\'s copy, undoable',
      () async {
    await c.startNew();
    await c.addPhoto(PickedPhoto(await tinyPng()));
    await c.settle();
    await c.photoReady();
    final id = c.poster!.photo!.id;
    expect(c.setPhotoColour('bw'), isTrue);
    // Shown at once: the phone tints the copy it has while the server's
    // black-and-white copy downloads.
    expect(c.spec.photoColour, 'bw');
    expect(c.scene.tint, 'bw');
    await c.settle();
    await c.photoReady();
    expect(api.calls, contains('patch:{"photoColour":"bw"}'));
    expect(api.calls.where((x) => x.startsWith('colour:')), isEmpty,
        reason: 'POST /photos/:id/colour is only for a photo on its own');
    expect(api.posters[c.poster!.id]!.spec.photoColour, 'bw');
    expect(api.calls, contains('bytes:$id:enhanced:bw'));
    expect(c.scene.tint, 'keep', reason: 'the server\'s copy is already black and white');
    // "Put it back in colour" really changes it back.
    c.undo();
    expect(c.spec.photoColour, 'keep');
    await c.settle();
    await c.photoReady();
    expect(api.posters[c.poster!.id]!.spec.photoColour, 'keep');
    expect(c.scene.tint, 'keep');
  });

  test('a card whose spec says black and white is fetched and shown in black and white', () async {
    const photo = PosterPhoto(id: 77, width: 30, height: 40, variants: ['original', 'enhanced']);
    api.posters[300] = const Poster(
        id: 300,
        version: 4,
        photo: photo,
        spec: PosterSpec(name: 'Ananya', photoUse: 'enhanced', photoColour: 'bw'));
    api.history[300] = [];
    await c.ensure(300);
    await c.photoReady();
    expect(api.calls, contains('bytes:77:enhanced:bw'));
    // He taps "As it is": the PATCH names the colour, the fetch follows it.
    c.setPhotoColour('keep');
    await c.settle();
    await c.photoReady();
    expect(api.posters[300]!.spec.photoColour, 'keep');
    expect(api.calls, contains('bytes:77:enhanced:keep'));
    // On the original, the phone does the tint itself.
    c.apply(const PosterChange(photoUse: 'original'));
    c.setPhotoColour('sepia');
    await c.photoReady();
    expect(c.scene.tint, 'sepia');
  });

  // Integration check, 2026-09-26: a 5xx the server NAMES is its answer.
  // Kept queued as "offline", one refused colour held every later change —
  // her corrected name included — on the phone for good.
  test('black and white the server cannot make is said plainly, and the next change still goes',
      () async {
    await c.startNew();
    await c.addPhoto(PickedPhoto(await tinyPng()));
    await c.settle();
    const why = "Changing the photo's colours isn't available just now — the photo on the card stays as it is.";
    api.refusePatch = (change) => change.photoColour != null
        ? const PosterApiException(503, 'unavailable', why)
        : null;
    expect(c.setPhotoColour('bw'), isTrue);
    await c.settle();
    expect(c.offline, isFalse);
    expect(c.hasUnsent, isFalse);
    expect(c.spec.photoColour, 'keep', reason: 'the card shows what the server has');
    expect(c.notice, why);
    c.apply(const PosterChange(set: {'name': 'Ananya'}));
    await c.settle();
    expect(api.posters[c.poster!.id]!.spec.name, 'Ananya');
    expect(c.hasUnsent, isFalse);
  });

  test('a card made offline tells the server only what he chose', () async {
    api.reachable = false;
    await c.startNew();
    c.apply(const PosterChange(set: {'name': 'Ananya'}));
    c.apply(const PosterChange(design: 'garden_green'));
    api.reachable = true;
    expect(await c.addPhoto(PickedPhoto(await tinyPng())), isTrue);
    final sent = api.createSpecs.last!;
    expect(sent['name'], 'Ananya');
    expect(sent['design'], 'garden_green');
    // Sent, these would mark the card as his choice on the server: its
    // heading would stop following his words' script, its colour its design.
    expect(sent.containsKey('language'), isFalse);
    expect(sent.containsKey('colour'), isFalse);

    api.reachable = false;
    await c.startNew();
    c.apply(const PosterChange(colour: 'gold'));
    api.reachable = true;
    expect(await c.addPhoto(PickedPhoto(await tinyPng())), isTrue);
    expect(api.createSpecs.last!['colour'], 'gold', reason: 'a colour he picked is his');
  });

  group('a change made while the server is out of reach', () {
    test('is kept and sent before the next one, never quietly undone', () async {
      await c.startNew();
      final id = c.poster!.id;
      api.reachable = false;
      c.apply(const PosterChange(set: {'name': 'Ananya'}));
      await c.settle();
      expect(c.offline, isTrue);
      expect(c.spec.name, 'Ananya');
      expect(c.hasUnsent, isTrue);
      api.reachable = true;
      c.apply(const PosterChange(textSize: 'bigger'));
      await c.settle();
      expect(c.spec.name, 'Ananya', reason: 'the server copy now has it too');
      expect(api.posters[id]!.spec.name, 'Ananya');
      expect(api.posters[id]!.spec.textScale, 1.15);
      expect(c.offline, isFalse);
      expect(c.hasUnsent, isFalse);
    });

    test('goes by itself a little later when nothing else is changed', () async {
      c = PosterController(
          api: api,
          sharer: spy.install(),
          signatures: SignatureStore(),
          retryAfter: const Duration(milliseconds: 20));
      await c.startNew();
      final id = c.poster!.id;
      api.reachable = false;
      c.apply(const PosterChange(set: {'name': 'Ananya'}));
      await c.settle();
      api.reachable = true;
      for (var i = 0; i < 50 && api.posters[id]!.spec.name != 'Ananya'; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(api.posters[id]!.spec.name, 'Ananya');
      expect(c.offline, isFalse);
      c.dispose();
    });
  });

  group('the photo drawn is always the card\'s own', () {
    late Uint8List red;
    late Uint8List blue;

    setUp(() async {
      red = await tinyPng(w: 30, h: 40, colour: const Color(0xFFFF0000));
      blue = await tinyPng(w: 60, h: 20, colour: const Color(0xFF0000FF));
    });

    Future<void> cardA() async {
      await c.startNew();
      c.apply(const PosterChange(set: {'name': 'Daughter'}));
      await c.addPhoto(PickedPhoto(red));
      await c.settle();
      await c.photoReady();
      expect(c.scene.photo!.width, 30);
      api.posters[500] = const Poster(
          id: 500,
          version: 2,
          photo: PosterPhoto(id: 99, width: 60, height: 20, variants: ['original', 'enhanced']),
          spec: PosterSpec(name: 'Son', photoUse: 'enhanced'));
      api.history[500] = [];
      api.photoPngs[99] = blue;
    }

    test('a failed download never leaves the last card\'s photo on this one', () async {
      await cardA();
      api.photoFails.add(99);
      await c.ensure(500);
      await c.photoReady();
      expect(c.poster!.id, 500);
      expect(c.scene.photo, isNull, reason: 'never the daughter\'s photo on the son\'s card');
      expect(c.photoFailed, isTrue);
      expect(await c.share(), ShareOutcome.photoMissing);
      expect(spy.native.where((m) => m.method == 'shareImageTo'), isEmpty);
      // Back online, "Try the photo again" brings it.
      api.photoFails.clear();
      c.retryPhoto();
      await c.photoReady();
      expect(c.scene.photo!.width, 60);
      expect(c.photoFailed, isFalse);
    });

    test('"send it" right after the card opened waits for its photo', () async {
      await cardA();
      api.photoGate = Completer<void>();
      await c.ensure(500);
      expect(c.scene.photo, isNull, reason: 'the old photo is gone at once');
      var done = false;
      final sending = c.share().then((o) {
        done = true;
        return o;
      });
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(done, isFalse, reason: 'it waits for the photo');
      api.photoGate!.complete();
      expect(await sending, ShareOutcome.whatsapp);
      expect(c.scene.photo!.width, 60);
    });
  });

  test('a photo the server refuses does not stay on the card', () async {
    await c.startNew();
    api.uploadError = const PosterApiException(
        415, 'unsupported_type', "That photo doesn't open - please pick another one.");
    final ok = await c.addPhoto(PickedPhoto(await tinyPng()));
    expect(ok, isFalse);
    expect(c.poster!.photo, isNull);
    expect(c.spec.photoUse, 'none');
    expect(c.scene.photo, isNull);
    expect(c.notice, "That photo doesn't open - please pick another one.");
  });

  test('a photo picked while offline stays on the card and goes up later', () async {
    await c.startNew();
    final id = c.poster!.id;
    api.reachable = false;
    expect(await c.addPhoto(PickedPhoto(await tinyPng())), isTrue);
    expect(c.scene.photo, isNotNull);
    expect(c.hasUnsent, isTrue);
    api.reachable = true;
    c.apply(const PosterChange(set: {'name': 'Ananya'}));
    await c.settle();
    expect(c.scene.photo, isNotNull, reason: 'the server copy without it does not wipe it');
    await c.resync();
    await c.settle();
    expect(api.posters[id]!.photo, isNotNull);
    expect(api.posters[id]!.spec.name, 'Ananya');
    expect(c.hasUnsent, isFalse);
  });

  test('an answer for the card he left never lands on the one he opened', () async {
    await c.startNew();
    final a = c.poster!.id;
    final b = (await api.create()).id;
    api.patchGate = Completer<void>();
    c.apply(const PosterChange(textSize: 'bigger')); // on A, held
    await c.open(api.posters[b]!);
    c.apply(const PosterChange(set: {'name': 'Bee'})); // on B, queued behind it
    final gate = api.patchGate!;
    api.patchGate = null;
    gate.complete();
    await c.settle();
    expect(c.poster!.id, b);
    expect(c.spec.name, 'Bee');
    expect(api.posters[b]!.spec.name, 'Bee', reason: 'B\'s change was sent');
    expect(api.posters[a]!.spec.textScale, 1.15);
  });

  test('a card made while offline, then refused a photo, keeps its own server copy', () async {
    await c.startNew();
    final a = c.poster!.id;
    api.reachable = false;
    await c.startNew(); // stays on the phone
    expect(c.poster!.isLocal, isTrue);
    api.reachable = true;
    api.uploadError = const PosterApiException(413, 'too_large', 'That photo is too big to use.');
    expect(await c.addPhoto(PickedPhoto(await tinyPng())), isFalse);
    final b = c.poster!.id;
    expect(b, isNot(a));
    expect(b, greaterThan(0));
    api.uploadError = null;
    c.apply(const PosterChange(set: {'name': 'Bee'}));
    await c.settle();
    expect(c.poster!.id, b);
    expect(api.posters[b]!.spec.name, 'Bee');
    expect(api.posters[a]!.spec.name, '', reason: 'the other card is untouched');
    expect(await c.share(), ShareOutcome.whatsapp);
    for (var i = 0; i < 50 && api.finalIds.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(api.finalIds, [b]);
  });

  test('a card that cannot be fetched is not stood in for by another', () async {
    await c.startNew();
    final here = c.poster!.id;
    expect(await c.ensure(12345), isFalse);
    expect(c.poster!.id, here);
    expect(await c.ensure(here), isTrue);
    expect(await c.ensure(null), isTrue);
  });

  test('the automatic heading follows the age; his own heading stays his', () async {
    // The server stores its automatic heading as text.
    api.posters[400] = const Poster(
        id: 400,
        version: 1,
        spec: PosterSpec(name: 'Ananya', age: 25, headline: 'Happy 25th Birthday'));
    api.history[400] = [];
    await c.ensure(400);
    c.apply(const PosterChange(set: {'age': 26}));
    expect(c.spec.printedHeadline, 'Happy 26th Birthday', reason: 'at once, before the server');
    await c.settle();
    expect(c.spec.printedHeadline, 'Happy 26th Birthday');
    c.apply(const PosterChange(set: {'headline': 'Happy Birthday, my little star'}));
    c.apply(const PosterChange(set: {'age': 27}));
    expect(c.spec.printedHeadline, 'Happy Birthday, my little star');
  });

  test('no internet: the words shown are plain, never the socket error', () async {
    api.reachable = false;
    expect(await c.addLoosePhoto(PickedPhoto(await tinyPng())), isNull);
    expect(c.notice, PosterApiException.noInternet);
    expect(c.notice, isNot(contains('offline')));
    api.reachable = true;
    final ph = await c.addLoosePhoto(PickedPhoto(await tinyPng()));
    api.reachable = false;
    expect(ph, isNotNull);
    expect(await c.keepLoosePhoto(), isFalse);
    expect(c.notice, PosterApiException.noInternet);
    await c.cardFromLoosePhoto();
    expect(c.notice, PosterApiException.noInternet);
  });

  test('signing out forgets the card, its photo and the signature on this phone', () async {
    final store = SignatureStore();
    await store.save(SignatureData.fromRaw([
      [(p: const Offset(0, 0), t: 0), (p: const Offset(80, 30), t: 40)],
      [(p: const Offset(10, 40), t: 90), (p: const Offset(90, 20), t: 140)],
    ]));
    final keepStore = SignatureStore.instance;
    final keepController = PosterController.instance;
    SignatureStore.instance = store;
    c = PosterController(api: api, sharer: spy.install(), signatures: store);
    PosterController.instance = c;
    addTearDown(() {
      SignatureStore.instance = keepStore;
      PosterController.instance = keepController;
    });
    await c.startNew();
    await c.addPhoto(PickedPhoto(await tinyPng()));
    expect(c.signature, isNotNull);
    await PosterController.forgetAccount();
    expect(c.poster, isNull);
    expect(c.photo, isNull);
    expect(c.signature, isNull);
    expect(await SignatureStore().load(), isNull, reason: 'gone from secure storage');
  });
}
