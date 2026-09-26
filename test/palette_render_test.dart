import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:myassistant/design/accent_controller.dart';
import 'package:myassistant/design/gpu_programs.dart';
import 'package:myassistant/design/neon_tokens.dart';
import 'package:myassistant/features/assistant/state/assistant_engine.dart';
import 'package:myassistant/models/brief.dart';
import 'package:myassistant/models/momentum.dart';
import 'package:myassistant/services/auth_service.dart';
import 'package:myassistant/services/brief_service.dart';
import 'package:myassistant/services/momentum_service.dart';
import 'package:myassistant/shell/home_shell.dart';
import 'package:myassistant/theme/app_theme.dart';
import 'package:myassistant/widgets/whats_new_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// COLOUR OPTIONS FOR THE CLIENT (2026-09-26). The owner: "the client is
/// not satisfied with the color… create a PDF of multiple color
/// combinations… with the front home page screenshot in that color
/// palette". Each candidate re-skins the REAL Home screen, filled with
/// sample content, on the owner's phone size, and is written out as a PNG.
///
/// Opt-in, since it renders a dozen full screens:
///   flutter test test/palette_render_test.dart \
///     --dart-define=PALETTE_RENDERS=build/palette_renders
const _out = String.fromEnvironment('PALETTE_RENDERS');

/// A larger set, as JSON ({"themes": [{number, name, dark, bg, surface,
/// raised, primary, partner, info, third, text, text2, hint}]}), rendered
/// instead of the twelve below, as <number>.png:
///   --dart-define=PALETTE_FILE=path/to/palettes.json
const _file = String.fromEnvironment('PALETTE_FILE');

Color _hex(String h) => Color(int.parse('FF${h.replaceFirst('#', '')}', radix: 16));

List<(String, NeonPalette)> _fromFile() {
  final j = jsonDecode(File(_file).readAsStringSync()) as Map<String, dynamic>;
  return [
    for (final t in (j['themes'] as List).cast<Map<String, dynamic>>())
      (
        (t['number'] as int).toString().padLeft(3, '0'),
        NeonPalette(
          name: t['name'] as String,
          dark: t['dark'] as bool,
          bg: _hex(t['bg'] as String),
          surface: _hex(t['surface'] as String),
          surfaceHigh: _hex(t['raised'] as String),
          primary: _hex(t['primary'] as String),
          partner: _hex(t['partner'] as String),
          secondary: _hex(t['info'] as String),
          tertiary: _hex(t['third'] as String),
          textHi: _hex(t['text'] as String),
          textLo: _hex(t['text2'] as String),
          textDim: _hex(t['hint'] as String),
          success: t['dark'] as bool ? _okDark : _okLight,
          warning: t['dark'] as bool ? _warnDark : _warnLight,
          error: t['dark'] as bool ? _errDark : _errLight,
        ),
      ),
  ];
}

const Color _okDark = Color(0xFF4ADE80), _warnDark = Color(0xFFFBBF24), _errDark = Color(0xFFF87171);
const Color _okLight = Color(0xFF15803D), _warnLight = Color(0xFFB45309), _errLight = Color(0xFFDC2626);

NeonPalette _darkP(String name, List<int> c) => NeonPalette(
      name: name, dark: true,
      bg: Color(c[0]), surface: Color(c[1]), surfaceHigh: Color(c[2]),
      primary: Color(c[3]), partner: Color(c[4]),
      secondary: Color(c[5]), tertiary: Color(c[6]),
      textHi: Color(c[7]), textLo: Color(c[8]), textDim: Color(c[9]),
      success: _okDark, warning: _warnDark, error: _errDark,
    );

NeonPalette _lightP(String name, List<int> c) => NeonPalette(
      name: name, dark: false,
      bg: Color(c[0]), surface: Color(c[1]), surfaceHigh: Color(c[2]),
      primary: Color(c[3]), partner: Color(c[4]),
      secondary: Color(c[5]), tertiary: Color(c[6]),
      textHi: Color(c[7]), textLo: Color(c[8]), textDim: Color(c[9]),
      success: _okLight, warning: _warnLight, error: _errLight,
    );

/// Order of each list: page, card, raised, primary, partner, info, third,
/// words, secondary words, hints.
final palettes = <NeonPalette>[
  _darkP('Midnight Gold', [0xFF0B1120, 0xFF131B2E, 0xFF1C2640, 0xFFE6B85C, 0xFFD98F4E,
      0xFF7FB2E5, 0xFF8FD1A8, 0xFFF7F3EA, 0xFFC9C2B2, 0xFF918B7F]),
  _darkP('Emerald Night', [0xFF05130E, 0xFF0C2019, 0xFF133026, 0xFF34D399, 0xFF22B8CF,
      0xFF93C5FD, 0xFFFCD34D, 0xFFECFDF5, 0xFFB6D3C6, 0xFF7E9E91]),
  _darkP('Royal Plum', [0xFF140B1C, 0xFF201229, 0xFF2D1A3A, 0xFFE8A87C, 0xFFD86A9B,
      0xFFA99BF5, 0xFF7DD3C0, 0xFFFBF2F6, 0xFFD4C2D0, 0xFF9E8A9C]),
  _darkP('Peacock', [0xFF04181C, 0xFF0A262B, 0xFF103339, 0xFF1FC7B6, 0xFF3B82F6,
      0xFFF2C94C, 0xFF7BD88F, 0xFFEAFBF8, 0xFFB3D6D1, 0xFF7CA39E]),
  _darkP('Graphite & Coral', [0xFF121316, 0xFF1B1D21, 0xFF25282D, 0xFFFF7B5C, 0xFFFFB86B,
      0xFF64C7F2, 0xFFB9E57C, 0xFFF5F5F6, 0xFFC6C7CC, 0xFF8E9097]),
  _darkP('Mocha Cream', [0xFF16110D, 0xFF221A14, 0xFF2E241C, 0xFFD9A066, 0xFFE07A5F,
      0xFF8EC5B0, 0xFFF2CC8F, 0xFFF8F1E7, 0xFFD2C4B3, 0xFF9E8E7C]),
  _lightP('Pearl & Navy', [0xFFF5F7FB, 0xFFFFFFFF, 0xFFE9EDF5, 0xFF1E3A8A, 0xFF2F6FEB,
      0xFF0E7490, 0xFFB7791F, 0xFF0F172A, 0xFF475569, 0xFF64748B]),
  _lightP('Sage & Terracotta', [0xFFF4F6F1, 0xFFFFFFFF, 0xFFE8ECE3, 0xFF3F6B4E, 0xFFC0683A,
      0xFF2F6F7E, 0xFFA7822A, 0xFF1D2820, 0xFF4C5A50, 0xFF68756B]),
  _lightP('Saffron Sunrise', [0xFFFFF8F0, 0xFFFFFFFF, 0xFFFAEEDF, 0xFFD9480F, 0xFFF08C00,
      0xFF0B7285, 0xFF2B8A3E, 0xFF2A1A10, 0xFF6A5344, 0xFF877061]),
  _lightP('Lavender Calm', [0xFFF7F5FC, 0xFFFFFFFF, 0xFFEEEAF8, 0xFF6D4BD8, 0xFFC2519A,
      0xFF2F7EC7, 0xFF2E9E6F, 0xFF1E1A2E, 0xFF564F6B, 0xFF6F6887]),
  _lightP('Rose Gold Blush', [0xFFFBF6F4, 0xFFFFFFFF, 0xFFF4E9E5, 0xFFA85C6A, 0xFFC98B5E,
      0xFF4F74A6, 0xFF6E9A74, 0xFF2B2023, 0xFF67575B, 0xFF84747A]),
  _lightP('Classic Black & Teal', [0xFFFAFAFA, 0xFFFFFFFF, 0xFFEFEFEF, 0xFF111827, 0xFF0D9488,
      0xFF2563EB, 0xFFD97706, 0xFF0A0A0A, 0xFF4B5563, 0xFF6B7280]),
];

const _screen = ValueKey('palette-screen');

Map<String, dynamic> _brief(DateTime now) {
  int at(int h, int m) => DateTime(now.year, now.month, now.day, h, m).millisecondsSinceEpoch;
  return {
    'weather_line': 'Sunny · 29°C',
    'messages': [
      {'from': 'Priya', 'text': 'Can we move the review to 4 pm?'},
    ],
    'agenda': [
      {'kind': 'meeting', 'id': 1, 'title': 'Client review call', 'at': at(11, 30)},
      {'kind': 'reminder', 'id': 2, 'title': 'Pay the electricity bill', 'at': at(17, 0)},
      {'kind': 'reminder', 'id': 3, 'title': 'Evening walk', 'at': at(19, 0)},
    ],
    'promises': [
      {'id': 1, 'text': 'Send the proposal to Ravi', 'due_label': 'Today'},
      {'id': 2, 'text': 'Call Amma back', 'due_label': 'Tomorrow'},
    ],
  };
}

Map<String, dynamic> _momentum(DateTime now) {
  final day = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  return {
    'ok': true,
    'day': day,
    'priorities': [
      {'id': 1, 'title': 'Finish the quarterly report', 'done': true, 'position': 0},
      {'id': 2, 'title': 'Review the new designs', 'done': false, 'position': 1},
      {'id': 3, 'title': '30 minutes of reading', 'done': false, 'position': 2},
    ],
    'habits': [
      {'id': 1, 'title': 'Drink water', 'doneToday': true, 'streak': 6, 'best': 9,
        'last7': [true, true, true, false, true, true, true]},
      {'id': 2, 'title': 'Walk', 'doneToday': false, 'streak': 3, 'best': 5,
        'last7': [true, false, true, true, true, false, false]},
    ],
    'focus': {'todayMin': 50, 'weekMin': 240, 'totalMin': 900},
    'streak': {'current': 5, 'best': 8, 'activeToday': true, 'graceUsedThisWeek': false},
    'week': {'days': [], 'wins': 9, 'focusMin': 240, 'habitsKept': 11},
    'milestones': [],
  };
}

String _slug(String name) =>
    name.toLowerCase().replaceAll('&', 'and').replaceAll(RegExp(r'[^a-z0-9]+'), '-');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  for (final name in [
    'com.llfbandit.record/messages',
    'xyz.luan/audioplayers.global',
    'xyz.luan/audioplayers',
  ]) {
    messenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null);
  }

  setUpAll(() async {
    if (_out.isEmpty) return;
    GoogleFonts.config.allowRuntimeFetching = false;
    for (final w in NeonType.weights) {
      GoogleFonts.manrope(fontWeight: w);
    }
    for (final w in const [FontWeight.w500, FontWeight.w600, FontWeight.w700]) {
      GoogleFonts.spaceGrotesk(fontWeight: w);
    }
    await GoogleFonts.pendingFonts();
    await (FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
        .load();
    await Future.wait([
      GpuProgram.ambient.load(),
      GpuProgram.siriOrb.load(),
      GpuProgram.voiceBackdrop.load(),
    ]);
    final report = FlutterError.onError;
    FlutterError.onError = (_) {};
    AssistantEngine.instance;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    FlutterError.onError = report;
  });

  tearDown(() {
    Neon.usePalette(null);
    Neon.setDark(false);
    Neon.setAccent(AccentController.defaultSeed);
    BriefService.instance.loaded = false;
    HomeShell.lastTab = 0;
  });

  Future<void> render(WidgetTester tester, String file, {NeonPalette? palette}) async {
    messenger.setMockStreamHandler(
        const EventChannel('xyz.luan/audioplayers.global/events'),
        MockStreamHandler.inline(onListen: (_, __) {}));
    SharedPreferences.setMockInitialValues({
      'whats_new_seen_${WhatsNewCard.release}': true,
    });
    tester.view.devicePixelRatio = 2.625;
    tester.view.physicalSize = const Size(1080, 2340);
    addTearDown(tester.view.reset);

    if (palette == null) {
      Neon.usePalette(null);
      Neon.setDark(false);
      Neon.setAccent(AccentController.defaultSeed);
    } else {
      Neon.usePalette(palette);
    }
    final now = DateTime.now();
    AuthService.instance.user = const AppUser(id: 1, name: 'Sir', provider: 'email');
    BriefService.instance
      ..brief = TodayBrief.fromJson(_brief(now))
      ..loaded = true;
    MomentumService.instance.debugSeed(MomentumSummary.fromJson(_momentum(now)));
    HomeShell.lastTab = 0;

    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(RepaintBoundary(
      key: _screen,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        home: const HomeShell(),
      ),
    ));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(_screen));
    final png = await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 2.625);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data!.buffer.asUint8List();
    });
    Directory(_out).createSync(recursive: true);
    File('$_out/$file.png').writeAsBytesSync(png!);

    await tester.pumpWidget(const SizedBox());
    AssistantEngine.instance.cancelReconnect();
    // Home starts both services' five-minute refresh; stop them, or the
    // first render ends with their timers still pending.
    await BriefService.instance.reset();
    await MomentumService.instance.reset();
    await tester.pump(const Duration(seconds: 5));
    tester.takeException();
  }

  if (_file.isNotEmpty) {
    for (final (file, p) in _fromFile()) {
      testWidgets('palette $file: ${p.name}', (tester) async {
        await render(tester, file, palette: p);
      }, skip: _out.isEmpty);
    }
    return;
  }

  testWidgets('today\'s look, for reference', (tester) async {
    await render(tester, '00-current');
  }, skip: _out.isEmpty);

  for (final (i, p) in palettes.indexed) {
    testWidgets('palette: ${p.name}', (tester) async {
      await render(tester, '${(i + 1).toString().padLeft(2, '0')}-${_slug(p.name)}', palette: p);
    }, skip: _out.isEmpty);
  }
}
