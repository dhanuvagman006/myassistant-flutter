/// THE FAST VOICE — Gemini Live through Firebase AI Logic (2026-09-30).
///
/// Measured from the PC that morning (the same proxy firebase_ai uses, the
/// App Check debug token): the cascade — the phone's recogniser, 1.4 s of
/// pause, /ai/context, a text model, then Fola TTS — took 5-8 s from the
/// owner's last word to her first sound. gemini-3.8-live answered in 0.62 s
/// (500 ms of silence, END_SENSITIVITY_HIGH); with a tool declared
/// BLOCKING it spoke the tool's result 1.75 s after the owner stopped.
///
/// ONE SESSION PER CONVERSATION. [LiveVoice.warm] asks the server for the
/// Live instruction and tools (POST /ai/context, mode 'live') and opens the
/// session while the orb's hello plays; [LiveVoice.start] opens the
/// microphone (16 kHz PCM16, VOICE_COMMUNICATION with the echo canceller)
/// and streams it in 40 ms chunks; her audio (24 kHz) plays through the
/// app's one [PcmPlayer] from its first chunk.
///
/// NOTHING IS LOST FROM THE CASCADE:
///  - every tool the Live model calls runs through the brain
///    ([AssistantBrain.openToolTurn]) — POST /ai/tool, the pending-yes
///    approvals, local tools, device actions — and is answered with the
///    call's id;
///  - every turn is recorded with POST /ai/turn (mode 'live', latency, and
///    how much of the reply was heard when the owner cut in);
///  - if Live is off, cannot connect within [LiveTimeouts.connect], drops
///    twice or stalls, [LiveFallback] hands the turn to the cascade: the
///    owner is never left without an answer.
///
/// TALKING OVER HER. While she plays, the microphone goes through the same
/// echo-aware [BargeInDetector] as the cascade; Live is sent silence (it
/// must not hear her own voice as the owner). The moment the detector is
/// sure, she stops HERE at once and Live is sent the last ~480 ms of real
/// audio (the pre-roll) and everything after, so its own detector sees the
/// owner and interrupts; its 'interrupted' flushes the player.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:firebase_ai/firebase_ai.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/log.dart';
import '../services/audio/barge_in.dart';
import '../services/audio/mic_preroll.dart';
import '../services/audio/mic_stats.dart';
import '../services/audio/mic_stream.dart';
import '../services/audio/pcm_player.dart';
import 'brain.dart';
import 'config.dart';
import 'json_schema.dart';
import 'model_port.dart';
import 'speech.dart';
import 'tool_server.dart';
import 'types.dart';

// ---------------------------------------------------------------- tools

/// A Live function declaration the model WAITS on.
///
/// gemini-3.8-live runs tools asynchronously by default (NON_BLOCKING):
/// measured 2026-09-30, it went silent after our tool response — turn
/// complete, no audio. Declared "behavior": "BLOCKING" it spoke the result.
/// firebase_ai 4.0.0 has no field for it, so the JSON gets it here.
class BlockingFunctionDeclaration extends FunctionDeclaration {
  BlockingFunctionDeclaration(
    super.name,
    super.description, {
    required super.parameters,
    super.optionalParameters,
  });

  @override
  Map<String, Object?> toJson() => {...super.toJson(), 'behavior': 'BLOCKING'};
}

/// A server (or local) tool as the Live model is given it.
BlockingFunctionDeclaration liveDeclarationFor(AiToolSpec tool) {
  final (properties, optional) = objectParts(tool.parameters);
  return BlockingFunctionDeclaration(tool.name, tool.description,
      parameters: properties, optionalParameters: optional);
}

// ---------------------------------------------------------------- setup

/// Everything a Live session is opened with.
class LiveSetup {
  const LiveSetup({
    required this.model,
    required this.voice,
    required this.system,
    this.tools = const [],
    this.live = const AiLive(),
  });

  final String model;
  final String voice;
  final String system;
  final List<AiToolSpec> tools;

  /// The voice-activity settings (silence, padding, sensitivities).
  final AiLive live;

  List<Tool>? get sdkTools => tools.isEmpty
      ? null
      : [
          Tool.functionDeclarations([for (final t in tools) liveDeclarationFor(t)]),
        ];

  static Sensitivity _sensitivity(String s) => s == 'low' ? Sensitivity.low : Sensitivity.high;

  LiveGenerationConfig get generationConfig => LiveGenerationConfig(
        responseModalities: [ResponseModalities.audio],
        speechConfig: SpeechConfig(voiceName: voice),
        inputAudioTranscription: AudioTranscriptionConfig(),
        outputAudioTranscription: AudioTranscriptionConfig(),
        // A long conversation outlives the 15-minute audio context without
        // this: the oldest turns slide out instead.
        contextWindowCompression: ContextWindowCompressionConfig(slidingWindow: SlidingWindow()),
        realtimeInputConfig: RealtimeInputConfig(
          automaticActivityDetection: ActivityDetectionConfig(
            startSensitivity: _sensitivity(live.startSensitivity),
            endSensitivity: _sensitivity(live.endSensitivity),
            prefixPaddingMS: live.prefixMs,
            silenceDurationMS: live.silenceMs,
          ),
          activityHandling: ActivityHandling.interrupt,
        ),
        // Feeling in her voice, matched to theirs (the client, 2026-09-30).
        enableAffectiveDialog: live.affectiveDialog ? true : null,
      );
}

// ---------------------------------------------------------------- the wire

/// What the Live session says, as [LiveVoice] needs it (firebase_ai's
/// messages mapped, or a test's).
sealed class LiveIn {
  const LiveIn();
}

/// setupComplete: the session is ready for audio.
final class LiveInReady extends LiveIn {
  const LiveInReady();
}

/// Her audio, the transcriptions, the end of her turn, an interruption.
final class LiveInContent extends LiveIn {
  const LiveInContent({
    this.audio = const [],
    this.heard,
    this.said,
    this.turnComplete = false,
    this.interrupted = false,
  });

  /// PCM16 chunks with their sample rate.
  final List<(Uint8List, int)> audio;

  /// More of what the owner said (input transcription).
  final String? heard;

  /// More of what she is saying (output transcription).
  final String? said;
  final bool turnComplete;
  final bool interrupted;
}

final class LiveInToolCall extends LiveIn {
  const LiveInToolCall(this.calls);
  final List<FunctionCall> calls;
}

final class LiveInToolCancel extends LiveIn {
  const LiveInToolCancel(this.ids);
  final List<String> ids;
}

/// The server will close this connection soon.
final class LiveInGoAway extends LiveIn {
  const LiveInGoAway([this.timeLeft]);
  final String? timeLeft;
}

/// A handle this session can be resumed with.
final class LiveInResumption extends LiveIn {
  const LiveInResumption({this.handle, this.resumable = false});
  final String? handle;
  final bool resumable;
}

/// The server sent something (anything, understood or not): the session is
/// alive. At most two a second.
final class LiveInPing extends LiveIn {
  const LiveInPing();
}

/// One firebase_ai message as a [LiveIn].
LiveIn liveInFrom(LiveServerMessage m) => switch (m) {
      LiveServerContent(
        :final modelTurn,
        :final turnComplete,
        :final interrupted,
        :final inputTranscription,
        :final outputTranscription,
      ) =>
        LiveInContent(
          audio: [
            for (final p in modelTurn?.parts ?? const <Part>[])
              if (p is InlineDataPart && p.mimeType.toLowerCase().startsWith('audio/'))
                (p.bytes, SpeechEngine.sampleRateOf(p.mimeType)),
          ],
          heard: inputTranscription?.text,
          said: outputTranscription?.text,
          turnComplete: turnComplete == true,
          interrupted: interrupted == true,
        ),
      LiveServerToolCall(:final functionCalls) => LiveInToolCall(functionCalls ?? const []),
      LiveServerToolCallCancellation(:final functionIds) =>
        LiveInToolCancel(functionIds ?? const []),
      GoingAwayNotice(:final timeLeft) => LiveInGoAway(timeLeft),
      SessionResumptionUpdate(:final newHandle, :final resumable) =>
        LiveInResumption(handle: newHandle, resumable: resumable == true),
      // The only other kind firebase_ai parses: setupComplete.
      _ => const LiveInReady(),
    };

/// One open Live session.
abstract interface class LiveSessionPort {
  /// What the server says, until the connection closes.
  Stream<LiveIn> get messages;
  void sendAudio(Uint8List pcm16);

  /// Words for the model to answer now (a nudge).
  void sendText(String text);
  void sendToolResponses(List<FunctionResponse> responses);
  Future<void> close();
}

/// Opens Live sessions (firebase_ai, or a test's).
abstract interface class LiveConnector {
  Future<LiveSessionPort> connect(LiveSetup setup, {String? resumeHandle});
}

/// The real thing: firebase_ai's LiveGenerativeModel on the Gemini
/// Developer API, with the same App Check and Firebase user as every other
/// model call ([FirebaseModelPort.defaultAi]).
class FirebaseLiveConnector implements LiveConnector {
  FirebaseLiveConnector({FirebaseAI Function()? ai}) : _ai = ai ?? FirebaseModelPort.defaultAi;

  final FirebaseAI Function() _ai;

  @override
  Future<LiveSessionPort> connect(LiveSetup setup, {String? resumeHandle}) async {
    final model = _ai().liveGenerativeModel(
      model: setup.model,
      liveGenerationConfig: setup.generationConfig,
      tools: setup.sdkTools,
      systemInstruction: setup.system.trim().isEmpty ? null : Content.system(setup.system),
    );
    final session = await model.connect(
      sessionResumption: resumeHandle == null
          ? SessionResumptionConfig()
          : SessionResumptionConfig.resume(resumeHandle),
    );
    return _FirebaseLiveSession(session);
  }
}

class _FirebaseLiveSession implements LiveSessionPort {
  _FirebaseLiveSession(this._s) {
    _s.onFrame = _alive;
    _listen();
  }

  final LiveSession _s;
  final _out = StreamController<LiveIn>();
  StreamSubscription<LiveServerResponse>? _sub;
  bool _closed = false;
  bool _errored = false;
  int _relistens = 0;
  final _clock = Stopwatch()..start();
  int _pingMs = -1000;

  /// Every frame from the server (third_party/firebase_ai's onFrame): the
  /// session is alive, whatever the frame was.
  void _alive() {
    final ms = _clock.elapsedMilliseconds;
    if (ms - _pingMs < 500 || _out.isClosed) return;
    _pingMs = ms;
    _out.add(const LiveInPing());
  }

  /// receive() ends on an error. Our copy of firebase_ai no longer makes
  /// one of a message it does not know (gemini-3.8-live sends ~30 a turn:
  /// voiceActivity, keep-alives — upstream each one ENDED receive() and lost
  /// what came right behind it, third_party/README.md). A server error is
  /// still one, and the socket may be open after it: listened to again. A
  /// closed socket, or an end without an error, is the real end.
  void _listen() {
    _sub = _s.receive().listen(
      (r) {
        _relistens = 0;
        if (!_out.isClosed) _out.add(liveInFrom(r.message));
      },
      onError: (Object e) {
        final closed = e is LiveWebSocketClosedException;
        _errored = !closed;
        AppLog.add('live', closed ? 'the socket closed: $e' : 'server error: ${AssistantBrain.describeError(e)}');
      },
      onDone: () {
        if (_closed) return;
        if (_errored && _relistens++ < 20) {
          _errored = false;
          _listen();
          return;
        }
        if (!_out.isClosed) _out.close();
      },
    );
  }

  @override
  Stream<LiveIn> get messages => _out.stream;

  /// Sends; a socket found closed ends the session at once, so the voice
  /// reconnects instead of talking into nothing.
  void _quiet(Future<void> Function() send) {
    void failed(Object e) {
      if (e is! LiveWebSocketClosedException || _closed || _out.isClosed) return;
      AppLog.add('live', 'sending into a closed socket: the session is over');
      unawaited(_sub?.cancel());
      unawaited(_out.close());
    }

    try {
      send().catchError(failed);
    } catch (e) {
      failed(e);
    }
  }

  @override
  void sendAudio(Uint8List pcm16) =>
      _quiet(() => _s.sendAudioRealtime(InlineDataPart('audio/pcm;rate=16000', pcm16)));

  @override
  void sendText(String text) => _quiet(() => _s.sendTextRealtime(text));

  @override
  void sendToolResponses(List<FunctionResponse> responses) =>
      _quiet(() => _s.sendToolResponse(responses));

  @override
  Future<void> close() async {
    _closed = true;
    await _sub?.cancel();
    if (!_out.isClosed) await _out.close();
    await _s.close();
  }
}

// ---------------------------------------------------------------- events

/// Both halves of a finished turn's audio, for review (the owner's
/// testers who said yes to "help improve"): the microphone frames fed to
/// Live and the PCM Live spoke back. See services/turn_audio_uploader.dart.
final class LiveTurnAudio {
  const LiveTurnAudio({
    required this.turnId,
    required this.startedAt,
    required this.user,
    required this.agent,
    this.userRate = 16000,
    this.agentRate = 24000,
  });
  final String turnId;
  final DateTime startedAt;
  final List<Uint8List> user;
  final List<Uint8List> agent;
  final int userRate;
  final int agentRate;
}

/// What the engine hears from a Live conversation.
sealed class LiveEvent {
  const LiveEvent();
}

/// The owner's words so far this turn (captions).
final class LiveHeard extends LiveEvent {
  const LiveHeard(this.text);
  final String text;
}

/// The owner stopped talking; her answer is coming (THINKING).
final class LiveThinking extends LiveEvent {
  const LiveThinking();
}

/// A tool's progress, as the brain reports it: [BrainToolCall] (RESPONDING),
/// [BrainDeviceAction] (the engine performs it and answers),
/// [BrainNeedsConfirmation] (the confirm card).
final class LiveBrain extends LiveEvent {
  const LiveBrain(this.event);
  final BrainEvent event;
}

/// Her first audio of the turn is playing (SPEAKING).
final class LiveSpeaking extends LiveEvent {
  const LiveSpeaking();
}

/// Her words so far this turn (captions).
final class LiveSaid extends LiveEvent {
  const LiveSaid(this.text);
  final String text;
}

/// The owner talked over her (or tapped): she stopped.
final class LiveInterrupted extends LiveEvent {
  const LiveInterrupted();
}

/// A turn is over: answered and heard to the end (DONE), cut off, or
/// nothing at all (a cough; [user] and [reply] empty).
final class LiveTurnDone extends LiveEvent {
  const LiveTurnDone({
    required this.user,
    required this.reply,
    this.interrupted = false,
    this.latency = const {},
    this.opening = false,
  });
  final String user;
  final String reply;
  final bool interrupted;

  /// Her hello ([LiveVoice.greet]), not an answer to him.
  final bool opening;

  /// endToFirstAudio, endToPlay and tool, in ms (when known).
  final Map<String, int> latency;
}

/// The server's claim check corrected what she said.
final class LiveCorrected extends LiveEvent {
  const LiveCorrected(this.text);
  final String text;
}

/// Live could not answer: the cascade takes over. [words]: the owner's
/// question, still unanswered — the cascade answers it (only when no tool
/// ran, so nothing is ever done twice). [line]: something to say instead
/// (a tool ran but she went quiet). [keepLive]: the next turn may try Live
/// again; otherwise the conversation carries on without it.
final class LiveFallback extends LiveEvent {
  const LiveFallback({required this.reason, this.words, this.line, this.keepLive = false});
  final String reason;
  final String? words;
  final String? line;
  final bool keepLive;
}

// ---------------------------------------------------------------- settings

/// The owner's choices: the fast voice on or off, and its voice. Kept on
/// the phone (the Voice screen), read when a conversation starts.
class LiveVoicePrefs {
  static const onKey = 'live_voice_on';
  static const voiceKey = 'live_voice_name';

  /// "Fast live voice" — on unless the owner turned it off.
  static bool enabled = true;

  /// The Live voice they picked (null: the server's default).
  static String? chosenVoice;

  static Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      enabled = p.getBool(onKey) ?? true;
      chosenVoice = p.getString(voiceKey);
    } catch (_) {}
  }

  static Future<void> setEnabled(bool on) async {
    enabled = on;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(onKey, on);
    } catch (_) {}
  }

  static Future<void> setVoice(String voice) async {
    chosenVoice = voice;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(voiceKey, voice);
    } catch (_) {}
  }

  /// The voice a session uses: the owner's pick, else the server's.
  static String voiceFor(AiLive live) {
    final v = (chosenVoice ?? '').trim();
    return v.isEmpty ? live.voice : v;
  }
}

/// A short sample of a Live voice for the picker. The Live voices are the
/// same prebuilt voices the speech model speaks, so the sample is made
/// with it (no session to open) and kept, so a second tap is instant.
class LiveVoicePreview {
  static final _cache = <String, List<SpeechChunk>>{};

  static String line(String voice) => "Hi, I'm $voice. This is how I'll sound when we talk.";

  /// Plays [voice]'s sample into [sink]. False when it could not be made.
  static Future<bool> play(
    String voice, {
    required AudioSink sink,
    ModelPort? port,
    AiConfig Function()? config,
  }) async {
    await sink.stop();
    final chunks = _cache[voice];
    if (chunks == null) {
      final base = config ?? () => AiConfigStore.instance.current;
      final engine = SpeechEngine(
        port: port ?? FirebaseModelPort(),
        config: () => base().withVoice(voice),
      );
      final made = <SpeechChunk>[];
      try {
        await for (final c in engine.synthesizeChunks(line(voice))) {
          made.add(c);
          await sink.play(c.pcm, sampleRate: c.sampleRate);
        }
      } catch (_) {}
      if (made.isEmpty) return false;
      _cache[voice] = made;
      return true;
    }
    for (final c in chunks) {
      await sink.play(c.pcm, sampleRate: c.sampleRate);
    }
    return true;
  }
}

// ---------------------------------------------------------------- the voice

class LiveTimeouts {
  const LiveTimeouts({
    this.context = const Duration(seconds: 4),
    this.connect = const Duration(seconds: 3),
    this.firstReply = const Duration(seconds: 6),
    this.afterTool = const Duration(seconds: 10),
    this.turnIds = const Duration(seconds: 5),
    this.record = const Duration(seconds: 5),
    this.tool = const Duration(seconds: 40),
    this.micSilent = const Duration(seconds: 2),
    this.hearing = const Duration(seconds: 2),
    this.heardOnly = const Duration(seconds: 10),
  });

  /// POST /ai/context for the session's instruction and tools.
  final Duration context;

  /// Connect plus setupComplete; past this the cascade answers.
  final Duration connect;

  /// The owner stopped talking and she has said nothing, called nothing.
  final Duration firstReply;

  /// A tool answered and she has said nothing.
  final Duration afterTool;

  /// A server turn id for a tool or the record.
  final Duration turnIds;
  final Duration record;

  /// One tool call, end to end. Past this the model is answered anyway
  /// (a BLOCKING tool left unanswered leaves it waiting for good).
  final Duration tool;

  /// No frame from an open microphone for this long: it is reopened.
  final Duration micSilent;

  /// He stopped, and the server has not made one sound since he began
  /// (see [LiveVoice._armHearingCheck]).
  final Duration hearing;

  /// The server heard him, this phone's VAD never heard him stop (too
  /// quiet a microphone), and nothing has answered since his last words.
  final Duration heardOnly;
}

/// One turn of the Live conversation: the owner's words, her answer, and
/// what was measured.
class _LiveTurn {
  _LiveTurn(this.index);

  final int index;
  String heard = '';
  String said = '';

  /// The last loud frame of the owner's speech (end of speech), µs.
  int? endUs;

  /// His first word (this phone's VAD), µs, and how much he said.
  int? onsetUs;
  int speechMs = 0;

  /// This phone's copy of what he said (real audio, from just before the
  /// onset), so a new session can hear it if this one stopped hearing.
  final utterance = <Uint8List>[];
  static const utteranceMax = 375; // ×40 ms = 15 s

  /// Her reply's PCM, kept for review uploads (capped: 45 s at 24 kHz).
  final reply = <Uint8List>[];
  int replyRate = 24000;
  int replyBytes = 0;
  static const replyMaxBytes = 24000 * 2 * 45;
  final startedAt = DateTime.now();

  /// A fresh session was given [utterance] ([LiveVoice._revive]).
  bool revived = false;

  /// Her hello, said on the app's cue ([LiveVoice.greet]).
  bool opening = false;

  /// Her first audio arrived / was first heard, µs.
  int? firstAudioUs;
  int? playUs;
  int toolMs = 0;

  /// Her audio received this turn, ms.
  int audioMs = 0;

  /// She answered in any way (audio, words or a tool).
  bool answered = false;

  /// She made a sound.
  bool spoke = false;
  bool serverDone = false;
  bool interrupted = false;
  bool nudged = false;
  bool finished = false;
  int? cutOffAfter;
  BrainToolTurn? tools;
  Future<(String?, String?)>? ids;

  bool get ranTools => tools?.toolLog.isNotEmpty ?? false;

  Map<String, int> latency() {
    final end = endUs;
    final first = firstAudioUs;
    if (end == null || first == null) return {if (toolMs > 0) 'tool': toolMs};
    return {
      'endToFirstAudio': ((first - end) / 1000).round(),
      if (playUs != null) 'endToPlay': ((playUs! - end) / 1000).round(),
      'tool': toolMs,
    };
  }
}

class LiveVoice {
  LiveVoice({
    required LiveConnector connector,
    required ToolServer server,
    required AssistantBrain brain,
    required PcmPlayer player,
    MicStream? mic,
    AiConfigStore? configs,
    Future<Map<String, Object?>> Function()? deviceContext,
    this.timeouts = const LiveTimeouts(),
    bool Function()? enabled,
    this.onTurnAudio,
  })  : _connector = connector,
        _server = server,
        _brain = brain,
        _player = player,
        _mic = mic ?? MicStream(),
        _configs = configs ?? AiConfigStore.instance,
        _deviceContext = deviceContext,
        _enabled = enabled ?? (() => LiveVoicePrefs.enabled);

  /// The real wiring: firebase_ai, the backend, the app's config.
  factory LiveVoice.standard({
    required AssistantBrain brain,
    required PcmPlayer player,
    Future<Map<String, Object?>> Function()? deviceContext,
    void Function(LiveTurnAudio audio)? onTurnAudio,
  }) =>
      LiveVoice(
        connector: FirebaseLiveConnector(),
        server: ToolServer(),
        brain: brain,
        player: player,
        deviceContext: deviceContext,
        onTurnAudio: onTurnAudio,
      );

  final LiveConnector _connector;
  final ToolServer _server;
  final AssistantBrain _brain;
  final PcmPlayer _player;
  final MicStream _mic;
  final AiConfigStore _configs;
  final Future<Map<String, Object?>> Function()? _deviceContext;
  final bool Function() _enabled;

  /// Given both halves of each recorded turn's audio (review uploads);
  /// null keeps nothing beyond the utterance the revive path needs.
  void Function(LiveTurnAudio audio)? onTurnAudio;
  final LiveTimeouts timeouts;

  final _events = StreamController<LiveEvent>.broadcast();

  /// Everything the engine needs to follow the conversation.
  Stream<LiveEvent> get events => _events.stream;

  LiveSessionPort? _session;
  StreamSubscription<LiveIn>? _sub;
  int _gen = 0;
  Completer<void>? _ready;
  Future<bool>? _connecting;
  LiveSetup? _setup;
  Set<String> _serverTools = const {};
  String? _sid;
  String? _handle;
  bool _resumable = false;
  bool _goingAway = false;
  bool _reconnecting = false;
  bool _reconnectedSinceTurn = false;
  bool _stopped = true;

  Future<(String?, String?)>? _nextIds;

  _LiveTurn? _turn;
  int _turns = 0;
  int _stalls = 0;
  bool _dropOutput = false;
  final _cancelledIds = <String>{};
  Timer? _watch;
  Timer? _idle;

  bool _micOn = false;
  bool _wasPlaying = false;

  /// STUCK ON "LISTENING" (the client's S24 Ultra, 2026-09-30). Nothing
  /// noticed when the microphone stopped sending (a notification paused
  /// it) or the session stopped hearing (a dead socket, a stuck server):
  /// the screen said Listening and nothing ever happened again. Now:
  ///  - the microphone's frames are watched ([LiveTimeouts.micSilent]) and
  ///    a silent one is reopened;
  ///  - every frame from the server is a sign of life ([LiveInPing]); he
  ///    spoke, and nothing at all came back, or nothing he said was heard
  ///    twice running: a FRESH session hears his words again ([_revive]);
  ///  - still deaf after that: the cascade takes over, and says so.
  int _lastFrameUs = 0;
  int _lastInUs = 0;
  Timer? _micWatch;
  bool _restartingMic = false;
  final _micRestarts = <int>[];
  int _deafTurns = 0;
  int _deadRevives = 0;
  int _revives = 0;
  bool _reviving = false;
  bool _droppedWhileOpening = false;
  Timer? _hearCheck;

  /// Real speech (this phone's VAD) that must be heard back: shorter is a
  /// cough or a door.
  static const _deafSpeechMs = 600;

  /// Speech this long is a sentence, not a clatter: one unheard sentence
  /// is already enough to open a fresh session and replay it.
  static const _deafSentenceMs = 1500;

  /// Said when the fast voice gives up on a turn nobody heard.
  static const missedLine = "Sorry, I didn't catch that. Could you say it again?";

  /// The owner's microphone level, 0..1, while she is silent (the orb).
  void Function(double level)? onLevel;
  int? _lastLoudUs;

  /// The room: its noise floor learnt while she is silent — from the first
  /// frame, not from her first reply (voice audit, 2026-09-30) — and the
  /// owner's own onset and end of speech.
  /// 700 ms since 2026-10-01: at 500 the client's think-pauses ("Tell me
  /// the …") ended his turn on this phone and the TV gate fed Live
  /// silence, so half a sentence was answered.
  VoiceActivityDetector room = VoiceActivityDetector(hangoverMs: 700);
  final _preRoll = MicPreRoll(keepMs: 480);

  /// THE TV GATE (2026-09-30, measured on gemini-3.8-live with a TV mixed
  /// in at 10 dB: Live's own end-of-turn never fired, no answer; at 5 dB
  /// 4.3 s). Once this phone's VAD hears the owner stop, Live gets silence
  /// instead of the room until she answers or he speaks again — so its
  /// 500 ms silence rule closes the turn. The last ~400 ms are kept and
  /// sent first if he carries on, so nothing he says is lost.
  bool _gated = false;
  int _sentFrames = 0;
  int _gatedAtUs = 0;
  final _gateRoll = ListQueue<Uint8List>();
  static const _gateRollMax = 10; // ×40 ms
  static const _gateMaxUs = 8000000;

  /// Frames held while the session is (re)connecting: ~3 s.
  final _backlog = ListQueue<Uint8List>();
  static const _backlogMax = 75;

  /// The session is open and ready for audio.
  bool get connected => _session != null && !_reconnecting;

  /// The microphone is streaming to Live.
  bool get listening => _micOn;

  /// A turn is under way (the owner has spoken, her answer is not over).
  bool get turnOpen {
    final t = _turn;
    return t != null && !t.finished && (t.heard.isNotEmpty || t.answered || t.endUs != null);
  }

  int _now() => _player.nowUs();

  void _emit(LiveEvent e) {
    if (!_events.isClosed) _events.add(e);
  }

  // ------------------------------------------------------------ connect

  /// Opens the session if it is not open (the instruction and tools from
  /// the server, then connect and setup). True when it is ready. Safe to
  /// call often: one connection at a time.
  Future<bool> warm() {
    if (_session != null || _reconnecting) return Future.value(true);
    return _connecting ??= _connectFresh().whenComplete(() => _connecting = null);
  }

  Future<Map<String, Object?>> _device() async {
    final provider = _deviceContext;
    if (provider == null) return const {};
    try {
      return await provider();
    } catch (_) {
      return const {};
    }
  }

  Future<bool> _connectFresh() async {
    if (!_enabled()) return false;
    final started = _now();
    try {
      final cfg = (await _configs.get()).live;
      if (!cfg.on) {
        AppLog.add('live', 'off in the config: the cascade answers');
        return false;
      }
      final ctx = await _server.context(
        text: '',
        mode: 'live',
        sessionId: _brain.sessionId,
        device: await _device(),
        timeout: timeouts.context,
      );
      if (ctx == null) {
        AppLog.add('live', 'no context from the server: the cascade answers');
        return false;
      }
      _sid = ctx.sessionId;
      _nextIds = Future.value((ctx.sessionId, ctx.turnId));
      final names = {for (final s in ctx.tools) s.name};
      final local = [
        for (final l in _brain.localTools.available())
          if (!names.contains(l.name)) l.spec,
      ];
      _serverTools = names;
      final setup = LiveSetup(
        model: cfg.model,
        voice: LiveVoicePrefs.voiceFor(cfg),
        system: systemFor(ctx),
        tools: [...ctx.tools, ...local],
        live: cfg,
      );
      _setup = setup;
      final ok = await _open(setup);
      final ms = (_now() - started) ~/ 1000;
      AppLog.add(
          'live',
          ok
              ? 'connected in $ms ms (${setup.model}, ${setup.voice}, ${setup.tools.length} tools)'
              : 'could not connect ($ms ms): the cascade answers');
      if (ok) _armIdle();
      return ok;
    } catch (e) {
      AppLog.add('live', 'connect failed: ${AssistantBrain.describeError(e)}');
      return false;
    }
  }

  /// The server's instruction, with what a live voice needs, and the
  /// conversation so far (a fresh Live session knows none of it).
  static String systemFor(AiContext ctx) {
    final b = StringBuffer(ctx.system.trim())
      ..write('\n\nYOU ARE SPEAKING OUT LOUD in a live voice conversation: short, natural '
          'sentences; no lists, links or formatting. When you use a tool, say what '
          'happened as soon as it answers.');
    if (ctx.history.isNotEmpty) {
      b.write('\n\nEARLIER IN THIS CONVERSATION:');
      for (final h in ctx.history) {
        final t = h.text.trim();
        b.write('\n${h.isUser ? 'The owner' : 'You'}: '
            '${t.length > 400 ? '${t.substring(0, 400)}…' : t}');
      }
    }
    return b.toString();
  }

  /// Connects [setup] (resuming [handle]) and waits for setupComplete.
  Future<bool> _open(LiveSetup setup, {String? handle}) async {
    final gen = ++_gen;
    final ready = Completer<void>();
    _ready = ready;
    LiveSessionPort? s;
    final deadline = DateTime.now().add(timeouts.connect);
    try {
      s = await _connector.connect(setup, resumeHandle: handle).timeout(timeouts.connect);
      final session = s;
      _sub = session.messages.listen(
        (m) => _onIn(gen, m),
        onError: (Object _) {},
        onDone: () => _onClosed(gen),
      );
      final left = deadline.difference(DateTime.now());
      await ready.future.timeout(left.isNegative ? Duration.zero : left);
      if (gen != _gen) {
        _closeQuietly(session);
        return false;
      }
      _session = session;
      _flushBacklog();
      return true;
    } catch (e) {
      AppLog.add('live', 'session not ready: ${AssistantBrain.describeError(e)}');
      if (gen == _gen) {
        await _sub?.cancel();
        _sub = null;
      }
      _closeQuietly(s);
      return false;
    }
  }

  void _flushBacklog() {
    final s = _session;
    if (s == null) return;
    while (_backlog.isNotEmpty) {
      s.sendAudio(_backlog.removeFirst());
    }
  }

  /// A session nobody talks to is closed after [AiLive.idleCloseSec].
  void _armIdle() {
    _idle?.cancel();
    if (_micOn) return;
    final secs = _configs.current.live.idleCloseSec;
    _idle = Timer(Duration(seconds: secs), () {
      if (_micOn || _session == null) return;
      AppLog.add('live', 'idle ${secs}s: session closed');
      unawaited(_closeSession());
    });
  }

  Future<void> _closeSession() async {
    _gen++;
    final s = _session;
    _session = null;
    await _sub?.cancel();
    _sub = null;
    _ready = null;
    _closeQuietly(s);
  }

  /// The socket's close handshake is NEVER waited for (owner's phone,
  /// 2026-10-01 08:20: a close on a half-dead mobile link held the stop
  /// for 52 s, so the orb stayed "Listening" and the next tap looked
  /// ignored — the client's "I have to tap twice"). It is given two
  /// seconds in the background and otherwise abandoned; the session is
  /// already gone as far as the conversation is concerned.
  static void _closeQuietly(LiveSessionPort? s) {
    if (s == null) return;
    unawaited(s
        .close()
        .timeout(const Duration(seconds: 2))
        .catchError((Object _) {}));
  }

  // ------------------------------------------------------------ the mic

  /// Warms the session (within [LiveTimeouts]) and opens the microphone.
  /// False: Live cannot answer now — the cascade listens instead.
  /// Served switch: half a sentence is kept from the cascade.
  bool get fragmentGuard => _configs.current.live.fragmentGuard;

  Future<bool> start() async {
    _stopped = false;
    if (!await warm()) return false;
    if (_stopped) return false;
    // The served hangover, read per conversation so a bad value can be
    // taken back from the server without a release.
    final hang = _configs.current.live.vadHangoverMs;
    if (hang >= 200 && hang <= 3000 && hang != room.hangoverMs) {
      room = VoiceActivityDetector(hangoverMs: hang);
    }
    _idle?.cancel();
    if (_micOn) return true;
    unawaited(_player.warm());
    final opened = await _openMic();
    if (!opened) {
      AppLog.add('live', 'the microphone could not be opened');
      return false;
    }
    if (_stopped) {
      await _mic.stop();
      return false;
    }
    _micOn = true;
    _armMicWatch();
    return true;
  }

  Future<bool> _openMic() => _mic.start(_onMic,
      bufferBytes: MicStream.liveChunkBytes,
      onLost: (why) => unawaited(_restartMic('stream $why')));

  /// HER HELLO, IN HER OWN VOICE (owner, 2026-09-30: "the hello sir should
  /// not be a recorded audio, I want the same tone as the conversation").
  /// Live is asked to say [instruction]'s line the moment it can, with the
  /// microphone already open: he can talk over it, and listening never
  /// waits for it. False when it cannot be said now (no session yet, or he
  /// is already talking).
  bool greet(String instruction) {
    final s = _session;
    if (s == null || _reconnecting || _stopped || !_micOn) return false;
    if (room.speaking || turnOpen) return false;
    _turn = _LiveTurn(++_turns)..opening = true;
    s.sendText(instruction);
    _armWatch(timeouts.firstReply);
    return true;
  }

  /// The microphone is let go (typing, the camera, a cascade turn); the
  /// session stays. [resume] opens it again.
  Future<void> pause() async {
    if (!_micOn) return;
    _micOn = false;
    _micWatch?.cancel();
    await _mic.stop();
    _armIdle();
  }

  /// While the microphone is open, a frame is expected every 40 ms.
  void _armMicWatch() {
    _micWatch?.cancel();
    _lastFrameUs = _now();
    final tick = timeouts.micSilent.inMicroseconds ~/ 4;
    _micWatch = Timer.periodic(Duration(microseconds: tick < 100000 ? 100000 : tick), (_) {
      if (!_micOn || _restartingMic) return;
      final quietUs = _now() - _lastFrameUs;
      if (quietUs > timeouts.micSilent.inMicroseconds) {
        unawaited(_restartMic('no audio for ${quietUs ~/ 1000} ms'));
      }
    });
  }

  /// The open microphone stopped sending: closed and opened again. More
  /// than [_micRestartsMax] in a minute, or one that will not open: the
  /// cascade (the phone's own recogniser) listens instead.
  Future<void> _restartMic(String why) async {
    if (_restartingMic || !_micOn || _stopped) return;
    _restartingMic = true;
    final now = _now();
    _micRestarts
      ..removeWhere((at) => now - at > 60000000)
      ..add(now);
    AppLog.add('live', 'the microphone went quiet ($why): reopening it');
    var ok = false;
    try {
      try {
        await _mic.stop();
      } catch (_) {}
      if (_micRestarts.length <= _micRestartsMax && _micOn && !_stopped) {
        try {
          ok = await _openMic();
        } catch (_) {}
      }
    } finally {
      _restartingMic = false;
    }
    if (_stopped || !_micOn) {
      // Paused or stopped meanwhile: the microphone stays closed.
      if (ok) await _mic.stop();
      return;
    }
    if (!ok) {
      _fail('the microphone stopped');
      return;
    }
    _lastFrameUs = _now();
    // A sentence the silence cut off ends here, so its turn is answered.
    if (room.speaking) {
      room.reset();
      _onLocalEnd();
      _gated = true;
      _gatedAtUs = _now();
    }
  }

  static const _micRestartsMax = 3;

  /// Opens the microphone again after [pause]. False when the session is
  /// gone (the cascade listens instead).
  Future<bool> resume() => start();

  /// A tap on her: she stops now, and the rest of that answer is dropped.
  Future<void> interrupt() async {
    final t = _turn;
    final answering = t != null && !t.finished && t.answered;
    if (answering) {
      t.interrupted = true;
      t.cutOffAfter ??= _heardChars(t);
      _dropOutput = !t.serverDone;
    }
    await _player.stop();
    if (answering) {
      _emit(const LiveInterrupted());
      _finish(t);
    }
  }

  /// The conversation is over: microphone, session and timers go. The
  /// player is the engine's.
  Future<void> stop() async {
    _stopped = true;
    _watch?.cancel();
    _idle?.cancel();
    _micWatch?.cancel();
    _micRestarts.clear();
    _hearCheck?.cancel();
    _deafTurns = 0;
    _deadRevives = 0;
    _revives = 0;
    _droppedWhileOpening = false;
    final t = _turn;
    if (t != null && !t.finished) {
      t.tools?.cancel();
      if (t.answered) t.interrupted = true;
      _finish(t, quiet: true);
    }
    _turn = null;
    if (_micOn) {
      _micOn = false;
      await _mic.stop();
    }
    await _closeSession();
    _backlog.clear();
    _cancelledIds.clear();
    _dropOutput = false;
    _goingAway = false;
    _reconnecting = false;
    _reconnectedSinceTurn = false;
    _handle = null;
    _resumable = false;
    _nextIds = null;
    _stalls = 0;
  }

  void _onMic(Uint8List pcm, double? _) {
    if (!_micOn) return;
    for (final c in MicStream.split(pcm)) {
      _frame(c, MicStream.levelOf(c) ?? 0);
    }
  }

  void _send(Uint8List chunk) {
    // A heartbeat every ~8 s of microphone (diagnostics, 2026-09-30).
    if (++_sentFrames % 200 == 0) {
      AppLog.add('live', 'mic → Live: $_sentFrames frames (gated $_gated, playing ${_player.playing}, '
          'session ${_session != null}, bar ${room.threshold.toStringAsFixed(3)})');
    }
    final s = _session;
    if (s == null || _reconnecting) {
      // A revival replays his words itself ([_revive]).
      if (_reviving) return;
      _backlog.add(chunk);
      while (_backlog.length > _backlogMax) {
        _backlog.removeFirst();
      }
      return;
    }
    s.sendAudio(chunk);
  }

  /// One ≤40 ms microphone frame.
  void _frame(Uint8List c, double level) {
    final ms = MicStream.msOf(c);
    final now = _now();
    _lastFrameUs = now;
    if (!_player.playing) {
      _wasPlaying = false;
      final ev = room.feed(c, level);
      final loud = level > room.threshold;
      if (loud) _lastLoudUs = now;
      onLevel?.call(level);
      switch (ev) {
        case VadEvent.onset:
          _ungate(flush: true);
          _onOnset(now, room.takeLeadIn());
        case VadEvent.end:
          _keep(c, loud ? ms : 0);
          _onLocalEnd();
          _gated = true;
          _gatedAtUs = now;
        case VadEvent.speech:
          _keep(c, loud ? ms : 0);
        case VadEvent.quiet:
          break;
      }
      if (_gated && now - _gatedAtUs > _gateMaxUs) _ungate(flush: true);
      if (_gated) {
        _gateRoll.add(c);
        while (_gateRoll.length > _gateRollMax) {
          _gateRoll.removeFirst();
        }
        _send(Uint8List(c.length));
        return;
      }
      _send(c);
      return;
    }
    // SHE IS SPEAKING: only a confirmed interruption reaches Live.
    final detector = BargeInWatch.detector;
    if (!_wasPlaying) {
      _wasPlaying = true;
      _ungate(flush: false);
      detector.resetRun();
      _preRoll.clear();
    }
    _preRoll.add(c, ms);
    final heardUs = now - PcmPlayer.ringLatencyUs;
    final echo = _player.echo.maxBetween(heardUs - ms * 1000 - 300000, heardUs + 100000);
    final confirmed = detector.feed(
      mic: level,
      echo: echo,
      floor: room.noiseFloor,
      speechBar: room.threshold,
      ms: ms,
    );
    if (!confirmed) {
      // Silence keeps Live's clock running without her echo in it.
      _send(Uint8List(c.length));
      return;
    }
    _bargeIn(now);
  }

  /// Live hears the room again; [flush] sends the frames held back.
  void _ungate({required bool flush}) {
    if (!_gated) return;
    _gated = false;
    if (flush) {
      for (final f in _gateRoll) {
        _send(f);
      }
    }
    _gateRoll.clear();
  }

  /// The owner is talking over her: she stops here at once, and Live gets
  /// the moments that led up to it, so it hears them too and interrupts.
  void _bargeIn(int now) {
    MicStats.bargeIns++;
    MicStats.echoCoupling = BargeInWatch.detector.coupling;
    AppLog.add('voice',
        'barge-in (live, leak ${BargeInWatch.detector.coupling.toStringAsFixed(2)})');
    final t = _turn;
    if (t != null && !t.finished) {
      t.interrupted = true;
      t.cutOffAfter ??= _heardChars(t);
      _dropOutput = !t.serverDone;
    }
    unawaited(_player.stop());
    _wasPlaying = false;
    _emit(const LiveInterrupted());
    if (t != null && !t.finished) _finish(t);
    for (final f in _preRoll.drain()) {
      _send(Uint8List.fromList(f));
    }
    // The owner's new turn has begun.
    room.reset();
    _lastLoudUs = now;
    _turn = _LiveTurn(++_turns);
  }

  /// How many characters of her reply had been heard (a cut-off turn).
  int _heardChars(_LiveTurn t) {
    final start = t.playUs;
    if (start == null || t.audioMs <= 0 || t.said.isEmpty) return 0;
    final playedMs = ((_now() - start) / 1000).clamp(0, t.audioMs);
    var n = (t.said.length * playedMs / t.audioMs).floor();
    if (n >= t.said.length) return t.said.length;
    // Back to the last whole word.
    final space = t.said.lastIndexOf(' ', n);
    n = space < 0 ? 0 : space;
    return n;
  }

  void _onOnset(int now, List<List<int>> leadIn) {
    final cur = _turn;
    if (cur != null && !cur.finished && !cur.opening && cur.endUs != null && !cur.answered) {
      // He had stopped and her answer is owed; a new voice (a TV, someone
      // else) must not stop the clock on it — "Thinking…" sat forever
      // (audit 2026-10-01).
      _armWatch(timeouts.heardOnly);
    } else {
      _watch?.cancel();
    }
    final hello = _turn;
    if (hello != null && hello.opening && !hello.finished) {
      // He spoke before (or while) she greeted: his words are his own turn.
      _finish(hello, quiet: !hello.spoke && !hello.answered && !hello.ranTools, record: false);
    }
    final t = _turn;
    if (t == null || t.finished) _turn = _LiveTurn(++_turns);
    final turn = _turn!;
    turn.onsetUs ??= now;
    for (final f in leadIn) {
      _keep(f is Uint8List ? f : Uint8List.fromList(f), 0);
    }
    turn.speechMs += room.onsetMs;
    AppLog.add('live', 'turn ${turn.index}: he speaks');
  }

  /// A frame of his speech, kept for [_revive] while nothing has answered;
  /// [ms] counts only when it was loud (the VAD's hangover is not speech).
  void _keep(Uint8List c, int ms) {
    final t = _turn;
    if (t == null || t.finished || t.answered) return;
    t.speechMs += ms;
    if (t.utterance.length < _LiveTurn.utteranceMax) t.utterance.add(c);
  }

  void _onLocalEnd() {
    final t = _turn;
    if (t == null || t.finished || t.answered) return;
    t.endUs = _lastLoudUs;
    AppLog.add('live', 'turn ${t.index}: he stopped');
    if (t.opening && t.speechMs >= _deafSpeechMs && !t.spoke) {
      // He talked before the hello was said: the hello is dropped and
      // his words are answered (owner's phone, 2026-10-01).
      AppLog.add('live', 'turn ${t.index}: he spoke over the hello — answer him');
      _session?.sendText('[SYSTEM] Skip the greeting: answer what I just said.');
    }
    _emit(const LiveThinking());
    _armWatch(timeouts.firstReply);
    _armHearingCheck(t, timeouts.hearing);
  }

  /// THE SERVER MUST HAVE HEARD HIM. Measured 2026-09-30 on
  /// gemini-3.8-live: real speech brings its voiceActivity about a second
  /// after he starts; 48 s of silence, a cough or 2 s of noise bring
  /// nothing at all. So: [_deafSpeechMs] of real speech and not one frame
  /// since he began — the session is not hearing, and a fresh one is
  /// opened to hear his words again ([_revive]).
  void _armHearingCheck(_LiveTurn t, Duration after) {
    _hearCheck?.cancel();
    _hearCheck = Timer(after, () {
      if (t.finished || t.answered || !identical(_turn, t) || _stopped || _reviving) return;
      if (t.speechMs < _deafSpeechMs || _lastInUs > (t.onsetUs ?? 0)) return;
      if (t.revived) {
        // A fresh session got his words and made no sound either: it was
        // not speech (a clatter, a horn) — unless that keeps happening.
        _deadRevives++;
        AppLog.add('live', 'turn ${t.index}: the fresh session heard nothing either ($_deadRevives)');
        if (_deadRevives >= 2) {
          _fail('Live stopped hearing', line: missedLine);
        } else {
          _finish(t);
        }
        return;
      }
      AppLog.add('live', 'turn ${t.index}: ${t.speechMs} ms of speech, not a sound back');
      unawaited(_revive(t));
    });
  }

  /// A FRESH SESSION HEARS HIM AGAIN: the old one is let go, a new one is
  /// opened (the server's context: the conversation so far, never the old
  /// session's resumption handle), and his words go to it from this phone's
  /// copy, then a moment of silence to end his turn. He never repeats
  /// himself. Could not open, or too many: the cascade, which says so.
  Future<void> _revive(_LiveTurn t) async {
    if (_reviving || _reconnecting || _stopped || _setup == null) return;
    if (++_revives > _revivesMax) {
      _fail('Live keeps losing him', line: missedLine);
      return;
    }
    _reviving = true;
    _watch?.cancel();
    AppLog.add('live', 'turn ${t.index}: a fresh session hears him again');
    _gen++;
    final old = _session;
    final oldSub = _sub;
    _session = null;
    _sub = null;
    _ready = null;
    _handle = null;
    _resumable = false;
    unawaited(() async {
      await oldSub?.cancel();
      try {
        await old?.close();
      } catch (_) {}
    }());
    _backlog.clear();
    var ok = false;
    try {
      ok = await (_connecting ??= _connectFresh().whenComplete(() => _connecting = null));
    } catch (_) {}
    _reviving = false;
    if (_stopped) return;
    final s = _session;
    if (!ok || s == null) {
      _fail('Live stopped hearing', line: missedLine);
      return;
    }
    if (t.finished || t.answered) return;
    for (final f in t.utterance) {
      s.sendAudio(f);
    }
    for (var i = 0; i < 20; i++) {
      s.sendAudio(Uint8List(MicStream.liveChunkBytes)); // 800 ms of silence
    }
    t
      ..revived = true
      ..onsetUs = _now();
    _armWatch(timeouts.firstReply);
    // Before the watch: the fresh session's own sound (or none) decides.
    _armHearingCheck(t, timeouts.hearing * 2);
  }

  static const _revivesMax = 3;

  /// Real progress: the server heard him, or answered.
  void _heardBack() {
    _deafTurns = 0;
    _deadRevives = 0;
    _hearCheck?.cancel();
  }

  // ------------------------------------------------------------ the server

  void _onIn(int gen, LiveIn m) {
    if (gen != _gen) return;
    _lastInUs = _now();
    switch (m) {
      case LiveInPing():
        break;
      case LiveInReady():
        final r = _ready;
        if (r != null && !r.isCompleted) r.complete();
      case LiveInContent():
        _onContent(m);
      case LiveInToolCall(:final calls):
        unawaited(_onToolCall(calls));
      case LiveInToolCancel(:final ids):
        _cancelledIds.addAll(ids);
        AppLog.add('live', 'tool call cancelled by the model');
      case LiveInGoAway(:final timeLeft):
        AppLog.add('live', 'the server will close the session (${timeLeft ?? '?'} left)');
        _goingAway = true;
        if (!turnOpen) unawaited(_resume());
      case LiveInResumption(:final handle, :final resumable):
        if (resumable && handle != null && handle.isNotEmpty) {
          _handle = handle;
          _resumable = true;
        }
    }
  }

  _LiveTurn _current() {
    final t = _turn;
    if (t != null && !t.finished) return t;
    return _turn = _LiveTurn(++_turns);
  }

  void _onContent(LiveInContent c) {
    if (c.interrupted) _onServerInterrupted();
    final heard = c.heard;
    if (heard != null && heard.isNotEmpty) {
      final t = _current();
      if (t.heard.isEmpty) AppLog.add('live', 'turn ${t.index}: Live hears him');
      t.heard += heard;
      _heardBack();
      _emit(LiveHeard(t.heard.trim()));
      // No end of speech from this phone to wait for (a microphone too
      // quiet for its VAD, the S24 Ultra's is): his words start the watch
      // themselves, so an unanswered question never waits for ever.
      if (t.endUs == null && !t.answered) {
        _armWatch(timeouts.heardOnly);
      }
    }
    for (final (pcm, rate) in c.audio) {
      _onAudio(pcm, rate);
    }
    final said = c.said;
    if (said != null && said.isNotEmpty && !_dropOutput) {
      final last = _turn;
      // Words that trail a turn already over belong to it.
      final t = last != null && last.finished && last.serverDone && !last.interrupted
          ? last
          : _current();
      t
        ..said += said
        ..answered = true;
      _watch?.cancel();
      _heardBack();
      _emit(LiveSaid(t.said.trim()));
    }
    if (c.turnComplete) _onTurnComplete();
  }

  void _onAudio(Uint8List pcm, int rate) {
    if (_dropOutput || pcm.length < 2) return;
    final t = _current();
    _watch?.cancel();
    _stalls = 0;
    _heardBack();
    final first = t.firstAudioUs == null;
    if (first) {
      t.firstAudioUs = _now();
      t.endUs ??= _lastLoudUs;
    }
    t
      ..answered = true
      ..spoke = true
      ..audioMs += pcm.length * 1000 ~/ (rate * 2);
    if (onTurnAudio != null && t.replyBytes < _LiveTurn.replyMaxBytes) {
      t.replyRate = rate;
      t.reply.add(pcm);
      t.replyBytes += pcm.length;
    }
    unawaited(_player.play(pcm, sampleRate: rate).catchError((Object _) {}));
    if (first) {
      t.playUs = _player.replyStartUs;
      _emit(const LiveSpeaking());
    }
  }

  void _onServerInterrupted() {
    _dropOutput = false;
    final t = _turn;
    if (t == null || t.finished || !t.answered) return;
    // Live heard the owner over her: never keep talking over them.
    t.interrupted = true;
    t.cutOffAfter ??= _heardChars(t);
    unawaited(_player.stop());
    _emit(const LiveInterrupted());
    _finish(t);
  }

  void _onTurnComplete() {
    _dropOutput = false;
    final t = _turn;
    AppLog.add('live', 'turn ${t?.index}: complete (spoke ${t?.spoke}, tools ${t?.ranTools}, finished ${t?.finished})');
    if (t == null || t.finished) return;
    t.serverDone = true;
    if (!t.spoke && t.ranTools && !t.nudged) {
      // A tool answered and she said nothing (gemini-3.8-live did exactly
      // that with a NON_BLOCKING tool): asked once to say how it went.
      t
        ..nudged = true
        ..serverDone = false;
      AppLog.add('live', 'silent after a tool: asking her to say the result');
      _session?.sendText('[SYSTEM] Tell me the result of that now, in one short sentence.');
      _armWatch(timeouts.afterTool);
      return;
    }
    if (!t.spoke && t.ranTools) {
      final line = _toolLine(t);
      t.said = line;
      _finish(t, quiet: true);
      _emit(LiveFallback(reason: 'silent after a tool', line: line, keepLive: true));
      return;
    }
    if (!t.spoke && _meaningful(t.heard)) {
      // Heard, not answered, nothing done: the cascade answers it.
      _finish(t, quiet: true, record: false);
      _emit(LiveFallback(reason: 'no answer', words: t.heard.trim(), keepLive: true));
      return;
    }
    _finishWhenHeard(t);
  }

  /// The turn is DONE once its last sound has been heard.
  void _finishWhenHeard(_LiveTurn t) {
    if (!_player.playing) return _finish(t);
    _player.drained().then((_) {
      if (!t.finished) _finish(t);
    });
  }

  static bool _meaningful(String heard) =>
      RegExp(r'\p{L}.*\p{L}', unicode: true).hasMatch(heard);

  static String _toolLine(_LiveTurn t) {
    final log = t.tools?.toolLog ?? const [];
    final ok = log.isNotEmpty && log.every((e) => e['ok'] == true);
    return ok ? 'Done.' : "Sorry, I couldn't finish that.";
  }

  /// No word from her in [after]: the turn is handed on.
  void _armWatch(Duration after) {
    _watch?.cancel();
    final t = _turn;
    if (t == null) return;
    _watch = Timer(after, () {
      if (t.finished || t.spoke || !identical(_turn, t) || _reviving) return;
      if (t.ranTools) {
        AppLog.add('live', 'no answer after the tool: said for her');
        final line = _toolLine(t);
        t.said = line;
        _finish(t, quiet: true);
        _emit(LiveFallback(reason: 'stalled after a tool', line: line, keepLive: true));
        return;
      }
      if (_meaningful(t.heard)) {
        _stalls++;
        AppLog.add('live', 'no answer in ${after.inSeconds}s (stall $_stalls): the cascade answers');
        if (_stalls >= 2) {
          // Twice: the cascade answers these words and listens from here —
          // with the Live microphone CLOSED ([_fail] stops it), or the
          // phone's recogniser would get silence (one capture at a time).
          _fail('no answer twice');
          return;
        }
        _finish(t, quiet: true, record: false);
        _emit(LiveFallback(reason: 'stalled', words: t.heard.trim(), keepLive: true));
        return;
      }
      if (!t.answered && !t.revived && t.speechMs >= _deafSpeechMs &&
          (++_deafTurns >= 2 || t.speechMs >= _deafSentenceMs)) {
        // Real speech, a server that answers with keep-alives only, not a
        // word heard. A short burst may be a clatter: let go once, revive
        // the second time. A whole sentence is revived AT ONCE (2026-10-01:
        // waiting for a second one dropped the first thing the client
        // said, silently). Nothing is lost: the utterance is replayed.
        AppLog.add('live', 'turn ${t.index}: nothing heard of ${t.speechMs} ms');
        _deafTurns = 0;
        unawaited(_revive(t));
        return;
      }
      // A cough, a door: nothing to answer.
      _finish(t);
    });
  }

  // ------------------------------------------------------------ tools

  /// This turn's server ids: the ones opened ahead, else a new turn now.
  Future<(String?, String?)> _takeIds() async {
    final next = _nextIds;
    _nextIds = null;
    if (next != null) {
      try {
        final got = await next.timeout(timeouts.turnIds);
        if (got.$1 != null && got.$2 != null) return got;
      } catch (e) {
        AppLog.add('live', 'turn ids not ready: ${AssistantBrain.describeError(e)}');
      }
    }
    final ctx = await _server
        .openLiveTurn(sessionId: _sid, device: await _device(), timeout: timeouts.turnIds)
        .catchError((Object _) => null);
    if (ctx?.sessionId != null) _sid = ctx!.sessionId;
    return (ctx?.sessionId ?? _sid, ctx?.turnId);
  }

  /// The next turn's ids, opened while nobody is waiting on them.
  void _openNextTurn() {
    if (_nextIds != null || _session == null) return;
    _nextIds = () async {
      final ctx = await _server
          .openLiveTurn(sessionId: _sid, device: await _device(), timeout: timeouts.turnIds)
          .catchError((Object _) => null);
      return (ctx?.sessionId ?? _sid, ctx?.turnId);
    }();
  }

  Future<(String?, String?)> _idsOf(_LiveTurn t) => t.ids ??= _takeIds();

  BrainToolTurn _toolsOf(_LiveTurn t) => t.tools ??= _brain.openToolTurn(
        ids: () => _idsOf(t),
        serverTools: _serverTools,
        onEvent: (e) => _emit(LiveBrain(e)),
        recontext: (words) async {
          final ctx = await _server.context(
            text: words,
            mode: 'live',
            sessionId: _sid,
            device: await _device(),
            timeout: timeouts.context,
          );
          if (ctx?.sessionId != null) _sid = ctx!.sessionId;
          return ctx;
        },
      );

  Future<void> _onToolCall(List<FunctionCall> calls) async {
    final session = _session;
    if (session == null || calls.isEmpty) return;
    AppLog.add('live', 'turn ${_turn?.index}: tools ${calls.map((c) => c.name).join(', ')}');
    _watch?.cancel();
    _heardBack();
    final t = _current()..answered = true;
    t.endUs ??= _lastLoudUs;
    final tools = _toolsOf(t);
    final started = _now();
    final responses = <FunctionResponse>[];
    for (final c in calls) {
      final id = c.id;
      if (id != null && _cancelledIds.contains(id)) continue;
      // EVERY CALL IS ANSWERED: the tools are BLOCKING, so a call left
      // unanswered (a tool that threw, or never came back) left the model
      // waiting for good — and deaf to him meanwhile.
      Map<String, Object?> answer;
      try {
        answer = await tools
            .run(c.name, Map<String, Object?>.of(c.args), userText: t.heard.trim())
            .timeout(timeouts.tool);
      } catch (e) {
        AppLog.add('live', 'tool ${c.name} failed: ${e.runtimeType}');
        answer = {
          'ok': false,
          'error': e is TimeoutException ? 'It took too long.' : 'It failed.',
        };
      }
      if (id != null && _cancelledIds.contains(id)) continue;
      responses.add(FunctionResponse(c.name, answer, id: id));
    }
    t.toolMs += (_now() - started) ~/ 1000;
    if (!identical(_session, session) || _stopped) {
      AppLog.add('live', 'tool answers dropped: the session changed meanwhile');
      return;
    }
    if (responses.isNotEmpty) session.sendToolResponses(responses);
    if (!t.finished && !t.spoke) _armWatch(timeouts.afterTool);
  }

  // ------------------------------------------------------------ turn over

  /// The turn is over. [quiet]: no LiveTurnDone (a LiveFallback ends it
  /// instead); [record]: false when the cascade will answer and record the
  /// same words itself.
  void _finish(_LiveTurn t, {bool quiet = false, bool record = true}) {
    if (t.finished) return;
    t.finished = true;
    if (identical(_turn, t)) _watch?.cancel();
    final latency = t.latency();
    if (latency.containsKey('endToFirstAudio')) {
      AppLog.add(
          'voice',
          'voice.latency live endToFirstAudio=${latency['endToFirstAudio']}ms '
              'endToPlay=${latency['endToPlay'] ?? '?'}ms tool=${latency['tool'] ?? 0}ms'
              '${t.interrupted ? ' (cut off)' : ''}');
    }
    t.tools?.finish(t.heard, t.said);
    _reconnectedSinceTurn = false;
    if (!quiet) {
      _emit(LiveTurnDone(
        user: t.heard.trim(),
        reply: t.said.trim(),
        interrupted: t.interrupted,
        latency: latency,
        opening: t.opening,
      ));
    }
    // Her hello is not a turn of the conversation's record.
    if (record && !t.opening) unawaited(_record(t));
    if (_goingAway && !_stopped) unawaited(_resume());
  }

  Future<void> _record(_LiveTurn t) async {
    final user = t.heard.trim();
    final reply = t.said.trim();
    if (user.isEmpty && reply.isEmpty && !t.ranTools) return;
    try {
      final (sid0, tid0) = await _idsOf(t);
      _openNextTurn();
      final sid = t.tools?.sessionId ?? sid0;
      final tid = t.tools?.turnId ?? tid0;
      if (sid == null || tid == null) return;
      final hear = onTurnAudio;
      if (hear != null && (t.utterance.isNotEmpty || t.reply.isNotEmpty)) {
        hear(LiveTurnAudio(
          turnId: tid,
          startedAt: t.startedAt,
          user: List.unmodifiable(t.utterance),
          agent: List.unmodifiable(t.reply),
          agentRate: t.replyRate,
        ));
      }
      final receipt = await _server.recordLiveTurn(
        sessionId: sid,
        turnId: tid,
        user: user,
        reply: reply,
        tools: t.tools?.toolLog ?? const [],
        latency: t.latency(),
        cutOffAfter: t.interrupted ? (t.cutOffAfter ?? 0) : null,
        timeout: timeouts.record,
      );
      if (receipt != null && receipt.corrected && receipt.reply.trim() != reply) {
        AppLog.add('live', 'the claim check corrected her reply');
        _emit(LiveCorrected(receipt.reply.trim()));
      }
    } catch (e) {
      AppLog.add('live', 'turn not recorded: ${e.runtimeType}');
    }
  }

  // ------------------------------------------------------------ drops

  /// GoAway: a new connection, resuming this session where the server can.
  Future<void> _resume() async {
    final setup = _setup;
    if (setup == null || _reconnecting || _reviving || _connecting != null || _stopped) return;
    _goingAway = false;
    _reconnecting = true;
    _droppedWhileOpening = false;
    final handle = _resumable ? _handle : null;
    final old = _session;
    final oldSub = _sub;
    _session = null;
    var ok = await _open(setup, handle: handle);
    _reconnecting = false;
    if (ok && _droppedWhileOpening) ok = _dropNew();
    await oldSub?.cancel();
    try {
      await old?.close();
    } catch (_) {}
    AppLog.add('live', ok ? 'session renewed${handle != null ? ' (resumed)' : ''}' : 'renewal failed');
    if (!ok) _fail('could not renew the session');
    _flushBacklog();
  }

  /// The connection closed on its own: once, it is opened again.
  void _onClosed(int gen) {
    if (gen != _gen) return;
    final r = _ready;
    if (r != null && !r.isCompleted) {
      // Closed before setupComplete: the setup was refused.
      r.completeError(StateError('closed before setup'));
      return;
    }
    if (_reconnecting) {
      // The session being opened closed at once: its opener sees this.
      _droppedWhileOpening = true;
      return;
    }
    if (_stopped) {
      // Warm, but nobody is talking yet: the next start connects afresh.
      _session = null;
      _sub = null;
      return;
    }
    final t = _turn;
    if (_reconnectedSinceTurn || _setup == null) {
      _fail('the session dropped');
      return;
    }
    AppLog.add('live', 'the session dropped: reconnecting once');
    // A question caught in the drop, unanswered: the cascade answers it.
    if (t != null && !t.finished && !t.answered && _meaningful(t.heard)) {
      _finish(t, quiet: true, record: false);
      _emit(LiveFallback(reason: 'dropped', words: t.heard.trim(), keepLive: true));
    } else if (t != null && !t.finished && t.answered) {
      t.interrupted = !t.serverDone;
      _finishWhenHeard(t);
    }
    // After the turn is finished (which clears it), or a second drop in a
    // row would reconnect again instead of handing over.
    _reconnectedSinceTurn = true;
    _session = null;
    unawaited(() async {
      _reconnecting = true;
      _droppedWhileOpening = false;
      var ok = await _open(_setup!, handle: _resumable ? _handle : null);
      _reconnecting = false;
      if (ok && _droppedWhileOpening) ok = _dropNew();
      if (!ok) {
        _fail('the session dropped');
      } else {
        _flushBacklog();
      }
    }());
  }

  /// The session just opened closed while it was being opened: it is let
  /// go, as a failed open.
  bool _dropNew() {
    AppLog.add('live', 'the new session closed at once');
    _gen++;
    final s = _session;
    _session = null;
    unawaited(_sub?.cancel());
    _sub = null;
    unawaited(s?.close().catchError((Object _) {}));
    return false;
  }

  /// Live is done for this conversation: the cascade carries on. [line]:
  /// said when there are no words of his for the cascade to answer.
  void _fail(String reason, {String? line}) {
    if (_stopped) return;
    AppLog.add('live', '$reason: the cascade takes over');
    final t = _turn;
    String? words;
    if (t != null && !t.finished) {
      if (!t.answered && !t.ranTools && _meaningful(t.heard)) words = t.heard.trim();
      // He spoke, nothing was transcribed and now the session is gone:
      // the words are lost, so he is told rather than left in silence.
      if (words == null && line == null && !t.answered && t.speechMs >= _deafSpeechMs) {
        line = missedLine;
      }
      if (t.answered) t.interrupted = true;
      _finish(t, quiet: true, record: words == null);
    }
    _emit(LiveFallback(reason: reason, words: words, line: words == null ? line : null));
    unawaited(stop());
  }

  /// Test seam: the session's messages, as if from the server.
  void debugIn(LiveIn m) => _onIn(_gen, m);

  /// Test seam: one microphone frame at [level].
  void debugFrame(Uint8List c, double level) => _frame(c, level);
}
