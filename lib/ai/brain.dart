/// THE ASSISTANT'S BRAIN — one turn, end to end, on Firebase AI Logic.
///
/// Owner, 2026-09-29: the app talks to the models itself (no /live proxy,
/// no /chat/stream): Gemini in the cloud through firebase_ai for every turn
/// (Gemini Nano on the phone was removed the same night on the owner's
/// word), Gemini TTS for the voice. The server stays the tool server:
/// context, tools, recording.
///
/// A turn: POST /ai/context -> route (router.dart) -> cloud with the tool
/// loop (every tool through POST /ai/tool; device actions handed to the
/// engine and their outcome fed back to the model; a fallback model when
/// the first one fails or stalls) | Google-Search-grounded cloud | a
/// shortcut run with no model -> POST /ai/turn (its claim-checked reply is
/// the one used) -> in voice mode, speech.dart says it.
///
/// HOW THE ENGINE CALLS IT (for wiring into assistant_engine.dart)
///
///     final brain = AssistantBrain.standard(sink: myPcmSink);
///     await brain.prepare();          // when the assistant opens: config
///     await for (final e in brain.turn(text: words, mode: BrainMode.voice,
///                                      image: photo, attachments: files)) {
///       switch (e) {
///         case BrainRouteChosen():      // log / orb "thinking"
///         case BrainPartialText(:final text):   // live caption
///         case BrainToolCall(:final name):      // "working on it" UI
///         case BrainDeviceAction(:final action, :final respond):
///           // Perform it exactly as the old live path did (_onEvent(action)),
///           // then ALWAYS answer, or the model waits 30 s:
///           respond(ok ? const DeviceOutcome.ok() : DeviceOutcome.failed(why));
///         case BrainNeedsConfirmation(:final summary):
///           // The reply asks "…?"; the user's next "yes" turn carries the
///           // approval token automatically. A Confirm button can simply
///           // call brain.turn(text: 'Yes').
///         case BrainFinalText(:final text, :final sources):  // the reply
///         case BrainSpokenAudio(:final pcm, :final sampleRate):
///           // Voice mode: already queued on the AudioSink given to the
///           // brain; use it for caption timing (or play it yourself when
///           // no sink was given).
///         case BrainError(:final message, :final fatal):  // say / show it
///       }
///     }
///
/// LOCAL TOOLS: `brain.localTools.register(LocalTool(...))` adds a tool that
/// runs in the app (local_tools.dart): declared to the cloud model beside
/// the server's tools, executed here instead of POST /ai/tool.
///
/// GEMINI LIVE (2026-09-30, live_voice.dart): the fast voice runs its model
/// in a Live session, but every tool it calls still comes through here —
/// `brain.openToolTurn(...)` gives one Live turn the same /ai/tool path,
/// the same pending-yes approvals, local tools and device actions, as the
/// same [BrainEvent]s.
///
/// Barge-in (the user taps or starts talking): `await brain.cancel()` stops
/// generation, tools, speech and the sink at once; the turn's stream closes
/// without a final event. Starting a new turn cancels the previous one.
/// `brain.reset()` forgets the local conversation and the server session
/// (sign-out, "new conversation"). Listening is listen.dart's VoiceListener:
/// listen -> brain.turn(voice) -> speak -> listen again.
library;

import 'dart:async';
import '../services/telemetry.dart';
import 'dart:convert';
import 'dart:io' show File, SocketException;
import 'dart:typed_data';

import 'package:firebase_ai/firebase_ai.dart';
import 'package:http/http.dart' as http;

import '../core/log.dart';
import '../services/device_capabilities.dart';
import 'cloud.dart';
import 'config.dart';
import 'local_tools.dart';
import 'model_port.dart';
import 'router.dart';
import 'server_model_port.dart' show ServerModelException;
import 'speech.dart';
import 'speech_markup.dart';
import 'tool_server.dart';
import 'types.dart';

export 'cloud.dart' show CloudBlockedException;
export 'config.dart' show AiConfig, AiConfigStore;
export 'local_tools.dart'
    show LocalTool, LocalToolCall, LocalToolHandler, LocalToolRegistry, LocalToolResult;
export 'router.dart' show AiRoute;
export 'speech.dart' show AudioSink;
export 'types.dart' show AiAttachment, ChatTurn, SourceLink;

enum BrainMode { voice, chat }

sealed class BrainEvent {
  const BrainEvent();
}

/// Which engine answers.
final class BrainRouteChosen extends BrainEvent {
  const BrainRouteChosen(this.route, this.reason);
  final AiRoute route;
  final String reason;
}

/// The reply so far ([text]) and what was just added ([delta]).
final class BrainPartialText extends BrainEvent {
  const BrainPartialText(this.text, this.delta);
  final String text;
  final String delta;
}

/// The model called a tool (the server runs it).
final class BrainToolCall extends BrainEvent {
  const BrainToolCall(this.name, this.args);
  final String name;
  final Map<String, Object?> args;
}

/// Something the PHONE must do (open the camera, place a call, …): the
/// engine performs [action] and must call [respond] with the outcome.
final class BrainDeviceAction extends BrainEvent {
  const BrainDeviceAction({
    required this.tool,
    required this.action,
    required this.respond,
  });
  final String tool;
  final Map<String, dynamic> action;
  final void Function(DeviceOutcome outcome) respond;
}

/// The server wants the user's yes before [tool] runs.
final class BrainNeedsConfirmation extends BrainEvent {
  const BrainNeedsConfirmation({
    required this.tool,
    required this.args,
    required this.summary,
    required this.approvalToken,
  });
  final String tool;
  final Map<String, Object?> args;
  final String summary;
  final String approvalToken;
}

/// The reply, as recorded (claim-checked when [corrected]).
final class BrainFinalText extends BrainEvent {
  const BrainFinalText({
    required this.text,
    required this.route,
    this.corrected = false,
    this.sources = const [],
    this.searchSuggestionsHtml,
    this.turnId,
  });
  final String text;
  final AiRoute route;
  final bool corrected;

  /// The server's name for this turn (null when the server never named
  /// it): the recorded audio is filed under it for review.
  final String? turnId;

  /// Pages a Google-Search-grounded reply used.
  final List<SourceLink> sources;

  /// Google's Search-suggestions chip (to show with a grounded reply).
  final String? searchSuggestionsHtml;
}

/// Voice mode: one sentence of the reply as PCM16 mono.
final class BrainSpokenAudio extends BrainEvent {
  const BrainSpokenAudio({
    required this.index,
    required this.sentence,
    required this.pcm,
    required this.sampleRate,
  });
  final int index;
  final String sentence;
  final Uint8List pcm;
  final int sampleRate;
}

/// Something went wrong. [fatal]: the turn ended without a reply; not
/// fatal: the reply stands (e.g. it could not be spoken).
final class BrainError extends BrainEvent {
  const BrainError(this.code, this.message, {this.fatal = true});
  final String code;
  final String message;
  final bool fatal;

  /// Plain words for any failure.
  factory BrainError.from(Object e) {
    if (e is TimeoutException) {
      return const BrainError('timeout', 'Sorry, that took longer than it should. Could you try once more?');
    }
    if (e is CloudBlockedException) {
      return const BrainError('blocked', "I'm sorry, I'm not able to help with that one.");
    }
    // The server's model proxy: a rate limit or exhausted credits arrive
    // as a 429 (or a 'quota' message in a stream) — a kind "busy" line,
    // never the generic failure.
    if (e is ServerModelException &&
        (e.status == 429 || e.body.toLowerCase().contains('quota'))) {
      return const BrainError(
          'quota', "I'm a little busy right now — please give me a minute and try again.");
    }
    if (e is QuotaExceeded) {
      return const BrainError(
          'quota', "I'm a little busy right now — please give me a minute and try again.");
    }
    if (e is ServiceApiNotEnabled || e is InvalidApiKey) {
      return const BrainError('not_enabled', "I'm not quite ready yet — please try again in a little while.");
    }
    if (e is UnsupportedUserLocation) {
      return const BrainError('location', "The assistant isn't available where you are.");
    }
    if (e is SocketException || e is http.ClientException) {
      return const BrainError('offline', "I can't reach the internet right now. Please check your connection and try again.");
    }
    if (e is FirebaseAIException) {
      final m = e.message.toLowerCase();
      if (m.contains('app check') || m.contains('permission') || m.contains('unauth')) {
        return const BrainError(
            'denied', "I couldn't connect just now. Please try again in a moment.");
      }
      return const BrainError('server', "Sorry, I couldn't connect just now. Please try again in a moment.");
    }
    return const BrainError('failed', "Sorry, something didn't work on my side. Let's try that again.");
  }
}

/// What happened when the phone performed a device action.
class DeviceOutcome {
  const DeviceOutcome({required this.ok, this.detail, this.data});
  const DeviceOutcome.ok([this.detail])
      : ok = true,
        data = null;
  const DeviceOutcome.failed(String this.detail)
      : ok = false,
        data = null;

  final bool ok;
  final String? detail;
  final Map<String, Object?>? data;

  Map<String, Object?> toJson() => {
        'ok': ok,
        if (detail != null) 'detail': detail,
        if (data != null) ...data!,
      };
}

class BrainTimeouts {
  const BrainTimeouts({
    this.cloudRound = const Duration(seconds: 30),
    this.cloudFirst = const Duration(seconds: 10),
    this.cloudHedge = const Duration(milliseconds: 4500),
    this.tts = const Duration(seconds: 15),
    this.context = const Duration(seconds: 8),
    this.tool = const Duration(seconds: 25),
    this.deviceAction = const Duration(seconds: 30),
    this.record = const Duration(seconds: 5),
  });

  /// One cloud model call.
  final Duration cloudRound;

  /// The cloud model's first words; past this it has failed.
  final Duration cloudFirst;

  /// Silent this long, the conversation model gets company: the fallback
  /// is asked too and whichever answers first is heard.
  final Duration cloudHedge;

  /// One spoken sentence.
  final Duration tts;
  final Duration context;
  final Duration tool;
  final Duration deviceAction;
  final Duration record;
}

class _Cancelled implements Exception {
  const _Cancelled();
}

class _Approval {
  const _Approval(this.token, this.expires, this.turn);
  final String token;
  final DateTime expires;
  final int turn;
}

class _Turn {
  _Turn(this.index, this.out);

  final int index;
  final StreamController<BrainEvent> out;
  bool cancelled = false;
  bool done = false;

  /// The app-local tools offered to the model this turn.
  Set<String> localNames = const {};

  /// The server's session and turn for this turn. Renewed mid-turn when
  /// the server lost the session (a deploy, a restart): see _lostSession.
  String? sid;
  String? tid;

  /// /ai/context again, for this very turn (after a lost session).
  Future<AiContext?> Function()? recontext;
  bool renewed = false;
  final _cancelHooks = <void Function()>[];
  final _signal = Completer<void>();

  void emit(BrainEvent e) {
    if (!cancelled && !out.isClosed) out.add(e);
  }

  void onCancel(void Function() hook) {
    if (cancelled) {
      hook();
    } else {
      _cancelHooks.add(hook);
    }
  }

  void cancel() {
    if (cancelled || done) return;
    cancelled = true;
    for (final h in List.of(_cancelHooks)) {
      try {
        h();
      } catch (_) {}
    }
    _cancelHooks.clear();
    if (!_signal.isCompleted) _signal.complete();
  }

  /// [f], unless the turn is cancelled first.
  Future<T> guard<T>(Future<T> f) {
    if (cancelled) return Future<T>.error(const _Cancelled());
    return Future.any<T>([
      f,
      _signal.future.then<T>((_) => throw const _Cancelled()),
    ]);
  }
}

class AssistantBrain {
  AssistantBrain({
    required ToolServer server,
    required AiConfigStore configs,
    required CloudEngine cloud,
    SpeechEngine? speech,
    AudioSink? sink,
    this.timeouts = const BrainTimeouts(),
    Future<Map<String, Object?>> Function()? deviceContext,
    DateTime Function()? now,
    LocalToolRegistry? localTools,
  })  : localTools = localTools ?? LocalToolRegistry(),
        _server = server,
        _configs = configs,
        _cloud = cloud,
        _speech = speech,
        _sink = sink,
        _deviceContext = deviceContext,
        _now = now ?? DateTime.now;

  /// The real wiring: firebase_ai, the backend, the shared config store.
  /// [sink] is the app's PCM player.
  factory AssistantBrain.standard({
    AudioSink? sink,
    BrainTimeouts timeouts = const BrainTimeouts(),
    Future<Map<String, Object?>> Function()? deviceContext,
    LocalToolRegistry? localTools,
  }) {
    final port = ModelPorts.cloud();
    final configs = AiConfigStore.instance;
    return AssistantBrain(
      server: ToolServer(),
      configs: configs,
      cloud: CloudEngine(port),
      speech: SpeechEngine(port: port, config: () => configs.current, timeout: timeouts.tts),
      sink: sink,
      timeouts: timeouts,
      deviceContext: deviceContext ?? phoneContext,
      localTools: localTools,
    );
  }

  /// What this phone can do right now, for /ai/context (the server offers
  /// only tools whose permission was granted).
  static Future<Map<String, Object?>> phoneContext() async {
    try {
      final c = await DeviceCapabilities.collect();
      return {
        'caps': {'granted': c['granted'], 'denied': c['denied']},
        // Which handset (admin → Phones): "works on mine, breaks on his".
        if ((c['model'] ?? '').toString().isNotEmpty) 'model': c['model'],
        if ((c['osVersion'] ?? '').toString().isNotEmpty) 'os': c['osVersion'],
      };
    } catch (_) {
      return const {};
    }
  }

  final ToolServer _server;
  final AiConfigStore _configs;
  final CloudEngine _cloud;
  final SpeechEngine? _speech;
  final AudioSink? _sink;
  final Future<Map<String, Object?>> Function()? _deviceContext;
  final DateTime Function() _now;
  final BrainTimeouts timeouts;

  /// Tools that run in the app (see local_tools.dart).
  final LocalToolRegistry localTools;

  final _history = <ChatTurn>[];
  final _pending = <String, _Approval>{};
  String? _sessionId;
  _Turn? _active;
  var _turns = 0;

  /// The server's conversation session (from /ai/context).
  String? get sessionId => _sessionId;

  /// This conversation, as the phone remembers it (latest last).
  List<ChatTurn> get history => List.unmodifiable(_history);

  bool get busy => _active != null;

  /// The stand-in for when /ai/context cannot be reached: no tools, no memory.
  static String standInSystem(BrainMode mode) =>
      "You are a friendly personal assistant. Your services can't be reached "
      "right now, so you cannot take actions or look at the user's data: if "
      'asked to, say so in a sentence and suggest trying again soon. Answer '
      'everything else helpfully and briefly.'
      '${mode == BrainMode.voice ? ' Speak naturally in short sentences, with no lists or formatting.' : ''}';

  static const emptyReply = "Sorry, I couldn't come up with an answer. Please try again.";

  /// When the assistant opens: fetch the config and warm the model
  /// connection, so the first turn waits for neither. Best effort.
  Future<void> prepare() async {
    unawaited(warmUp());
    try {
      await _configs.get();
    } catch (e) {
      AppLog.add('brain', 'config not ready: ${e.runtimeType}');
    }
  }

  /// The tokens and the connection to the models, ready before a turn
  /// needs them (the engine calls it when the orb is tapped).
  Future<void> warmUp() async {
    try {
      await _cloud.port.warmUp();
    } catch (e) {
      AppLog.add('brain', 'warm-up failed: ${e.runtimeType}');
    }
  }

  /// One turn. [image] is a photo ("what is this"); [attachments] are
  /// other files (PDF, audio, video). [speak] says the reply aloud (the
  /// default: in voice mode only) — a typed message in a spoken
  /// conversation is a chat turn that is still answered out loud. See the
  /// top of this file.
  Stream<BrainEvent> turn({
    required String text,
    BrainMode mode = BrainMode.chat,
    AiAttachment? image,
    List<AiAttachment> attachments = const [],
    bool untrusted = false,
    // The owner shared this from another app and chose what to do with it
    // (e.g. "Add to shopping list"): still outside content, but the choice
    // is theirs (/ai/context words its note accordingly).
    bool shared = false,
    bool? speak,
  }) {
    _active?.cancel();
    late final _Turn t;
    final out = StreamController<BrainEvent>(
      onListen: () {
        _run(t, text, mode, image, attachments, untrusted, shared, speak ?? mode == BrainMode.voice)
            .whenComplete(() {
          t.done = true;
          if (identical(_active, t)) _active = null;
          t.out.close();
        });
      },
      onCancel: () => t.cancel(),
    );
    t = _Turn(++_turns, out);
    _active = t;
    return out.stream;
  }

  /// Barge-in: stop the turn, the cloud, the speech and the player.
  Future<void> cancel() async {
    final t = _active;
    _active = null;
    t?.cancel();
    await _speech?.cancel();
    try {
      await _sink?.stop();
    } catch (_) {}
  }

  /// THE TOOLS OF ONE GEMINI LIVE TURN (2026-09-30). The Live session
  /// (live_voice.dart) speaks for itself, but a tool it calls runs exactly
  /// as a cascade turn's: server tools through POST /ai/tool with the
  /// pending-yes approvals (a token rides only on a later turn's yes),
  /// app-local tools here, device actions handed to the engine — reported
  /// through [onEvent] as the same [BrainToolCall], [BrainDeviceAction] and
  /// [BrainNeedsConfirmation]. [ids] gives this turn's server session and
  /// turn, asked for only when a tool needs them; [serverTools] are the
  /// names the Live session was given by the server (a local tool of the
  /// same name never shadows one); [recontext] renews a session the server
  /// lost.
  BrainToolTurn openToolTurn({
    required Future<(String?, String?)> Function() ids,
    required Set<String> serverTools,
    required void Function(BrainEvent event) onEvent,
    Future<AiContext?> Function(String userText)? recontext,
  }) {
    final out = StreamController<BrainEvent>(sync: true);
    final t = _Turn(++_turns, out);
    out.stream.listen(onEvent);
    t.localNames = {
      for (final l in localTools.available())
        if (!serverTools.contains(l.name)) l.name,
    };
    return _BrainToolTurn(this, t, ids, recontext);
  }

  /// Forget this conversation (sign-out, "new conversation").
  void reset() {
    _active?.cancel();
    _active = null;
    _history.clear();
    _pending.clear();
    _sessionId = null;
  }

  // ------------------------------------------------------------ the turn

  Future<void> _run(
    _Turn t,
    String rawText,
    BrainMode mode,
    AiAttachment? image,
    List<AiAttachment> others,
    bool untrusted,
    bool shared,
    bool speak,
  ) async {
    final started = _now();
      final span = Telemetry.instance.trace('assistant_turn');
    try {
      final words =
          rawText.trim().isEmpty && image != null ? 'What is in this picture?' : rawText.trim();
      final config = await t.guard(_configs.get());
      final all = [if (image != null) image, ...others];
      Map<String, Object?> device = const {};
      final provider = _deviceContext;
      if (provider != null) {
        try {
          device = await t.guard(provider());
        } on _Cancelled {
          rethrow;
        } catch (_) {}
      }
      // A "no" to a question still pending uses its approval up: a later
      // "yes" must not carry it (the server refuses a spent token too).
      if (_hasPending() && isDecline(words)) _pending.clear();
      Future<AiContext?> askContext() => _server.context(
            text: words,
            mode: mode.name,
            sessionId: _sessionId,
            attachments: all,
            untrusted: untrusted,
            shared: shared,
            // A reply that will be spoken may carry how it should sound.
            expressive: speak && _speech != null,
            device: device,
            timeout: timeouts.context,
          );
      final fetched = await t.guard(askContext());
      final ctx = fetched ?? AiContext(system: standInSystem(mode), fromServer: false);
      // Always the session the server says: an unknown id (lost in a
      // restart) silently became a new one there.
      if (ctx.sessionId != null) _sessionId = ctx.sessionId;
      t
        ..sid = ctx.sessionId
        ..tid = ctx.turnId
        ..recontext = askContext;
      final history = ctx.history.isNotEmpty
          ? ctx.history
          : _history.length > 8
              ? _history.sublist(_history.length - 8)
              : List.of(_history);

      final decision = chooseRoute(
        RouteRequest(
          text: words,
          images: image == null ? 0 : 1,
          otherAttachments: others.length,
          serverShortcut: ctx.shortcut,
          pendingConfirmation: _hasPending() && isAffirmative(words),
        ),
        config,
      );
      AppLog.add('brain', 'route $decision');
      t.emit(BrainRouteChosen(decision.route, decision.reason));

      var engine = decision.route;
      final feed = speak && _speech != null ? _VoiceFeed(_speech) : null;
      t.onCancel(() => feed?.stream?.cancel());
      var reply = '';
      var sources = const <SourceLink>[];
      String? suggestions;
      final toolLog = <Map<String, Object?>>[];

      switch (decision.route) {
        case AiRoute.shortcut:
          reply = await _shortcut(t, ctx, decision.shortcut!, words, toolLog);
        case AiRoute.search:
          final done = await _searchTurn(t, ctx, config, history, words, all, feed, voice: speak);
          reply = done.text;
          sources = done.sources;
          suggestions = done.searchSuggestionsHtml;
        case AiRoute.cloud:
          reply = await _cloudTurn(t, ctx, config, history, words, all, toolLog, feed,
              conversation: decision.reason == 'conversation', voice: speak);
      }
      final raw = reply;

      // How it should sound stays with the voice; what is shown and
      // remembered is the words alone.
      final marked = SpeechMarkup.parse(reply);
      reply = marked.display;
      if (reply.isEmpty) reply = emptyReply;
      var spoken = marked.spoken.isEmpty ? reply : marked.spoken;
      var corrected = false;
      var silent = false;
      final sid = t.sid;
      final tid = t.tid;
      if (sid != null && tid != null) {
        final latencyMs = _now().difference(started).inMilliseconds;
        span
          ..attribute('engine', engine.name)
          ..attribute('mode', mode.name)
          ..metric('tools', toolLog.length)
          ..stop();
        Telemetry.instance.event('assistant_turn', {
          'engine': engine.name,
          'mode': mode.name,
          'tools': toolLog.length,
          'latency_ms': latencyMs,
        });
        final receipt = await t.guard(_server.recordTurn(
          sessionId: sid,
          turnId: tid,
          user: words,
          reply: reply,
          engine: engine.name,
          tools: toolLog,
          latencyMs: latencyMs,
          mode: mode.name,
          timeout: timeouts.record,
        ));
        if (receipt != null && receipt.reply.trim().isNotEmpty) {
          final checked = SpeechMarkup.strip(receipt.reply);
          // A corrected reply is spoken as corrected, in the same tone.
          if (checked != reply) spoken = checked;
          reply = checked;
          corrected = receipt.corrected;
        } else if (receipt != null && receipt.corrected) {
          // The model chose to stay silent (a voice turn that was not for
          // it): nothing is shown, said or remembered as its line.
          silent = true;
        }
      }
      if (silent) {
        feed?.stream?.cancel();
        _history.add(ChatTurn('user', words));
        if (_history.length > 16) _history.removeRange(0, _history.length - 16);
        t.emit(BrainFinalText(text: '', route: engine, corrected: true, turnId: t.tid));
        return;
      }
      _remember(words, reply);
      t.emit(BrainFinalText(
        text: reply,
        route: engine,
        corrected: corrected,
        sources: sources,
        searchSuggestionsHtml: suggestions,
        turnId: t.tid,
      ));
      if (feed != null) {
        final early = feed.stream;
        if (early != null && spoken == (marked.spoken.isEmpty ? reply : marked.spoken)) {
          // The checked reply is the one already being voiced: the rest of
          // it goes in, and it plays.
          feed.update(raw, done: true);
          early.close();
          await _play(t, early, spoken);
        } else {
          early?.cancel();
          await _say(t, spoken, tone: marked.tone);
        }
      }
    } on _Cancelled {
      return;
    } catch (e) {
      if (t.cancelled) return;
      AppLog.add('brain', 'turn failed: ${describeError(e)}');
      t.emit(BrainError.from(e));
    }
  }

  void _remember(String user, String reply) {
    _history
      ..add(ChatTurn('user', user))
      ..add(ChatTurn('model', reply));
    if (_history.length > 16) _history.removeRange(0, _history.length - 16);
  }

  Future<List<AiAttachment>> _withBytes(List<AiAttachment> all) async => [
        for (final a in all)
          if (a.bytes != null)
            a
          else if (a.path != null)
            AiAttachment(
              kind: a.kind,
              mimeType: a.mimeType,
              path: a.path,
              bytes: await _readFile(a.path!),
            ),
      ];

  static Future<Uint8List?> _readFile(String path) async {
    try {
      return await File(path).readAsBytes();
    } catch (_) {
      return null;
    }
  }

  Future<String> _cloudTurn(
    _Turn t,
    AiContext ctx,
    AiConfig config,
    List<ChatTurn> history,
    String words,
    List<AiAttachment> all,
    List<Map<String, Object?>> toolLog,
    _VoiceFeed? feed, {
    bool conversation = false,
    bool voice = false,
  }) async {
    final canUseTools = t.sid != null && t.tid != null;
    final serverTools = canUseTools ? ctx.tools : const <AiToolSpec>[];
    final taken = {for (final s in ctx.tools) s.name};
    // Local tools beside the server's; a server tool of the same name wins.
    final local = [
      for (final l in localTools.available())
        if (!taken.contains(l.name)) l.spec,
    ];
    t.localNames = {for (final l in local) l.name};
    final attachments = await t.guard(_withBytes(all));
    CloudRequest request(String model) => CloudRequest(
          model: model,
          text: words,
          system: ctx.system,
          history: history,
          attachments: attachments,
          tools: [...serverTools, ...local],
          maxToolRounds: config.limits.maxToolRounds,
          roundTimeout: timeouts.cloudRound,
          firstTimeout: timeouts.cloudFirst,
          generationConfig:
              thinkingFor(config, model, conversation: conversation, voice: voice),
        );
    final text = StringBuffer();
    var shown = '';
    CloudFinished? finished;
    await _hedged(
      t,
      config,
      'cloud',
      serverTools.length + local.length,
      (model) => _cloud.turn(request(model),
          runTool: (name, args) => _runTool(t, ctx, name, args, words, toolLog)),
      (e) {
        switch (e) {
          case CloudTextDelta(text: final delta):
            _appendDelta(text, delta);
            final now = SpeechMarkup.stripPartial(text.toString());
            if (now != shown) {
              t.emit(BrainPartialText(
                  now, now.startsWith(shown) ? now.substring(shown.length) : now));
              shown = now;
            }
            feed?.update(text.toString());
          case CloudToolStarted():
            break;
          case CloudFinished():
            finished = e;
        }
      },
    );
    return finished?.text ?? text.toString();
  }

  /// The longest spoken reply to a plain conversation turn, in tokens
  /// (2026-09-30, voice audit: a voice answer is a sentence or three, and an
  /// uncapped one kept the voice waiting on text nobody would listen to).
  static const voiceReplyTokens = 400;

  /// The same for a spoken turn that may use tools or search: room for the
  /// low thinking level as well, which counts against the cap.
  static const voiceToolReplyTokens = 1024;

  /// Models that cannot think "minimal" (3.8 Flash thinks low at least).
  static bool _noMinimal(String model) => RegExp(r'3\.8-flash(?!-lite)').hasMatch(model);

  /// The configured thinking level for [model]: the conversation model's
  /// own; a fallback answers without (it is there to be quick).
  ///
  /// 2026-09-30 (voice audit): a plain [conversation] turn — no tool or
  /// fresh-fact word — thinks minimally; the tool routes keep the
  /// configured level. A [voice] reply is capped ([voiceReplyTokens]).
  static GenerationConfig? thinkingFor(
    AiConfig config,
    String model, {
    bool conversation = false,
    bool voice = false,
  }) {
    final cap = !voice
        ? null
        : conversation
            ? voiceReplyTokens
            : voiceToolReplyTokens;
    if (model != config.models.cloud) {
      return cap == null ? null : GenerationConfig(maxOutputTokens: cap);
    }
    var level = switch (config.models.thinking.trim().toLowerCase()) {
      'minimal' => ThinkingLevel.minimal,
      'low' => ThinkingLevel.low,
      'medium' => ThinkingLevel.medium,
      'high' => ThinkingLevel.high,
      _ => null,
    };
    if (conversation) level = _noMinimal(model) ? ThinkingLevel.low : ThinkingLevel.minimal;
    if (level == null && cap == null) return null;
    return GenerationConfig(
      maxOutputTokens: cap,
      thinkingConfig: level == null ? null : ThinkingConfig.withThinkingLevel(level),
    );
  }

  /// Logs that [what] was asked (with [tools] tools); the returned
  /// callback logs, once, how long the first answer took.
  void Function() _timing(String what, int tools) {
    final asked = _now();
    AppLog.add('brain', '$what asked${tools > 0 ? ' ($tools tools)' : ''}');
    var told = false;
    return () {
      if (told) return;
      told = true;
      AppLog.add('brain', '$what answering after ${_now().difference(asked).inMilliseconds} ms');
    };
  }

  /// [e] for the log: its type and the start of its message.
  static String describeError(Object e) {
    final what = switch (e) {
      FirebaseAIException(:final message) => message,
      TimeoutException(:final message) => message ?? '',
      _ => '$e',
    };
    final line = what.replaceAll(RegExp(r'\s+'), ' ').trim();
    return line.isEmpty
        ? '${e.runtimeType}'
        : '${e.runtimeType}: ${line.length > 140 ? '${line.substring(0, 140)}…' : line}';
  }

  /// Whether a failed cloud call is worth the fallback model: the model
  /// failed or stalled, not the phone, the app's standing or the content.
  static bool fallbackHelps(Object e) =>
      e is TimeoutException ||
      e is QuotaExceeded ||
      (e is ServerException &&
          !RegExp(r'app check|permission|unauth|api key|not enabled', caseSensitive: false)
              .hasMatch(e.message));

  /// One model call, heard through [onData], answered by the conversation
  /// model — or by the fallback, asked too when the first has said nothing
  /// for [BrainTimeouts.cloudHedge] or failed before saying anything in a
  /// way another model may not. Whichever speaks first is heard; the other
  /// is dropped before it has done anything (a tool runs only after its
  /// model's first event, and by then the other is gone). Once a model has
  /// spoken, nothing is asked again: no action ever happens twice.
  Future<void> _hedged(
    _Turn t,
    AiConfig config,
    String what,
    int tools,
    Stream<CloudEvent> Function(String model) open,
    void Function(CloudEvent event) onData,
  ) {
    final first = config.models.cloud;
    final second = config.models.cloudFallback.trim();
    final canHedge = second.isNotEmpty && second != first;
    final done = Completer<void>();
    final subs = <String, StreamSubscription<CloudEvent>>{};
    final failed = <String>{};
    String? winner;
    Timer? hedge;

    void end([Object? error, StackTrace? stack]) {
      hedge?.cancel();
      for (final e in subs.entries) {
        if (e.key != winner) e.value.cancel().ignore();
      }
      if (done.isCompleted) return;
      error == null ? done.complete() : done.completeError(error, stack);
    }

    late void Function(String model) ask;
    ask = (model) {
      final heard = _timing('$what $model', tools);
      subs[model] = open(model).listen(
        (e) {
          if (winner == null) {
            winner = model;
            hedge?.cancel();
            for (final other in subs.entries) {
              if (other.key != model) other.value.cancel().ignore();
            }
            if (subs.length > 1) AppLog.add('brain', '$model answered first');
          }
          if (winner != model) return;
          heard();
          onData(e);
        },
        onError: (Object e, StackTrace st) {
          if (winner == model) return end(e, st);
          if (winner != null || done.isCompleted) return;
          failed.add(model);
          AppLog.add('brain', '$what $model failed (${describeError(e)})');
          if (!fallbackHelps(e)) return end(e, st);
          if (canHedge && !subs.containsKey(second)) {
            hedge?.cancel();
            return ask(second);
          }
          if (failed.length == subs.length) end(e, st);
        },
        onDone: () {
          if (winner == model) end();
        },
        cancelOnError: true,
      );
    };

    t.onCancel(() {
      hedge?.cancel();
      for (final s in subs.values) {
        s.cancel().ignore();
      }
      if (!done.isCompleted) done.completeError(const _Cancelled());
    });
    ask(first);
    if (canHedge) {
      hedge = Timer(timeouts.cloudHedge, () {
        if (winner != null || subs.containsKey(second) || done.isCompleted) return;
        AppLog.add('brain', '$first slow; asking $second too');
        ask(second);
      });
    }
    return done.future;
  }

  Future<CloudFinished> _searchTurn(
    _Turn t,
    AiContext ctx,
    AiConfig config,
    List<ChatTurn> history,
    String words,
    List<AiAttachment> all,
    _VoiceFeed? feed, {
    bool voice = false,
  }) async {
    final attachments = await t.guard(_withBytes(all));
    final text = StringBuffer();
    var shown = '';
    CloudFinished? finished;
    await _hedged(
      t,
      config,
      'search',
      0,
      (model) => _cloud.search(CloudRequest(
        model: model,
        text: words,
        system: ctx.system,
        history: history,
        attachments: attachments,
        roundTimeout: timeouts.cloudRound,
        firstTimeout: timeouts.cloudFirst,
        generationConfig: thinkingFor(config, model, voice: voice),
      )),
      (e) {
        switch (e) {
          case CloudTextDelta(text: final delta):
            _appendDelta(text, delta);
            final now = SpeechMarkup.stripPartial(text.toString());
            if (now != shown) {
              t.emit(BrainPartialText(
                  now, now.startsWith(shown) ? now.substring(shown.length) : now));
              shown = now;
            }
            feed?.update(text.toString());
          case CloudToolStarted():
            break;
          case CloudFinished():
            finished = e;
        }
      },
    );
    return finished ?? CloudFinished(text: text.toString());
  }

  // ------------------------------------------------------------ tools

  static String _canonical(Object? v) {
    if (v is Map) {
      final keys = [for (final k in v.keys) '$k']..sort();
      return '{${keys.map((k) => '${jsonEncode(k)}:${_canonical(v[k])}').join(',')}}';
    }
    if (v is List) return '[${v.map(_canonical).join(',')}]';
    return jsonEncode(v);
  }

  static String _approvalKey(String name, Map<String, Object?> args) => '$name ${_canonical(args)}';

  bool _hasPending() {
    final now = _now();
    _pending.removeWhere((_, a) => !a.expires.isAfter(now));
    return _pending.isNotEmpty;
  }

  /// The confirmation token for this exact call — only in a LATER turn
  /// than the one that asked, and only when the user said yes.
  String? _takeApproval(String name, Map<String, Object?> args, String userText, int turn) {
    if (!_hasPending()) return null;
    final key = _approvalKey(name, args);
    final a = _pending[key];
    if (a == null || a.turn >= turn || !isAffirmative(userText)) return null;
    _pending.remove(key);
    return a.token;
  }

  void _askLater(_Turn t, String name, Map<String, Object?> args, AiToolResult res) {
    final token = res.approvalToken;
    if (token == null) return;
    _pending[_approvalKey(name, args)] =
        _Approval(token, _now().add(const Duration(minutes: 10)), t.index);
    t.emit(BrainNeedsConfirmation(
      tool: name,
      args: args,
      summary: res.summary ?? '',
      approvalToken: token,
    ));
  }

  Future<DeviceOutcome> _device(_Turn t, String tool, Map<String, dynamic> action) {
    final answered = Completer<DeviceOutcome>();
    t.emit(BrainDeviceAction(
      tool: tool,
      action: action,
      respond: (o) {
        if (!answered.isCompleted) answered.complete(o);
      },
    ));
    return t.guard(answered.future.timeout(
      timeouts.deviceAction,
      onTimeout: () => const DeviceOutcome.failed('The phone did not answer.'),
    ));
  }

  /// The model's tool call: the server runs it; a device action is the
  /// engine's; the model is told how both went. Throws only on cancel.
  Future<Map<String, Object?>> _runTool(
    _Turn t,
    AiContext ctx,
    String name,
    Map<String, Object?> args,
    String userText,
    List<Map<String, Object?>> toolLog,
  ) async {
    t.emit(BrainToolCall(name, args));
    if (t.localNames.contains(name)) return _runLocalTool(t, name, args, userText, toolLog);
    if (t.sid == null || t.tid == null) {
      return {'ok': false, 'error': 'Tools are not available right now.'};
    }
    final res = await _callTool(t, name, args, userText);
    // A call that still needs the owner's yes ran nothing - even when a
    // token was sent and refused ("approval not accepted"): a new question.
    final ran = res.ok && !res.needsConfirmation;
    final log = <String, Object?>{'name': name, 'ok': ran};
    toolLog.add(log);
    if (res.needsConfirmation) _askLater(t, name, args, res);
    var answer = res.toFunctionResponse();
    final action = res.deviceAction;
    if (action != null && ran) {
      final outcome = await _device(t, name, action);
      log['outcome'] = outcome.ok ? 'ok' : (outcome.detail ?? 'failed');
      answer = {...answer, 'device': outcome.toJson()};
    }
    return answer;
  }

  /// The server lost this session (sessions live in its memory: a deploy
  /// or a restart forgets them) - the tool did not run.
  static bool _lostSession(AiToolResult r) =>
      r.status == 404 && (r.error ?? '').toLowerCase().contains('unknown session');

  /// POST /ai/tool for this turn. A lost session is renewed with /ai/context
  /// for this very turn and the call retried ONCE (it never ran, so that is
  /// safe); every later call of the turn uses the new ids.
  Future<AiToolResult> _callTool(
    _Turn t,
    String name,
    Map<String, Object?> args,
    String userText,
  ) async {
    final token = _takeApproval(name, args, userText, t.index);
    Future<AiToolResult> call() => _server.tool(
          sessionId: t.sid!,
          turnId: t.tid!,
          name: name,
          args: args,
          userText: userText,
          approvalToken: token,
          timeout: timeouts.tool,
        );
    var res = await t.guard(call());
    final again = t.recontext;
    if (_lostSession(res) && again != null && !t.renewed) {
      t.renewed = true;
      AppLog.add('brain', 'session lost on the server: renewing it');
      final fresh = await t.guard(again());
      if (fresh?.sessionId != null && fresh?.turnId != null) {
        t
          ..sid = fresh!.sessionId
          ..tid = fresh.turnId;
        _sessionId = fresh.sessionId;
        res = await t.guard(call());
      }
    }
    return res;
  }

  /// An app-local tool: run here, never POST /ai/tool; its device action
  /// (if any) is the engine's, as for a server tool.
  Future<Map<String, Object?>> _runLocalTool(
    _Turn t,
    String name,
    Map<String, Object?> args,
    String userText,
    List<Map<String, Object?>> toolLog,
  ) async {
    final res = await t.guard(localTools.run(
      LocalToolCall(name: name, args: args, userText: userText),
      timeout: timeouts.tool,
    ));
    final log = <String, Object?>{'name': name, 'ok': res.ok, 'local': true};
    toolLog.add(log);
    var answer = res.toFunctionResponse();
    final action = res.deviceAction;
    if (action != null && res.ok) {
      final outcome = await _device(t, name, action);
      log['outcome'] = outcome.ok ? 'ok' : (outcome.detail ?? 'failed');
      answer = {...answer, 'device': outcome.toJson()};
    }
    return answer;
  }

  /// A shortcut said whole: run it, no model (the server's own wording).
  Future<String> _shortcut(
    _Turn t,
    AiContext ctx,
    String name,
    String words,
    List<Map<String, Object?>> toolLog,
  ) async {
    if (t.sid == null || t.tid == null) {
      return "I couldn't reach your shortcuts just now. Please try again.";
    }
    final args = <String, Object?>{'name': name};
    t.emit(BrainToolCall('run_shortcut', args));
    final res = await _callTool(t, 'run_shortcut', args, words);
    final log = <String, Object?>{
      'name': 'run_shortcut',
      'ok': res.ok && !res.needsConfirmation,
    };
    toolLog.add(log);
    if (res.needsConfirmation) {
      _askLater(t, 'run_shortcut', args, res);
      final s = (res.summary ?? '').trim();
      return s.isEmpty ? 'Shall I go ahead?' : (s.endsWith('?') ? s : '$s?');
    }
    if (!res.ok) return "I couldn't run $name: ${res.error ?? 'something went wrong'}.";
    final action = res.deviceAction;
    if (action != null) {
      final outcome = await _device(t, 'run_shortcut', action);
      log['outcome'] = outcome.ok ? 'ok' : (outcome.detail ?? 'failed');
    }
    final speak = (res.speak ?? '').trim();
    return speak.isEmpty ? 'Done.' : speak;
  }

  /// A streamed piece joins the reply with the space the model left out
  /// when it resumed after a tool ("…right now.Here he is.", tester run
  /// 2026-10-01): a sentence end followed straight by a letter gets one.
  static void _appendDelta(StringBuffer text, String delta) {
    if (delta.isEmpty) return;
    if (text.isNotEmpty) {
      final prev = text.toString();
      final last = prev[prev.length - 1];
      final first = delta[0];
      if ('.!?'.contains(last) && RegExp(r'[A-Za-zऀ-෿"“]').hasMatch(first)) {
        text.write(' ');
      }
    }
    text.write(delta);
  }

  // ------------------------------------------------------------ voice

  Future<void> _say(_Turn t, String reply, {String? tone}) async {
    final stream = _speech!.open(style: tone);
    for (final p in SpeechEngine.sentences(SpeechEngine.forSpeech(reply))) {
      stream.add(p);
    }
    stream.close();
    await _play(t, stream, reply);
  }

  /// Plays [stream] into the sink; a barge-in stops both at once.
  Future<void> _play(_Turn t, SpeechStream stream, String reply) async {
    final sink = _sink;
    t.onCancel(() {
      stream.cancel();
      if (sink != null) unawaited(sink.stop().catchError((_) {}));
    });
    final handed = await t.guard(stream.release(sink, onChunk: (c) {
      t.emit(BrainSpokenAudio(
        index: c.index,
        sentence: c.text,
        pcm: c.pcm,
        sampleRate: c.sampleRate,
      ));
    }));
    if (handed == 0 && reply.trim().isNotEmpty) {
      t.emit(const BrainError('tts', "The reply couldn't be spoken.", fatal: false));
    }
  }
}

/// Hands a reply's finished sentences to the speech engine while the model
/// is still writing it, so its voice is ready the moment the reply is: the
/// last piece of the text so far may still grow, every piece before it is
/// final. Short pieces wait to be joined, as [SpeechEngine.sentences] joins
/// them.
class _VoiceFeed {
  _VoiceFeed(this._engine);

  final SpeechEngine _engine;
  SpeechStream? stream;
  var _fed = 0;
  var _waiting = '';

  /// [raw] is the reply so far, delivery marks and all.
  ///
  /// The first sentence goes to the speech model as soon as it is written;
  /// everything after it waits for the end of the reply and goes as one
  /// request, so the voice carries on instead of starting over each
  /// sentence ([SpeechEngine.pieces]). A very long reply is cut at
  /// [SpeechEngine.maxPiece].
  void update(String raw, {bool done = false}) {
    final marked = SpeechMarkup.parse(raw);
    final spoken = SpeechEngine.forSpeech(marked.spoken);
    final pieces = SpeechEngine.sentences(spoken, minChars: 1);
    // 2026-09-30 (voice audit): a last piece that already ENDS a sentence
    // is final too — the first one goes to the voice the moment its full
    // stop is written, not when the next sentence begins.
    final ready = done || (stream == null && endsSentence(spoken, pieces))
        ? pieces.length
        : pieces.length - 1;
    for (; _fed < ready; _fed++) {
      _waiting = _waiting.isEmpty ? pieces[_fed] : '$_waiting ${pieces[_fed]}';
      final enough = stream == null
          ? _waiting.length >= SpeechEngine.minChars
          : _waiting.length >= SpeechEngine.maxPiece;
      if (enough) _hand(marked.tone);
    }
    if (done && _waiting.isNotEmpty) _hand(marked.tone);
  }

  void _hand(String? tone) {
    (stream ??= _engine.open(style: tone)).add(_waiting);
    _waiting = '';
  }

  static final _stop = RegExp('[^0-9][.!?।॥]["\'”’)\\]]*\$');

  /// Whether [spoken] (split into [pieces]) ends on a finished sentence:
  /// it ends in . ! ? or । and the splitter, shown one more word, would
  /// cut exactly there (so "Rs." or an initial still waits). A digit before
  /// the stop waits too ("3." may be "3.5").
  static bool endsSentence(String spoken, List<String> pieces) {
    final text = spoken.trimRight();
    if (pieces.isEmpty || !_stop.hasMatch(text)) return false;
    final probe = SpeechEngine.sentences('$text Next', minChars: 1);
    return probe.length == pieces.length + 1 && probe[pieces.length - 1] == pieces.last;
  }
}

/// The tool side of one Gemini Live turn ([AssistantBrain.openToolTurn]):
/// what the Live model calls runs here exactly as in a cascade turn.
abstract interface class BrainToolTurn {
  /// What ran this turn, as /ai/turn is told ({name, ok, outcome?, local?}).
  List<Map<String, Object?>> get toolLog;

  /// This turn's server session and turn (renewed when the server lost the
  /// session); null until a tool or the record asked for them.
  String? get sessionId;
  String? get turnId;

  bool get cancelled;

  /// The server's ids for this turn, asked for once.
  Future<void> resolveIds();

  /// Runs the model's call [name]([args]) for words [userText]; the answer
  /// the model is handed. Never throws: a cancelled or failed call is an
  /// ok == false answer.
  Future<Map<String, Object?>> run(
    String name,
    Map<String, Object?> args, {
    required String userText,
  });

  /// Stops a call still running (the model cancelled it, or a barge-in).
  void cancel();

  /// The turn is over: the phone remembers it as the cascade does (a
  /// fallback turn later carries it as history).
  void finish(String user, String reply);
}

class _BrainToolTurn implements BrainToolTurn {
  _BrainToolTurn(this._brain, this._t, this._ids, this._recontext);

  final AssistantBrain _brain;
  final _Turn _t;
  final Future<(String?, String?)> Function() _ids;
  final Future<AiContext?> Function(String userText)? _recontext;
  Future<void>? _resolving;

  @override
  final toolLog = <Map<String, Object?>>[];

  @override
  String? get sessionId => _t.sid;
  @override
  String? get turnId => _t.tid;

  @override
  bool get cancelled => _t.cancelled;

  @override
  Future<void> resolveIds() => _resolving ??= () async {
        try {
          final (sid, tid) = await _ids();
          _t
            ..sid = sid
            ..tid = tid;
          if (sid != null) _brain._sessionId = sid;
        } catch (_) {}
      }();

  @override
  Future<Map<String, Object?>> run(
    String name,
    Map<String, Object?> args, {
    required String userText,
  }) async {
    if (_t.cancelled) return const {'ok': false, 'error': 'cancelled'};
    await resolveIds();
    // A "no" to a question still pending uses its approval up (as a
    // cascade turn does before its tools run).
    if (_brain._hasPending() && isDecline(userText)) _brain._pending.clear();
    final again = _recontext;
    _t.recontext = again == null ? null : () => again(userText);
    try {
      return await _brain._runTool(_t, const AiContext(), name, args, userText, toolLog);
    } on _Cancelled {
      return const {'ok': false, 'error': 'cancelled'};
    } catch (e) {
      return {'ok': false, 'error': '$e'};
    }
  }

  @override
  void cancel() => _t.cancel();

  @override
  void finish(String user, String reply) {
    if (_brain._hasPending() && isDecline(user)) _brain._pending.clear();
    final u = user.trim();
    final r = reply.trim();
    if (u.isNotEmpty && r.isNotEmpty) {
      _brain._remember(u, r);
    } else if (u.isNotEmpty) {
      final h = _brain._history..add(ChatTurn('user', u));
      if (h.length > 16) h.removeRange(0, h.length - 16);
    }
    _t.done = true;
    if (!_t.out.isClosed) _t.out.close();
  }
}
