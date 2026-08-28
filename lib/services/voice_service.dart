import 'dart:async';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

import 'api_service.dart';
import 'phone_state_guard.dart';
import 'style_prefs.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'dart:io';

/// Voice layer for the assistant (A2 Voice, A3 Multi-language).
///
/// Jobs:
///  1. WATCH — wake-word watching via live transcripts (fallback engine).
///  2. CAPTURE — record one question in the user's chosen language.
///  3. SPEAK — read replies aloud with the most natural voice installed
///     for the reply's language (auto-detected per reply), and support
///     BARGE-IN: while speaking, keep listening; if real user speech is
///     heard (echo-filtered), stop speaking and treat it as the next
///     question.
class VoiceService {
  VoiceService._();
  static final VoiceService instance = VoiceService._();

  final stt.SpeechToText _stt = stt.SpeechToText();
  final FlutterTts _tts = FlutterTts();

  /// A4 — user changed voice speed in settings: applies immediately.
  Future<void> applySpeechRate(double rate) => _tts.setSpeechRate(rate);

  bool _ready = false;
  bool _watching = false;
  Timer? _restartTimer;

  /// Variants the recognizer commonly hears for "Hey Hari".
  static const _wakeWords = [
    'hey hari',
    'hey harry',
    'hey hurry',
    'a hari',
    'hey hardy',
  ];

  static bool containsWakeWord(String text) {
    final t = text.toLowerCase();
    return _wakeWords.any(t.contains) ||
        t.split(RegExp(r'\s+')).any((w) => w == 'hari' || w == 'harry');
  }

  /// Session hooks: the active capture / barge-in session subscribes to
  /// recognizer status + errors so it can restart or finish immediately
  /// (the Android recognizer stops itself after a few quiet seconds).
  void Function(String status)? _sessionStatus;
  void Function()? _sessionError;

  Future<bool> init() async {
    if (_ready) return true;
    _ready = await _stt.initialize(
      onStatus: (status) {
        _sessionStatus?.call(status);
        // The platform recognizer stops itself every few seconds of
        // silence; while watching we simply start it again.
        if (_watching && (status == 'done' || status == 'notListening')) {
          _restartTimer?.cancel();
          _restartTimer = Timer(
            const Duration(milliseconds: 400),
            () {
              if (_watching) _listenForWake();
            },
          );
        }
      },
      onError: (_) {
        _sessionError?.call();
        if (_watching) {
          _restartTimer?.cancel();
          _restartTimer = Timer(
            const Duration(milliseconds: 900),
            () {
              if (_watching) _listenForWake();
            },
          );
        }
      },
    );
    await _tts.setSpeechRate(StylePrefs.instance.speechRate);
    await _tts.setPitch(1.0);
    await _tts.awaitSpeakCompletion(true);
    // LIP-SYNC: each word boundary the engine reports becomes a pulse the
    // avatar's mouth rides — her lips move WITH the words, not on a loop.
    _tts.setProgressHandler((_, __, ___, word) {
      isSpeaking.value = true;
      ttsLevel.value = (0.55 + 0.45 * _pulseRand.nextDouble())
          .clamp(0.0, 1.0);
    });
    _tts.setStartHandler(() => isSpeaking.value = true);
    void endSpeech() {
      isSpeaking.value = false;
      ttsLevel.value = 0;
    }

    _tts.setCompletionHandler(endSpeech);
    _tts.setCancelHandler(endSpeech);
    _tts.setErrorHandler((_) => endSpeech());
    await _loadVoices();
    return _ready;
  }

  /// True while a reply is being read aloud (drives the avatar's
  /// "speaking" look even if backend states have already moved on).
  final ValueNotifier<bool> isSpeaking = ValueNotifier(false);

  /// 0..1 pulse per spoken word — the avatar's mouth openness.
  final ValueNotifier<double> ttsLevel = ValueNotifier(0);
  final _pulseRand = math.Random();

  bool get isReady => _ready;

  /// Re-attempt initialization — used when the user granted the mic
  /// permission AFTER the first init failed (previously the app stayed
  /// "Microphone unavailable" until a full restart).
  Future<bool> reinit() async {
    if (_ready) return true;
    _ready = false;
    return init();
  }

  /// Languages the device recognizer can transcribe (for the picker).
  Future<List<stt.LocaleName>> sttLocales() async {
    if (!_ready) return const [];
    try {
      final l = await _stt.locales();
      l.sort((a, b) => a.name.compareTo(b.name));
      return l;
    } catch (_) {
      return const [];
    }
  }

  // ---------------- NATURAL VOICE SELECTION ----------------
  // Devices ship many voices per language; the defaults are often the
  // robotic "local" ones. Google's "network" / neural voices are far more
  // human. We index every installed voice once and pick the best match
  // for whatever language a reply is in.

  final List<Map<String, String>> _voices = [];
  final Map<String, Map<String, String>?> _bestVoiceCache = {};
  String _currentTtsLang = '';

  Future<void> _loadVoices() async {
    try {
      final raw = await _tts.getVoices;
      _voices.clear();
      if (raw is List) {
        for (final v in raw) {
          if (v is Map) {
            final name = v['name']?.toString() ?? '';
            final locale = v['locale']?.toString() ?? '';
            if (name.isNotEmpty && locale.isNotEmpty) {
              _voices.add({'name': name, 'locale': locale});
            }
          }
        }
      }
    } catch (_) {}
  }

  int _voiceScore(Map<String, String> v, String wantLocale) {
    final name = v['name']!.toLowerCase();
    final loc = v['locale']!.toLowerCase();
    final want = wantLocale.toLowerCase();
    var s = 0;
    if (loc == want || loc == want.replaceAll('-', '_')) s += 100;
    if (loc.split(RegExp('[-_]')).first == want.split('-').first) s += 40;
    // Quality tiers seen in Google/Samsung TTS voice names.
    if (name.contains('neural') || name.contains('wavenet')) s += 14;
    if (name.contains('network')) s += 10; // Google cloud-quality voices
    if (name.contains('enhanced') || name.contains('premium')) s += 8;
    if (name.contains('local')) s += 1;
    return s;
  }

  Map<String, String>? _bestVoiceFor(String locale) {
    return _bestVoiceCache.putIfAbsent(locale, () {
      Map<String, String>? best;
      var bestScore = 39; // must at least match the language
      for (final v in _voices) {
        final s = _voiceScore(v, locale);
        if (s > bestScore) {
          bestScore = s;
          best = v;
        }
      }
      return best;
    });
  }

  Future<void> _applyLanguageFor(String text) async {
    final lang = detectLanguage(text);
    if (lang == _currentTtsLang) return;
    try {
      // If the device has NO voice for this language, setLanguage would
      // either throw or fail silently and speak() would say NOTHING —
      // one of the "TTS sometimes doesn't talk" bugs. Fall back to the
      // English-India voice: an accented reading beats dead silence.
      final available = await _tts.isLanguageAvailable(lang);
      final useLang = available == true ? lang : 'en-IN';
      if (useLang == _currentTtsLang) return;
      _currentTtsLang = useLang;
      await _tts.setLanguage(useLang);
      final voice = _bestVoiceFor(useLang);
      if (voice != null) await _tts.setVoice(voice);
    } catch (_) {
      _currentTtsLang = 'en-IN';
      try {
        await _tts.setLanguage('en-IN');
      } catch (_) {}
    }
  }

  // ---------------- LANGUAGE DETECTION (for TTS) ----------------
  // Script detection covers all Indic + major world scripts; for Latin
  // text a light stop-word check separates the big European languages.

  static const _scriptRanges = <String, List<List<int>>>{
    'hi-IN': [[0x0900, 0x097F]], // Devanagari (Hindi/Marathi)
    'bn-IN': [[0x0980, 0x09FF]],
    'pa-IN': [[0x0A00, 0x0A7F]],
    'gu-IN': [[0x0A80, 0x0AFF]],
    'or-IN': [[0x0B00, 0x0B7F]],
    'ta-IN': [[0x0B80, 0x0BFF]],
    'te-IN': [[0x0C00, 0x0C7F]],
    'kn-IN': [[0x0C80, 0x0CFF]],
    'ml-IN': [[0x0D00, 0x0D7F]],
    'si-LK': [[0x0D80, 0x0DFF]],
    'ur-PK': [[0x0600, 0x06FF], [0x0750, 0x077F]], // Arabic script
    'ru-RU': [[0x0400, 0x04FF]],
    'el-GR': [[0x0370, 0x03FF]],
    'he-IL': [[0x0590, 0x05FF]],
    'th-TH': [[0x0E00, 0x0E7F]],
    'ja-JP': [[0x3040, 0x30FF]],
    'ko-KR': [[0xAC00, 0xD7AF], [0x1100, 0x11FF]],
    'zh-CN': [[0x4E00, 0x9FFF]],
  };

  static final _latinHints = <String, Set<String>>{
    'es-ES': {'el', 'la', 'los', 'las', 'una', 'está', 'para', 'por', 'qué',
        'gracias', 'hola', 'sí', 'usted', 'cómo'},
    'fr-FR': {'le', 'la', 'les', 'une', 'est', 'vous', 'pour', 'avec', 'oui',
        'bonjour', 'merci', 'être', 'c\'est', 'je'},
    'de-DE': {'der', 'die', 'das', 'und', 'ist', 'nicht', 'ich', 'sie', 'ein',
        'mit', 'für', 'danke', 'hallo'},
    'pt-BR': {'o', 'os', 'uma', 'é', 'não', 'você', 'para', 'com', 'obrigado',
        'olá', 'sim', 'está'},
    'it-IT': {'il', 'lo', 'gli', 'una', 'è', 'non', 'per', 'con', 'grazie',
        'ciao', 'sì', 'sono'},
    'id-ID': {'yang', 'dan', 'ini', 'itu', 'tidak', 'saya', 'anda', 'untuk',
        'dengan', 'terima', 'kasih'},
  };

  /// Best-effort BCP-47 tag for the language [text] is written in.
  static String detectLanguage(String text) {
    final counts = <String, int>{};
    var latin = 0;
    for (final code in text.runes) {
      if ((code >= 0x41 && code <= 0x5A) ||
          (code >= 0x61 && code <= 0x7A) ||
          (code >= 0x00C0 && code <= 0x024F)) {
        latin++;
        continue;
      }
      for (final e in _scriptRanges.entries) {
        for (final r in e.value) {
          if (code >= r[0] && code <= r[1]) {
            counts[e.key] = (counts[e.key] ?? 0) + 1;
            break;
          }
        }
      }
    }
    if (counts.isNotEmpty) {
      final top = counts.entries.reduce((a, b) => a.value >= b.value ? a : b);
      if (top.value * 3 >= latin) return top.key; // mostly non-Latin script
    }
    // Latin text: quick stop-word vote, default English (Indian voice).
    final words = text
        .toLowerCase()
        .replaceAll(RegExp(r'[^\p{L}\p{M}\s' "'" r']', unicode: true), ' ')
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    String best = 'en-IN';
    var bestHits = 2; // need at least 3 hits to leave English
    for (final e in _latinHints.entries) {
      final hits = words.where(e.value.contains).length;
      if (hits > bestHits) {
        bestHits = hits;
        best = e.key;
      }
    }
    return best;
  }

  // ---------------- WATCH MODE ----------------

  void Function()? _onWake;

  Future<void> startWatching({required void Function() onWake}) async {
    if (!_ready) return;
    _onWake = onWake;
    _watching = true;
    await _listenForWake();
  }

  Future<void> _listenForWake() async {
    if (!_watching || _stt.isListening) return;
    await _stt.listen(
      onResult: (r) {
        if (_watching && containsWakeWord(r.recognizedWords)) {
          final cb = _onWake;
          stopWatching();
          cb?.call();
        }
      },
      listenOptions: stt.SpeechListenOptions(
        partialResults: true,
        listenMode: stt.ListenMode.dictation,
        cancelOnError: false,
        // Longest session Android reliably allows. pauseFor must not be
        // shorter than listenFor here, or silence (the normal state while
        // waiting for a wake word) ends the session early and the mic
        // audibly recycles every few seconds. With these values the
        // recognizer holds one session ~55 s, then restarts once — the
        // minimum cycling this engine permits. TRULY continuous listening
        // requires the Porcupine engine (raw audio stream, no sessions).
        listenFor: const Duration(seconds: 55),
        pauseFor: const Duration(seconds: 55),
      ),
    );
  }

  Future<void> stopWatching() async {
    _watching = false;
    _restartTimer?.cancel();
    if (_stt.isListening) await _stt.stop();
  }

  // ---------------- CAPTURE ONE QUESTION ----------------

  /// Listens once and completes with the final transcript
  /// ('' if nothing was heard). [localeId] selects the recognizer
  /// language (null = device default), e.g. 'kn_IN', 'hi_IN'.
  Future<String> captureQuestion({
    String? localeId,
    void Function(String partial)? onPartial,
    void Function(double level)? onLevel, // 0..1 for the orb animation
  }) async {
    if (!_ready) return '';
    await stopWatching();

    final completer = Completer<String>();
    String last = '';

    await _stt.listen(
      onResult: (r) {
        last = r.recognizedWords;
        onPartial?.call(last);
        if (r.finalResult && !completer.isCompleted) {
          completer.complete(last.trim());
        }
      },
      // Android reports rms roughly -2..10 dB — map to 0..1.
      onSoundLevelChange: (db) =>
          onLevel?.call(((db + 2) / 12).clamp(0.0, 1.0)),
      listenOptions: stt.SpeechListenOptions(
        localeId: localeId,
        partialResults: true,
        listenMode: stt.ListenMode.dictation,
        cancelOnError: true,
        listenFor: const Duration(seconds: 16),
        // End-of-speech for the fallback recognizer. Trimmed from 2200 ms so
        // a turn ends promptly when this path is used (some devices whose
        // amplitude meter is unreliable fall back here).
        pauseFor: const Duration(milliseconds: 1400),
      ),
    );

    // Finish the moment the recognizer session actually ends, so the UI
    // never shows "listening" while the mic is already off.
    void finishSoon() {
      Timer(const Duration(milliseconds: 250), () {
        if (!completer.isCompleted) completer.complete(last.trim());
      });
    }

    _sessionStatus = (st) {
      if (st == 'done' || st == 'notListening') finishSoon();
    };
    _sessionError = finishSoon;

    // Safety net if no status ever arrives.
    Timer(const Duration(seconds: 24), () {
      if (!completer.isCompleted) completer.complete(last.trim());
    });

    final q = await completer.future;
    _sessionStatus = null;
    _sessionError = null;
    return q;
  }

  Future<void> cancelCapture() async {
    if (_stt.isListening) await _stt.stop();
    try {
      if (await _rec.isRecording()) {
        _recCancelled = true;
        // Stopping a MediaRecorder within the first frames triggers the
        // native "Stop() called but track is not started" — give the
        // pipeline a beat to write its first samples before stopping.
        await Future.delayed(const Duration(milliseconds: 120));
        if (await _rec.isRecording()) await _rec.stop();
      }
    } catch (_) {}
  }

  // ---------------- RECORD FOR CLOUD STT (Whisper) ----------------
  // Records the question as a small m4a for the backend /stt endpoint.
  // Whisper auto-detects the language, so this path needs no locale at
  // all — it's what makes Kannada/Hindi/mixed speech "just work".

  final AudioRecorder _rec = AudioRecorder();
  bool _recCancelled = false;

  /// Whether the cloud recording path can run at all.
  Future<bool> canRecord() async {
    try {
      return await _rec.hasPermission();
    } catch (_) {
      return false;
    }
  }

  /// True if the last recordUntilSilence ended because the user cancelled
  /// (orb tap) rather than because no speech was detected. The controller
  /// uses this to decide whether to fall back to the device recognizer.
  bool get lastRecordingCancelled => _recCancelled;

  bool _lastRecordingHadSound = false;

  /// True if the last capture contained audio meaningfully above the noise
  /// floor. When this is false the room really was silent, so re-running a
  /// second recognizer session would only waste the user's time.
  bool get lastRecordingHadSound => _lastRecordingHadSound;

  /// Records until the speaker goes quiet (or [maxSeconds]).
  /// Returns the file path, or null if nothing was said / cancelled.
  ///
  /// Voice activity detection is ADAPTIVE: mic sensitivity and reported
  /// dBFS ranges vary wildly between devices, so fixed thresholds made
  /// quiet phones "never hear" speech. Instead we sample the ambient
  /// noise floor for the first ~600 ms and require speech to rise a fixed
  /// margin ABOVE that floor.
  Future<String?> recordUntilSilence({
    int maxSeconds = 15,
    int noSpeechTimeoutMs = 4000,
    // AUTO-LISTEN turns (the continuous loop reopening the mic by itself)
    // must be far stricter than a deliberate tap. With requireLatch a clip
    // is only uploaded when sustained speech actually latched the gate —
    // "any sound above the floor" is NOT enough, because in a lived-in room
    // that's the TV, a fan, or someone across the room, and uploading it is
    // how "00:00" ended up transcribed as the user's words.
    bool requireLatch = false,
    void Function(double level)? onLevel, // 0..1 for UI animation
  }) async {
    try {
      if (!await _rec.hasPermission()) return null;
      _recCancelled = false;
      _lastRecordingHadSound = false;

      final dir = await getTemporaryDirectory();
      final path =
          '${dir.path}/hari_q_${DateTime.now().millisecondsSinceEpoch}.m4a';

      await _rec.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          sampleRate: 16000,
          numChannels: 1,
          bitRate: 48000,
          // BACKGROUND NOISE: let the platform DSP strip steady background
          // noise (fans, traffic, TV) and cancel our own speaker echo, so
          // only the user's voice reaches both the VAD and the STT. autoGain
          // stays OFF — it would normalise levels and break the noise-floor
          // VAD below.
          noiseSuppress: true,
          echoCancel: true,
          androidConfig: AndroidRecordConfig(
            // VOICE_COMMUNICATION routes through the phone's hardware
            // echo-canceller / noise-suppressor — the same path calls use.
            audioSource: AndroidAudioSource.voiceCommunication,
          ),
        ),
        path: path,
      );

      // Wall-clock timing. The previous loop assumed each iteration took
      // exactly 120 ms, but every iteration also awaited platform-channel
      // calls costing ~35 ms each — so real elapsed time ran ~60% ahead of
      // the counters and every timeout overshot badly. A Stopwatch measures
      // what ACTUALLY elapsed.
      final sw = Stopwatch()..start();

      // --- calibrate the ambient noise floor (~300 ms) ---
      // Use the MINIMUM level seen, not a running average. People very often
      // start talking the instant they tap the mic, and averaging folded
      // their voice into the "floor" — which pushed the gates above their
      // actual speech, so the turn never latched and a truncated clip got
      // sent (transcribing to nothing: "I couldn't hear that clearly").
      // The quietest moment in the window is a far better floor estimate,
      // and it keeps adapting downward during the loop below.
      var floor = -50.0;
      var floorSamples = 0;
      var peak = -160.0;
      while (sw.elapsedMilliseconds < 300) {
        await Future.delayed(const Duration(milliseconds: 100));
        if (_recCancelled) break;
        try {
          final db = (await _rec.getAmplitude()).current;
          if (db.isFinite && db > -120) {
            floor = floorSamples == 0 ? db : math.min(floor, db);
            floorSamples++;
            if (db > peak) peak = db;
          }
        } catch (_) {}
      }

      // Some devices/encoders report NO usable amplitude at all (always
      // -160 / NaN). Level-gating on a dead meter meant the app decided
      // "you never spoke" and silently gave up — the exact "not
      // detecting me" bug. If the meter looks dead, skip VAD entirely:
      // record a fixed window and let the server's STT decide.
      if (floorSamples == 0 && !_recCancelled) {
        // Dead amplitude meter: skip VAD, record a short fixed window and
        // let the server's STT decide. 7 s was far longer than a spoken
        // question needs and felt like a hang; 3.5 s is plenty.
        while (sw.elapsedMilliseconds < 3500 && !_recCancelled) {
          await Future.delayed(const Duration(milliseconds: 200));
          onLevel?.call(0.35 + 0.25 * ((sw.elapsedMilliseconds ~/ 200) % 2));
        }
        final saved = await _rec.stop();
        if (_recCancelled) return null;
        _lastRecordingHadSound = true;
        return saved ?? path;
      }

      var started = false;
      var silentMs = 0;
      // Real speech is sustained; a single loud frame is a transient (a
      // door, a clap). ~180 ms of speech-level audio accepts a natural
      // syllable while still rejecting thumps.
      var voicedMs = 0;
      const startVoicedMs = 180;
      var lastMs = sw.elapsedMilliseconds;
      // Timestamp of the last frame that was clearly speech. Frames that
      // hover in the dead zone (neither speech nor clearly quiet) do not
      // refresh it, so a turn ALWAYS ends even if the level never drops
      // cleanly below the quiet gate — the mic can never hang.
      var lastVoicedAt = sw.elapsedMilliseconds;
      // Never send a clip shorter than this. A very short fragment ("Wha…")
      // transcribes to nothing, which the server reports as "I couldn't
      // hear that clearly" — the failure mode for quick questions like
      // "what is your name".
      const minCaptureMs = 900;

      while (sw.elapsedMilliseconds < maxSeconds * 1000) {
        await Future.delayed(const Duration(milliseconds: 90));
        if (_recCancelled) break;

        double db;
        try {
          // Only ONE platform call per iteration now — the old loop also
          // awaited isRecording() every tick, roughly doubling the cost of
          // the loop and stretching every timeout.
          db = (await _rec.getAmplitude()).current;
        } catch (_) {
          continue;
        }
        // Measure the REAL time this iteration took, so the silence and
        // timeout windows below are true milliseconds.
        final now = sw.elapsedMilliseconds;
        final dt = (now - lastMs).clamp(1, 1000);
        lastMs = now;

        if (!db.isFinite) continue;
        if (db > peak) peak = db;
        // Keep tracking a FALLING noise floor: if calibration happened to
        // catch the user's voice, the floor corrects itself as soon as they
        // pause, and the gates below follow it down.
        if (db < floor) floor = floor * 0.7 + db * 0.3;

        // Gates are recomputed from the current floor so they stay valid as
        // it adapts. Ordering always holds: floor < quiet < speech.
        final speechDb = math.max(floor + 3.0, math.min(floor + 6.0, -28.0));
        final quietDb = floor + math.max(1.5, (speechDb - floor) * 0.5);

        // Map roughly floor..0 dBFS to 0..1 for the orb animation.
        onLevel?.call(((db - floor) / (0 - floor)).clamp(0.0, 1.0));

        // RETROACTIVE LATCH: if the user began talking before/during
        // calibration, no frame ever cleared the (initially too-high) gate.
        // Once the floor corrects itself downward, a peak well above it is
        // proof they already spoke — latch now so the normal end-of-speech
        // rule applies, instead of sitting out the full no-speech timeout.
        if (!started && peak >= floor + 8.0 && now >= minCaptureMs) {
          started = true;
          lastVoicedAt = now;
        }

        // Belt-and-braces: once the user has started, never keep the mic
        // open more than 800 ms past their last clearly-voiced frame.
        if (started && now >= minCaptureMs && now - lastVoicedAt >= 800) break;

        if (db > speechDb) {
          voicedMs += dt;
          if (voicedMs >= startVoicedMs) started = true;
          lastVoicedAt = now;
          silentMs = 0;
        } else if (db < quietDb) {
          voicedMs = 0;
          silentMs += dt;
          // No sustained speech within the window -> stop waiting.
          if (!started && now >= noSpeechTimeoutMs) break;
          // HEARD SOMETHING, BUT THE GATE NEVER LATCHED (e.g. calibration
          // caught the user's voice, so the thresholds sat too high). On a
          // MANUAL tap the clip is worth sending and holding the mic open is
          // the "kept listening after I stopped" complaint — end after
          // ~700 ms of quiet. In AUTO mode unlatched sound is presumed
          // background noise, so this early-out doesn't apply.
          if (!requireLatch &&
              !started &&
              peak >= floor + 4.0 &&
              silentMs >= 700) {
            break;
          }
          // Finished talking: end after 450 ms of real silence, but never
          // before minCaptureMs — short questions have word gaps that would
          // otherwise cut the clip into a meaningless fragment.
          if (started && now >= minCaptureMs && silentMs >= 450) break;
        } else {
          // Dead zone: decay the voiced counter so a slow fade doesn't latch
          // "started"; still honour the no-speech timeout.
          voicedMs = (voicedMs - dt ~/ 2).clamp(0, startVoicedMs).toInt();
          if (!started && now >= noSpeechTimeoutMs) break;
        }
      }

      final saved = await _rec.stop();
      if (_recCancelled) return null;

      // Upload decision. MANUAL tap: generous — if ANY sound rose
      // meaningfully above the noise floor, send it and let the server's
      // STT judge (it recognises quiet or accented speech far better than
      // a dB meter, and a deliberate tap means the user intended to talk).
      // AUTO turn: strict — only a latched, sustained-speech capture is
      // sent, so the loop can idle in a noisy room without transcribing
      // the television.
      _lastRecordingHadSound =
          started || (!requireLatch && peak >= floor + 4.0);
      if (!_lastRecordingHadSound) return null;
      return saved ?? path;
    } catch (_) {
      try {
        await _rec.stop();
      } catch (_) {}
      return null;
    }
  }

  // ---------------- SPEAK ----------------

  /// Cloud neural voice player (Gemini TTS via backend /tts). Falls back to
  /// the on-device engine when the network / server is unavailable.
  final AudioPlayer _player = AudioPlayer();

  /// Set false to force the on-device voice (e.g. an offline toggle).
  bool cloudVoiceEnabled = true;

  /// When the cloud voice last failed. While inside the cooldown window we
  /// speak locally immediately (no slow network timeout per sentence), then
  /// retry the good voice automatically — transient outages self-heal.
  DateTime? _cloudVoiceFailedAt;
  static const _cloudCooldown = Duration(seconds: 45);

  bool get _cloudInCooldown {
    final t = _cloudVoiceFailedAt;
    return t != null && DateTime.now().difference(t) < _cloudCooldown;
  }

  /// Speaks [text] in a natural voice matching its language.
  /// Prefers the cloud neural voice; falls back to on-device TTS.
  Future<void> speak(String text) async {
    // HARD MUTE during phone calls: no sentence may START while the
    // phone is ringing or a call is connected — a streamed reply that
    // finishes mid-call must never talk over it.
    if (PhoneStateGuard.instance.inCall) return;
    final say = sanitizeForSpeech(text);
    if (say.isEmpty) return;

    if (cloudVoiceEnabled && !_cloudInCooldown) {
      final ok = await _speakCloud(say);
      if (ok) {
        _cloudVoiceFailedAt = null; // reachable again
        return;
      }
      _cloudVoiceFailedAt = DateTime.now(); // back off briefly, then retry
    }
    await _speakLocal(say);
  }

  /// Synthesizes [say] to a temp WAV via the cloud neural voice. Returns the
  /// file path, or null if synthesis failed / is disabled. Does NOT play —
  /// so the caller can synthesize the NEXT sentence while the current one is
  /// still playing (see [prefetchSpeech] / [AssistantEngine] pipelining).
  Future<String?> _synthCloud(String say) async {
    try {
      final iso = _langIso(say);
      return await ApiService.synthesizeSpeech(say, language: iso);
    } catch (_) {
      return null;
    }
  }

  /// Plays an already-synthesized cloud WAV at [path], driving the avatar
  /// mouth and honouring barge-in/stop. Deletes the temp file when done.
  /// Returns false (leaving no audio playing) if playback fails, so the
  /// caller can fall back to the on-device voice.
  Future<bool> _playCloudFile(String path) async {
    try {
      // Stop any lingering local/cloud audio before the new utterance.
      try {
        await _tts.stop();
      } catch (_) {}
      await _player.stop();

      isSpeaking.value = true;
      // Drive the avatar mouth with a gentle pulse while the file plays
      // (the cloud path has no per-word callbacks like flutter_tts).
      final pulse = Timer.periodic(const Duration(milliseconds: 120), (_) {
        ttsLevel.value =
            (0.45 + 0.45 * _pulseRand.nextDouble()).clamp(0.0, 1.0);
      });

      // Resolve when the file finishes NATURALLY *or* when playback is
      // stopped (barge-in / orb tap / phone call). onPlayerComplete only
      // fires on natural end, so relying on it alone would hang the whole
      // speak chain the moment we cut Hari off.
      final done = Completer<void>();
      final sub = _player.onPlayerStateChanged.listen((s) {
        if ((s == PlayerState.completed || s == PlayerState.stopped) &&
            !done.isCompleted) {
          done.complete();
        }
      });
      try {
        await _player.play(DeviceFileSource(path));
        // Backstop: never hang forever if no state event arrives.
        await done.future.timeout(
          const Duration(seconds: 30),
          onTimeout: () {},
        );
      } finally {
        await sub.cancel();
        pulse.cancel();
        isSpeaking.value = false;
        ttsLevel.value = 0;
        // Clean up the temp WAV.
        try {
          File(path).delete().ignore();
        } catch (_) {}
      }
      return true;
    } catch (_) {
      isSpeaking.value = false;
      ttsLevel.value = 0;
      try {
        File(path).delete().ignore();
      } catch (_) {}
      return false;
    }
  }

  /// Plays [say] with the cloud neural voice. Returns false (without
  /// speaking) if synthesis or playback fails, so the caller can fall back.
  Future<bool> _speakCloud(String say) async {
    final path = await _synthCloud(say);
    if (path == null) return false;
    return _playCloudFile(path);
  }

  /// Pre-synthesizes cloud audio for [text] so playback can begin the instant
  /// it's this sentence's turn. Pipelining the NEXT sentence's synthesis while
  /// the current one plays removes the multi-second gap that used to fall
  /// before EVERY spoken sentence. Returns a playable file path, or null when
  /// the cloud voice is unavailable (caller should fall back to [speak]).
  Future<String?> prefetchSpeech(String text) async {
    if (!cloudVoiceEnabled || _cloudInCooldown) return null;
    if (PhoneStateGuard.instance.inCall) return null;
    final say = sanitizeForSpeech(text);
    if (say.isEmpty) return null;
    return _synthCloud(say);
  }

  /// Speaks [text], using [prefetchedPath] if one was prepared by
  /// [prefetchSpeech] (instant playback — no synthesis wait). Falls back to
  /// normal synthesis / the on-device voice exactly like [speak] when no
  /// prefetch is available or playback fails.
  Future<void> speakPrefetched(String text, String? prefetchedPath) async {
    if (PhoneStateGuard.instance.inCall) {
      if (prefetchedPath != null) discardPrefetched(prefetchedPath);
      return;
    }
    if (prefetchedPath == null) {
      await speak(text);
      return;
    }
    final ok = await _playCloudFile(prefetchedPath);
    if (ok) {
      _cloudVoiceFailedAt = null; // cloud voice reachable
      return;
    }
    // Playback of the prefetched clip failed — read this sentence with the
    // on-device voice rather than dropping it.
    await _speakLocal(sanitizeForSpeech(text));
  }

  /// Deletes an unplayed prefetched clip (barge-in / cancel cleanup) so temp
  /// WAVs don't pile up when a reply is cut short.
  void discardPrefetched(String path) {
    try {
      File(path).delete().ignore();
    } catch (_) {}
  }

  /// The on-device engine (offline / fallback path).
  Future<void> _speakLocal(String say) async {
    await _applyLanguageFor(say);
    // Some Android TTS engines drop a new utterance if one is already
    // playing (instead of replacing it) — another "went silent" case.
    try {
      await _tts.stop();
    } catch (_) {}
    await _tts.speak(say);
  }

  /// ISO-639-1 code for the reply's language (for the cloud voice accent).
  static String? _langIso(String text) {
    final tag = detectLanguage(text); // e.g. 'kn-IN'
    final code = tag.split(RegExp('[-_]')).first.toLowerCase();
    return code.length == 2 ? code : null;
  }

  // ---------------- BARGE-IN (talk over Hari to interrupt) ----------------
  // While Hari is speaking, we quietly monitor the mic. Hardware echo
  // cancellation removes most of Hari's own voice, so when the USER starts
  // talking their voice stands out above the residual. A sustained rise =>
  // the user wants to interrupt: we fire [onBargeIn], and the controller
  // stops the reply and starts listening for the new question.

  bool _monitoring = false;
  bool _bargedIn = false;
  Timer? _monitorTimer;

  /// True if the most recent speaking phase was cut off by the user talking.
  bool get lastSpeakInterrupted => _bargedIn;

  /// Begins listening for a barge-in. Safe to call repeatedly; best-effort
  /// (silently does nothing if the mic can't be opened alongside playback).
  ///
  /// Implementation note: this used to record an .m4a file it never read
  /// (only the amplitude meter was used). On budget devices that churned
  /// the hardware AAC encoder every reply and produced the native errors
  ///   E/MPEG4Writer: Stop() called but track is not started
  ///   Failed to query component interface for required system resources
  /// A raw PCM stream needs no encoder, no muxer and no file — the level is
  /// computed here from the samples — so those errors cannot occur, and the
  /// codec stays free for TTS playback.
  Future<void> startBargeInMonitor(void Function() onBargeIn) async {
    if (_monitoring) return;
    _bargedIn = false;
    try {
      if (!await _rec.hasPermission()) return;
      if (await _rec.isRecording()) return; // capture in progress — skip
      _monitoring = true;

      final stream = await _rec.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
          echoCancel: true, // cancel Hari's own voice from the mic
          noiseSuppress: true,
          androidConfig: AndroidRecordConfig(
            audioSource: AndroidAudioSource.voiceCommunication,
          ),
        ),
      );

      // Calibrate the residual-echo/ambient floor over the first chunks,
      // then watch for the user's voice rising clearly and steadily above
      // it. Levels come straight from the PCM samples (RMS -> dBFS).
      var baseline = -50.0;
      var calib = 0;
      var loudMs = 0;
      var lastChunkAt = DateTime.now();
      _monitorSub = stream.listen((chunk) {
        if (!_monitoring) return;
        final now = DateTime.now();
        final dt =
            now.difference(lastChunkAt).inMilliseconds.clamp(1, 500).toInt();
        lastChunkAt = now;

        final db = _pcmDb(chunk);
        if (!db.isFinite) return;
        if (calib < 4) {
          baseline = calib == 0 ? db : (baseline * 0.6 + db * 0.4);
          calib++;
          return;
        }
        // User speaking OVER Hari: well above the echo floor AND above an
        // absolute gate (so quiet room tone never triggers).
        if (db > baseline + 12 && db > -38) {
          loudMs += dt;
          if (loudMs >= 300) {
            // ~300 ms of real talk-over — treat as an interrupt.
            _bargedIn = true;
            _monitoring = false;
            _monitorSub?.cancel();
            _monitorSub = null;
            () async {
              try {
                if (await _rec.isRecording()) await _rec.stop();
              } catch (_) {}
              try {
                await _player.stop();
              } catch (_) {}
              try {
                await _tts.stop();
              } catch (_) {}
              onBargeIn();
            }();
          }
        } else {
          loudMs = (loudMs - dt).clamp(0, 100000).toInt();
        }
      }, onError: (_) {
        _monitoring = false;
      });
    } catch (_) {
      _monitoring = false;
    }
  }

  StreamSubscription<List<int>>? _monitorSub;

  /// dBFS of a 16-bit little-endian PCM chunk (RMS).
  static double _pcmDb(List<int> chunk) {
    if (chunk.length < 2) return double.negativeInfinity;
    var sum = 0.0;
    var n = 0;
    for (var i = 0; i + 1 < chunk.length; i += 2) {
      var s = chunk[i] | (chunk[i + 1] << 8);
      if (s >= 0x8000) s -= 0x10000; // sign-extend
      sum += (s * s).toDouble();
      n++;
    }
    if (n == 0) return double.negativeInfinity;
    final rms = math.sqrt(sum / n);
    if (rms <= 0) return -120.0;
    return 20 * math.log(rms / 32768.0) / math.ln10;
  }

  /// Stops the barge-in monitor and releases the mic (so a capture can
  /// grab it next). Returns whether a barge-in was detected.
  Future<bool> stopBargeInMonitor() async {
    _monitoring = false;
    _monitorTimer?.cancel();
    _monitorTimer = null;
    await _monitorSub?.cancel();
    _monitorSub = null;
    try {
      if (await _rec.isRecording()) await _rec.stop();
    } catch (_) {}
    return _bargedIn;
  }

  /// Cleans a reply before it is read aloud (the FULL text is still
  /// shown in the transcript card):
  ///  • If the reply is mostly in a non-Latin script (Kannada, Hindi…),
  ///    drop parenthesised Latin-only chunks — models love adding
  ///    "(Namaskara! ...)" transliterations, which made TTS speak the
  ///    answer twice, once in the language and once in English.
  ///  • Strip leftover markdown symbols that TTS would read out.
  static String sanitizeForSpeech(String text) {
    var t = text.trim();
    if (t.isEmpty) return t;

    final lang = detectLanguage(t);
    final nonLatin = !lang.startsWith('en') && _scriptRanges.containsKey(lang);
    if (nonLatin) {
      t = t.replaceAllMapped(RegExp(r'[(（]([^)）]*)[)）]'), (m) {
        final inside = m[1] ?? '';
        var latin = 0, other = 0;
        for (final c in inside.runes) {
          if ((c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)) {
            latin++;
          } else if (c > 0x7F) {
            other++;
          }
        }
        // Latin-only chunk inside a non-Latin reply = transliteration.
        return (latin > 0 && other == 0) ? '' : m[0]!;
      });
    }
    t = t.replaceAll(RegExp(r'[*_#`>|]+'), ' ');
    t = t.replaceAll(RegExp(r'\s{2,}'), ' ').trim();
    return t;
  }

  Future<void> stopSpeaking() async {
    isSpeaking.value = false;
    ttsLevel.value = 0;
    try {
      await _player.stop();
    } catch (_) {}
    try {
      await _tts.stop();
    } catch (_) {}
  }
}
