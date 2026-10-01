// The brain, scripted, for tests that drive the engine (AssistantEngine
// .debugUse): no model, no server, no Firebase.
import 'dart:async';

import 'package:myassistant/ai/brain.dart';
import 'package:myassistant/ai/listen.dart';
import 'package:myassistant/ai/tool_server.dart' show AiContext;

typedef Emit = void Function(BrainEvent e);

/// The brain, scripted: each turn runs the next script with an [Emit].
class FakeBrain implements AssistantBrain {
  final turns = <({String text, BrainMode mode, bool? speak, AiAttachment? image, bool untrusted})>[];
  final scripts = <Future<void> Function(Emit emit)>[];
  var cancels = 0;
  var resets = 0;
  StreamController<BrainEvent>? _active;

  @override
  final LocalToolRegistry localTools = LocalToolRegistry();

  /// Whether each turn was marked as shared by the owner (in turn order).
  final sharedTurns = <bool>[];

  @override
  Stream<BrainEvent> turn({
    required String text,
    BrainMode mode = BrainMode.chat,
    AiAttachment? image,
    List<AiAttachment> attachments = const [],
    bool untrusted = false,
    bool shared = false,
    bool? speak,
  }) {
    turns.add((text: text, mode: mode, speak: speak, image: image, untrusted: untrusted));
    sharedTurns.add(shared);
    final previous = _active;
    if (previous != null && !previous.isClosed) previous.close();
    final out = StreamController<BrainEvent>();
    _active = out;
    final script = scripts.isEmpty ? null : scripts.removeAt(0);
    scheduleMicrotask(() async {
      if (script != null) {
        await script((e) {
          if (!out.isClosed) out.add(e);
        });
      }
      if (!out.isClosed) await out.close();
    });
    return out.stream;
  }

  @override
  Future<void> cancel() async {
    cancels++;
    final a = _active;
    _active = null;
    if (a != null && !a.isClosed) await a.close();
  }

  @override
  Future<void> prepare() async {}

  @override
  Future<void> warmUp() async {}

  @override
  void reset() => resets++;

  @override
  bool get busy => _active != null;

  @override
  String? get sessionId => null;

  @override
  List<ChatTurn> get history => const [];

  @override
  BrainTimeouts get timeouts => const BrainTimeouts();

  /// Live turns' tools (2026-09-30): each call answers from [liveTool].
  final liveToolCalls = <({String name, Map<String, Object?> args, String userText})>[];
  Map<String, Object?> Function(String name, Map<String, Object?> args) liveTool =
      (_, __) => const {'ok': true};

  @override
  BrainToolTurn openToolTurn({
    required Future<(String?, String?)> Function() ids,
    required Set<String> serverTools,
    required void Function(BrainEvent event) onEvent,
    Future<AiContext?> Function(String userText)? recontext,
  }) =>
      _FakeToolTurn(this, onEvent);
}

class _FakeToolTurn implements BrainToolTurn {
  _FakeToolTurn(this.brain, this.onEvent);
  final FakeBrain brain;
  final void Function(BrainEvent event) onEvent;

  @override
  final toolLog = <Map<String, Object?>>[];

  @override
  String? get sessionId => 's1';

  @override
  String? get turnId => 't1';

  @override
  bool cancelled = false;

  @override
  Future<void> resolveIds() async {}

  @override
  Future<Map<String, Object?>> run(String name, Map<String, Object?> args,
      {required String userText}) async {
    brain.liveToolCalls.add((name: name, args: args, userText: userText));
    onEvent(BrainToolCall(name, args));
    final answer = brain.liveTool(name, args);
    toolLog.add({'name': name, 'ok': answer['ok'] == true});
    return answer;
  }

  @override
  void cancel() => cancelled = true;

  @override
  void finish(String user, String reply) {}
}

/// A recogniser that never hears anything (its listen never ends).
class DeafRecognizer implements RecognizerPort {
  @override
  Future<bool> initialize({
    required void Function(String status) onStatus,
    required void Function(String error, bool permanent) onError,
  }) async =>
      true;

  @override
  Future<List<String>> localeIds() async => const [];

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
