import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/features/poster/poster_controller.dart' show PickedPhoto;
import 'package:myassistant/features/poster/poster_share.dart';
import 'package:myassistant/features/poster_studio/studio_actions.dart';
import 'package:myassistant/features/poster_studio/studio_api.dart';
import 'package:myassistant/features/poster_studio/studio_controller.dart';
import 'package:myassistant/features/poster_studio/studio_fonts.dart';
import 'package:myassistant/features/poster_studio/studio_models.dart';
import 'package:myassistant/features/poster_studio/studio_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<Uint8List> pngOf(Color c, {int w = 60, int h = 75}) async {
  final rec = ui.PictureRecorder();
  ui.Canvas(rec).drawRect(ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), ui.Paint()..color = c);
  final img = await rec.endRecording().toImage(w, h);
  final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
  return bytes!.buffer.asUint8List();
}

class FakeStudioApi implements PosterStudioApi {
  final calls = <String>[];
  EventDesign? designReply;
  StudioApiException? designError;
  StudioApiException? backgroundError;
  StudioBackground painted = const StudioBackground(id: '77', url: '/docs/77/file');
  final jobs = <StudioJob>[];
  Uint8List? picture;
  final saved = <({Uint8List png, String name, String note})>[];

  @override
  Future<EventDesign> design(String request,
      {StudioFormat format = StudioFormat.portrait, String? brandName, List<Color> brandColours = const []}) async {
    calls.add('design:$request');
    if (designError != null) throw designError!;
    return designReply ?? EventDesign(title: request);
  }

  @override
  Future<StudioBackground> background(
      {required String prompt, required String style, required StudioFormat format, int? seed}) async {
    calls.add('background:$prompt:${format.name}:$seed');
    if (backgroundError != null) throw backgroundError!;
    return painted;
  }

  @override
  Future<StudioJob> job(String jobId) async {
    calls.add('job:$jobId');
    return jobs.isEmpty ? StudioJob(jobId, 'running') : jobs.removeAt(0);
  }

  @override
  Future<Uint8List> bytes(StudioBackground b) async {
    calls.add('bytes:${b.id}');
    return picture ??= await pngOf(const Color(0xFFFFFFFF));
  }

  @override
  Future<bool> saveFinal(Uint8List png, {required String name, String note = ''}) async {
    saved.add((png: png, name: name, note: note));
    return true;
  }
}

class FakeShare extends PosterShare {
  final sent = <({Uint8List png, String name, String app})>[];
  ShareOutcome answer = ShareOutcome.whatsapp;

  @override
  Future<ShareOutcome> share(Uint8List png,
      {required String name, String app = 'whatsapp', bool saveToPhotos = false}) async {
    sent.add((png: png, name: name, app: app));
    return answer;
  }

  @override
  Future<bool> saveToPhotos(Uint8List png, String name) async => true;
}

class FakeHost implements PosterStudioHost {
  int shown = 0;
  @override
  bool showStudio() {
    shown++;
    return true;
  }
}

const designJson = {
  'title': 'Annual Day 2026',
  'subtitle': 'Music, dance and dinner',
  'dateText': 'Saturday, 4 October',
  'timeText': '',
  'location': '',
  'cta': 'All are welcome',
  'details': ['Entry free'],
  'style': 'neon night party',
  'palette': {'primary': '#22E4FF', 'secondary': '#E040FB', 'accent': '#4D8BFF', 'ink': '#F6F8FF'},
  'backgroundPrompt': 'a glowing stage at night',
  'missing': ['venue', 'time', 'price'],
  'format': 'portrait',
  'date': '2026-10-04',
  'source': 'ai',
};

Future<void> settle(PosterStudioController c) async {
  for (var i = 0; i < 200 && (c.generating || c.designing); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  await Future<void>.delayed(const Duration(milliseconds: 20));
}

/// THE POSTER STUDIO (2026-09-30): the words are his, set by the phone;
/// the AI paints only the picture.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => StudioFonts.ensureLoaded());
  setUp(() => SharedPreferences.setMockInitialValues({}));

  late FakeStudioApi api;
  late FakeShare share;
  late PosterStudioController c;

  setUp(() {
    api = FakeStudioApi();
    share = FakeShare();
    c = PosterStudioController(api: api, sharer: share, pollEvery: Duration.zero);
  });

  group('open_poster_studio', () {
    test('opens the studio with every line of the design filled in, then the background', () async {
      final host = FakeHost();
      await PosterStudioActions(host: host, controller: c).handle({
        'type': 'open_poster_studio',
        'request': 'Poster for our annual day on Saturday',
        'design': designJson,
        'backgroundId': 77,
        'background': {'id': 77, 'url': '/docs/77/file', 'width': 1080, 'height': 1350, 'provider': 'fal', 'mime': 'image/jpeg'},
      });
      expect(host.shown, 1);
      expect(c.design.title, 'Annual Day 2026');
      expect(c.design.subtitle, 'Music, dance and dinner');
      expect(c.design.dateText, 'Saturday, 4 October');
      expect(c.design.details, ['Entry free']);
      expect(c.template.id, 'neon_night', reason: 'the style word picks the template');
      final l = c.prepared!.layout;
      expect(l.block(StudioField.title)!.text, 'Annual Day 2026');
      expect(l.block(StudioField.cta)!.text, 'All are welcome');
      await settle(c);
      expect(api.calls, contains('bytes:77'));
      expect(c.imageSource, 'ai');
      expect(c.image, isNotNull);
      expect(c.prepared!.scene.image, same(c.image));
      // A white picture: the words get their scrim.
      expect(c.prepared!.panels, isNotEmpty);
    });

    test('a background still being painted is polled until it is done', () async {
      api.jobs.addAll([
        const StudioJob('j1', 'running'),
        const StudioJob('j1', 'running'),
        const StudioJob('j1', 'done', background: StudioBackground(id: '91', url: '/docs/91/file')),
      ]);
      await PosterStudioActions(host: FakeHost(), controller: c)
          .handle({'type': 'open_poster_studio', 'design': designJson, 'backgroundJob': 'j1'});
      expect(c.design.title, 'Annual Day 2026');
      await settle(c);
      expect(api.calls.where((x) => x == 'job:j1').length, 3);
      expect(api.calls, contains('bytes:91'));
      expect(c.imageSource, 'ai');
    });

    test('a failed picture leaves the drawn background and says so', () async {
      api.jobs.add(const StudioJob('j2', 'failed', error: 'generation_failed'));
      await PosterStudioActions(host: FakeHost(), controller: c)
          .handle({'type': 'open_poster_studio', 'design': designJson, 'backgroundJob': 'j2'});
      await settle(c);
      expect(c.image, isNull);
      expect(c.notice, contains('drawn background'));
      expect(c.prepared, isNotNull, reason: 'the poster still shows, on drawn art');
    });

    test('other device actions are not its business', () async {
      final host = FakeHost();
      await PosterStudioActions(host: host, controller: c).handle({'type': 'poster_show'});
      expect(host.shown, 0);
    });
  });

  group('missing lines', () {
    test('each line he did not say is asked for, and goes away once answered or skipped', () async {
      await c.openDirective(StudioDirective.fromJson({'design': designJson}));
      await settle(c);
      expect(c.prompts.map((p) => p.label), ['Add location?', 'Add time?', 'Add price?']);
      c.answer(c.prompts.first, 'Town Hall, MG Road');
      expect(c.design.location, 'Town Hall, MG Road');
      expect(c.prompts.map((p) => p.label), ['Add time?', 'Add price?']);
      c.answer(c.prompts.last, '₹200');
      expect(c.design.details, ['Entry free', 'Entry: ₹200']);
      c.skip(c.prompts.single);
      expect(c.prompts, isEmpty);
      await c.refresh();
      expect(c.prepared!.layout.block(StudioField.location)!.text, 'Town Hall, MG Road');
    });

    test("the server's own field names are asked for in plain words", () {
      const d = EventDesign(title: 'Meetup', missing: ['dateText', 'timeText', 'location', 'contact', 'speaker']);
      expect(studioPrompts(d, {}).map((p) => p.label),
          ['Add date?', 'Add time?', 'Add location?', 'Add contact number?', 'Add speaker?']);
    });

    test('a line typed in Edit text stops being asked for', () async {
      await c.openDirective(StudioDirective.fromJson({'design': designJson}));
      c.setAll({StudioField.time: '6:30 PM'});
      expect(c.prompts.map((p) => p.label), isNot(contains('Add time?')));
      expect(c.design.when, 'Saturday, 4 October  ·  6:30 PM');
    });
  });

  group('the picture', () {
    test('AI pictures switched off: the drawn background, no error', () async {
      api.backgroundError = const StudioApiException(503, 'off', 'Image generation is off');
      await c.openDirective(StudioDirective.fromJson({'design': designJson}));
      await settle(c);
      expect(c.aiOff, isTrue);
      expect(c.image, isNull);
      expect(c.notice, contains('drawn background'));
      expect(c.prepared, isNotNull);
    });

    test('Regenerate asks with a new seed; Variation changes the arrangement', () async {
      await c.openDirective(StudioDirective.fromJson({'design': designJson}));
      await settle(c);
      final first = api.calls.lastWhere((x) => x.startsWith('background:'));
      await c.newPicture();
      await settle(c);
      final second = api.calls.lastWhere((x) => x.startsWith('background:'));
      expect(second, isNot(first));
      expect(second, startsWith('background:a glowing stage at night:portrait:'));
      expect(c.template.style, 'neon');
      final v = c.variant;
      c.variation();
      expect(c.variant, (v + 1) % 3);
    });

    test('his own photo replaces the picture', () async {
      await c.openDirective(StudioDirective.fromJson({'design': designJson}));
      await settle(c);
      expect(await c.usePhoto(PickedPhoto(await pngOf(const Color(0xFF203040)))), isTrue);
      expect(c.imageSource, 'photo');
    });

    test('a brand colour becomes a palette and is remembered', () async {
      await c.openDirective(StudioDirective.fromJson({'design': designJson}));
      await c.addBrandColour(const Color(0xFF1E88E5));
      expect(c.palette.brand, isTrue);
      expect(c.palette.primary, const Color(0xFF1E88E5));
      final again = PosterStudioController(api: api, sharer: share);
      await again.loadBrandColours();
      expect(again.brandColours, [const Color(0xFF1E88E5)]);
    });
  });

  group('sharing', () {
    test('share sends the full-size PNG to WhatsApp and keeps one copy in his documents', () async {
      await c.openDirective(StudioDirective.fromJson({'design': designJson}));
      await settle(c);
      expect(await c.share(), ShareOutcome.whatsapp);
      expect(share.sent.single.app, 'whatsapp');
      expect(share.sent.single.name, 'Annual Day 2026 Saturday, 4 October.png');
      final codec = await ui.instantiateImageCodec(share.sent.single.png);
      final frame = await codec.getNextFrame();
      expect((frame.image.width, frame.image.height), (1080, 1350));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(api.saved.single.note, 'Event poster: Annual Day 2026');
      // The same poster again: not a second copy.
      await c.share(app: 'any');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(share.sent.length, 2);
      expect(api.saved.length, 1);
    });

    test('a poster with a line that does not fit is never sent', () async {
      await c.openDirective(StudioDirective.fromJson({'design': designJson}));
      c.setField(StudioField.details, [for (var i = 0; i < 80; i++) 'A very long detail line $i'].join('\n'));
      await c.refresh();
      expect(c.needs, isNotEmpty);
      expect(await c.share(), ShareOutcome.failed);
      expect(share.sent, isEmpty);
    });
  });

  group('screen', () {
    Future<void> pump(WidgetTester t, {StudioPhotoPicker? pick}) async {
      await t.binding.setSurfaceSize(const Size(420, 900));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(MaterialApp(home: PosterStudioScreen(controller: c, pickPhoto: pick)));
      await t.pump();
    }

    testWidgets('the missing lines show as "Add location?" and fill the poster', (t) async {
      await t.runAsync(() async {
        await c.openDirective(StudioDirective.fromJson({'design': designJson}));
        await settle(c);
      });
      await pump(t);
      expect(find.text('Add location?'), findsOneWidget);
      expect(find.text('Share on WhatsApp'), findsOneWidget);
      for (final tool in ['Regenerate', 'Style', 'Colours', 'Edit text', 'Change image', 'Variation']) {
        expect(find.text(tool), findsOneWidget, reason: tool);
      }
      await t.tap(find.text('Add location?'));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField).last, 'Kerala Samajam Hall');
      await t.tap(find.text('Add to poster'));
      await t.pumpAndSettle();
      expect(c.design.location, 'Kerala Samajam Hall');
      expect(find.text('Add location?'), findsNothing);
    });

    testWidgets('Edit text highlights the missing lines', (t) async {
      await t.runAsync(() async {
        await c.openDirective(StudioDirective.fromJson({'design': designJson}));
        await settle(c);
      });
      await pump(t);
      await t.tap(find.text('Edit text'));
      await t.pumpAndSettle();
      expect(find.text('Add location?'), findsWidgets);
      expect(find.text('Add time?'), findsWidgets);
      await t.enterText(find.widgetWithText(TextField, 'Title'), 'Annual Day 2027');
      await t.dragUntilVisible(find.text('Done'), find.byType(ListView).last, const Offset(0, -200));
      await t.pumpAndSettle();
      await t.tap(find.text('Done'));
      await t.pumpAndSettle();
      expect(c.design.title, 'Annual Day 2027');
    });

    testWidgets('Style and Colours change the look', (t) async {
      await t.runAsync(() async {
        await c.openDirective(StudioDirective.fromJson({'design': designJson}));
        await settle(c);
      });
      await pump(t);
      await t.tap(find.text('Style'));
      await t.pumpAndSettle();
      expect(find.text('Bold Minimal'), findsOneWidget);
      await t.tap(find.text('Corporate Clean'));
      await t.pumpAndSettle();
      expect(c.template.id, 'corporate_clean');
      await t.tap(find.text('Colours'));
      await t.pumpAndSettle();
      await t.tap(find.text('Gold'));
      await t.pumpAndSettle();
      expect(c.palette.id, 'gold');
      expect(c.paletteChosen, isTrue);
    });

    testWidgets('Share on WhatsApp takes the share path', (t) async {
      await t.runAsync(() async {
        await c.openDirective(StudioDirective.fromJson({'design': designJson}));
        await settle(c);
      });
      await pump(t);
      await t.tap(find.text('Share on WhatsApp'));
      // The PNG is drawn by the engine: let real time pass, then the
      // test's own clock, until it has gone.
      for (var i = 0; i < 100 && share.sent.isEmpty; i++) {
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await t.pump();
      }
      expect(share.sent.single.app, 'whatsapp');
    });

    testWidgets('an empty studio asks what the event is and designs it', (t) async {
      await pump(t);
      expect(find.text("What's the event?"), findsOneWidget);
      await t.enterText(find.byType(TextField).first, 'Onam sadya on Sunday');
      await t.tap(find.text('Design my poster'));
      await t.runAsync(() => settle(c));
      await t.pump();
      expect(api.calls.first, 'design:Onam sadya on Sunday');
      expect(c.design.title, 'Onam sadya on Sunday');
    });
  });
}
