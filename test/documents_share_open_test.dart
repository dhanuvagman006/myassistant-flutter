// DOCUMENTS: SHARE-IN, OPEN, SHARE-OUT, AND AN EVENT SEEN IN A PICTURE
// (defects of 2026-09-27, build 120).
//
//  - a recalled PDF, deck, document or sheet opens from the pop-up gallery
//    through the signed-in download, never a browser URL or Image.network;
//  - a shared deck, Word file or sheet goes out with its own extension,
//    not "<title>.jpg";
//  - a document received in chat is opened as what it is;
//  - Android offers the app for office files, CSV and text;
//  - a refusal the server explained is shown in its words, not blamed on
//    the connection; a file kept but not read says so;
//  - the event /vision reads off a screenshot becomes a one-tap card.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:myassistant/features/assistant/state/assistant_engine.dart';
import 'package:myassistant/features/assistant/widgets/action_cards.dart';
import 'package:myassistant/models/user_document.dart';
import 'package:myassistant/models/vision_result.dart';
import 'package:myassistant/screens/chat_screen.dart';
import 'package:myassistant/services/share_intake_service.dart';
import 'package:myassistant/widgets/assistant_result_overlay.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _pptx =
    'application/vnd.openxmlformats-officedocument.presentationml.presentation';
const _docx =
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
const _xlsx = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';

UserDocument _doc(String mime,
        {String title = 'Solar Energy for Homes', String filename = ''}) =>
    UserDocument(
      id: 7,
      filename: filename,
      mime: mime,
      title: title,
      category: 'other',
      docDate: '',
      summary: '',
      note: '',
      createdAt: 0,
    );

/// The glass cards tilt with the gyroscope; the test has none.
void _noSensors(WidgetTester tester) {
  final m = tester.binding.defaultBinaryMessenger;
  const methods = MethodChannel('dev.fluttercommunity.plus/sensors/method');
  const gyro = EventChannel('dev.fluttercommunity.plus/sensors/gyroscope');
  m.setMockMethodCallHandler(methods, (_) async => null);
  m.setMockStreamHandler(gyro, MockStreamHandler.inline(onListen: (_, __) {}));
  addTearDown(() {
    m.setMockMethodCallHandler(methods, null);
    m.setMockStreamHandler(gyro, null);
  });
}

void main() {
  GoogleFonts.config.allowRuntimeFetching = false;
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('sharing a document out', () {
    test('a deck, a Word file and a sheet keep their own extension, never .jpg', () {
      expect(shareFileName(_doc(_pptx), _pptx), 'Solar Energy for Homes.pptx');
      expect(shareFileName(_doc(_docx, title: 'Leave letter'), _docx),
          'Leave letter.docx');
      expect(shareFileName(_doc(_xlsx, title: 'Weekly shopping list'), _xlsx),
          'Weekly shopping list.xlsx');
      expect(shareFileName(_doc('text/csv', title: 'Tally'), 'text/csv'),
          'Tally.csv');
      expect(shareFileName(_doc('video/mp4', title: 'Video note for Nila'),
              'video/mp4'),
          'Video note for Nila.mp4');
      expect(shareFileName(_doc('image/jpeg', title: 'Aadhaar Card'), 'image/jpeg'),
          'Aadhaar Card.jpg');
    });

    test('an unhelpful download type falls back to the document\'s own', () {
      expect(
          shareFileName(_doc(_pptx), 'application/octet-stream'),
          'Solar Energy for Homes.pptx');
      expect(_doc('application/msword').fileExtension, '.doc',
          reason: 'an old Word file is not a .docx');
      expect(_doc('application/vnd.ms-excel').fileExtension, '.xls');
      expect(_doc('video/mp4').fileExtension, '.mp4');
    });
  });

  group('the pop-up gallery', () {
    testWidgets('a recalled deck gets its glyph and an Open button, not a broken image',
        (t) async {
      await t.pumpWidget(MaterialApp(
          home: DocumentGalleryScreen(documents: [_doc(_pptx)])));
      await t.pump();
      expect(find.byType(Image), findsNothing,
          reason: 'Image.network over a .pptx drew "Couldn\'t load this document."');
      expect(find.widgetWithText(OutlinedButton, 'Open'), findsOneWidget);
      expect(find.byIcon(Icons.slideshow_rounded), findsOneWidget);
      expect(find.text("Couldn't load this document."), findsNothing);
    });

    testWidgets('a PDF opens in the app (Open PDF), never through a browser URL',
        (t) async {
      await t.pumpWidget(MaterialApp(
          home: DocumentGalleryScreen(
              documents: [_doc('application/pdf', title: 'Car insurance')])));
      await t.pump();
      expect(find.widgetWithText(OutlinedButton, 'Open PDF'), findsOneWidget);
      final src = File('lib/features/assistant/widgets/action_cards.dart')
          .readAsStringSync();
      final gallery = src.substring(src.indexOf('class _DocumentGalleryScreenState'));
      expect(gallery, isNot(contains('launchUrl(')),
          reason: '/docs/:id/file in a browser has no session: "sign in required"');
      expect(gallery, contains('openDocumentFile(d)'));
    });
  });

  group('a document received in chat', () {
    test('is built from the type the server sends', () {
      final pdf = chatDocument(id: 3, mime: 'application/pdf', title: 'Receipt');
      expect(pdf.isPdf, isTrue);
      expect(pdf.isImage, isFalse, reason: 'it was always built as image/jpeg');
      expect(pdf.title, 'Receipt');
    });

    test('a video note is a video even from a server that sends no type', () {
      final v = chatDocument(id: 4, media: 'video');
      expect(v.mime, 'video/mp4');
      final old = chatDocument(id: 5);
      expect(old.mime, 'image/jpeg', reason: 'unknown keeps the old photo guess');
      expect(old.title, 'Document');
    });
  });

  group('sharing into the app', () {
    test('Android offers the app for office files, CSV and text', () {
      final m = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
      final send = RegExp(
              r'<intent-filter>\s*<action android:name="android\.intent\.action\.SEND"/>[\s\S]*?</intent-filter>')
          .allMatches(m)
          .map((x) => x.group(0)!)
          .join('\n');
      final multiple = RegExp(
              r'<intent-filter>\s*<action android:name="android\.intent\.action\.SEND_MULTIPLE"/>[\s\S]*?</intent-filter>')
          .allMatches(m)
          .map((x) => x.group(0)!)
          .join('\n');
      for (final type in [_docx, _xlsx, _pptx, 'text/csv', 'application/msword',
        'application/vnd.ms-excel', 'application/vnd.ms-powerpoint']) {
        expect(send, contains('android:mimeType="$type"'), reason: 'SEND $type');
        expect(multiple, contains('android:mimeType="$type"'),
            reason: 'SEND_MULTIPLE $type');
      }
      expect(m, isNot(contains('android:mimeType="*/*"')),
          reason: 'never a share target for everything');
    });

    test("a refusal the server explained is shown in its words, not 'check your connection'", () {
      const words = "That kind of file can't be saved here (unsupported type "
          'application/zip). Photos, PDFs, and office or text files can.';
      expect(ShareIntakeService.refusalMessage(const DocumentUploadException(415, words)),
          words);
      expect(
          ShareIntakeService.refusalMessage(const DocumentUploadException(
              413, 'file too large — the limit is 18 MB')),
          contains('18 MB'));
      expect(ShareIntakeService.refusalMessage(const DocumentUploadException(500, 'x')),
          isNull, reason: 'a server fault is not the user\'s file');
      expect(ShareIntakeService.refusalMessage(const DocumentUploadException(415, '')),
          isNull);
      expect(ShareIntakeService.refusalMessage(const SocketException('offline')),
          isNull);
    });

    test('a shared CSV or .txt FILE is a file, not a passage of text', () {
      final dir = Directory.systemTemp.createTempSync('share-intake-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final csv = File('${dir.path}/tally.csv')..writeAsStringSync('a,b\n1,2\n');
      // The plugin types text/* by mime, with the file's path as its "text"
      // (an Android path: absolute, from '/').
      if (!Platform.isWindows) {
        expect(ShareIntakeService.isSharedFile(SharedMediaType.text, csv.path),
            isTrue);
      }
      expect(
          ShareIntakeService.isSharedFile(
              SharedMediaType.text, 'https://example.com/story'),
          isFalse);
      expect(ShareIntakeService.isSharedFile(SharedMediaType.text, 'hello there'),
          isFalse);
      expect(ShareIntakeService.isSharedFile(SharedMediaType.file, '/x/a.docx'),
          isTrue);
      expect(ShareIntakeService.isSharedFile(SharedMediaType.url, '/x'), isFalse);
    });

    test('a file kept but not read says so (readable:false + notice)', () {
      final r = DocumentUploadResult.fromJson({
        'document': {'id': 9, 'filename': 'Accounts 2019.xls', 'mime': 'application/vnd.ms-excel'},
        'filedUnder': 'personal',
        'readable': false,
        'notice': "Saved. I can't read inside old Excel files.",
      });
      expect(r.readable, isFalse);
      expect(r.notice, startsWith('Saved.'));
      final older = DocumentUploadResult.fromJson({
        'document': {'id': 9, 'filename': 'a.jpg', 'mime': 'image/jpeg'},
      });
      expect(older.readable, isTrue, reason: 'a server without the field reads it');
      expect(older.notice, isNull);
    });
  });

  group('an event seen in a picture (look_at_screenshot)', () {
    final now = DateTime(2026, 9, 27, 12);
    VisionAction event({String? start = '2026-10-04T11:00:00+05:30', String? end}) =>
        VisionAction.fromJson({
          'type': 'calendar',
          'title': "Priya's wedding",
          'startIso': start,
          'endIso': end,
          'location': 'Mysuru',
        })!;

    test('the server\'s resolved date is read, and only a coming one is offered', () {
      final e = event();
      expect(e.isUpcoming(now), isTrue);
      expect(event(start: '2026-09-01T11:00:00+05:30').isUpcoming(now), isFalse);
      expect(event(start: '').isUpcoming(now), isFalse, reason: 'no date, no offer');
      expect(e.durationMin, 60);
      expect(event(end: '2026-10-04T13:30:00+05:30').durationMin, 150);
      final local = DateTime.parse('2026-10-04T11:00:00+05:30').toLocal();
      expect(e.whenLabel(now: now), contains('${local.day} Oct'));
      expect(e.whenLabel(now: now, withYear: true), contains('2026'));
    });

    testWidgets('the card offers Remind me and Add to calendar, one tap each',
        (t) async {
      _noSensors(t);
      var reminded = 0, calendared = 0, closed = 0;
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: EventOfferCard(
            event: event(),
            onRemind: () async {
              reminded++;
              return true;
            },
            onCalendar: () async {
              calendared++;
              return true;
            },
            onClose: () => closed++,
          ),
        ),
      ));
      expect(find.text("Priya's wedding"), findsOneWidget);
      expect(find.textContaining('Mysuru'), findsOneWidget);
      await t.tap(find.text('Remind me'));
      await t.pump();
      await t.tap(find.text('Add to calendar'));
      await t.pump();
      await t.tap(find.byTooltip('Close'));
      expect([reminded, calendared, closed], [1, 1, 1]);
    });

    testWidgets('the engine\'s seen event is the card on Home, above what is only read',
        (t) async {
      _noSensors(t);
      t.view.devicePixelRatio = 2.625;
      t.view.physicalSize = const Size(1080, 2340);
      addTearDown(t.view.reset);
      final engine = AssistantEngine.instance;
      addTearDown(() {
        engine
          ..seenEvent = null
          ..presentedTitle = null
          ..presentedText = null;
      });
      await t.pumpWidget(const MaterialApp(
          home: Scaffold(body: Stack(children: [AssistantResultOverlay()]))));
      engine
        ..presentedTitle = 'Your note'
        ..presentedText = 'Buy milk.'
        ..seenEvent = event()
        ..notifyListeners();
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      expect(find.byType(EventOfferCard), findsOneWidget);
      expect(find.byType(ScriptCard), findsNothing);
      engine.dismissSeenEvent();
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      expect(find.byType(EventOfferCard), findsNothing);
      expect(find.byType(ScriptCard), findsOneWidget);
    });
  });
}
