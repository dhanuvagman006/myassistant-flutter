import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/features/poster/poster_controller.dart';
import 'package:myassistant/features/poster/poster_device_actions.dart';
import 'package:myassistant/features/poster/poster_models.dart';
import 'package:myassistant/features/poster/poster_service.dart';
import 'package:myassistant/features/poster/signature/signature_model.dart';
import 'package:myassistant/features/poster/signature/signature_store.dart';

import 'poster_fakes.dart';

class FakeHost implements PosterHost {
  final lines = <String>[];
  int holds = 0;
  int shown = 0;
  int pads = 0;
  PickedPhoto? photo;
  SignatureData? signature;

  /// Set to make the picker report the camera switched off.
  PhotoAccessDenied? deny;
  final order = <String>[];

  @override
  Future<void> tellModel(String line) async {
    order.add('tell');
    lines.add(line);
  }

  @override
  Future<T> holdMic<T>(Future<T> Function() body) async {
    holds++;
    return body();
  }

  @override
  void showPoster() {
    order.add('show');
    shown++;
  }

  @override
  Future<PickedPhoto?> pickPhoto(String source) async {
    order.add('pick:$source');
    if (deny != null) throw deny!;
    return photo;
  }

  @override
  Future<SignatureData?> openSignaturePad() async {
    order.add('pad');
    pads++;
    return signature;
  }
}

/// The assistant's card actions (contract §4) — what each does on the
/// phone and the exact [SYSTEM] line it hands back.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final contract = loadContract();
  final da = (contract['deviceActions'] as Map).cast<String, dynamic>();
  Map<String, dynamic> action(String k) => (da[k] as Map).cast<String, dynamic>();

  late FakePosterApi api;
  late ShareSpy spy;
  late PosterController c;
  late FakeHost host;
  late PosterDeviceActions actions;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    api = FakePosterApi()..photoPng = await tinyPng();
    spy = ShareSpy();
    c = PosterController(api: api, sharer: spy.install(), signatures: SignatureStore());
    host = FakeHost();
    actions = PosterDeviceActions(host, controller: c);
    // The fixture's card 12 exists on the fake server.
    final show = action('poster_show');
    final p = Poster.fromJson((show['poster'] as Map).cast<String, dynamic>());
    api.posters[12] = p;
    api.history[12] = [];
  });

  test('a closed picker says so, and nothing is uploaded', () async {
    await actions.handle(action('poster_pick_photo'));
    expect(host.lines, [PosterLines.pickerClosed]);
    expect(host.holds, 1, reason: 'the mic is held while the picker is up');
    expect(api.calls.where((x) => x == 'upload'), isEmpty);
    expect(host.order.first, 'pick:ask');
  });

  test('a picked photo goes on the card, the card comes up, and the model hears what is missing',
      () async {
    api.posters[12] = api.posters[12]!.copyWith(
        spec: api.posters[12]!.spec.copyWith(name: '', message: ''));
    host.photo = PickedPhoto(await tinyPng());
    await actions.handle(action('poster_pick_photo'));
    expect(api.calls, contains('upload:12:keep'));
    expect(c.poster!.id, 12);
    expect(host.shown, 1);
    expect(host.lines.single, PosterLines.photoAddedMissing(12, ['name', 'message']));
  });

  test('with every line there, the model is told to read the words back', () async {
    host.photo = PickedPhoto(await tinyPng());
    await actions.handle(action('poster_pick_photo'));
    expect(host.lines.single, PosterLines.photoAddedComplete(12));
  });

  test('poster_show opens the card; "with my signature" and none saved opens the pad first',
      () async {
    host.signature = SignatureData.fromRaw([
      [(p: const Offset(0, 0), t: 0), (p: const Offset(80, 30), t: 40)],
      [(p: const Offset(10, 40), t: 90), (p: const Offset(90, 20), t: 140)],
    ]);
    await actions.handle(action('poster_show'));
    expect(host.shown, 1);
    expect(host.pads, 1);
    expect(host.order.indexOf('show'), lessThan(host.order.indexOf('pad')));
    expect(c.signature, isNotNull);
    expect(host.lines, contains(PosterLines.signatureSaved));
  });

  test('poster_show with a signature already saved does not ask again', () async {
    await SignatureStore().save(SignatureData.fromRaw([
      [(p: const Offset(0, 0), t: 0), (p: const Offset(80, 30), t: 40)],
      [(p: const Offset(10, 40), t: 90), (p: const Offset(90, 20), t: 140)],
    ]));
    c = PosterController(api: api, sharer: spy.install(), signatures: SignatureStore());
    actions = PosterDeviceActions(host, controller: c);
    await actions.handle(action('poster_show'));
    expect(host.pads, 0);
    expect(host.lines, isEmpty);
  });

  test('poster_share opens WhatsApp with the card; he presses Send', () async {
    await actions.handle(action('poster_show'));
    host.lines.clear();
    c.useSignature(SignatureData.fromRaw([
      [(p: const Offset(0, 0), t: 0), (p: const Offset(80, 30), t: 40)],
      [(p: const Offset(10, 40), t: 90), (p: const Offset(90, 20), t: 140)],
    ]));
    await actions.handle(action('poster_share'));
    final call = spy.native.singleWhere((m) => m.method == 'shareImageTo');
    expect((call.arguments as Map)['pkg'], 'com.whatsapp');
    expect(host.lines.single, PosterLines.shared);
    expect(host.lines.single, contains('presses Send'));
  });

  test('no WhatsApp on the phone: the share menu, and the model is told which', () async {
    spy.reply = 'not_installed';
    await actions.handle(action('poster_share'));
    expect(spy.sheets, hasLength(1));
    expect(host.lines.last, PosterLines.shareFallback);
  });

  test('poster_sign opens the pad and puts the signature on the card', () async {
    await c.open(api.posters[12]!.copyWith(spec: api.posters[12]!.spec.copyWith(signature: false)));
    host.signature = SignatureData.fromRaw([
      [(p: const Offset(0, 0), t: 0), (p: const Offset(80, 30), t: 40)],
      [(p: const Offset(10, 40), t: 90), (p: const Offset(90, 20), t: 140)],
    ]);
    await actions.handle(action('poster_sign'));
    expect(c.spec.signature, isTrue);
    expect(host.lines.single, PosterLines.signatureSaved);
  });

  test('"make my old photo clearer, in black and white": the photo is cleaned up in black and '
      'white, and the model hears its id', () async {
    host.photo = PickedPhoto(await tinyPng());
    final e = Map<String, dynamic>.of(action('poster_pick_photo_for_photo'))..['colour'] = 'bw';
    await actions.handle(e);
    expect(api.calls, contains('upload:-:bw'), reason: 'the colour asked for goes with it');
    final id = c.loosePhoto!.id;
    expect(c.loosePhoto!.colour, 'bw');
    expect(api.calls, contains('bytes:$id:enhanced:bw'));
    expect(host.lines.single, PosterLines.photoShown(id));
    expect(host.lines.single, contains('(photo $id)'));
  });

  test('a card that cannot be opened is never swapped for the one on screen', () async {
    // Card 15 (his son's) is on screen; card 12 cannot be fetched.
    api.posters[15] = api.posters[12]!.copyWith(id: 15, spec: api.posters[12]!.spec.copyWith(name: 'Son'));
    api.history[15] = [];
    await c.open(api.posters[15]!);
    api.posters.remove(12);
    await actions.handle(action('poster_share'));
    expect(spy.native.where((m) => m.method == 'shareImageTo'), isEmpty);
    expect(host.lines.single, PosterLines.cardNotOpened);
    host.lines.clear();
    host.photo = PickedPhoto(await tinyPng());
    await actions.handle(action('poster_pick_photo'));
    expect(api.calls.where((x) => x.startsWith('upload')), isEmpty);
    expect(api.posters[15]!.photo!.id, 41, reason: 'the son\'s card keeps its own photo');
    expect(c.poster!.id, 15);
    expect(host.lines.single, PosterLines.cardNotOpened);
    host.lines.clear();
    await actions.handle(action('poster_sign'));
    expect(host.pads, 0);
    expect(host.lines.single, PosterLines.cardNotOpened);
  });

  test('the camera switched off is not "closed the picker"', () async {
    host.deny = const PhotoAccessDenied('camera');
    await actions.handle(action('poster_pick_photo_for_photo'));
    expect(host.lines.single, PosterLines.accessOff('camera'));
    expect(host.lines.single, isNot(PosterLines.pickerClosed));
    expect(host.lines.single, contains('Settings'));
  });

  test('a photo the server refuses: the model is told, and the card has no photo', () async {
    api.posters[12] = api.posters[12]!.copyWith(clearPhoto: true,
        spec: api.posters[12]!.spec.copyWith(photoUse: 'none'));
    api.uploadError = const PosterApiException(415, 'unsupported_type', "That photo doesn't open.");
    host.photo = PickedPhoto(await tinyPng());
    await actions.handle(action('poster_pick_photo'));
    expect(host.lines.single, PosterLines.photoFailed);
    expect(c.poster!.photo, isNull);
  });

  test('a closed signature pad changes nothing', () async {
    await c.open(api.posters[12]!.copyWith(spec: api.posters[12]!.spec.copyWith(signature: false)));
    await actions.handle(action('poster_sign'));
    expect(c.spec.signature, isFalse);
    expect(host.lines.single, PosterLines.signClosed);
  });
}
