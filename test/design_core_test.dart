// THE DESIGN CORE (2026-09-30, the client's neon direction). Pins what the
// screens build on:
//   * the theme names every colour role and floating surface (no purple-
//     grey SDK default is left for a menu, picker, tooltip or toast);
//   * a pushed page stands under Home's sky, which never ticks and is not
//     painted again when the page above it changes;
//   * a press dips at once where nothing scrolls (and still waits inside a
//     list); Tappable, NeonPill, AppleRow and GlowCard all answer a touch;
//   * a card flies into its page on one surface;
//   * a sheet rises on a spring that does not bounce;
//   * the state widgets: the loader, the lit empty state, the danger-lit
//     error and a success mark that settles and stops.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:myassistant/design/apple_kit.dart';
import 'package:myassistant/design/motion.dart';
import 'package:myassistant/design/neon_tokens.dart';
import 'package:myassistant/design/neon_widgets.dart';
import 'package:myassistant/services/app_feedback.dart';
import 'package:myassistant/theme/app_theme.dart';
import 'package:myassistant/widgets/ambient_background.dart';

Widget _reduced(BuildContext context, Widget? child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: true),
      child: child!,
    );

double _scaleAbove(WidgetTester tester, Finder f) => tester
    .widget<AnimatedScale>(
        find.ancestor(of: f, matching: find.byType(AnimatedScale)).first)
    .scale;

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);
  late bool wasDark;
  setUp(() {
    wasDark = Neon.isDark;
    Neon.setDark(true);
  });
  tearDown(() => Neon.setDark(wasDark));

  group('the theme', () {
    test('every colour role is a token, never the seed\'s purple-grey', () {
      final s = AppTheme.light().colorScheme;
      expect(s.surface, Neon.surface);
      expect(s.surfaceContainerLowest, Neon.bg);
      expect(s.surfaceContainerLow, Neon.surface);
      expect(s.surfaceContainer, Neon.surface);
      expect(s.surfaceContainerHigh, Neon.surfaceHigh);
      expect(s.surfaceTint.a, 0, reason: 'M3 tints raised surfaces lilac');
      expect(s.outline, Neon.lineBright);
      expect(s.outlineVariant, Neon.line);
      expect(s.onSurfaceVariant, Neon.textLo);
      expect(s.inverseSurface, Neon.surfaceHigh);
      expect(s.onSecondary, Neon.textOn(Neon.cyan),
          reason: 'white on bright cyan was 1.6:1');
    });

    test('every surface a screen can open is themed, and floats lit', () {
      final t = AppTheme.light();
      expect(t.canvasColor, Neon.surface);
      expect(t.popupMenuTheme.color, Neon.surfaceHigh);
      expect(t.menuTheme.style?.backgroundColor?.resolve({}), Neon.surfaceHigh);
      expect(t.dropdownMenuTheme.menuStyle, isNotNull);
      expect(t.datePickerTheme.backgroundColor, Neon.surface);
      expect(t.timePickerTheme.backgroundColor, Neon.surface);
      expect(t.tooltipTheme.decoration, isNotNull);
      expect(t.dialogTheme.barrierColor, Neon.scrim);
      expect(t.dialogTheme.shadowColor?.withValues(alpha: 1),
          Neon.violet.withValues(alpha: 1));
      expect(t.textSelectionTheme.cursorColor, Neon.cyan);
      expect(t.checkboxTheme.fillColor, isNotNull);
      expect(t.radioTheme.fillColor, isNotNull);
      expect(t.scrollbarTheme.thumbColor, isNotNull);
      expect(t.badgeTheme.backgroundColor, Neon.pink);
      expect(t.switchTheme.trackOutlineColor, isNotNull);
      expect(t.progressIndicatorTheme.strokeCap, StrokeCap.round);
      expect(t.listTileTheme.titleTextStyle, isNotNull);
      expect(t.chipTheme.selectedColor, isNotNull);
      expect(t.chipTheme.checkmarkColor, Neon.cyan);
      // The white navigation-bar trap is gone.
      expect(t.navigationBarTheme.backgroundColor!.computeLuminance(),
          lessThan(0.05));
    });

    test('the chosen day in a date picker reads on its fill', () {
      final d = AppTheme.light().datePickerTheme;
      final fill = d.dayBackgroundColor!.resolve({WidgetState.selected})!;
      final ink = d.dayForegroundColor!.resolve({WidgetState.selected})!;
      final a = fill.computeLuminance(), b = ink.computeLuminance();
      final ratio = (a > b ? a + 0.05 : b + 0.05) / (a > b ? b + 0.05 : a + 0.05);
      expect(ratio, greaterThanOrEqualTo(4.5));
    });
  });

  group('NeonScaffold', () {
    testWidgets('a pushed page stands under the sky: static, on its own layer',
        (tester) async {
      var n = 0;
      late StateSetter bump;
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(),
        home: NeonScaffold(
          appBar: AppBar(title: const Text('Page')),
          body: StatefulBuilder(builder: (context, set) {
            bump = set;
            return Text('count $n');
          }),
        ),
      ));
      expect(find.byType(AmbientLight), findsOneWidget);
      await tester.pump();
      await tester.pump();
      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
      expect(scaffold.backgroundColor!.a, 0,
          reason: 'an opaque Scaffold would hide the sky');
      expect(SchedulerBinding.instance.transientCallbackCount, 0,
          reason: 'the sky must never tick');
      expect(tester.binding.hasScheduledFrame, isFalse);

      final sky = tester.renderObject<RenderRepaintBoundary>(find.descendant(
          of: find.byType(AmbientLight),
          matching: find.byType(RepaintBoundary)));
      final before = sky.debugSymmetricPaintCount;
      bump(() => n++);
      await tester.pump();
      expect(find.text('count 1'), findsOneWidget);
      expect(sky.debugSymmetricPaintCount, before,
          reason: 'the sky was painted again for a change on the page');
    });

    testWidgets('sky: false is the plain ground', (tester) async {
      await tester.pumpWidget(const MaterialApp(
          home: NeonScaffold(sky: false, body: Text('x'))));
      expect(find.byType(AmbientLight), findsNothing);
      expect(tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
          Neon.bg);
    });
  });

  group('press', () {
    testWidgets('where nothing scrolls, it dips on the first touch',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: Center(
                child: PressScale(
                    scale: 0.94, child: SizedBox(width: 80, height: 80, child: Text('b'))))),
      ));
      final g = await tester.startGesture(tester.getCenter(find.text('b')));
      await tester.pump();
      expect(_scaleAbove(tester, find.text('b')), 0.94);
      await g.up();
      await tester.pump();
      expect(_scaleAbove(tester, find.text('b')), 1.0);
      await tester.pumpAndSettle();
    });

    testWidgets('inside a list it still waits for a resting finger',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ListView(children: [
            for (var i = 0; i < 5; i++)
              PressScale(child: SizedBox(height: 80, child: Text('row $i'))),
          ]),
        ),
      ));
      final g = await tester.startGesture(tester.getCenter(find.text('row 1')));
      await tester.pump();
      expect(_scaleAbove(tester, find.text('row 1')), 1.0);
      await tester.pump(const Duration(milliseconds: 100));
      expect(_scaleAbove(tester, find.text('row 1')), lessThan(1.0));
      await g.up();
      await tester.pumpAndSettle();
    });

    testWidgets('Tappable: dips, taps, long-presses, reads as a button',
        (tester) async {
      var taps = 0, holds = 0;
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: Tappable(
              onTap: () => taps++,
              onLongPress: () => holds++,
              semanticLabel: 'Open the story',
              child: const SizedBox(width: 120, height: 80, child: Text('card')),
            ),
          ),
        ),
      ));
      final g = await tester.startGesture(tester.getCenter(find.text('card')));
      await tester.pump();
      expect(_scaleAbove(tester, find.text('card')), 0.97);
      await g.up();
      await tester.pumpAndSettle();
      expect(taps, 1);
      await tester.longPress(find.text('card'));
      await tester.pumpAndSettle();
      expect(holds, 1);
      expect(
          tester.getSemantics(find.byType(Tappable)),
          matchesSemantics(
            label: 'Open the story\ncard',
            isButton: true,
            hasTapAction: true,
            hasLongPressAction: true,
            onTapHint: 'open',
          ));
      handle.dispose();
    });

    testWidgets('Tappable with nothing to do is its child, untouched',
        (tester) async {
      await tester.pumpWidget(
          const MaterialApp(home: Tappable(child: Text('plain'))));
      expect(find.byType(PressScale), findsNothing);
    });

    testWidgets('NeonPill, AppleRow and GlowCard(onTap) answer a touch',
        (tester) async {
      var hits = 0;
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Column(children: [
            NeonPill(label: 'Remind me', onPressed: () => hits++),
            AppleRow(title: 'A row', onTap: () => hits++),
            GlowCard(
                onTap: () => hits++,
                child: const SizedBox(height: 60, child: Text('lit card'))),
          ]),
        ),
      ));
      for (final (label, dip) in [
        ('Remind me', 0.95),
        ('A row', 0.985),
        ('lit card', 0.97),
      ]) {
        final g = await tester.startGesture(tester.getCenter(find.text(label)));
        await tester.pump();
        expect(_scaleAbove(tester, find.text(label)), dip, reason: label);
        await g.up();
        await tester.pumpAndSettle();
      }
      expect(hits, 3);
    });

    testWidgets('a disabled pill does not dip', (tester) async {
      await tester.pumpWidget(const MaterialApp(
          home: Scaffold(body: Center(child: NeonPill(label: 'Off')))));
      expect(find.byType(PressScale), findsNothing);
    });
  });

  group('a card opens into its page', () {
    Widget app(GlobalKey<NavigatorState> nav, {bool reduced = false}) =>
        MaterialApp(
          navigatorKey: nav,
          theme: AppTheme.light(),
          builder: reduced ? _reduced : null,
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 200,
                child: GlowCard(
                  heroTag: cardHeroTag(7),
                  child: const SizedBox(height: 90, child: Text('the card')),
                ),
              ),
            ),
          ),
        );

    Route<void> page() => MaterialPageRoute<void>(
          builder: (_) => NeonScaffold(
            body: Hero(
              tag: cardHeroTag(7),
              flightShuttleBuilder: cardFlight,
              child: const SizedBox(
                  height: 300, width: double.infinity, child: Text('the page')),
            ),
          ),
        );

    testWidgets('one surface grows from the card to the page, and back',
        (tester) async {
      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(app(nav));
      nav.currentState!.push(page());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      final flying = find.byWidgetPredicate(
          (w) => w.runtimeType.toString() == '_CardFlight');
      expect(flying, findsOneWidget);
      final clip = tester.widget<ClipRRect>(
          find.descendant(of: flying, matching: find.byType(ClipRRect)));
      final r = (clip.borderRadius as BorderRadius).topLeft.x;
      expect(r, lessThan(Neon.rLg));
      expect(r, greaterThan(0), reason: 'the corners straighten as it grows');
      await tester.pumpAndSettle();
      expect(flying, findsNothing);
      expect(find.text('the page'), findsOneWidget);
      nav.currentState!.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(flying, findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.text('the card'), findsOneWidget);
    });

    testWidgets('with Remove animations on, nothing flies', (tester) async {
      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(app(nav, reduced: true));
      expect(find.byType(Hero), findsNothing);
      nav.currentState!.push(page());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(
          find.byWidgetPredicate(
              (w) => w.runtimeType.toString() == '_CardFlight'),
          findsNothing);
      await tester.pumpAndSettle();
    });

    test('the tag is the id', () {
      expect(cardHeroTag(7), cardHeroTag(7));
      expect(cardHeroTag(7), isNot(cardHeroTag(8)));
      expect(cardHeroTag('7'), isNot(titleHeroTag('7')));
    });
  });

  group('the sheet', () {
    // The owner (2026-09-30): "add some more delay to get real effect".
    test('rises on a spring you can feel: fast, a small lift past rest, settled', () {
      final c = Motion.sheetRise;
      expect(c.transform(0), 0);
      expect(c.transform(1), 1);
      var most = 0.0;
      for (var i = 1; i < 100; i++) {
        most = most > c.transform(i / 100) ? most : c.transform(i / 100);
      }
      expect(most, greaterThan(1.02), reason: 'the spring is felt');
      expect(most, lessThan(1.05), reason: 'weight, not a bounce');
      // 150 ms of 600: most of the way there.
      expect(c.transform(150 / 600), greaterThan(0.75));
      expect(c.transform(0.05), lessThan(0.5), reason: 'it starts from rest');
      expect((c.transform(0.95) - 1).abs(), lessThan(0.01), reason: 'settled by the end');
    });

    testWidgets('showAppSheet takes the spring, and reduced motion a fade',
        (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(MaterialApp(
          home: Builder(builder: (c) {
        ctx = c;
        return const SizedBox();
      })));
      final style = appSheetAnimation(ctx);
      expect(style.duration, Motion.sheetIn);
      expect(style.curve, same(Motion.sheetRise),
          reason: 'the SDK asserts one curve instance for a sheet\'s life');
      expect(style.reverseDuration, Motion.pageBack);
      await tester.pumpWidget(MaterialApp(
          builder: _reduced,
          home: Builder(builder: (c) {
            ctx = c;
            return const SizedBox();
          })));
      expect(appSheetAnimation(ctx).duration, Motion.out);
    });

    testWidgets('a sheet opens and closes on it', (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(body: Builder(builder: (c) {
            ctx = c;
            return const SizedBox();
          }))));
      showAppSheet<void>(
          context: ctx, builder: (_) => const SizedBox(height: 200, child: Text('sheet')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      final mid = tester.getTopLeft(find.text('sheet')).dy;
      await tester.pumpAndSettle();
      final rest = tester.getTopLeft(find.text('sheet')).dy;
      expect(mid - rest, lessThan(60), reason: 'most of the way in 150 ms');
      Navigator.of(ctx).pop();
      await tester.pumpAndSettle();
      expect(find.text('sheet'), findsNothing);
    });
  });

  group('states', () {
    testWidgets('the loader: inline and page, turning, with a label',
        (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: Column(children: [
            NeonLoader.inline(),
            Expanded(child: NeonLoader.page(label: 'Loading your clients…')),
          ]),
        ),
      ));
      expect(tester.getSize(find.byType(NeonLoader).first), const Size(18, 18));
      expect(find.text('Loading your clients…'), findsOneWidget);
      expect(find.bySemanticsLabel('Loading'), findsNWidgets(2));
      expect(SchedulerBinding.instance.transientCallbackCount, greaterThan(0));
      handle.dispose();
    });

    testWidgets('the loader holds still with Remove animations on',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
          builder: _reduced, home: Center(child: NeonLoader())));
      await tester.pump();
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('the empty state: a lit tile and a pill action; the error is danger-lit',
        (tester) async {
      var tapped = 0;
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Column(children: [
            Expanded(
              child: NeonEmptyState(
                icon: Icons.inbox_rounded,
                title: 'Nothing yet',
                body: 'Add your first one.',
                actionLabel: 'Add',
                onAction: () => tapped++,
              ),
            ),
            Expanded(child: NeonErrorState(message: 'Couldn\'t load', onRetry: () {})),
          ]),
        ),
      ));
      expect(find.widgetWithText(NeonPill, 'Add'), findsOneWidget);
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      expect(tapped, 1);
      final error = tester.widget<NeonEmptyState>(find.descendant(
          of: find.byType(NeonErrorState), matching: find.byType(NeonEmptyState)));
      expect(error.tone, NeonTone.danger);
      expect(find.text('Try again'), findsOneWidget);
    });

    testWidgets('success: appears, settles, then asks for no frames',
        (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(const MaterialApp(
          home: Center(child: NeonSuccess(label: 'Saved'))));
      expect(tester.binding.hasScheduledFrame, isTrue);
      await tester.pump(NeonSuccess.duration);
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.binding.hasScheduledFrame, isFalse);
      expect(find.text('Saved'), findsOneWidget);
      expect(
          tester.getSemantics(find.byType(NeonSuccess)),
          matchesSemantics(label: 'Saved', isLiveRegion: true));
      handle.dispose();
    });

    testWidgets('success is simply there with Remove animations on',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
          builder: _reduced, home: Center(child: NeonSuccess())));
      await tester.pump();
      expect(tester.binding.hasScheduledFrame, isFalse);
    });
  });

  group('toasts', () {
    testWidgets('each tone is lit by its own rim', (tester) async {
      await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(body: Builder(builder: (c) {
            return TextButton(
                onPressed: () => AppFeedback.show('Saved, but offline',
                    context: c, tone: FeedbackTone.warning),
                child: const Text('go'));
          }))));
      await tester.tap(find.text('go'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final bar = tester.widget<SnackBar>(find.byType(SnackBar));
      final side = (bar.shape as RoundedRectangleBorder).side;
      expect(side.color.withValues(alpha: 1),
          NeonTone.warning.rim.first.withValues(alpha: 1));
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
      AppFeedback.dismiss();
      await tester.pumpAndSettle();
    });
  });
}
