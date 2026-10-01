// THE CLARITY PASS (2026-09-24) — type, weight, targets and hierarchy.
//
// What the audit of build 106 found, pinned so it does not come back:
//
//  * text under 12 sp, and 28 font sizes, many half a point apart;
//  * weights that never drew: google_fonts gives each weight its own
//    family, so a bare TextStyle(fontWeight: w700) drew the regular file;
//  * white glyphs on the evening theme's pastel accent and tiles;
//  * targets under 48 dp — the Home suggestion chips, the calendar arrows,
//    the voice screen's Sound button;
//  * the calendar's thirty grey bordered tiles on an empty month;
//  * "Open settings" below the fold on "Do it for me";
//  * a label per row on You, and two section-label styles on two tabs;
//  * the same date twice on a document tile, and videos with no name.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:myassistant/design/accent_controller.dart';
import 'package:myassistant/design/apple_kit.dart';
import 'package:myassistant/design/neon_tokens.dart';
import 'package:myassistant/features/assistant/state/assistant_engine.dart';
import 'package:myassistant/features/assistant/state/assistant_state.dart';
import 'package:myassistant/models/user_document.dart';
import 'package:myassistant/screens/assistant_settings_screen.dart';
import 'package:myassistant/screens/home_dashboard.dart';
import 'package:myassistant/screens/hub_screen.dart';
import 'package:myassistant/theme/app_theme.dart';
import 'package:myassistant/widgets/document_tile.dart';
import 'package:myassistant/widgets/inline_voice.dart';
import 'package:myassistant/widgets/month_calendar.dart';
import 'package:shared_preferences/shared_preferences.dart';

const nightInk = Color(0xFF14121C);

/// Every Dart file under lib/, with its text.
Iterable<(String, String)> libSources() sync* {
  for (final f in Directory('lib').listSync(recursive: true)) {
    if (f is File && f.path.endsWith('.dart')) {
      yield (f.path.replaceAll('\\', '/'), f.readAsStringSync());
    }
  }
}

/// Runs [body] the way the layout sweep does: offline, so loaders fail
/// fast, and whatever that throws (no network, no plugin) is ignored. The
/// handler is put back before anything is checked.
Future<void> offline(Future<void> Function() body) async {
  final original = FlutterError.onError;
  FlutterError.onError = (d) {
    if (d.exceptionAsString().contains('overflowed')) original?.call(d);
  };
  try {
    await body();
  } finally {
    FlutterError.onError = original;
  }
}

Future<void> pumpOffline(WidgetTester t, Widget body) => offline(() async {
      await t.pumpWidget(MaterialApp(home: body));
      for (var i = 0; i < 6; i++) {
        await t.pump(const Duration(milliseconds: 300));
      }
    });

Future<void> closeApp(WidgetTester t) => offline(() async {
      await t.pumpWidget(const SizedBox());
      AssistantEngine.instance.cancelReconnect();
      await t.pump(const Duration(seconds: 5));
    });

/// The owner's phone width, tall enough that a whole tab is built.
void tallPhone(WidgetTester t) {
  t.view.devicePixelRatio = 2.625;
  t.view.physicalSize = const Size(1080, 5000);
  addTearDown(t.view.reset);
}

TextStyle styleOf(WidgetTester t, String text) =>
    t.widget<Text>(find.text(text)).style!;

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() {
    Neon.setDark(false);
    Neon.setAccent(AccentController.defaultSeed);
  });

  group('the type scale', () {
    test('no text under 12 sp, and no half-point sizes', () {
      final bad = <String>[];
      final size = RegExp(r'fontSize:\s*(\d+(?:\.\d+)?)\b');
      for (final (path, src) in libSources()) {
        final lines = src.split('\n');
        for (var i = 0; i < lines.length; i++) {
          for (final m in size.allMatches(lines[i])) {
            final v = double.parse(m.group(1)!);
            if (v < 12 || v != v.roundToDouble()) bad.add('$path:${i + 1} $v');
          }
        }
      }
      expect(bad, isEmpty, reason: 'off the scale: ${bad.join(', ')}');
    });

    test('the named sizes are the scale, floor 12', () {
      expect(NeonType.caption, 12);
      expect([
        NeonType.caption,
        NeonType.footnote,
        NeonType.body,
        NeonType.callout,
        NeonType.rowTitle,
        NeonType.headline,
        NeonType.title3,
        NeonType.title2,
        NeonType.largeTitle,
      ], orderedEquals([12, 13, 14, 15, 16, 17, 20, 26, 32]));
    });

    // A widget test on purpose: the styles start a font load, and in a
    // plain test that load completes (and fails, offline) after the test.
    testWidgets('the roles ask google_fonts for their REAL weight file',
        (t) async {
      // google_fonts names a weight's family "Manrope_700"; a bare
      // fontWeight on the theme's "Manrope_regular" drew the 400 file.
      expect(NeonType.row.fontFamily, 'Manrope_600');
      expect(NeonType.sectionLabel.fontFamily, 'Manrope_700');
      expect(NeonType.sectionTitle.fontFamily, 'Manrope_700');
      expect(NeonType.cardTitle.fontFamily, 'Manrope_700');
      expect(NeonType.manrope(13).fontFamily, 'Manrope_regular');
      expect(
          identical(NeonType.manrope(15, FontWeight.w700),
              NeonType.manrope(15, FontWeight.w700)),
          isTrue,
          reason: 'cached: one style per size and weight');
    });
  });

  // Review of the clarity pass (2026-09-24): build 107 had only ever
  // fetched Manrope Regular and SemiBold; this pass adds Medium, Bold and
  // ExtraBold. Until ux-fonts bundles them, they come from the network.
  group('the new weight files', () {
    test('every weight a call site asks NeonType for is preloaded', () {
      final call = RegExp(r'(?<!GoogleFonts\.)\bmanrope\(');
      final weight = RegExp(r'FontWeight\.w(\d)00');
      final missing = <String>{};
      for (final (path, src) in libSources()) {
        for (final m in call.allMatches(src)) {
          // The call's own arguments, up to its closing bracket.
          var depth = 1, i = m.end;
          while (depth > 0 && i < src.length) {
            final c = src[i++];
            if (c == '(') depth++;
            if (c == ')') depth--;
          }
          for (final w in weight.allMatches(src.substring(m.end, i))) {
            final fw = FontWeight.values[int.parse(w.group(1)!) - 1];
            if (!NeonType.weights.contains(fw)) missing.add('$path w${w[1]}00');
          }
        }
      }
      expect(missing, isEmpty,
          reason: 'add it to NeonType.weights so main() preloads it');
      expect(NeonType.weights,
          containsAll([FontWeight.w500, FontWeight.w700, FontWeight.w800]));
    });

    test('main() asks for them first and waits for them before runApp', () {
      final main = File('lib/main.dart').readAsStringSync();
      final start = main.indexOf('final fonts = NeonType.preload();');
      final wait = main.indexOf('await fonts;');
      expect(start, isNot(-1));
      expect(start, lessThan(main.indexOf('Firebase.initializeApp()')),
          reason: 'loads while Firebase starts, not after it');
      expect(wait, greaterThan(start));
      expect(wait, lessThan(main.indexOf('runApp(')));
    });

    testWidgets('the wait is capped and never throws, even offline',
        (t) async {
      await offline(() async {
        var done = false;
        Object? error;
        NeonType.preload(wait: const Duration(milliseconds: 400)).then<void>(
            (_) => done = true,
            onError: (Object e) => error = e);
        await t.pump(const Duration(milliseconds: 400));
        await t.pump();
        expect(error, isNull);
        expect(done, isTrue, reason: 'runApp never waits past the cap');
      });
    });
  });

  group('shared pieces', () {
    testWidgets('GroupLabel: one style, real bold, readable ink', (t) async {
      await t.pumpWidget(
          const MaterialApp(home: Scaffold(body: GroupLabel('Voice'))));
      final s = styleOf(t, 'VOICE');
      expect(s.fontFamily, 'Manrope_700');
      expect(s.fontSize, NeonType.footnote);
      expect(s.color, Neon.textLo,
          reason: 'textDim was 3.6:1 on the ambient wash');
    });

    // Review (2026-09-24): the clarity pass had moved these titles to
    // Manrope SemiBold on the belief that the bare style drew the regular
    // file. Inside an AppBar it inherits the theme's SpaceGrotesk_700, so
    // it already drew bold — and the swap gave detail bars a different
    // face from every plain AppBar.
    testWidgets('detail-bar titles keep the app-bar face: Space Grotesk bold',
        (t) async {
      TextStyle drawn(String text) => t
          .widget<RichText>(find.descendant(
              of: find.text(text), matching: find.byType(RichText)))
          .text
          .style!;
      await offline(() async {
        await t.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: Builder(
            builder: (context) => Scaffold(
              appBar: appleAppBar(context, 'Reminders'),
              body: Scaffold(appBar: AppBar(title: const Text('Plain'))),
            ),
          ),
        ));
      });
      final detail = drawn('Reminders');
      expect(detail.fontFamily, 'SpaceGrotesk_700');
      expect(detail.fontFamily, drawn('Plain').fontFamily,
          reason: 'one app-bar title face across the app');
      expect(detail.fontSize, NeonType.headline);
      expect(detail.color, Neon.textHi);
    });

    testWidgets(
        'AppleRow title is semibold for real; the button keeps the app font',
        (t) async {
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Column(children: [
            GroupedCard(children: [
              AppleRow(
                  title: 'Reminders', subtitle: 'Everything', onTap: () {}),
            ]),
            ApplePrimaryButton(label: 'Continue', onPressed: () {}),
          ]),
        ),
      ));
      expect(styleOf(t, 'Reminders').fontFamily, 'Manrope_600');
      expect(styleOf(t, 'Everything').fontSize, NeonType.footnote);
      // A bare TextStyle in a button REPLACES the theme font: the label
      // was drawn in the phone's default font.
      final label = t.widget<DefaultTextStyle>(find
          .ancestor(
              of: find.text('Continue'),
              matching: find.byType(DefaultTextStyle))
          .first);
      expect(label.style.fontFamily, 'Manrope_600');
      // The group has an edge on the flat ground.
      final m = t.widget<Material>(find
          .descendant(
              of: find.byType(GroupedCard), matching: find.byType(Material))
          .first);
      expect((m.shape as RoundedRectangleBorder).side.color, Neon.line);
    });

    testWidgets('tile glyphs: white by day, dark ink on the evening pastels',
        (t) async {
      Future<Color?> glyph() async {
        await t.pumpWidget(MaterialApp(
            home: Scaffold(
                body: IconTile(Icons.description_rounded, Neon.accentC))));
        return t.widget<Icon>(find.byIcon(Icons.description_rounded)).color;
      }

      expect(await glyph(), Colors.white);
      Neon.setDark(true);
      Neon.setAccent(const Color(0xFF8B9CFF)); // Indigo, the owner's
      expect(await glyph(), nightInk, reason: 'white on #3FE3FD was 1.4:1');
    });

    testWidgets('the mic glyph is white on its deep-navy centre, whatever the accent',
        (t) async {
      Neon.setDark(true);
      Neon.setAccent(const Color(0xFF8B9CFF));
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
              child: AssistantOrbButton(onTap: () {}, onLongPress: () {})),
        ),
      ));
      // The ring of light holds the accent now (2026-09-30); the glyph sits
      // on #0A1142–#1B2A7A, where white is well over 4.5:1.
      // 2026-09-30: the text white token (#F3F6FF), not a raw white.
      expect(t.widget<Icon>(find.byIcon(Icons.mic_rounded)).color, Neon.textHi);
    });
  });

  group('Home', () {
    testWidgets('the suggestion chips are 48 dp to the finger, and not clipped',
        (t) async {
      tallPhone(t); // What's new sits above the chips on a first run
      await pumpOffline(t, const Scaffold(body: HomeDashboard()));
      final chip = find.byIcon(Icons.graphic_eq_rounded).first;

      final target =
          find.ancestor(of: chip, matching: find.byType(GestureDetector)).first;
      expect(t.getSize(target).height, greaterThanOrEqualTo(48));
      final row = t.widget<ListView>(
          find.ancestor(of: chip, matching: find.byType(ListView)).first);
      expect(row.clipBehavior, Clip.none);
      await closeApp(t);
    });

    testWidgets('calendar: empty days are plain card; arrows are 48 dp',
        (t) async {
      await pumpOffline(t,
          const Scaffold(body: SingleChildScrollView(child: MonthCalendar())));
      for (final tip in ['Previous month', 'Next month']) {
        // The button, padded to its tap target (the tooltip wraps only
        // the 40 dp visual).
        final s = t.getSize(find
            .ancestor(
                of: find.byTooltip(tip), matching: find.byType(IconButton))
            .first);
        expect(s.width, greaterThanOrEqualTo(48), reason: tip);
        expect(s.height, greaterThanOrEqualTo(48), reason: tip);
      }
      final day = DateTime.now().day == 15 ? '16' : '15';
      final cell = t.widget<Container>(find
          .ancestor(of: find.text(day), matching: find.byType(Container))
          .first);
      final deco = cell.decoration! as BoxDecoration;
      expect(deco.color, Colors.transparent,
          reason: 'no grey tile on an empty day');
      expect(deco.border, isNull, reason: 'no border on an empty day');
      expect(styleOf(t, day).fontSize, NeonType.footnote);
      await closeApp(t);
    });
  });

  testWidgets('Hub uses the shared label and card', (t) async {
    tallPhone(t);
    await pumpOffline(t, const Scaffold(body: HubScreen()));
    // Seven since 2026-09-25: "Stay informed" holds News. Eight in build
    // 120: "Connections" holds Connected apps.
    expect(find.byType(GroupLabel), findsNWidgets(8));
    expect(find.byType(GroupedCard), findsNWidgets(8));
    expect(styleOf(t, 'YOUR DAY').color, Neon.textLo);
    await closeApp(t);
  });

  testWidgets('You: one Voice card, and Theme colour inside Appearance',
      (t) async {
    await pumpOffline(t, const AssistantSettingsScreen());
    GroupedCard cardOf(String text) => t.widget<GroupedCard>(find
        .ancestor(of: find.text(text), matching: find.byType(GroupedCard))
        .first);
    // One design in every theme (2026-09-30): Adaptive, Light and Dark are
    // gone; Theme colour stays in Appearance.
    expect(find.text('APPEARANCE'), findsOneWidget);
    expect(find.text('Adaptive'), findsNothing);
    expect(find.text('Theme colour'), findsOneWidget);
    cardOf('Theme colour');
    // Below Appearance and Home (News on Home, 2026-09-30).
    await t.scrollUntilVisible(find.text('VOICE'), 200,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('VOICE'), findsOneWidget);
    expect(find.text('ASSISTANT VOICE'), findsNothing);
    expect(find.text('RECOGNISE MY VOICE'), findsNothing);
    // Voice ID left with the live socket (2026-09-29): nothing heard the
    // owner's audio to check it against any more.
    expect(find.text('Voice ID'), findsNothing);
    expect(find.text('Respond only to my voice'), findsNothing);
    await closeApp(t);
  });

  group('the voice screen', () {
    tearDown(() {
      AssistantEngine.instance
        ..inlineVoice = false
        ..phase = AssistantPhase.idle;
    });

    testWidgets(
        'Manrope for everything but the spoken line; a readable hint; 48 dp Sound',
        (t) async {
      t.view.devicePixelRatio = 2.625;
      t.view.physicalSize = const Size(1080, 2340);
      addTearDown(t.view.reset);
      final engine = AssistantEngine.instance
        ..inlineVoice = true
        ..phase = AssistantPhase.listening;
      await t.pumpWidget(
          const MaterialApp(home: Scaffold(body: InlineCaptionOverlay())));
      engine.notifyListeners();
      await t.pump(const Duration(milliseconds: 400));

      final field = t.widget<TextField>(find.byType(TextField));
      expect(field.style!.fontFamily, startsWith('Manrope'));
      final hint = field.decoration!.hintStyle!;
      expect(hint.fontFamily, startsWith('Manrope'));
      expect(hint.color!.a, closeTo(0.52, 0.005), reason: '45% was 4.4:1');

      final sound = find.text('Sound on');
      expect(styleOf(t, 'Sound on').fontFamily, startsWith('Manrope'));
      final pill = find
          .ancestor(of: sound, matching: find.byType(GestureDetector))
          .first;
      expect(t.getSize(pill).height, greaterThanOrEqualTo(48));
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 1));
    });
  });

  group('documents', () {
    UserDocument doc(
            {String mime = 'application/pdf', String title = 'Report'}) =>
        UserDocument(
          id: 1,
          filename: 'x',
          mime: mime,
          title: title,
          category: '',
          docDate: '2026-09-20',
          summary: '',
          note: '',
          createdAt: 0,
        );

    test('a video has its own name and glyph', () {
      final v = doc(mime: 'video/mp4', title: 'Video — Cineastic');
      expect(v.kind, 'other', reason: 'display only: the kind is unchanged');
      expect(documentTypeLabel(v), 'Video');
      expect(documentGlyph(v).icon, Icons.movie_rounded);
    });

    testWidgets('the grid says the date once, and never breaks inside it',
        (t) async {
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 120,
            height: 170,
            child: DocumentGridTile(
              document: doc(title: 'Document · 20 Sept 2026'),
              onOpen: () {},
              onLongPress: () {},
            ),
          ),
        ),
      ));
      expect(find.text('Document · 20 Sept 2026'), findsOneWidget);
      expect(find.text('PDF'), findsOneWidget,
          reason: 'no second date under it');
      expect(styleOf(t, 'PDF').fontSize, NeonType.caption);
    });
  });

  test('words in red take errorInk, and the dead blurred sheets are gone', () {
    final red =
        RegExp(r'TextStyle\(color: (Neon\.error|AppleColors\.red)\b(?!Ink)');
    final hits = [
      for (final (path, src) in libSources())
        if (red.hasMatch(src)) path,
    ];
    expect(hits, isEmpty, reason: '#EF4444 words are 3.8:1 on white');
    final home = File('lib/features/home/home_cards.dart').readAsStringSync();
    expect(home.contains('BackdropFilter('), isFalse);
  });
}
