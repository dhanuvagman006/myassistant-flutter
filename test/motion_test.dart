// ONE MOTION SYSTEM (2026-09-24, "need more smoothness while using the
// app"). The audit found eleven durations and eight curves typed by hand,
// pages that floated up a quarter of the screen, tabs that cut, cards and
// panels that appeared in one frame, a spoken line that shimmered with
// every word, press dips on every scroll and a mic that spun back into its
// notch. These pin the fixes by what the framework is asked to draw:
//   * a page slides in a short way from the side (a modal rises a little),
//     the page under it steps back, and with "Remove animations" pages
//     only fade;
//   * tabs fade through; hidden tabs and tabs under a session cannot tick;
//   * the spoken line takes new words in place, and a finished line shrinks
//     into the older ones;
//   * a press dips only under a resting finger, never on a scroll;
//   * cards and panels grow out of the dock without crossing it;
//   * the tilt of a result card never rebuilds the card, shares one sensor
//     stream and ignores tremor;
//   * the dock does not bounce, and the mic does not spin back in.
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:myassistant/design/gyro_tilt.dart';
import 'package:myassistant/design/motion.dart';
import 'package:myassistant/features/assistant/state/assistant_engine.dart';
import 'package:myassistant/features/assistant/state/assistant_state.dart';
import 'package:myassistant/features/assistant/widgets/action_cards.dart';
import 'package:myassistant/models/news_item.dart';
import 'package:myassistant/screens/assistant_settings_screen.dart';
import 'package:myassistant/screens/chat_screen.dart';
import 'package:myassistant/screens/home_dashboard.dart';
import 'package:myassistant/screens/hub_screen.dart';
import 'package:myassistant/services/brief_service.dart';
import 'package:myassistant/shell/home_shell.dart';
import 'package:myassistant/theme/app_theme.dart';
import 'package:myassistant/widgets/assistant_result_overlay.dart';
import 'package:myassistant/widgets/inline_voice.dart';
import 'package:myassistant/widgets/news_panel.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The owner's phone: 1080 x 2340 at 2.625 (411 x 891 dp).
void _ownersPhone(WidgetTester tester) {
  tester.view.devicePixelRatio = 2.625;
  tester.view.physicalSize = const Size(1080, 2340);
  addTearDown(tester.view.reset);
}

Future<void> _settle(WidgetTester tester, [int steps = 8]) async {
  for (var i = 0; i < steps; i++) {
    await tester.pump(const Duration(milliseconds: 300));
  }
}

Future<void> _teardownShell(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  // The assistant keeps retrying its server offline (by design).
  AssistantEngine.instance.cancelReconnect();
  await tester.pump(const Duration(seconds: 5));
  tester.takeException();
}

/// "Remove animations" (Samsung: Accessibility › Visibility enhancements).
Widget _reduced(BuildContext context, Widget? child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: true),
      child: child!,
    );

/// The phone's gyroscope, played by the test.
const _gyro = EventChannel('dev.fluttercommunity.plus/sensors/gyroscope');
const _sensorMethods = MethodChannel('dev.fluttercommunity.plus/sensors/method');

class _Sensor {
  int listens = 0;
  MockStreamHandlerEventSink? sink;

  void install(WidgetTester tester) {
    final m = tester.binding.defaultBinaryMessenger;
    m.setMockMethodCallHandler(_sensorMethods, (_) async => null);
    m.setMockStreamHandler(
      _gyro,
      MockStreamHandler.inline(
        onListen: (_, events) {
          listens++;
          sink = events;
        },
        onCancel: (_) => sink = null,
      ),
    );
    addTearDown(() {
      m.setMockMethodCallHandler(_sensorMethods, null);
      m.setMockStreamHandler(_gyro, null);
    });
  }

  /// One reading, in rad/s.
  void rate(double x, double y) =>
      sink?.success(<double>[x, y, 0, 0]);
}

/// A card with state of its own, to see whether a tilt rebuilds it.
class _Probe extends StatefulWidget {
  const _Probe(this.label);
  final String label;
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  Widget build(BuildContext context) =>
      SizedBox(width: 200, height: 80, child: Text(widget.label));
}

/// For the tests that use the assistant: put it back as it was.
void _resetEngineAfter() {
  addTearDown(() {
    AssistantEngine.instance
      ..inlineVoice = false
      ..phase = AssistantPhase.idle
      ..presentedTitle = null
      ..presentedText = null
      ..newsItems = const [];
    AssistantEngine.instance.caption.value = null;
    BriefService.instance.loaded = false;
    HomeShell.lastTab = 0;
  });
}

double _opacityProduct(WidgetTester tester, Finder of) {
  var p = 1.0;
  for (final e in find
      .ancestor(of: of, matching: find.byType(FadeTransition))
      .evaluate()) {
    p *= (e.widget as FadeTransition).opacity.value;
  }
  return p;
}

void main() {
  // No network in tests: fall back to the default font.
  GoogleFonts.config.allowRuntimeFetching = false;

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('pages', () {
    Future<NavigatorState> app(WidgetTester tester, {bool reduced = false}) async {
      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(
          pageTransitionsTheme: const PageTransitionsTheme(builders: {
            TargetPlatform.android: AppPageTransitions(),
            TargetPlatform.iOS: AppPageTransitions(),
          }),
        ),
        navigatorKey: nav,
        builder: reduced ? _reduced : null,
        home: const Scaffold(body: Text('home')),
      ));
      return nav.currentState!;
    }

    testWidgets('a page slides in from the side and is solid half-way; the page under it steps back',
        (tester) async {
      final nav = await app(tester);
      nav.push(MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('page'))));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      final page = tester.getTopLeft(find.text('page'));
      expect(page.dx, greaterThan(0), reason: 'it comes in from the side');
      expect(page.dy, 0, reason: 'it used to rise a quarter of the screen');
      expect(tester.getTopLeft(find.text('home')).dx, lessThan(0),
          reason: 'the page underneath steps back');

      await tester.pump(const Duration(milliseconds: 60)); // half-way
      expect(_opacityProduct(tester, find.text('page')), greaterThan(0.99),
          reason: 'it was a ghost, a third opaque, half-way in');

      await tester.pump(const Duration(milliseconds: 150));
      expect(tester.getTopLeft(find.text('page')), Offset.zero);

      // Back: it leaves to the side it came from, in 200 ms.
      nav.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(tester.getTopLeft(find.text('page')).dx, greaterThan(0));
      expect(tester.getTopLeft(find.text('page')).dy, 0,
          reason: 'Back used to drop the page a quarter of the screen');
      await tester.pump(const Duration(milliseconds: 60));
      expect(find.text('page'), findsNothing);
      expect(tester.getTopLeft(find.text('home')), Offset.zero);
    });

    testWidgets('a full-screen modal rises a little; nothing moves under it',
        (tester) async {
      final nav = await app(tester);
      nav.push(MaterialPageRoute<void>(
          fullscreenDialog: true,
          builder: (_) => const Scaffold(body: Text('gallery'))));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      final at = tester.getTopLeft(find.text('gallery'));
      expect(at.dx, 0);
      expect(at.dy, greaterThan(0));
      expect(at.dy, lessThan(0.07 * 2340 / 2.625 * 2.625),
          reason: 'a little, not a quarter of the screen');
      expect(tester.getTopLeft(find.text('home')), Offset.zero);
      await tester.pump(const Duration(milliseconds: 250));
    });

    testWidgets('reduced: page transition has no slide', (tester) async {
      final nav = await app(tester, reduced: true);
      nav.push(MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('page'))));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(tester.getTopLeft(find.text('page')), Offset.zero,
          reason: 'with "Remove animations" on, nothing slides');
      expect(tester.getTopLeft(find.text('home')), Offset.zero);
      final o = _opacityProduct(tester, find.text('page'));
      expect(o, greaterThan(0));
      expect(o, lessThan(1), reason: 'it still fades');
      await tester.pump(const Duration(milliseconds: 250));
    });

    testWidgets('a section on a page that is still sliding in does not drift in again',
        (tester) async {
      final nav = await app(tester);
      nav.push(MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Reveal(child: Text('section')))));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      final own = find.descendant(
          of: find.byType(EnterOnce), matching: find.byType(FadeTransition));
      expect(tester.widget<FadeTransition>(own.first).opacity.value, 1.0,
          reason: 'the page brings it in; a second drift kept it moving 600 ms');
      await tester.pump(const Duration(milliseconds: 300));
    });
  });

  group('first appearance', () {
    testWidgets('a stagger never waits more than 200 ms', (tester) async {
      await tester.pumpWidget(const MaterialApp(
          home: Scaffold(body: Reveal(delayMs: 600, child: Text('row 20')))));
      await tester.pump(const Duration(milliseconds: 199));
      expect(_opacityProduct(tester, find.text('row 20')), 0);
      await tester.pump(const Duration(milliseconds: 1)); // the cap
      await tester.pump(const Duration(milliseconds: 300));
      expect(_opacityProduct(tester, find.text('row 20')), 1,
          reason: 'row twenty of the sent list started 570 ms late');
      expect(SchedulerBinding.instance.transientCallbackCount, 0);
    });

    testWidgets('a quick load never flashes a spinner; a slow one shows it',
        (tester) async {
      Widget at(bool loading) => MaterialApp(
          home: Scaffold(
              body: LoadSwitch(loading: loading, child: const Text('loaded'))));
      await tester.pumpWidget(at(true));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await tester.pumpWidget(at(false));
      await tester.pump();
      expect(find.text('loaded'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(CircularProgressIndicator), findsNothing,
          reason: 'a fast load flashed a spinner for a frame or three');

      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(at(true));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(CircularProgressIndicator), findsOneWidget,
          reason: 'a slow load still says it is loading');
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('tabs', () {
    Future<void> home(WidgetTester tester) async {
      _resetEngineAfter();
      _ownersPhone(tester);
      BriefService.instance.loaded = true;
      await tester.pumpWidget(const MaterialApp(home: HomeShell()));
      await _settle(tester);
    }

    bool ticks(WidgetTester tester, Type t) => TickerMode.valuesOf(
            tester.element(find.byType(t, skipOffstage: false)))
        .enabled;

    testWidgets('hidden tabs cannot tick, nor can the tabs under a session',
        (tester) async {
      await home(tester);
      expect(ticks(tester, HomeDashboard), isTrue);
      for (final hidden in [HubScreen, ChatScreen, AssistantSettingsScreen]) {
        expect(ticks(tester, hidden), isFalse,
            reason: '$hidden animated behind Home (a spinner on a hidden '
                'Chat kept the phone drawing 60 frames a second)');
      }

      HomeShell.requestedTab.value = 2; // "open my chats"
      await _settle(tester, 2);
      expect(ticks(tester, ChatScreen), isTrue);
      expect(ticks(tester, HomeDashboard), isFalse);

      AssistantEngine.instance
        ..inlineVoice = true
        ..phase = AssistantPhase.listening
        ..notifyListeners();
      await _settle(tester, 3);
      expect(InlineCaptionOverlay.covering.value, isTrue);
      expect(ticks(tester, ChatScreen), isFalse,
          reason: 'nobody can see the tab under the session move');

      AssistantEngine.instance
        ..inlineVoice = false
        ..phase = AssistantPhase.idle
        ..notifyListeners();
      await _settle(tester, 2);
      expect(ticks(tester, ChatScreen), isTrue);
      await _teardownShell(tester);
    });

    testWidgets('switching tabs fades the new tab in, then asks for no frames',
        (tester) async {
      await home(tester);
      final fade = find.ancestor(
          of: find.byType(IndexedStack), matching: find.byType(FadeTransition));
      double opacity() => tester.widget<FadeTransition>(fade.first).opacity.value;
      expect(opacity(), 1);

      HomeShell.requestedTab.value = 1; // Hub
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(opacity(), greaterThan(0));
      expect(opacity(), lessThan(1),
          reason: 'switching tabs was a hard one-frame cut');
      await tester.pump(const Duration(milliseconds: 200));
      expect(opacity(), 1);
      await _settle(tester);
      expect(SchedulerBinding.instance.transientCallbackCount, 0);
      expect(tester.binding.hasScheduledFrame, isFalse);
      await _teardownShell(tester);
    });

    testWidgets('the selected tab grows a little and does not bounce; its label keeps one weight',
        (tester) async {
      await home(tester);
      final dock = find.byType(BottomAppBar);
      HomeShell.requestedTab.value = 1;
      var most = 0.0;
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        for (final e in find
            .descendant(of: dock, matching: find.byType(ScaleTransition))
            .evaluate()) {
          final v = (e.widget as ScaleTransition).scale.value;
          if (v > most) most = v;
        }
      }
      expect(most, greaterThan(1.0));
      expect(most, lessThanOrEqualTo(1.06 + 1e-9),
          reason: 'it overshot to ~1.13 on easeOutBack');
      final hub = tester.widget<Text>(
          find.descendant(of: dock, matching: find.text('Hub')));
      final chat = tester.widget<Text>(
          find.descendant(of: dock, matching: find.text('Chat')));
      expect(hub.style!.fontWeight, chat.style!.fontWeight,
          reason: 'the label thickened and re-centred when selected');
      await _teardownShell(tester);
    });

    testWidgets('the mic leaves at once for the keyboard and comes back without a spin',
        (tester) async {
      await home(tester);
      tester.view.viewInsets = const FakeViewPadding(bottom: 1190);
      await tester.pump();
      expect(find.byType(AssistantOrbButton), findsNothing,
          reason: 'it stayed, riding up over the text box as it shrank');
      await tester.pump(const Duration(milliseconds: 300));
      tester.view.resetViewInsets();
      await tester.pump();
      expect(_opacityProduct(tester, find.byIcon(Icons.mic_rounded)), lessThan(1),
          reason: 'it fades in as it grows back');
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        for (final e in find
            .ancestor(
                of: find.byType(AssistantOrbButton),
                matching: find.byType(RotationTransition))
            .evaluate()) {
          expect((e.widget as RotationTransition).turns.value, 1.0,
              reason: 'the mic spun 45° back into its notch');
        }
      }
      expect(find.byType(AssistantOrbButton), findsOneWidget);
      await _teardownShell(tester);
    });
  });

  group('the spoken line', () {
    Future<void> session(WidgetTester tester) async {
      _resetEngineAfter();
      _ownersPhone(tester);
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: InlineCaptionOverlay()),
      ));
      AssistantEngine.instance
        ..inlineVoice = true
        ..phase = AssistantPhase.listening
        ..notifyListeners();
      await tester.pump(const Duration(milliseconds: 400));
    }

    Future<void> close(WidgetTester tester) async {
      AssistantEngine.instance
        ..inlineVoice = false
        ..phase = AssistantPhase.idle
        ..notifyListeners();
      await _settle(tester, 3);
    }

    testWidgets('new words join the line in place instead of cross-fading a copy of it',
        (tester) async {
      await session(tester);
      final engine = AssistantEngine.instance;
      engine.caption.value = const CaptionLine('you', 'Book a table');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      engine.caption.value = const CaptionLine('you', 'Book a table for two');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      final line = find.text('Book a table for two');
      expect(line, findsOneWidget);
      final switcher =
          find.ancestor(of: line, matching: find.byType(AnimatedSwitcher)).first;
      expect(find.descendant(of: switcher, matching: find.byType(Text)),
          findsOneWidget,
          reason: 'every word cross-faded the whole line into a copy of itself');
      expect(find.text('Book a table'), findsNothing);
      await close(tester);
    });

    testWidgets('a finished line shrinks into the older lines instead of snapping',
        (tester) async {
      await session(tester);
      final engine = AssistantEngine.instance;
      const first = 'Please book a table for two at the Italian place near the';
      engine.caption.value = const CaptionLine('you', first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      engine.caption.value = const CaptionLine('you', '$first office tonight');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text(first), findsOneWidget,
          reason: 'a second, fading copy of the finished line ghosted under it');
      double size() => tester.widget<Text>(find.text(first)).style!.fontSize!;
      expect(size(), greaterThan(15.5),
          reason: 'it snapped from the spotlight to the older size in one frame');
      expect(find.text('office tonight'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 300));
      expect(size(), 15.5);
      await close(tester);
    });
  });

  group('press', () {
    Widget rows({bool reduced = false}) => MaterialApp(
          builder: reduced ? _reduced : null,
          home: Scaffold(
            body: ListView(children: [
              for (var i = 0; i < 20; i++)
                PressScale(
                    child: SizedBox(height: 80, child: Text('row $i'))),
            ]),
          ),
        );

    double scaleOf(WidgetTester tester, String row) => tester
        .widget<AnimatedScale>(find.ancestor(
            of: find.text(row), matching: find.byType(AnimatedScale)))
        .scale;

    testWidgets('a resting finger dips it, and it comes back', (tester) async {
      await tester.pumpWidget(rows());
      final g = await tester.startGesture(tester.getCenter(find.text('row 1')));
      await tester.pump(const Duration(milliseconds: 100));
      expect(scaleOf(tester, 'row 1'), lessThan(1.0));
      await g.up();
      await tester.pump();
      expect(scaleOf(tester, 'row 1'), 1.0);
      await tester.pump(const Duration(milliseconds: 300));
    });

    testWidgets('a quick tap still gets a short dip', (tester) async {
      await tester.pumpWidget(rows());
      await tester.tap(find.text('row 1'));
      await tester.pump();
      expect(scaleOf(tester, 'row 1'), lessThan(1.0));
      await tester.pump(const Duration(milliseconds: 250));
      expect(scaleOf(tester, 'row 1'), 1.0);
      await tester.pump(const Duration(milliseconds: 300));
    });

    testWidgets('a scroll that starts on it never dips it', (tester) async {
      await tester.pumpWidget(rows());
      final g = await tester.startGesture(tester.getCenter(find.text('row 3')));
      await g.moveBy(const Offset(0, -30));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 30));
        expect(scaleOf(tester, 'row 3'), 1.0,
            reason: 'the tile under a scroll stayed shrunk for the whole drag');
        await g.moveBy(const Offset(0, -10));
      }
      await g.up();
      await tester.pumpAndSettle();
    });

    testWidgets('with Remove animations on, it never dips', (tester) async {
      await tester.pumpWidget(rows(reduced: true));
      final g = await tester.startGesture(tester.getCenter(find.text('row 1')));
      await tester.pump(const Duration(milliseconds: 150));
      expect(scaleOf(tester, 'row 1'), 1.0);
      await g.up();
      await tester.pump(const Duration(milliseconds: 300));
    });
  });

  group('cards and panels', () {
    Future<void> overlay(WidgetTester tester, {bool reduced = false}) async {
      _resetEngineAfter();
      _ownersPhone(tester);
      _Sensor().install(tester);
      await tester.pumpWidget(MaterialApp(
        builder: reduced ? _reduced : null,
        home: const Scaffold(body: Stack(children: [AssistantResultOverlay()])),
      ));
      AssistantEngine.instance
        ..presentedTitle = 'Your note'
        ..presentedText = 'Buy milk and bread on the way home.'
        ..notifyListeners();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
    }

    testWidgets('a result card grows out of the mic, never crossing it, and leaves at once',
        (tester) async {
      await overlay(tester);
      final early = tester.getRect(find.byType(ScriptCard));
      expect(_opacityProduct(tester, find.byType(ScriptCard)), lessThan(1),
          reason: 'cards appeared at full size in one frame');
      await tester.pump(const Duration(milliseconds: 300));
      final settled = tester.getRect(find.byType(ScriptCard));
      expect(_opacityProduct(tester, find.byType(ScriptCard)), 1);
      expect(early.height, lessThan(settled.height), reason: 'it grows');
      expect(early.bottom, moreOrLessEquals(settled.bottom, epsilon: 0.5),
          reason: 'about its bottom edge, just above the mic');

      AssistantEngine.instance.dismissPresentedText();
      await tester.pump();
      expect(find.byType(ScriptCard), findsNothing, reason: 'closing stays instant');
    });

    testWidgets('reduced: a card appears in place', (tester) async {
      await overlay(tester, reduced: true);
      final early = tester.getRect(find.byType(ScriptCard));
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.getRect(find.byType(ScriptCard)), early,
          reason: 'with "Remove animations" on, nothing grows or moves');
    });

    testWidgets('the headlines fade in and grow without their list crossing the dock line',
        (tester) async {
      _resetEngineAfter();
      _ownersPhone(tester);
      tester.view.padding = const FakeViewPadding(bottom: 300);
      await tester.pumpWidget(const MaterialApp(
        home: Material(child: Stack(children: [NewsPanel()])),
      ));
      AssistantEngine.instance
        ..newsItems = const [
          NewsItem(title: 'Monsoon arrives early', url: 'https://example.com'),
        ]
        ..notifyListeners();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      final list = find
          .descendant(of: find.byType(NewsPanel), matching: find.byType(Scrollable))
          .first;
      final early = tester.getRect(list);
      expect(_opacityProduct(tester, list), lessThan(1),
          reason: 'the panel appeared in one frame');
      await tester.pump(const Duration(milliseconds: 300));
      final settled = tester.getRect(list);
      expect(_opacityProduct(tester, list), 1);
      expect(early.bottom, moreOrLessEquals(settled.bottom, epsilon: 0.5),
          reason: 'the list must end at the dock line on every frame');
      expect(early.width, lessThan(settled.width));
    });
  });

  group('tilt', () {
    Future<List<State>> cards(WidgetTester tester, _Sensor sensor) async {
      sensor.install(tester);
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: Column(children: [
            GyroTilt(child: _Probe('one')),
            GyroTilt(child: _Probe('two')),
            GyroTilt(child: _Probe('three')),
          ]),
        ),
      ));
      await tester.pump();
      return [
        for (final l in ['one', 'two', 'three'])
          tester.state(find.ancestor(of: find.text(l), matching: find.byType(_Probe))),
      ];
    }

    testWidgets('one sensor stream for every card, tremor ignored, and a tilt never rebuilds the card',
        (tester) async {
      final sensor = _Sensor();
      final before = await cards(tester, sensor);
      expect(sensor.listens, 1, reason: 'one gyroscope stream per card');

      // A hand holding the phone still: tremor under the deadband.
      for (var i = 0; i < 5; i++) {
        sensor.rate(0.03, -0.02);
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(SchedulerBinding.instance.transientCallbackCount, 0,
          reason: 'tremor kept the app drawing 60 frames a second');

      // A real turn of the wrist.
      sensor.rate(1.2, 0.8);
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 16));
      expect(SchedulerBinding.instance.transientCallbackCount, greaterThan(0));
      final tilted = tester.widget<Transform>(find
          .ancestor(of: find.text('one'), matching: find.byType(Transform))
          .first);
      expect(tilted.transform.isIdentity(), isFalse, reason: 'it tilts');

      // The phone rests: the tilt settles and the ticker sleeps.
      sensor.rate(0, 0);
      for (var i = 0; i < 180; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(SchedulerBinding.instance.transientCallbackCount, 0);

      final after = [
        for (final l in ['one', 'two', 'three'])
          tester.state(find.ancestor(of: find.text(l), matching: find.byType(_Probe))),
      ];
      for (var i = 0; i < 3; i++) {
        expect(identical(before[i], after[i]), isTrue,
            reason: 'moving the phone threw the card away and built it again');
      }
      await tester.pumpWidget(const SizedBox());
      expect(sensor.sink, isNull, reason: 'the stream closes with the last card');
    });

    testWidgets('with Remove animations on, the sensor is never opened',
        (tester) async {
      final sensor = _Sensor()..install(tester);
      await tester.pumpWidget(const MaterialApp(
        builder: _reduced,
        home: Scaffold(body: GyroTilt(child: _Probe('still'))),
      ));
      await tester.pump();
      expect(sensor.listens, 0);
      expect(find.text('still'), findsOneWidget);
    });
  });
}
