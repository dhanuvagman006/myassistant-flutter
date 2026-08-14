import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/network/assistant_api.dart';
import '../../../core/log.dart';
import '../../../models/user_document.dart';
import '../../../services/api_service.dart';
import '../../../services/call_service.dart';
import '../../../services/phone_state_guard.dart';
import '../../../services/live_service.dart';
import '../../../services/voice_service.dart';
import 'assistant_state.dart';

/// The assistant experience's single source of truth (ChangeNotifier — the
/// state-management style used across this codebase; the UI observes it
/// with AnimatedBuilder/ListenableBuilder).
///
/// Owns: session lifecycle, mic capture, backend event stream, the phase
/// state machine, transcript, tool/search/contact/call cards, confirmation
/// flow, cancellation, and speaking replies out loud.
class AssistantEngine extends ChangeNotifier {
  AssistantEngine._();
  static final AssistantEngine instance = AssistantEngine._();

  final _api = AssistantApi.instance;
  final _voice = VoiceService.instance;

  // ---------------- observable state ----------------

  AssistantPhase phase = AssistantPhase.idle;
  bool connected = false;
  String? errorMessage;

  /// Live mic loudness 0..1 while listening — drives the hero animation.
  double micLevel = 0;

  /// Interim transcript while the user is still speaking (device-side).
  String partial = '';

  final List<TranscriptEntry> transcript = [];
  final List<ToolActivity> activities = [];

  String? searchQuery;
  List<SearchResult> searchResults = const [];

  /// Saved documents recalled by this turn ("pull up patient Ramesh's
  /// file") — shown as cards while the reply is spoken.
  List<UserDocument> documentCards = const [];

  ContactMatch? foundContact;
  List<ContactMatch> ambiguousContacts = const [];
  PendingConfirmation? pendingConfirmation;
  CallStatusInfo? callStatus;
  String? readyAudioUrl; // cloned-voice preview from audio_ready
  bool usedClonedVoice = false;

  bool get micBusy => phase == AssistantPhase.listening;

  /// Set by the assistant screen: opens the human-avatar video call when the
  /// user asks for it by voice ("open video mode"). Lives here as a hook
  /// because navigation needs a BuildContext, which the engine has no
  /// business holding.
  void Function()? onOpenVideoMode;

  /// True while the local TTS is reading a reply — the avatar's mouth and
  /// the "Speaking…" pill follow THIS, because the backend has already
  /// moved to `completed` by the time audio actually plays on-device.
  bool _ttsActive = false;

  Timer? _stuckWatchdog;

  // ---------------- BARGE-IN (talk over Hari to interrupt) ----------------
  // The mic-monitor lives in VoiceService; the engine turns it on while any
  // reply is being spoken. If the user talks over Hari, we stop the reply
  // and immediately capture what they're saying as the next turn — no tap.
  bool _bargeMonitorOn = false;
  bool _bargedIn = false;

  void _beginBargeWatch() {
    if (_bargeMonitorOn) return;
    _bargedIn = false;
    _bargeMonitorOn = true;
    _voice.startBargeInMonitor(() {
      _bargedIn = true;
      _voice.stopSpeaking(); // cut the current sentence mid-word
      _speakQueue.clear(); // drop the rest of the reply
    });
  }

  /// Stops the barge-in monitor. Returns true if the user interrupted and a
  /// fresh capture was therefore started — the caller must NOT then also
  /// re-open the mic via the continuous-conversation loop.
  Future<bool> _endBargeWatch() async {
    if (!_bargeMonitorOn) return false;
    _bargeMonitorOn = false;
    await _voice.stopBargeInMonitor(); // frees the mic for a new capture
    if (_bargedIn) {
      _bargedIn = false;
      // The user interrupted — start listening for their new question at
      // once (fire-and-forget so we don't nest inside the speak finally).
      Future.microtask(pressMic);
      return true;
    }
    return false;
  }

  /// Speaks [text] with the phase machine wrapped around the audio:
  /// speaking while the voice plays, completed when it ends.
  Future<void> _speakReply(String text) async {
    _ttsActive = true;
    _setPhase(AssistantPhase.speaking, silent: true);
    // The girl's lips ride the word pulses coming from the TTS engine.
    void feed() {
      micLevel = _voice.ttsLevel.value;
      notifyListeners();
    }

    _voice.ttsLevel.addListener(feed);
    _beginBargeWatch();
    try {
      await _voice.speak(text); // awaits completion (awaitSpeakCompletion)
    } finally {
      _voice.ttsLevel.removeListener(feed);
      micLevel = 0;
      _ttsActive = false;
      if (phase == AssistantPhase.speaking) {
        _setPhase(AssistantPhase.completed, silent: true);
      }
      notifyListeners();
      // If the user barged in, a capture is already starting — don't also
      // re-open the mic from the continuous loop.
      final resumed = await _endBargeWatch();
      if (!resumed) _maybeContinueListening();
    }
  }

  // ---------------- STREAMED SENTENCES (latency path) ----------------
  // The backend now streams conversation replies sentence-by-sentence;
  // we speak each the moment it arrives — the user hears sentence 1
  // while sentence 2 is still being generated server-side.

  final List<String> _speakQueue = [];
  bool _draining = false;
  TranscriptEntry? _liveEntry; // the assistant bubble being built live

  void _enqueueSentence(String sentence) {
    if (_liveEntry == null) {
      _liveEntry = TranscriptEntry(TranscriptRole.assistant, sentence);
      transcript.add(_liveEntry!);
    } else {
      final merged = '${_liveEntry!.text} $sentence';
      transcript[transcript.length - 1] =
          TranscriptEntry(TranscriptRole.assistant, merged);
      _liveEntry = transcript.last;
    }
    notifyListeners();
    _speakQueue.add(sentence);
    _drainSpeech();
  }

  Future<void> _drainSpeech() async {
    if (_draining) return;
    _draining = true;
    _ttsActive = true;
    _setPhase(AssistantPhase.speaking, silent: true);
    void feed() {
      micLevel = _voice.ttsLevel.value;
      notifyListeners();
    }

    _voice.ttsLevel.addListener(feed);
    _beginBargeWatch();
    String? pendingPath;
    try {
      // PIPELINE: keep one sentence's synthesis running AHEAD of playback so
      // there's no synthesis gap between spoken sentences. We pre-synthesize
      // the first, then while each sentence plays we synthesize the next.
      AppLog.add('latency', 'first sentence ${_turnClock?.elapsedMilliseconds}ms');
      String? nextPath = _speakQueue.isNotEmpty
          ? await _voice.prefetchSpeech(_speakQueue.first)
          : null;
      var firstAudio = true;
      while (_speakQueue.isNotEmpty) {
        final s = _speakQueue.removeAt(0);
        final path = nextPath;
        if (firstAudio) {
          firstAudio = false;
          AppLog.add(
              'latency', 'first audio ready ${_turnClock?.elapsedMilliseconds}ms');
        }
        // Start synthesizing the NEXT sentence while THIS one plays.
        final Future<String?> upcoming = _speakQueue.isNotEmpty
            ? _voice.prefetchSpeech(_speakQueue.first)
            : Future<String?>.value(null);
        await _voice.speakPrefetched(s, path);
        nextPath = await upcoming;
      }
      // A barge-in / cancel can drain the queue mid-flight; drop any
      // prefetched-but-unplayed audio so temp files don't accumulate.
      pendingPath = nextPath;
    } finally {
      if (pendingPath != null) _voice.discardPrefetched(pendingPath);
      _voice.ttsLevel.removeListener(feed);
      micLevel = 0;
      _draining = false;
      _ttsActive = false;
      if (phase == AssistantPhase.speaking) {
        _setPhase(AssistantPhase.completed, silent: true);
      }
      notifyListeners();
      // If the user barged in, a capture is already starting — don't also
      // re-open the mic from the continuous loop.
      final resumed = await _endBargeWatch();
      if (!resumed) _maybeContinueListening();
    }
  }

  /// If the backend stream dies mid-turn the app used to sit on
  /// "Transcribing…" forever. Any busy phase that lasts 35 s without a
  /// new event now surfaces a retryable error instead.
  void _armWatchdog() {
    _stuckWatchdog?.cancel();
    if (!phase.busy || phase == AssistantPhase.listening || _ttsActive) return;
    _stuckWatchdog = Timer(const Duration(seconds: 35), () {
      if (phase.busy && phase != AssistantPhase.listening && !_ttsActive) {
        _setLocalError("That took too long. Please try again.");
      }
    });
  }

  // ---------------- lifecycle ----------------

  bool _started = false;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    // The saved server override must win the race against this first
    // connect, or one launch in two would hit the wrong host.
    await ApiService.loadServerOverride();
    // INCOMING-CALL GUARD: the instant the phone rings or a call connects,
    // Hari goes silent and releases the mic — never talk over a call. This
    // was previously only wired in the (now-removed) controller, so the
    // mute didn't actually work on the live path until now.
    PhoneStateGuard.instance.start(
      onCallActive: _onPhoneCallActive,
      onCallEnded: _onPhoneCallEnded,
    );
    await _connect();
  }

  /// A call started/rang — cut all audio and the mic immediately.
  Future<void> _onPhoneCallActive() async {
    if (liveActive) await stopLive(); // a real call always wins the audio
    _bargedIn = false;
    // A real phone call always wins: close the continuous loop so the mic
    // can never reopen itself mid-call.
    _conversationEnded = true;
    if (_bargeMonitorOn) {
      _bargeMonitorOn = false;
      try {
        await _voice.stopBargeInMonitor();
      } catch (_) {}
    }
    _speakQueue.clear();
    try {
      await _voice.stopSpeaking();
    } catch (_) {}
    try {
      await _voice.cancelCapture();
    } catch (_) {}
    _ttsActive = false;
    if (phase != AssistantPhase.idle) _setPhase(AssistantPhase.idle, silent: true);
    notifyListeners();
  }

  void _onPhoneCallEnded() {
    // Nothing to resume — the live app waits for the user to tap the mic.
    if (phase != AssistantPhase.idle && !phase.busy) {
      _setPhase(AssistantPhase.idle, silent: true);
    }
  }

  Future<void> _connect() async {
    try {
      await _api.connect(
        onEvent: _onEvent,
        onDisconnect: () {
          connected = false;
          notifyListeners();
        },
      );
      connected = true;
      errorMessage = null;
    } catch (e) {
      connected = false;
      errorMessage = 'Could not reach the assistant service.';
      AppLog.add('engine', 'connect failed: $e');
      // Retry quietly — the screen shows the offline banner meanwhile.
      Future.delayed(const Duration(seconds: 4), () {
        if (_started && !connected) _connect();
      });
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _stuckWatchdog?.cancel();
    _api.close();
    super.dispose();
  }

  // ---------------- user input ----------------

  /// Mic button: record until silence, then hand the clip to the backend
  /// (STT + the whole turn run server-side; results stream back).
  ///
  /// [auto] is true when the continuous-conversation loop re-opened the mic
  /// by itself; a manual press always (re)starts a conversation.
  Future<void> pressMic({bool auto = false}) async {
    // THE ORB IS LIVE MODE. One tap opens a real speech-to-speech
    // conversation; tapping again hangs up. The classic record→STT→TTS
    // loop only runs as a SILENT fallback when live isn't available on
    // this key/server — the user never sees an error for it.
    if (liveActive) {
      await stopLive();
      return;
    }
    if (!auto && !_liveUnavailable) {
      final ok = await _startLive();
      if (ok) return;
      // Live couldn't start — fall through to the classic path, silently.
    }
    if (!auto) {
      // An explicit tap means "I want to talk" — revive a conversation that
      // had been closed by a goodbye or by silence.
      _conversationEnded = false;
      _silentTurns = 0;
      _failedTurns = 0;
    }
    if (phase == AssistantPhase.listening) {
      // Tap while listening = cancel this capture (both the recorder
      // and the device-recognizer fallback honour this).
      // An explicit cancel also closes the conversation loop, so the mic
      // doesn't immediately reopen against the user's wishes.
      _conversationEnded = true;
      _voice.stopSpeaking();
      _speakQueue.clear();
      await _voice.cancelCapture();
      return;
    }
    if (phase.busy && phase != AssistantPhase.completed) return;
    // Safety: never let a still-running barge monitor hold the mic while we
    // try to record a fresh clip.
    if (_bargeMonitorOn) {
      _bargeMonitorOn = false;
      _bargedIn = false;
      await _voice.stopBargeInMonitor();
    }
    await _voice.stopSpeaking();

    if (!await _voice.canRecord()) {
      _setLocalError('Microphone permission is needed. Enable it in Settings.');
      return;
    }

    _resetTurn();
    _setPhase(AssistantPhase.listening);
    HapticFeedback.mediumImpact();

    // LATENCY TRACING: every stage of the turn is timed and written to the
    // in-app log (Diagnostics screen), so a slow turn can be attributed to
    // capture, upload or the server instead of guessed at.
    _turnClock = Stopwatch()..start();
    final path = await _voice.recordUntilSilence(
      // The self-reopened mic (continuous loop) is strict: it only uploads
      // sustained, latched speech and gives up on an idle room after 2.5s
      // instead of 4 — so it never transcribes background noise ("00:00")
      // and never apologizes into silence.
      requireLatch: auto,
      noSpeechTimeoutMs: auto ? 2500 : 4000,
      onLevel: (l) {
        micLevel = l;
        notifyListeners();
      },
    );
    micLevel = 0;
    AppLog.add('latency', 'capture ${_turnClock!.elapsedMilliseconds}ms');

    if (path == null) {
      if (_voice.lastRecordingCancelled) {
        _setPhase(AssistantPhase.idle);
        return;
      }
      // The recorder captured nothing above the noise floor. The clip is
      // now uploaded whenever ANY sound was present, so reaching here means
      // the room really was silent — go straight back to idle instead of
      // starting a second, invisible listening session (that fallback was
      // what left the UI stuck on "Listening…" for seconds and then claimed
      // nothing was heard).
      if (!_voice.lastRecordingHadSound) {
        // Nothing was said. In a continuous conversation this is normal
        // (a pause after Hari's reply), so listen again — up to the
        // two-strike limit enforced in _maybeContinueListening.
        _silentTurns++;
        _setPhase(AssistantPhase.idle);
        _maybeContinueListening();
        return;
      }
      // Recorded audio exists but couldn't be saved — try the on-device
      // recognizer once, hard-bounded so the mic can never hang.
      _setPhase(AssistantPhase.transcribing);
      final heard = await _voice
          .captureQuestion(
            onPartial: (p) {
              partial = p;
              notifyListeners();
            },
            onLevel: (l) {
              micLevel = l;
              notifyListeners();
            },
          )
          .timeout(const Duration(seconds: 6), onTimeout: () => '');
      micLevel = 0;
      partial = '';
      if (heard.trim().isEmpty) {
        _setPhase(AssistantPhase.idle);
        return;
      }
      // (No local transcript add — the server echoes user_transcript.)
      _setPhase(AssistantPhase.thinking);
      try {
        await _api.sendText(heard.trim());
      } catch (_) {
        _setLocalError("I couldn't send that. Check your connection.");
      }
      return;
    }
    _setPhase(AssistantPhase.transcribing);
    _silentTurns = 0; // real speech captured — reset the walked-away counter
    try {
      final bytes = await File(path).readAsBytes();
      // Keep the clip: if the server's speech service hits a transient blip
      // (503 "high demand", timeout), we resend this exact audio once
      // instead of making the user repeat themselves.
      _lastAudioBytes = bytes;
      _audioResent = false;
      await _api.sendAudio(bytes);
      AppLog.add(
          'latency', 'uploaded ${_turnClock?.elapsedMilliseconds}ms '
              '(${(bytes.length / 1024).round()}kB)');
      // Backend takes over: transcribing → thinking → … via SSE.
    } catch (_) {
      _setLocalError("I couldn't upload your audio. Check your connection.");
    }
  }

  /// Times the current turn end-to-end (see the 'latency' entries in the
  /// Diagnostics log): capture → upload → first sentence → first audio.
  Stopwatch? _turnClock;

  // ---------------- LIVE MODE (speech-to-speech) ----------------
  // Real live conversation over the backend /live proxy: the mic streams
  // continuously, Hari's VOICE streams back, Google detects end-of-speech
  // and barge-in server-side. No STT step, no client VAD. The classic
  // record→transcribe loop stays untouched as the fallback.

  final _liveSvc = LiveService.instance;
  bool get liveActive => _liveSvc.active;

  bool _liveUnavailable = false;
  Completer<bool>? _liveStartResult;

  Future<void> toggleLive() async {
    if (liveActive) {
      await stopLive();
    } else {
      await _startLive();
    }
  }

  /// Starts a live session. Resolves TRUE once the session is ready, FALSE
  /// if it failed (so the caller can fall back to the classic loop without
  /// the user ever seeing an error).
  Future<bool> _startLive() async {
    // Live owns all audio: silence the classic loop completely first.
    _conversationEnded = true;
    _speakQueue.clear();
    if (_bargeMonitorOn) {
      _bargeMonitorOn = false;
      await _voice.stopBargeInMonitor();
    }
    await _voice.stopSpeaking();
    await _voice.cancelCapture();
    _resetTurn();

    _liveSvc.onReady = () {
      _liveStartResult?.complete(true);
      _liveStartResult = null;
      _setPhase(AssistantPhase.listening, silent: true);
      notifyListeners();
    };
    _liveSvc.onMicLevel = (l) {
      if (!_liveSvc.playing) {
        micLevel = l;
        notifyListeners();
      }
    };
    _liveSvc.onSpeaking = (speaking) {
      _setPhase(
        speaking ? AssistantPhase.speaking : AssistantPhase.listening,
        silent: true,
      );
      if (!speaking) micLevel = 0;
      notifyListeners();
    };
    // PURE VOICE: live mode shows NO text conversation. Transcripts are
    // logged for diagnostics only — the screen stays clean.
    _liveSvc.onUserText = (t) => AppLog.add('live', 'you: $t');
    _liveSvc.onHariText = (t) => AppLog.add('live', 'hari: $t');
    _liveSvc.onTurnComplete = () {};
    _liveSvc.onInterrupted = () {
      _setPhase(AssistantPhase.listening, silent: true);
      notifyListeners();
    };
    _liveSvc.onError = (msg) {
      // NO visible error. Log it, mark live unavailable for this run, and
      // let the orb fall back to the classic loop from now on.
      AppLog.add('live', 'unavailable: $msg');
      _liveUnavailable = true;
      _liveStartResult?.complete(false);
      _liveStartResult = null;
      _liveSvc.stop();
      _setPhase(AssistantPhase.idle, silent: true);
      notifyListeners();
    };
    _liveSvc.onClosed = () {
      _liveStartResult?.complete(false);
      _liveStartResult = null;
      if (phase != AssistantPhase.idle) {
        _setPhase(AssistantPhase.idle, silent: true);
      }
      notifyListeners();
    };

    _setPhase(AssistantPhase.thinking, silent: true); // "connecting…"
    notifyListeners();
    _liveStartResult = Completer<bool>();
    await _liveSvc.start();
    if (!_liveSvc.active) {
      _liveStartResult?.complete(false);
      _liveStartResult = null;
      _liveUnavailable = true;
      _setPhase(AssistantPhase.idle, silent: true);
      return false;
    }
    // Ready must arrive within 6s or we treat live as unavailable.
    final ok = await (_liveStartResult?.future ??
            Future<bool>.value(_liveSvc.active))
        .timeout(const Duration(seconds: 6), onTimeout: () {
      _liveUnavailable = true;
      _liveSvc.stop();
      _setPhase(AssistantPhase.idle, silent: true);
      return false;
    });
    return ok;
  }

  Future<void> stopLive() async {
    await _liveSvc.stop();
    micLevel = 0;
    _setPhase(AssistantPhase.idle, silent: true);
    notifyListeners();
  }

  // ---------------- OPENING GREETING ----------------
  // Spoken once when the assistant session becomes ready. It runs through
  // the SAME voice pipeline as every other reply (_speakQueue -> VoiceService
  // -> barge-in watcher), so it is interruptible and creates no second
  // session (§7, §8, §14).

  bool _greeted = false;

  /// True once the greeting has been delivered for this session. Guards
  /// against rebuilds, reconnects and back-navigation re-triggering it (§6).
  bool get hasGreeted => _greeted;

  /// Time-appropriate greeting text. Kept as one small generator rather
  /// than a hard-coded string per case (§16).
  static String greetingFor(String? name, {DateTime? now}) {
    final h = (now ?? DateTime.now()).hour;
    final part = h < 12
        ? 'Good morning'
        : h < 17
            ? 'Good afternoon'
            : 'Good evening';
    final first = (name ?? '').trim().split(RegExp(r'\s+')).first;
    final who = first.isEmpty ? '' : ', $first';
    return '$part$who. How can I help you today?';
  }

  /// Speaks the opening greeting exactly once per session.
  ///
  /// Called from the screen's init lifecycle — never from build(). Silent
  /// no-op if the user is already talking or a turn is in flight, so it can
  /// never talk over someone (§8, §15).
  Future<void> greetOnce({String? name}) async {
    if (_greeted) return;
    _greeted = true; // set FIRST: a rebuild racing this must not double-greet

    if (phase.busy || liveActive) return;
    if (PhoneStateGuard.instance.inCall) return;

    final text = greetingFor(name);
    transcript.add(TranscriptEntry(TranscriptRole.assistant, text));
    _setPhase(AssistantPhase.speaking, silent: true);
    notifyListeners();

    // Same queue + barge-in watcher as any other reply, so "Call Mom"
    // spoken over the greeting cuts it off and is processed normally.
    _speakQueue.add(text);
    await _drainSpeech();
  }

  /// Resets the greeting guard — used when a DIFFERENT user signs in, so
  /// the next person is greeted properly.
  void resetGreeting() => _greeted = false;

  // ---------------- CONTINUOUS CONVERSATION ----------------
  // Hari keeps the conversation going: after she finishes speaking she
  // listens again automatically, so it feels like a phone call instead of
  // a walkie-talkie. The loop ends when the user says goodbye, taps to
  // cancel, or twice says nothing at all.

  /// Set false to go back to tap-to-talk for every turn.
  bool continuousConversation = true;

  bool _conversationEnded = false;
  int _silentTurns = 0;

  /// Consecutive turns that produced no transcript. Guards against the loop
  /// re-listening forever into a broken speech service.
  int _failedTurns = 0;

  /// The last uploaded mic clip, kept so a transient server-side STT
  /// failure can be retried with the SAME audio — the user shouldn't have
  /// to repeat themselves because Google's endpoint had a load spike.
  List<int>? _lastAudioBytes;
  bool _audioResent = false;

  /// True while Hari will re-open the mic on her own after replying.
  bool get conversationActive =>
      continuousConversation && !_conversationEnded;

  /// Phrases that close the conversation. Deliberately conservative: the
  /// phrase must END the utterance (allowing trailing filler like "then",
  /// "thanks", "for now") and the utterance must be short. That way "see
  /// you at the clinic tomorrow" or "that's all right, continue" keep the
  /// conversation going, while "okay goodbye" ends it.
  static final RegExp _farewellRx = RegExp(
    r"\b(bye|bye bye|goodbye|good bye|good night|goodnight|see you|see ya|"
    r"talk (to you )?later|catch you later|that'?s all|thats all|that'?s it|"
    r"nothing else|no more questions|i'?m done|we'?re done|stop listening|"
    r"stop it|that will be all)"
    r"(?:\s+(hari|harry|then|now|dear|ok|okay|thanks|thank you|please|bye|"
    r"later|for now))*\s*$",
    caseSensitive: false,
  );

  /// Farewells in the other languages Hari speaks.
  static final RegExp _farewellNativeRx = RegExp(
    r"अलविदा|फिर मिलेंगे|बाय|बस इतना|ಬೈ|ಸಾಕು|ಹೋಗ್ತೀನಿ|ಮುಗಿಯಿತು|"
    r"போதும்|பிறகு பார்க்கலாம்|సరిపోతుంది|వెళ్తాను",
  );

  static bool isFarewell(String text) {
    var t = text.trim().toLowerCase();
    t = t.replaceAll(RegExp(r'[.!?,;।]+$'), '').trim();
    if (t.isEmpty) return false;
    // Sign-offs are short; a long sentence that merely contains "see you"
    // is not the user ending the conversation.
    if (t.split(RegExp(r'\s+')).length > 8) return false;
    return _farewellRx.hasMatch(t) || _farewellNativeRx.hasMatch(t);
  }

  /// Called when a reply has finished being spoken. Re-opens the mic unless
  /// something else legitimately owns the turn.
  void _maybeContinueListening() {
    if (!conversationActive) return;
    // A barge-in already schedules its own capture — don't double-start.
    if (_bargedIn || _bargeMonitorOn) return;
    if (PhoneStateGuard.instance.inCall) return;
    // These are waiting on the USER to tap something; don't talk over them.
    if (pendingConfirmation != null ||
        ambiguousContacts.isNotEmpty ||
        phase == AssistantPhase.error ||
        phase == AssistantPhase.listening ||
        phase == AssistantPhase.inCall) return;
    // Two silent turns in a row: they've walked away. Stop the mic rather
    // than listening to an empty room forever.
    if (_silentTurns >= 2) {
      _conversationEnded = true;
      notifyListeners();
      return;
    }
    // A brief settle lets the audio device release the speaker before the
    // mic reopens (prevents the tail of Hari's own voice being captured).
    Future.delayed(const Duration(milliseconds: 350), () {
      if (!conversationActive) return;
      if (phase == AssistantPhase.listening || phase.busy) return;
      if (pendingConfirmation != null || ambiguousContacts.isNotEmpty) return;
      pressMic(auto: true);
    });
  }

  /// Text fallback from the bottom input bar.
  Future<void> sendText(String text) async {
    final t = text.trim();
    if (t.isEmpty) return;
    await _voice.stopSpeaking();
    // Typing is an explicit "I'm here" — revive the loop, but respect a
    // typed goodbye the same way a spoken one is respected.
    _conversationEnded = isFarewell(t);
    _silentTurns = 0;
    _resetTurn();
    _setPhase(AssistantPhase.thinking);
    try {
      await _api.sendText(t);
    } catch (_) {
      _setLocalError("I couldn't send that. Check your connection.");
    }
  }

  /// Confirmation card buttons.
  Future<void> confirm(bool approved) async {
    final pending = pendingConfirmation;
    pendingConfirmation = null;
    notifyListeners();
    HapticFeedback.selectionClick();
    try {
      await _api.confirm(approved);
    } catch (_) {
      _setLocalError('That action could not be sent.');
      return;
    }
    // The phone permissions live HERE — the backend only narrates status,
    // this device actually dials.
    if (approved &&
        pending?.action == 'call' &&
        (pending?.contact?.phone.isNotEmpty ?? false)) {
      await CallService.instance.call(pending!.contact!.phone);
    }
  }

  /// Ambiguous-contact card selection.
  Future<void> chooseContact(ContactMatch m) async {
    ambiguousContacts = const [];
    notifyListeners();
    try {
      await _api.chooseContact(m.id);
    } catch (_) {
      _setLocalError('That choice could not be sent.');
    }
  }

  /// Cancel whatever is in flight.
  Future<void> cancelAction() async {
    _bargedIn = false; // an explicit cancel is not a barge-in
    _conversationEnded = true; // and it closes the continuous loop
    if (_bargeMonitorOn) {
      _bargeMonitorOn = false;
      await _voice.stopBargeInMonitor();
    }
    _speakQueue.clear();
    _voice.stopSpeaking();
    try {
      await _api.cancel();
    } catch (_) {}
    pendingConfirmation = null;
    ambiguousContacts = const [];
    _setPhase(AssistantPhase.idle);
  }

  void dismissError() {
    errorMessage = null;
    if (phase == AssistantPhase.error) phase = AssistantPhase.idle;
    notifyListeners();
  }

  // ---------------- backend events ----------------

  void _onEvent(Map<String, dynamic> e) {
    switch (e['type']) {
      case 'assistant_state':
        final p = AssistantPhase.fromWire(e['state'] as String? ?? '');
        // Never let a server 'idle' stomp on local listening/recording.
        if (p == AssistantPhase.idle && phase == AssistantPhase.listening) break;
        // The server fires speaking→completed the instant it SENDS the
        // reply, but the audio plays HERE afterwards — while our TTS is
        // talking, those two states are ours to manage, or the mouth
        // would freeze mid-sentence.
        if (_ttsActive &&
            (p == AssistantPhase.speaking || p == AssistantPhase.completed)) {
          break;
        }
        _setPhase(p, silent: true);
        if (p == AssistantPhase.error) {
          errorMessage = e['message'] as String? ?? 'Something went wrong.';
        }
        _haptic(p);
        break;

      case 'user_transcript':
        partial = '';
        _failedTurns = 0; // a real transcript — the service is healthy
        final said = e['text'] as String? ?? '';
        transcript.add(TranscriptEntry(TranscriptRole.user, said));
        // A goodbye closes the continuous loop: Hari still answers this
        // turn (so she can say goodbye back), but won't reopen the mic.
        if (isFarewell(said)) _conversationEnded = true;
        break;

      case 'assistant_sentence':
        _enqueueSentence(e['text'] as String? ?? '');
        break;

      case 'assistant_message':
        final text = e['text'] as String? ?? '';
        if (e['streamed'] == true) {
          // Sentences were already displayed + spoken as they arrived —
          // just settle the live bubble on the exact final text.
          if (_liveEntry != null) {
            transcript[transcript.length - 1] =
                TranscriptEntry(TranscriptRole.assistant, text);
            _liveEntry = null;
          } else {
            transcript.add(TranscriptEntry(TranscriptRole.assistant, text));
          }
        } else {
          transcript.add(TranscriptEntry(TranscriptRole.assistant, text));
          _speakReply(text); // non-streamed (booking/search) — speak whole
        }
        break;

      case 'tool_started':
        activities.add(ToolActivity(
          tool: e['tool'] as String? ?? '',
          label: e['label'] as String? ?? 'Working…',
        ));
        break;

      case 'tool_completed':
        for (final a in activities) {
          if (a.tool == e['tool'] && !a.completed) a.completed = true;
        }
        break;

      case 'search_results':
        searchQuery = e['query'] as String?;
        searchResults = ((e['results'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(SearchResult.fromJson)
            .toList();
        break;

      case 'documents':
        // Saved documents matched by this turn (doc recall or a client's
        // case file) — pop them on screen while Hari speaks the answer.
        documentCards = UserDocument.listFromJson(e['documents']);
        break;

      case 'contact_lookup':
        // Contacts live on THIS device — resolve the name here and post
        // the matches back so the backend can continue the flow.
        _resolveContacts(e['name'] as String? ?? '');
        break;

      case 'contact_found':
        foundContact =
            ContactMatch.fromJson((e['contact'] as Map).cast<String, dynamic>());
        ambiguousContacts = const [];
        break;

      case 'contacts_ambiguous':
        ambiguousContacts = ((e['matches'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(ContactMatch.fromJson)
            .toList();
        break;

      case 'contact_not_found':
        foundContact = null;
        ambiguousContacts = const [];
        break;

      case 'confirmation_request':
        pendingConfirmation = PendingConfirmation(
          action: e['action'] as String? ?? 'generic',
          question: e['question'] as String?,
          contact: e['contact'] is Map
              ? ContactMatch.fromJson((e['contact'] as Map).cast<String, dynamic>())
              : null,
          message: e['message'] as String?,
          spokenPreview: e['spoken_preview'] as String?,
        );
        HapticFeedback.mediumImpact();
        break;

      case 'call_status':
        callStatus = CallStatusInfo(
          status: e['status'] as String? ?? '',
          contactName: e['contact_name'] as String? ?? '',
        );
        break;

      case 'open_camera':
        // Voice-driven capture: the backend recognised "save/scan/remember
        // this" and asks the device to open the camera and file the shot.
        _captureDocument(e['note'] as String? ?? '');
        break;

      case 'open_video':
        // Voice-driven video mode: the backend recognised "open video
        // mode". Navigation needs a BuildContext, so the screen registers
        // [onOpenVideoMode] and performs the push itself.
        _conversationEnded = true; // the avatar screen owns the mic now
        _speakQueue.clear();
        _voice.stopSpeaking();
        onOpenVideoMode?.call();
        break;

      case 'transcript_failed':
        // The turn produced no transcript. Two different situations:
        //  • stt_error  — the speech service hiccuped (503 congestion,
        //    timeout, retired model). The server already retried; here we
        //    resend the SAME recorded clip exactly once after a short
        //    pause — congestion blips usually clear in a second, and the
        //    user shouldn't have to repeat themselves for Google's load
        //    spikes. If the resend also fails, stop the loop and say the
        //    service is down rather than blaming their microphone.
        //  • no_speech  — genuinely quiet; allow one retry, then stop.
        _failedTurns++;
        if (e['reason'] == 'stt_error') {
          AppLog.add('stt', 'stt_error: ${e['detail'] ?? ''}');
          final clip = _lastAudioBytes;
          if (!_audioResent && clip != null) {
            _audioResent = true;
            _setPhase(AssistantPhase.transcribing, silent: true);
            Future.delayed(const Duration(milliseconds: 1500), () async {
              try {
                await _api.sendAudio(clip);
              } catch (_) {
                _setLocalError(
                    'Speech service unavailable — please try again shortly.');
              }
            });
          } else {
            _conversationEnded = true;
            errorMessage =
                'Speech service unavailable — check the server logs.';
          }
        } else if (_failedTurns >= 2) {
          _conversationEnded = true;
        }
        break;

      case 'audio_ready':
        readyAudioUrl = e['url'] as String?;
        usedClonedVoice = e['cloned_voice'] == true;
        break;

      case 'error':
        errorMessage = e['message'] as String? ?? 'Something went wrong.';
        break;
    }
    notifyListeners();
  }

  /// Voice-driven document capture: open the camera, then file the shot
  /// into document memory with the user's own words as the note (so "the
  /// receipt I saved after the doctor" is findable later). No manual entry.
  Future<void> _captureDocument(String note) async {
    await _voice.stopSpeaking();
    XFile? shot;
    try {
      shot = await ImagePicker().pickImage(
        source: ImageSource.camera,
        maxWidth: 1920,
        maxHeight: 1920,
        imageQuality: 82,
      );
    } catch (_) {
      await _speakReply("I couldn't open the camera.");
      _setPhase(AssistantPhase.completed);
      return;
    }
    if (shot == null) {
      await _speakReply("Okay, nothing saved.");
      _setPhase(AssistantPhase.completed);
      return;
    }

    _setPhase(AssistantPhase.thinking, silent: true);
    notifyListeners();
    try {
      final bytes = await shot.readAsBytes();
      final doc = await ApiService.uploadDocument(
        bytes: bytes,
        filename: 'voice_save_${DateTime.now().millisecondsSinceEpoch}.jpg',
        mimeType: 'image/jpeg',
        note: note,
      );
      documentCards = [doc];
      notifyListeners();
      await _speakReply(
          "Saved. Ask me for it anytime — I'll remember what's on it.");
    } catch (_) {
      await _speakReply(
          "I couldn't save that — please check your connection and try again.");
    }
    _setPhase(AssistantPhase.completed);
  }

  Future<void> _resolveContacts(String name) async {
    try {
      final found = await CallService.instance.findContacts(name);
      final matches = <Map<String, dynamic>>[];
      for (final c in found) {
        if (c.phones.isEmpty) continue;
        final phone = CallService.instance.bestNumber(c);
        if (phone.isEmpty) continue;
        matches.add({'id': c.id, 'name': c.displayName, 'phone': phone});
      }
      await _api.sendContactMatches(matches);
    } catch (_) {
      await _api.sendContactMatches(const []);
    }
  }

  // ---------------- helpers ----------------

  void _resetTurn() {
    _speakQueue.clear();
    _liveEntry = null;
    errorMessage = null;
    searchQuery = null;
    searchResults = const [];
    documentCards = const [];
    foundContact = null;
    ambiguousContacts = const [];
    pendingConfirmation = null;
    callStatus = null;
    readyAudioUrl = null;
    activities.clear();
    notifyListeners();
  }

  void _setPhase(AssistantPhase p, {bool silent = false}) {
    phase = p;
    _armWatchdog();
    notifyListeners();
    if (!silent) _haptic(p);
  }

  void _setLocalError(String message) {
    errorMessage = message;
    phase = AssistantPhase.error;
    notifyListeners();
  }

  void _haptic(AssistantPhase p) {
    switch (p) {
      case AssistantPhase.waitingForConfirmation:
      case AssistantPhase.inCall:
        HapticFeedback.mediumImpact();
      case AssistantPhase.completed:
        HapticFeedback.lightImpact();
      case AssistantPhase.error:
        HapticFeedback.heavyImpact();
      default:
        break;
    }
  }
}
