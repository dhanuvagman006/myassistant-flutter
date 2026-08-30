import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/network/assistant_api.dart';
import '../../../core/log.dart';
import '../../../models/user_document.dart';
import '../../../services/api_service.dart';
import '../../../services/call_service.dart';
import '../../../services/phone_state_guard.dart';
import '../../../services/avatar_service.dart';
import '../../../services/contacts_sync_service.dart';
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

  /// True while a DEVICE FLOW owns the screen (camera capture, gallery
  /// pick). The continuous loop must NOT reopen the mic then — it recorded
  /// shutter clicks and camera-app silence, and the server answered every
  /// empty transcript with "I couldn't hear that clearly".
  bool _deviceFlowActive = false;

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
  ///
  /// The reply is split into sentences and fed through the SAME pipelined
  /// queue the streamed path uses, so playback begins after the FIRST
  /// sentence's synthesis instead of after the whole reply's — a long
  /// answer used to cost one huge synthesis wait before any audio at all.
  Future<void> _speakReply(String text) async {
    final parts = _splitSentences(text);
    if (parts.isEmpty) return;
    _speakQueue.addAll(parts);
    await _drainSpeech();
  }

  /// Sentence split for speech pipelining: . ! ? and the Devanagari danda ।.
  static List<String> _splitSentences(String text) {
    final t = text.trim();
    if (t.isEmpty) return const [];
    final parts = t
        .split(RegExp(r'(?<=[.!?।])\s+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    return parts.isEmpty ? [t] : parts;
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
    // Mirror the address book so "tell mom I'll be late" can be resolved by
    // the server-side tool mid-turn. Not awaited: it must never delay the
    // assistant coming up, and it silently does nothing without permission.
    ContactsSyncService.instance.maybeSync();
    // Auto-start Live Mode on launch so the user doesn't have to tap the mic.
    _startLive();
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
        // Every successful (re)connect — a blip must not leave the header
        // stuck on "Connecting" after the stream quietly came back.
        onConnected: () {
          connected = true;
          errorMessage = null;
          notifyListeners();
        },
      );
      connected = true;
      errorMessage = null;
      // THE REAL READY SIGNAL. The SSE session is open and the backend
      // answered — this, and only this, is what unlocks the greeting.
      // A new epoch means a genuinely new assistant session, so a
      // reconnect after a real drop can greet again, while rebuilds,
      // setState and navigation cannot (they never reach this line).
      _sessionEpoch++;
      _maybeGreetOnReady();
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
    if (!auto) {
      // ALWAYS retry live on a deliberate tap. _liveUnavailable used to be
      // sticky for the whole app run, so ONE transient failure (a quota
      // blip, a slow avatar reservation) silently demoted the app to the
      // classic loop until restart — "the agent is not visible".
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
      await _api.sendAudio(bytes, auto: auto);
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

  // ---------------- AVATAR ----------------
  // The photorealistic face is tied to the LIVE session, not to the screen:
  // it starts with live mode and dies with it, so the per-minute meter only
  // runs while a conversation is actually happening.
  final _avatar = AvatarService.instance;

  /// Guards against the mic gate sticking closed if the speaking-changed
  /// event that normally reopens it never arrives.
  Timer? _micGateWatchdog;

  /// Debounces the end of her turn, so a pause between clauses is not
  /// mistaken for her having finished.
  Timer? _silenceSettle;

  /// The avatar's video track while BeyondPresence is rendering, else null.
  /// The screen paints this into AssistantFace's live layer; null simply
  /// leaves the existing portrait in place.
  lk.VideoTrack? get avatarTrack => _avatar.videoTrack;

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
    _liveSvc.onUserText = (t) {
      AppLog.add('live', 'you: $t');
      // Gemini streams the user's transcript WHILE they are still talking,
      // so treating its arrival as "thinking" puts the orb in a busy state
      // during the user's own sentence. In avatar mode the turn boundaries
      // are known exactly — her transcript starts the reply, turn_complete
      // ends it — so stay on "listening" here and let those drive it.
      if (_avatar.isLive) {
        if (phase != AssistantPhase.listening) {
          _setPhase(AssistantPhase.listening, silent: true);
          notifyListeners();
        }
        return;
      }
      _setPhase(AssistantPhase.thinking, silent: true);
      notifyListeners();
    };
    _liveSvc.onHariText = (t) {
      AppLog.add('live', 'hari: $t');
      // With the avatar rendering, Hari's audio goes to the avatar service
      // and never reaches this app — so onSpeaking (which is driven by local
      // playback) can never fire, and the phase would stay stuck on the
      // "thinking" set by onUserText for the rest of the conversation.
      // Her transcript is the only speaking signal we still receive, so it
      // drives the phase instead. Audio-only mode keeps using onSpeaking,
      // which is tied to actual playback and therefore more precise.
      // Early guard. The room's audio-level signal is authoritative but
      // takes a few hundred ms to trip, and mic audio uploaded in that
      // window is enough to make the model think it was interrupted. Her
      // transcript arrives first, so close the gate on it.
      if (_avatar.isLive) {
        _liveSvc.remoteSpeaking = true;
        // Safety net: if the speaking-changed event never arrives (it is
        // what normally reopens the gate), the mic would stay muted and the
        // conversation would be over. Force it open after a long turn.
        _micGateWatchdog?.cancel();
        _micGateWatchdog = Timer(const Duration(seconds: 20), () {
          if (!_avatar.isSpeaking) {
            AppLog.add('avatar', 'mic gate watchdog released');
            _liveSvc.remoteSpeaking = false;
            _setPhase(AssistantPhase.listening, silent: true);
            notifyListeners();
          }
        });
        if (phase != AssistantPhase.speaking) {
          _setPhase(AssistantPhase.speaking, silent: true);
          notifyListeners();
        }
      }
    };
    _liveSvc.onTurnComplete = () {
      // End of Hari's turn — back to listening. Same reasoning as above:
      // without local audio there is no playback-finished event to wait on.
      // NOT used to return to listening: turn_complete means Gemini stopped
      // GENERATING, but the avatar is still playing out what it buffered.
      // Trusting it here would unmute the mic while she talks — exactly the
      // self-interruption this is meant to prevent. The speaking-changed
      // signal ends the turn instead.
      if (_avatar.isLive && !_avatar.isSpeaking) {
        micLevel = 0;
        _setPhase(AssistantPhase.listening, silent: true);
        notifyListeners();
      }
    };
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

    // Reserve the avatar BEFORE the socket: the backend needs the room at
    // setup time to know where to send Hari's voice. Never fatal — a null
    // room just means this conversation is audio-only with the portrait.
    _avatar.onChanged = notifyListeners;
    // Close the mic while she is audible, and drive the orb from the same
    // signal. This is what stops her interrupting herself: without it the
    // loudspeaker feeds her own voice back to the model as user speech.
    // PRIMARY signal — from the server, which knows exactly how much audio
    // it handed the avatar and how long that takes to play. LiveKit's own
    // active-speaker events (wired below) turned out to fire only sometimes,
    // which left the mic muted until the watchdog rescued it 20 s later.
    // Device actions arriving over the live socket go through the same
    // dispatcher as the classic path, so camera, contact lookup and document
    // capture all behave identically in both modes.
    _liveSvc.onDeviceAction = (action) {
      AppLog.add('live', 'device action: ${action['type']}');
      _onEvent(action);
    };

    _liveSvc.onAvatarSpeaking = (speaking) {
      AppLog.add('avatar', speaking ? 'speaking' : 'silent');
      _micGateWatchdog?.cancel();
      _micGateWatchdog = null;
      _silenceSettle?.cancel();
      _silenceSettle = null;
      _liveSvc.remoteSpeaking = speaking;
      micLevel = 0;
      _setPhase(
        speaking ? AssistantPhase.speaking : AssistantPhase.listening,
        silent: true,
      );
      notifyListeners();
    };

    _avatar.onSpeakingChanged = (speaking) {
      // Secondary. It may close the gate early (useful), but it must never
      // OPEN it — it has been seen to miss transitions entirely, and the
      // server signal above is the one that knows when she is really done.
      if (!speaking) return;
      _micGateWatchdog?.cancel();
      _micGateWatchdog = null;

      if (speaking) {
        _silenceSettle?.cancel();
        _silenceSettle = null;
        _liveSvc.remoteSpeaking = true;
        micLevel = 0;
        _setPhase(AssistantPhase.speaking, silent: true);
        notifyListeners();
        return;
      }

      // Do NOT reopen the mic on the first sign of silence. Natural pauses
      // between clauses register as silence, and reopening inside one lets
      // her own next words back into the model as if the user had spoken —
      // the self-interruption returns as a stutter mid-reply. Wait for the
      // silence to hold before deciding the turn is really over.
      _silenceSettle?.cancel();
      _silenceSettle = Timer(const Duration(milliseconds: 700), () {
        if (_avatar.isSpeaking) return; // she resumed — the gap was a pause
        _liveSvc.remoteSpeaking = false;
        micLevel = 0;
        _setPhase(AssistantPhase.listening, silent: true);
        notifyListeners();
      });
    };
    String? avatarRoom;
    try {
      if (await AvatarService.isAvailable()) avatarRoom = await _avatar.start();
    } catch (_) {
      avatarRoom = null;
    }

    await _liveSvc.start(avatarRoom: avatarRoom);
    if (!_liveSvc.active) {
      _liveStartResult?.complete(false);
      _liveStartResult = null;
      _liveUnavailable = true;
      await _avatar.stop(); // socket never came up — don't leave a paid room
      _setPhase(AssistantPhase.idle, silent: true);
      return false;
    }
    // Ready must arrive within 6s or we treat live as unavailable.
    final ok = await (_liveStartResult?.future ??
            Future<bool>.value(_liveSvc.active))
        .timeout(const Duration(seconds: 12), onTimeout: () {
      _liveUnavailable = true;
      _liveSvc.stop();
      _avatar.stop();
      _setPhase(AssistantPhase.idle, silent: true);
      return false;
    });
    return ok;
  }

  Future<void> stopLive() async {
    _micGateWatchdog?.cancel();
    _micGateWatchdog = null;
    _silenceSettle?.cancel();
    _silenceSettle = null;
    await _liveSvc.stop();
    // Ends the BEY session and deletes the room — this is what stops the
    // per-minute billing, so it runs on every exit from live mode.
    await _avatar.stop();
    micLevel = 0;
    _setPhase(AssistantPhase.idle, silent: true);
    notifyListeners();
  }

  // ---------------- OPENING GREETING ----------------
  // Spoken once when the assistant session becomes ready. It runs through
  // the SAME voice pipeline as every other reply (_speakQueue -> VoiceService
  // -> barge-in watcher), so it is interruptible and creates no second
  // session (§7, §8, §14).

  /// Increments each time a live session genuinely becomes ready. The
  /// greeting is keyed to this rather than a global boolean, so it can
  /// never fire twice for one session and is never permanently blocked
  /// after a real reconnect (§16).
  int _sessionEpoch = 0;
  int _greetedEpoch = -1;

  /// The user's display name, supplied by the screen once it is known.
  String? greetingName;

  /// Set false to suppress the automatic greeting entirely.
  bool greetingEnabled = true;

  bool get hasGreeted => _greetedEpoch == _sessionEpoch;

  /// Time-appropriate greeting text starting with Hello.
  static String greetingFor(String? name, {DateTime? now}) {
    final first = (name ?? '').trim().split(RegExp(r'\s+')).first;
    final who = first.isEmpty ? 'there' : first;
    // Short and professional — the greeting is also the app's first
    // latency impression, so one crisp sentence beats a flourish.
    final h = (now ?? DateTime.now()).hour;
    final part = h < 12
        ? 'Good morning'
        : h < 17
            ? 'Good afternoon'
            : 'Good evening';
    return '$part, $who! How can I help you today?';
  }

  /// Speaks the opening greeting — ONLY when the live session is really
  /// ready. Called from the connect path, never from a widget lifecycle.
  ///
  /// Refuses to speak when: not connected, already greeted this session,
  /// a turn is in flight, live mode owns the audio, or a phone call is
  /// active. If the session drops before the audio starts, the greeting is
  /// abandoned rather than spoken into a dead session (§4).
  Future<void> _maybeGreetOnReady() async {
    if (!greetingEnabled) return;
    if (!connected) return;                 // never greet while offline
    final epoch = _sessionEpoch;
    if (_greetedEpoch == epoch) return;     // once per real session
    if (phase.busy || liveActive || _liveStartResult != null) return;
    if (PhoneStateGuard.instance.inCall) return;
    _greetedEpoch = epoch;                  // claim before awaiting

    // Small settle so a reconnect storm cannot start speech mid-flap.
    await Future.delayed(const Duration(milliseconds: 600));
    // Re-verify: the session may have dropped during the settle.
    if (!connected || _sessionEpoch != epoch || phase.busy || liveActive) {
      if (_sessionEpoch == epoch) _greetedEpoch = -1; // allow a later retry
      return;
    }

    final text = greetingFor(greetingName);
    transcript.add(TranscriptEntry(TranscriptRole.assistant, text));
    _setPhase(AssistantPhase.speaking, silent: true);
    notifyListeners();

    // Same speak queue + barge-in watcher as any other reply, so "Call
    // Mom" over the greeting cuts it off and is processed normally.
    _speakQueue.add(text);
    await _drainSpeech();
  }

  /// Kept for the screen to nudge a greeting once the user's name is
  /// known, if the session was already ready before that happened.
  Future<void> greetOnce({String? name}) async {
    if (name != null && name.isNotEmpty) greetingName = name;
    await _maybeGreetOnReady();
  }

  /// Resets the greeting guard — used when a DIFFERENT user signs in, so
  /// the next person is greeted properly.
  void resetGreeting() => _greetedEpoch = -1;

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
    // The camera/gallery owns the screen — reopening the mic underneath it
    // only records noise. The flow re-enters here when it finishes.
    if (_deviceFlowActive) return;
    // These are waiting on the USER to tap something; don't talk over them.
    if (pendingConfirmation != null ||
        ambiguousContacts.isNotEmpty ||
        phase == AssistantPhase.error ||
        phase == AssistantPhase.listening ||
        phase == AssistantPhase.inCall) {
      return;
    }
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

  /// Ask the assistant something on the user's behalf (dashboard quick
  /// actions). Routed into whichever conversation currently owns the audio:
  /// the LIVE session when one is up (she answers by voice, tools and all),
  /// otherwise the classic SSE session — so a button tap and a spoken
  /// request are the same thing to the rest of the system.
  Future<void> askAssistant(String text) async {
    final t = text.trim();
    if (t.isEmpty) return;
    if (liveActive) {
      _liveSvc.sendText(t);
      return;
    }
    await sendText(t);
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

    // On-device flow (live mode): no server round-trip — the SSE session
    // knows nothing about this call. Dial (or drop) locally and let the
    // live model know what happened so the conversation stays coherent.
    if (_localCallFlow) {
      _localCallFlow = false;
      final who = pending?.contact?.name ?? 'them';
      if (approved && (pending?.contact?.phone.isNotEmpty ?? false)) {
        final ok = await CallService.instance.call(pending!.contact!.phone);
        if (liveActive) {
          _liveSvc.sendText(ok
              ? '[SYSTEM] The call to $who is being placed on the phone now.'
              : '[SYSTEM] The phone could not start the call to $who. Tell me briefly.');
        }
      } else if (liveActive) {
        _liveSvc.sendText('[SYSTEM] I declined the call to $who. Acknowledge briefly.');
      }
      return;
    }

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
    // On-device flow: the user's tap on the pick IS the choice — act on it
    // (relay or direct dial); the server was never part of this call.
    if (_localCallFlow) {
      _localCallFlow = false;
      notifyListeners();
      await _actOnResolvedCall(m);
      return;
    }
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
    _localCallFlow = false;
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

      case 'resolve_and_call':
        // LIVE MODE calling. The place_phone_call tool emits this action;
        // on the SSE path the server converts it into the contact_lookup
        // handshake, but on the LIVE socket it arrives here AS-IS — and
        // nothing handled it, so Hari said "Calling…" and the phone never
        // dialled. The whole flow is on-device anyway (contacts + dialler
        // live here), so resolve, confirm and dial locally.
        _handleResolveAndCall(
          e['name'] as String? ?? '',
          e['message'] as String?,
          agentAvailable: e['agent_available'] == true,
        );
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

      case 'analyze_camera':
        // Voice-driven vision analysis ("what tablet is this")
        _analyzeCamera(e['question'] as String? ?? 'What is in this image?');
        break;

      case 'capture_document':
      case 'open_camera':
        // Voice-driven capture: the backend recognised "save/scan/remember
        // this" and asks the device to open the camera/gallery and file the shot.
        _captureDocument(
          e['note'] as String? ?? '',
          clientId: e['client_id'] as int?,
          person: e['person'] as String?,
          source: e['source'] as String? ?? 'camera',
        );
        break;

      case 'open_url':
        // Voice-driven deep linking to external apps like Uber, Swiggy, Zomato.
        final url = e['url'] as String?;
        if (url != null && url.isNotEmpty) {
          launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
          // Auto-resume conversation after firing intent
          _setPhase(AssistantPhase.completed);
        }
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

  /// Voice-driven vision analysis: opens the camera, sends the photo directly
  /// to the backend /vision endpoint with the user's question, and speaks the answer.
  /// Opens the camera, sends the frame to /vision, and reports what it says.
  ///
  /// The mic is held shut for the whole capture: the shutter and whatever the
  /// user mutters while framing the shot would otherwise stream into the live
  /// model and be taken as a new question. The gate is released in a finally
  /// because there are five ways out of the inner method — cancelled capture,
  /// camera failure, upload failure, thrown error, success — and missing any
  /// one of them would leave the microphone dead for the rest of the session.
  Future<void> _analyzeCamera(String question) async {
    final gated = liveActive;
    if (gated) _liveSvc.remoteSpeaking = true;
    _deviceFlowActive = true; // no auto-listen under the camera
    try {
      await _analyzeCameraInner(question);
    } finally {
      _deviceFlowActive = false;
      if (gated) _liveSvc.remoteSpeaking = false;
    }
  }

  /// Say something that came out of the camera flow.
  ///
  /// In live mode the assistant's voice IS the avatar's, so speaking locally
  /// would be a second, unsynced voice — and in practice the user heard
  /// nothing and the assistant simply appeared to give up after the shutter.
  /// Routing through the live session makes her say it, and keeps the model
  /// aware of what happened.
  Future<void> _sayFromCamera(String text) async {
    if (liveActive) {
      _liveSvc.sendText('Say this to me now, in my language: "$text"');
      _setPhase(AssistantPhase.listening, silent: true);
      notifyListeners();
      return;
    }
    await _speakReply(text);
    _setPhase(AssistantPhase.completed);
  }

  Future<void> _analyzeCameraInner(String question) async {
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
      await _sayFromCamera("I couldn't open the camera.");
      return;
    }
    if (shot == null) {
      await _sayFromCamera("Okay, cancelled.");
      return;
    }

    _setPhase(AssistantPhase.thinking, silent: true);
    notifyListeners();
    try {
      final bytes = await shot.readAsBytes();
      
      var request = http.MultipartRequest('POST', Uri.parse('${ApiService.baseUrl}/vision'));
      if (ApiService.sessionToken != null) {
        request.headers['Authorization'] = 'Bearer ${ApiService.sessionToken}';
      }
      request.fields['mode'] = 'ask';
      request.fields['question'] = question;
      // contentType is REQUIRED, not optional. Without it the part goes up
      // as application/octet-stream and /vision — which accepts only
      // image/jpeg|png|webp — rejects every photo with 415. A filename
      // ending in .jpg does NOT set the MIME type.
      request.files.add(http.MultipartFile.fromBytes(
        'file',
        bytes,
        filename: 'scan.jpg',
        contentType: MediaType('image', 'jpeg'),
      ));
      
      final response = await request.send();
      final body = await response.stream.bytesToString();
      
      if (response.statusCode != 200) {
        // Log the body: a silent "couldn't analyse it" hid a 415 for the
        // whole of this feature's life.
        AppLog.add('vision',
            'HTTP ${response.statusCode}: ${body.substring(0, body.length < 160 ? body.length : 160)}');
        await _sayFromCamera("I couldn't read that image, sorry. Try again?");
        return;
      }
      
      final data = jsonDecode(body);
      final answer = data['answer'] as String? ?? "I couldn't see anything clearly.";

      transcript.add(TranscriptEntry(TranscriptRole.assistant, answer));

      if (liveActive) {
        // In live mode the assistant's voice belongs to the avatar. Speaking
        // this locally would talk over her with a second, unsynced voice and
        // leave the model unaware of what was on the sign. Hand the reading
        // back to the live session instead: she says it herself, in the
        // user's language, and can be asked follow-up questions about it.
        _liveSvc.sendText(
          'I pointed the camera and the image shows: "$answer". '
          'Tell me this now, naturally, in the language I am speaking.',
        );
        _setPhase(AssistantPhase.listening, silent: true);
        notifyListeners();
      } else {
        await _speakReply(answer);
        // Let the backend know we answered it so context is maintained
        _api.sendText("I looked at it and saw: $answer");
      }
      
    } catch (e) {
      await _sayFromCamera("There was a problem scanning the image.");
    }
  }

  /// Voice-driven document capture: open the camera or gallery, then file the shot
  /// into document memory with the user's own words as the note (so "the
  /// receipt I saved after the doctor" is findable later). No manual entry.
  ///
  /// [person] is who the document BELONGS to ("save this scan for Prasant") —
  /// passed through to the upload so the file lands in that person's records
  /// and "show me Prasant's records" finds it later.
  Future<void> _captureDocument(String note,
      {int? clientId, String? person, String source = 'camera'}) async {
    // Hold the continuous loop shut for the whole flow — the camera owns
    // the screen and the mic would only record shutter noise (the source of
    // the "I couldn't hear that clearly" error after every scan).
    _deviceFlowActive = true;
    final liveGated = liveActive;
    if (liveGated) _liveSvc.remoteSpeaking = true;
    try {
      await _voice.stopSpeaking();
      XFile? shot;
      try {
        shot = await ImagePicker().pickImage(
          source: source == 'gallery' ? ImageSource.gallery : ImageSource.camera,
          maxWidth: 1920,
          maxHeight: 1920,
          imageQuality: 82,
        );
      } catch (_) {
        await _sayFromCamera("I couldn't open the camera.");
        _setPhase(AssistantPhase.completed);
        return;
      }
      if (shot == null) {
        await _sayFromCamera("Okay, nothing saved.");
        _setPhase(AssistantPhase.completed);
        return;
      }

      _setPhase(AssistantPhase.thinking, silent: true);
      notifyListeners();
      try {
        final bytes = await shot.readAsBytes();
        final doc = await ApiService.uploadDocument(
          bytes: bytes,
          filename: 'Capture.jpg',
          mimeType: 'image/jpeg',
          note: note,
          clientId: clientId,
          person: person,
        );
        documentCards = [doc];
        notifyListeners();
        await _sayFromCamera(person == null
            ? "Saved and filed."
            : "Saved to $person's records.");
      } catch (_) {
        await _sayFromCamera(
            "I couldn't save that — please check your connection and try again.");
      }
      _setPhase(AssistantPhase.completed);
    } finally {
      _deviceFlowActive = false;
      if (liveGated) _liveSvc.remoteSpeaking = false;
    }
  }

  /// True while a call flow is being handled entirely ON-DEVICE (live
  /// mode). confirm()/chooseContact() then act locally instead of posting
  /// to the SSE session, which knows nothing about this flow.
  bool _localCallFlow = false;

  /// The message to deliver / question to ask on the current local call
  /// flow ("call X and tell him …"), and whether the server can place the
  /// call itself (agent relay) so the user never has to talk.
  String? _localCallTask;
  bool _localCallAgentAvailable = false;

  /// Live-mode "call X [and tell them Y]": resolve the name against the
  /// phone's contacts and act. The spoken yes/no already happened inside
  /// the live conversation (high-risk tools are gated server-side), so a
  /// single match proceeds immediately — no second tap to approve.
  Future<void> _handleResolveAndCall(String name, String? message,
      {bool agentAvailable = false}) async {
    if (name.trim().isEmpty) return;
    _localCallTask = message;
    _localCallAgentAvailable = agentAvailable;
    List<ContactMatch> matches = const [];
    try {
      final found = await CallService.instance.findContacts(name);
      matches = [
        for (final c in found)
          if (CallService.instance.bestNumber(c).isNotEmpty)
            ContactMatch(
              id: c.id,
              name: c.displayName,
              phone: CallService.instance.bestNumber(c),
            ),
      ];
    } catch (_) {}

    if (matches.isEmpty) {
      // Tell whichever brain is running, so Hari says it instead of the
      // user waiting on a call that can never come.
      if (liveActive) {
        _liveSvc.sendText(
            '[SYSTEM] No contact named "$name" was found on the phone. '
            'Tell me that briefly.');
      } else {
        await _speakReply("I couldn't find $name in your contacts.");
      }
      return;
    }

    if (matches.length == 1) {
      await _actOnResolvedCall(matches.first);
    } else {
      _localCallFlow = true; // chooseContact routes back here
      ambiguousContacts = matches.take(6).toList();
      notifyListeners();
    }
  }

  /// Acts on a resolved contact: agent relay (Hari speaks the message on
  /// the call herself) when a task + the server-side caller are available,
  /// else a plain direct dial for the user to talk.
  Future<void> _actOnResolvedCall(ContactMatch contact) async {
    HapticFeedback.mediumImpact();
    final task = _localCallTask;
    _localCallTask = null;

    if (task != null && task.isNotEmpty && _localCallAgentAvailable) {
      String? id;
      try {
        id = await ApiService.startAgentCall(
          toNumber: contact.phone,
          contactName: contact.name,
          task: task,
        );
      } catch (_) {
        id = null; // unavailable / quota / network — fall through
      }
      if (id != null) {
        await _followAgentCall(id, contact.name);
        return;
      }
      // Couldn't start after all — fall through to a direct dial, and be
      // honest about it.
      if (liveActive) {
        _liveSvc.sendText(
            '[SYSTEM] I could not start the relay call to ${contact.name}. '
            'The phone is dialling them directly instead — tell me briefly.');
      }
    }

    final ok = await CallService.instance.call(contact.phone);
    if (liveActive) {
      _liveSvc.sendText(ok
          ? '[SYSTEM] The phone is dialling ${contact.name} now.'
          : '[SYSTEM] The phone could not start the call to ${contact.name}. Tell me briefly.');
    }
  }

  /// Follows a server-placed relay call to its real end, keeping the
  /// call-status card honest and speaking the true outcome — never "done"
  /// unless the call actually landed.
  Future<void> _followAgentCall(String id, String who) async {
    callStatus = CallStatusInfo(status: 'dialing', contactName: who);
    notifyListeners();
    String state = 'failed';
    String? result;
    final deadline = DateTime.now().add(const Duration(minutes: 3));
    while (DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(seconds: 3));
      try {
        final st = await ApiService.agentCallStatus(id);
        state = st.state;
        result = st.result ?? result;
      } catch (_) {
        continue; // transient poll failure — keep following
      }
      if (state == 'completed' || state == 'no_answer' || state == 'failed') {
        break;
      }
      callStatus = CallStatusInfo(status: state, contactName: who);
      notifyListeners();
    }
    callStatus = null;
    notifyListeners();
    final said = result ??
        (state == 'completed'
            ? 'The call to $who is done.'
            : state == 'no_answer'
                ? '$who did not pick up, so the message was not delivered.'
                : 'The call to $who did not go through.');
    if (liveActive) {
      _liveSvc.sendText(
          '[SYSTEM] The call to $who has ended. Result: $said Tell me this '
          'now in one short sentence, exactly as it happened.');
    } else {
      await _speakReply(said);
    }
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
