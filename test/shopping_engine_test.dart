// THE SHOPPING LIST BY VOICE, ON THE PHONE (build 124): what the server's
// shopping tools hand the phone. shop_from_list's shop_handoff opens the
// first thing and is answered with what really happened; the list notice
// redraws an open list; "show my shopping list" opens the screen (one kind
// of it when asked) without stacking a second.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/ai/brain.dart';
import 'package:myassistant/ai/listen.dart';
import 'package:myassistant/ai/speech.dart';
import 'package:myassistant/features/assistant/state/assistant_engine.dart';
import 'package:myassistant/features/shopping/shop_handoff.dart';
import 'package:myassistant/features/shopping/shopping_list_screen.dart';
import 'package:myassistant/features/shopping/shopping_service.dart';
import 'package:myassistant/features/shopping/shopping_share.dart';
import 'package:myassistant/services/audio/pcm_player.dart';
import 'package:myassistant/services/avatar_message_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ai/fakes.dart';
import 'helpers/fake_brain.dart';
import 'helpers/fake_shopping.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  for (final c in [
    SystemChannels.platform,
    const MethodChannel('xyz.luan/audioplayers'),
    const MethodChannel('xyz.luan/audioplayers.global'),
    const MethodChannel('com.llfbandit.record/messages'),
  ]) {
    messenger.setMockMethodCallHandler(c, (_) async => null);
  }

  final engine = AssistantEngine.instance;
  late FakeBrain brain;
  late FakeShopPorts ports;
  late FakeShoppingServer server;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    brain = FakeBrain();
    engine
      ..debugMarkStarted()
      ..debugUse(
        brain: brain,
        listener: VoiceListener(recognizer: _SilentEars(), config: () => const AiConfig()),
        player: PcmPlayer(output: SilentOutput()),
        speech: SpeechEngine(port: FakeModel(), config: () => const AiConfig()),
      );
    ports = FakeShopPorts();
    ShopHandoffRunner.ports = ports;
    await ShopHandoffRunner.instance.reset();
    server = FakeShoppingServer();
    ShoppingService.transport = server.call;
    await ShoppingService.instance.reset();
  });

  /// The brain hands [action] over in a turn; the answer it got back.
  Future<DeviceOutcome> act(Map<String, dynamic> action) async {
    final answer = Completer<DeviceOutcome>();
    brain.scripts.add((emit) async {
      emit(BrainDeviceAction(tool: 'shop_from_list', action: action, respond: answer.complete));
      await answer.future;
      emit(const BrainFinalText(text: 'Opening Blinkit.', route: AiRoute.cloud));
    });
    await engine.askAssistant('order these ${DateTime.now().microsecondsSinceEpoch}');
    return answer.future.timeout(const Duration(seconds: 5));
  }

  group('shop_handoff', () {
    test('opens the first thing and answers where it opened', () async {
      final o = await act(handoffJson());
      expect(o.ok, isTrue);
      expect(ports.opened, ['com.grofers.customerapp https://blinkit.com/s/?q=onion']);
      expect(o.detail, contains('Opened Onion in Blinkit'));
      expect(o.detail, contains('next of the 3'));
      expect(o.detail, contains('Nothing is ordered or paid'));
      expect(ports.last!.title, 'Shopping · 1 of 3');
      await ShopHandoffRunner.instance.end();
    });

    test('in the browser when the app is not installed — and it says so', () async {
      ports.installed = {};
      final o = await act(handoffJson());
      expect(o.ok, isTrue);
      expect(o.detail, contains('in the browser'));
      await ShopHandoffRunner.instance.end();
    });

    test('nothing could open: the answer is a failure, never "opening"', () async {
      ports.installed = {};
      ports.browserWorks = false;
      final o = await act(handoffJson());
      expect(o.ok, isFalse);
      expect(o.detail, contains('NOTHING was opened'));
      expect(await ShopHandoffRunner.instance.hasTrip(), isFalse);
    });

    test('a hand-off with nothing in it is a failure', () async {
      final o = await act({'type': 'shop_handoff', 'groups': []});
      expect(o.ok, isFalse);
      expect(ports.opened, isEmpty);
    });
  });

  test('something shared for the list is ONE untrusted turn, with its photo', () async {
    brain.scripts.add((emit) async {
      emit(const BrainFinalText(text: 'Added the blue kurti to your list.', route: AiRoute.cloud));
    });
    final photo = AiAttachment(kind: 'image', mimeType: 'image/png', bytes: Uint8List(4));
    await engine.askAboutShared(ShoppingShare.ask(picture: true), image: photo);
    final turn = brain.turns.last;
    expect(turn.untrusted, isTrue, reason: 'what was shared is outside content');
    expect(brain.sharedTurns.last, isTrue,
        reason: 'but the owner chose the action — the server words its note for that');
    expect(identical(turn.image, photo), isTrue);
    expect(turn.text, contains('shopping list'));
    expect(engine.transcript.last.text, 'Added the blue kurti to your list.',
        reason: 'the answer is the result shown');
  });

  test('shopping_list_updated reads the list again', () async {
    engine.debugHandleEvent({'type': 'shopping_list_updated', 'notice': true});
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(server.paths, ['GET ']);
  });

  test('"show my shopping list" is a screen the phone can open', () {
    expect(engine.canOpenAppScreen('shopping_list'), isTrue);
  });

  testWidgets('open_app_screen shopping_list opens the list for that kind, once', (t) async {
    t.view.devicePixelRatio = 2.625;
    t.view.physicalSize = const Size(1080, 2340);
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      navigatorKey: AvatarMessageService.navigatorKey,
      home: const Scaffold(body: Text('home')),
    ));
    engine.debugHandleEvent(
        {'type': 'open_app_screen', 'screen': 'shopping_list', 'category': 'clothing_footwear'});
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    final screen = t.widget<ShoppingListScreen>(find.byType(ShoppingListScreen));
    expect(screen.category, 'clothing_footwear');
    expect(find.text('Kurti'), findsOneWidget);
    expect(find.text('Onion'), findsNothing);

    // Said again while it is open: it redraws, it does not stack.
    server.items.add(itemJson(50, 'Sandals', category: 'clothing_footwear'));
    engine.debugHandleEvent({'type': 'open_app_screen', 'screen': 'shopping_list'});
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    expect(find.byType(ShoppingListScreen), findsOneWidget);
    expect(find.text('Sandals'), findsOneWidget);

    // And a voice change redraws it too.
    server.items.add(itemJson(51, 'Dupatta', category: 'clothing_footwear'));
    engine.debugHandleEvent({'type': 'shopping_list_updated', 'notice': true});
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('Dupatta'), findsOneWidget);

    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 1));
  });
}

/// A recogniser that never hears anything (no conversation runs here).
class _SilentEars implements RecognizerPort {
  @override
  Future<bool> initialize({
    required void Function(String status) onStatus,
    required void Function(String error, bool permanent) onError,
  }) async =>
      true;

  @override
  Future<List<String>> localeIds() async => const ['en-IN'];

  @override
  Future<void> listen({
    required void Function(String words, bool isFinal) onResult,
    void Function(double level)? onLevel,
    String? localeId,
    required bool onDevice,
    required Duration listenFor,
    required Duration pauseFor,
  }) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> cancel() async {}
}
