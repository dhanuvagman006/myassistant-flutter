import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/design/tab_deck.dart';
import 'package:myassistant/design/motion.dart';

/// A tab that remembers a number, to prove switching keeps state.
class _Counter extends StatefulWidget {
  const _Counter(this.name);
  final String name;
  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  var n = 0;
  @override
  Widget build(BuildContext context) => ColoredBox(
        color: Colors.white,
        child: Center(
          child: TextButton(onPressed: () => setState(() => n++), child: Text('${widget.name} $n')),
        ),
      );
}

class _Host extends StatefulWidget {
  const _Host();
  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  int index = 0;
  Offset? origin;
  final swipes = <int>[];

  void show(int i, {Offset? from}) => setState(() {
        index = i;
        origin = from;
      });

  @override
  Widget build(BuildContext context) => TabDeck(
        index: index,
        origin: origin,
        onSwipe: (i) {
          swipes.add(i);
          show(i);
        },
        children: const [_Counter('home'), _Counter('hub'), _Counter('chat'), _Counter('you')],
      );
}

Future<_HostState> _pump(WidgetTester t, {bool reduced = false}) async {
  t.view.physicalSize = const Size(400, 800);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
      child: child!,
    ),
    home: const Scaffold(body: _Host()),
  ));
  return t.state<_HostState>(find.byType(_Host));
}

bool _onScreen(WidgetTester t, String text) => find.text(text).hitTestable().evaluate().isNotEmpty;

void main() {
  testWidgets('a dock tap brings the tab through: it fades in over the one fading out', (t) async {
    final host = await _pump(t);
    host.show(2, from: const Offset(300, 790)); // Chat's button, bottom right
    await t.pump();
    await t.pump(const Duration(milliseconds: 60));
    double opacityOf(String text) => t
        .widgetList<Opacity>(find.ancestor(of: find.text(text), matching: find.byType(Opacity)))
        .first
        .opacity;
    expect(find.text('home 0'), findsOneWidget, reason: 'the old tab is still there under it');
    expect(opacityOf('home 0'), lessThan(1), reason: 'and going');
    expect(opacityOf('chat 0'), lessThan(1), reason: 'the new one is still arriving');
    expect(find.byType(ClipPath), findsNothing, reason: 'nothing is clipped: no repaint per frame');
    await t.pump(Motion.tabSwitch);
    expect(_onScreen(t, 'chat 0'), isTrue);
    expect(find.text('home 0'), findsNothing, reason: 'hidden once the move is over');
    expect(opacityOf('chat 0'), 1.0, reason: 'fully there at rest');
  });

  testWidgets('the move is over within its own time, and needs no more frames', (t) async {
    final host = await _pump(t);
    host.show(1, from: const Offset(120, 790));
    await t.pump();
    await t.pump(Motion.tabSwitch + const Duration(milliseconds: 20));
    expect(_onScreen(t, 'hub 0'), isTrue);
    expect(find.text('home 0'), findsNothing);
  });

  testWidgets('the tab coming in takes a tap at once, and the tap ends the move', (t) async {
    final host = await _pump(t);
    host.show(2, from: const Offset(300, 790));
    await t.pump();
    await t.pump(const Duration(milliseconds: 60));
    await t.tap(find.text('chat 0'));
    await t.pump();
    expect(find.text('chat 1'), findsOneWidget, reason: 'the tap reached the new tab mid-move');
    expect(find.text('home 0'), findsNothing, reason: 'the old tab is gone');
    await t.pumpAndSettle();
    expect(_onScreen(t, 'chat 1'), isTrue);
  });

  testWidgets('every tab keeps its state across switches', (t) async {
    final host = await _pump(t);
    await t.tap(find.text('home 0'));
    await t.pump();
    host.show(1);
    await t.pumpAndSettle();
    host.show(0, from: const Offset(40, 790));
    await t.pumpAndSettle();
    expect(find.text('home 1'), findsOneWidget, reason: 'Home kept its count');
  });

  testWidgets('a swipe left past a third moves to the next tab, following the finger', (t) async {
    final host = await _pump(t);
    final g = await t.startGesture(const Offset(300, 400));
    await g.moveBy(const Offset(-40, 0));
    await g.moveBy(const Offset(-60, 0));
    await t.pump();
    final hubTab = find.ancestor(of: find.text('hub 0'), matching: find.byType(ColoredBox)).first;
    expect(t.getTopLeft(hubTab).dx, lessThan(400),
        reason: 'the next tab is already coming in from the right');
    expect(t.getTopLeft(hubTab).dx, greaterThan(250), reason: 'as far as the finger went, no further');
    await g.moveBy(const Offset(-90, 0));
    await g.up();
    await t.pumpAndSettle();
    expect(host.swipes, [1]);
    expect(_onScreen(t, 'hub 0'), isTrue);
  });

  testWidgets('a short, slow swipe springs back; the first tab only gives a little', (t) async {
    final host = await _pump(t);
    final homeTab = find.ancestor(of: find.textContaining('home'), matching: find.byType(ColoredBox)).first;
    await t.timedDragFrom(const Offset(200, 150), const Offset(-60, 0), const Duration(milliseconds: 600));
    await t.pumpAndSettle();
    expect(host.swipes, isEmpty);
    expect(t.getTopLeft(homeTab).dx, 0, reason: 'back in place');

    final g = await t.startGesture(const Offset(100, 150));
    await g.moveBy(const Offset(40, 0));
    await g.moveBy(const Offset(200, 0));
    await t.pump();
    final shift = t.getTopLeft(homeTab).dx;
    expect(shift, lessThanOrEqualTo(400 * 0.12 + 1), reason: 'nothing to the left of Home');
    await g.up();
    await t.pumpAndSettle();
    expect(host.swipes, isEmpty);
  });

  testWidgets('a quick flick is enough, even a short one', (t) async {
    final host = await _pump(t);
    await t.fling(find.text('home 0'), const Offset(-80, 0), 1200);
    await t.pumpAndSettle();
    expect(host.swipes, [1]);
  });

  testWidgets('reduced motion: tabs switch at once, and a swipe still switches', (t) async {
    final host = await _pump(t, reduced: true);
    host.show(3, from: const Offset(360, 790));
    await t.pump();
    expect(_onScreen(t, 'you 0'), isTrue, reason: 'no circle, no wait');
    await t.fling(find.text('you 0'), const Offset(200, 0), 1500);
    await t.pump();
    expect(host.swipes, [2]);
  });
}
