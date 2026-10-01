// SPEECH IN — the phone's own speech recogniser (speech_to_text), on-device
// when it can, in the user's language (config.models.ttsLanguage), with
// partial words for the captions and the end of speech for the turn.
//
// When the phone has no recogniser at all, the words are recorded instead
// and written down by a cloud model through Firebase AI Logic
// (config.models.cloudFast): the fallback, never the first choice.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:firebase_ai/firebase_ai.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import 'config.dart';
import 'model_port.dart';

sealed class HearEvent {
  const HearEvent();
}

/// The words so far (captions).
final class HearPartial extends HearEvent {
  const HearPartial(this.text);
  final String text;
}

/// What the user said ('' when nothing was heard). Always the last event.
final class HearFinal extends HearEvent {
  const HearFinal(this.text, {this.fromCloud = false, this.audio});
  final String text;
  final bool fromCloud;

  /// What the microphone recorded, when the turn was recorded (record
  /// mode): the engine sends it for review once the turn has a name.
  final RecordedAudio? audio;
}

/// The microphone level, 0..1 (the orb).
final class HearLevel extends HearEvent {
  const HearLevel(this.level);
  final double level;
}

/// The user stopped talking; the final words follow.
final class HearEndOfSpeech extends HearEvent {
  const HearEndOfSpeech();
}

/// Listening failed ('permission', 'unavailable', 'network', 'recorder', …).
final class HearError extends HearEvent {
  const HearError(this.code, {this.permanent = false});
  final String code;
  final bool permanent;
}

/// The recogniser, as the listener needs it (speech_to_text, or a fake).
abstract interface class RecognizerPort {
  Future<bool> initialize({
    required void Function(String status) onStatus,
    required void Function(String error, bool permanent) onError,
  });

  Future<List<String>> localeIds();

  Future<void> listen({
    required void Function(String words, bool isFinal) onResult,
    void Function(double level)? onLevel,
    String? localeId,
    required bool onDevice,
    required Duration listenFor,
    required Duration pauseFor,
  });

  Future<void> stop();
  Future<void> cancel();
}

/// speech_to_text. Its SpeechToText is one object for the whole app, so the
/// status and error listeners are taken over for each session.
class SpeechToTextRecognizer implements RecognizerPort {
  SpeechToTextRecognizer([stt.SpeechToText? speech]) : _stt = speech ?? stt.SpeechToText();

  final stt.SpeechToText _stt;
  void Function(String)? _onStatus;
  void Function(String, bool)? _onError;

  // Asking for them spins up a recogniser of its own each time; the list
  // does not change while the app runs.
  List<String>? _locales;

  void _attach() {
    _stt.statusListener = (s) => _onStatus?.call(s);
    _stt.errorListener = (e) => _onError?.call(e.errorMsg, e.permanent);
  }

  @override
  Future<bool> initialize({
    required void Function(String status) onStatus,
    required void Function(String error, bool permanent) onError,
  }) async {
    _onStatus = onStatus;
    _onError = onError;
    try {
      final ok = await _stt.initialize(
        onStatus: (s) => _onStatus?.call(s),
        onError: (e) => _onError?.call(e.errorMsg, e.permanent),
      );
      _attach();
      return ok;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<List<String>> localeIds() async {
    final known = _locales;
    if (known != null) return known;
    try {
      final ids = [for (final l in await _stt.locales()) l.localeId];
      if (ids.isNotEmpty) _locales = ids;
      return ids;
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<void> listen({
    required void Function(String words, bool isFinal) onResult,
    void Function(double level)? onLevel,
    String? localeId,
    required bool onDevice,
    required Duration listenFor,
    required Duration pauseFor,
  }) async {
    _attach();
    await _stt.listen(
      onResult: (r) => onResult(r.recognizedWords, r.finalResult),
      // Android reports roughly -2..10 dB.
      onSoundLevelChange:
          onLevel == null ? null : (db) => onLevel(((db + 2) / 12).clamp(0.0, 1.0)),
      listenOptions: stt.SpeechListenOptions(
        localeId: localeId,
        onDevice: onDevice,
        partialResults: true,
        listenMode: stt.ListenMode.dictation,
        // The listener recovers from errors itself; the plugin's own stop
        // on error could land on the session that replaced the failed one.
        cancelOnError: false,
        listenFor: listenFor,
        pauseFor: pauseFor,
      ),
    );
  }

  @override
  Future<void> stop() => _stt.stop();

  @override
  Future<void> cancel() => _stt.cancel();
}

/// Recorded speech for the cloud fallback.
class RecordedAudio {
  const RecordedAudio(this.bytes, this.mimeType);
  final Uint8List bytes;
  final String mimeType;
}

abstract interface class RecorderPort {
  /// False when the microphone cannot be used.
  Future<bool> start();

  /// 0..1 while recording.
  Stream<double> get levels;
  Future<RecordedAudio?> stop();
  Future<void> cancel();
}

/// The `record` package: 16 kHz mono WAV in the temp folder, deleted once
/// read.
class RecordRecorder implements RecorderPort {
  final AudioRecorder _rec = AudioRecorder();
  final _levels = StreamController<double>.broadcast();
  StreamSubscription<Amplitude>? _amp;
  String? _path;

  @override
  Stream<double> get levels => _levels.stream;

  @override
  Future<bool> start() async {
    try {
      if (!await _rec.hasPermission()) return false;
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/hari_listen_${DateTime.now().millisecondsSinceEpoch}.wav';
      _path = path;
      // Never paused by a notification sound (MicStream.config says why).
      await _rec.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 16000,
          numChannels: 1,
          audioInterruption: AudioInterruptionMode.none,
        ),
        path: path,
      );
      // dBFS: speech sits around -30..-10, silence below -50.
      _amp = _rec
          .onAmplitudeChanged(const Duration(milliseconds: 100))
          .listen((a) => _levels.add(((a.current + 50) / 50).clamp(0.0, 1.0)));
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<RecordedAudio?> stop() async {
    await _amp?.cancel();
    _amp = null;
    try {
      final path = await _rec.stop() ?? _path;
      if (path == null) return null;
      final file = File(path);
      final bytes = await file.readAsBytes();
      unawaited(file.delete().then((_) {}, onError: (_) {}));
      return RecordedAudio(bytes, 'audio/wav');
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> cancel() async {
    await _amp?.cancel();
    _amp = null;
    try {
      await _rec.cancel();
    } catch (_) {}
  }
}

/// Writes recorded speech down with a fast cloud model.
class CloudTranscriber {
  CloudTranscriber({
    required this.port,
    AiConfig Function()? config,
    this.timeout = const Duration(seconds: 20),
  }) : _config = config ?? (() => AiConfigStore.instance.current);

  final ModelPort port;
  final AiConfig Function() _config;
  final Duration timeout;

  static String instruction(String language) =>
      'Transcribe the speech in this recording exactly as it was said, in the '
      "language it was spoken in, written in that language's own script. The "
      "speaker's usual language is $language. Reply with the words only: no "
      'quotes, labels or notes. If there is no speech, reply with nothing.';

  Future<String> transcribe(Uint8List audio, String mimeType, {String? languageCode}) async {
    final cfg = _config();
    try {
      final resp = await port
          .generate(ModelRequest(
            model: cfg.models.cloudFast,
            contents: [
              Content.multi([
                TextPart(instruction(languageCode ?? cfg.models.ttsLanguage)),
                InlineDataPart(mimeType, audio),
              ]),
            ],
          ))
          .timeout(timeout);
      return (resp.text ?? '').trim().replaceAll(RegExp(r'^["“]|["”]$'), '').trim();
    } catch (_) {
      return '';
    }
  }
}

/// The recogniser locale for a BCP-47 language: the exact one, else the
/// same language in another region, else null (the phone's default). An
/// empty list (some phones do not say) passes the language through.
String? resolveLocale(String? wanted, List<String> available) {
  if (wanted == null || wanted.trim().isEmpty) return null;
  String norm(String s) => s.replaceAll('_', '-').toLowerCase();
  if (available.isEmpty) return wanted;
  final w = norm(wanted);
  for (final a in available) {
    if (norm(a) == w) return a;
  }
  final lang = w.split('-').first;
  for (final a in available) {
    if (norm(a).split('-').first == lang) return a;
  }
  return null;
}

class VoiceListener {
  VoiceListener({
    RecognizerPort? recognizer,
    this.recorder,
    this.transcriber,
    AiConfig Function()? config,
    DateTime Function()? now,
    this.speechLevel = 0.35,
  })  : recognizer = recognizer ?? SpeechToTextRecognizer(),
        _config = config ?? (() => AiConfigStore.instance.current),
        _now = now ?? DateTime.now;

  /// The phone's recogniser, the recorder and a cloud transcriber together.
  factory VoiceListener.standard(ModelPort port) => VoiceListener(
        recorder: RecordRecorder(),
        transcriber: CloudTranscriber(port: port),
      );

  final RecognizerPort recognizer;
  final RecorderPort? recorder;
  final CloudTranscriber? transcriber;
  final AiConfig Function() _config;
  final DateTime Function() _now;

  /// The level (0..1) above which the cloud fallback counts it as speech.
  final double speechLevel;

  _Session? _session;

  /// One utterance: partial words, the end of speech, then [HearFinal] (or
  /// [HearError]), and the stream closes. [language] defaults to the
  /// configured one; the phone's recogniser is asked to work on-device
  /// first and, if it cannot, online.
  ///
  /// END OF SPEECH (2026-09-30, voice audit): [pauseFor] of no new words
  /// ends the utterance, timed from the owner's LAST words — the clock only
  /// starts once they have said something, so a slow start is never cut
  /// off. (The plugin's own pause timer runs from the moment it starts
  /// listening; it is only given [recognizerPause], a safety net.)
  Stream<HearEvent> listen({
    String? language,
    Duration listenFor = const Duration(seconds: 30),
    Duration pauseFor = const Duration(milliseconds: 800),
    bool preferOnDevice = true,
  }) {
    _session?.cancel();
    late final _Session s;
    final out = StreamController<HearEvent>(
      onListen: () => _run(s),
      onCancel: () => s.cancel(),
    );
    s = _Session(out, language ?? _config().models.ttsLanguage, listenFor, pauseFor,
        preferOnDevice);
    s.onPause = () async {
      if (!identical(_session, s) || s.cloud) return;
      try {
        await recognizer.stop();
      } catch (_) {}
    };
    _session = s;
    return out.stream;
  }

  /// The pause the phone's recogniser itself is given: long, because it
  /// counts from the start of listening, not from the last word.
  static const recognizerPause = Duration(seconds: 3);

  /// End now: the words heard so far become the final ones.
  Future<void> stop() async {
    final s = _session;
    if (s == null) return;
    s.endNow();
    if (!s.cloud) {
      try {
        await recognizer.stop();
      } catch (_) {}
    }
  }

  /// Drop this utterance.
  Future<void> cancel() async {
    final s = _session;
    _session = null;
    if (s == null) return;
    s.cancel();
    try {
      if (s.cloud) {
        await recorder?.cancel();
      } else {
        await recognizer.cancel();
      }
    } catch (_) {}
  }

  Future<void> _run(_Session s) async {
    bool ready;
    try {
      ready = await recognizer.initialize(onStatus: s.onStatus, onError: s.onError);
    } catch (_) {
      ready = false;
    }
    if (s.closed) return;
    if (!ready) return _runCloud(s);
    // RECORD MODE (served, 2026-10-01): record the turn and let Gemini
    // transcribe it in whatever language was spoken. The phone's own
    // recogniser stays as the fallback when the recorder will not start.
    final rec = recorder;
    if (rec != null && transcriber != null && _config().listen.record) {
      if (await rec.start()) return _runCloud(s, started: true);
      if (s.closed) return;
    }
    final locale = resolveLocale(s.language, await recognizer.localeIds());
    s.locale = locale;
    await _start(s, onDevice: s.preferOnDevice);
  }

  Future<void> _start(_Session s, {required bool onDevice}) async {
    s.onDevice = onDevice;
    // Again with the other kind of recogniser: speech_to_text makes a new
    // one only when the kind changes, and the one it keeps can fail at once
    // (Android 16's on-device service, after a conversation was stopped:
    // "server disconnected" before a word, every time).
    s.retry = () => _start(s, onDevice: !onDevice);
    final rec = recorder;
    final tr = transcriber;
    s.fallback = rec != null && tr != null ? () => _runCloud(s) : null;
    try {
      await recognizer.listen(
        onResult: s.onResult,
        onLevel: (l) => s.emit(HearLevel(l)),
        localeId: s.locale,
        onDevice: onDevice,
        listenFor: s.listenFor,
        pauseFor: s.pauseFor > recognizerPause ? s.pauseFor : recognizerPause,
      );
    } catch (_) {
      s.recover('unavailable');
    }
  }

  Future<void> _runCloud(_Session s, {bool started = false}) async {
    final rec = recorder;
    final tr = transcriber;
    s.cloud = true;
    if (rec == null || tr == null) return s.fail('unavailable', permanent: true);
    if (!started && !await rec.start()) return s.fail('recorder', permanent: true);
    if (s.closed) {
      await rec.cancel();
      return;
    }
    var heard = false;
    DateTime? quietSince;
    final limit = Timer(s.listenFor, s.endNow);
    final levels = rec.levels.listen((l) {
      s.emit(HearLevel(l));
      if (l >= speechLevel) {
        heard = true;
        quietSince = null;
      } else if (heard) {
        quietSince ??= _now();
        if (_now().difference(quietSince!) >= s.pauseFor) s.endNow();
      }
    });
    await s.ended.future;
    limit.cancel();
    await levels.cancel();
    if (s.closed) {
      await rec.cancel();
      return;
    }
    s.emit(const HearEndOfSpeech());
    final audio = await rec.stop();
    if (!heard || audio == null || audio.bytes.isEmpty) {
      return s.finish('', fromCloud: true);
    }
    final text = await tr.transcribe(audio.bytes, audio.mimeType, languageCode: s.language);
    s.finish(text, fromCloud: true, audio: audio);
  }
}

class _Session {
  _Session(this.out, this.language, this.listenFor, this.pauseFor, this.preferOnDevice);

  final StreamController<HearEvent> out;
  final String language;
  final Duration listenFor;
  final Duration pauseFor;
  final bool preferOnDevice;

  String? locale;
  bool onDevice = true;
  bool cloud = false;
  bool closed = false;
  bool _retried = false;
  bool _restarting = false;
  bool _endSent = false;
  String _words = '';
  Future<void> Function()? retry;

  /// Recorded speech written down in the cloud, when the phone's
  /// recogniser cannot be used.
  Future<void> Function()? fallback;
  final ended = Completer<void>();
  Timer? _grace;

  /// [pauseFor] after the last new words: the utterance is over.
  Timer? _pause;

  /// Stops the recogniser, so its final words come now.
  Future<void> Function()? onPause;

  /// How long after the recogniser stops before the words heard so far
  /// are final (its final result normally comes first). 2026-09-30: 150
  /// ms, down from 400 (voice audit).
  static const grace = Duration(milliseconds: 150);

  bool get heardWords => _words.trim().isNotEmpty;

  void emit(HearEvent e) {
    if (!closed) out.add(e);
  }

  void onResult(String words, bool isFinal) {
    if (closed) return;
    if (isFinal) return finish(words);
    if (words != _words) {
      _words = words;
      emit(HearPartial(words));
      if (!cloud && words.trim().isNotEmpty) _armPause();
    }
  }

  void _armPause() {
    _pause?.cancel();
    _pause = Timer(pauseFor, () {
      if (closed || cloud) return;
      if (!_endSent) {
        _endSent = true;
        emit(const HearEndOfSpeech());
      }
      _grace ??= Timer(grace, () => finish(_words));
      unawaited(onPause?.call());
    });
  }

  void onStatus(String status) {
    if (closed || cloud) return;
    if (status == 'listening') {
      _restarting = false;
      return;
    }
    // The failed on-device session's own 'done' must not end the retry.
    if (_restarting) return;
    if (status == 'done' || status == 'notListening') {
      // Nothing heard is no end of speech: an error may follow (the plugin
      // says "done" first) and the listening goes on.
      if (!_endSent && heardWords) {
        _endSent = true;
        emit(const HearEndOfSpeech());
      }
      // The final result normally comes first; if it does not, what was
      // heard is final once the recogniser has had a moment.
      _grace ??= Timer(grace, () => finish(_words));
    }
  }

  void onError(String error, bool permanent) {
    if (closed || cloud) return;
    final e = error.toLowerCase();
    if (e.contains('no_match') || e.contains('speech_timeout')) return finish(_words);
    if (heardWords) return finish(_words);
    final code = codeOf(e);
    // speech_to_text calls every Android error permanent, so the flag says
    // nothing here: only a refused microphone ends the listening at once.
    if (code == 'permission') return fail(code, permanent: true);
    recover(code);
  }

  /// What a recogniser error means to the user.
  static String codeOf(String error) => error.contains('permission')
      ? 'permission'
      : error.contains('network')
          ? 'network'
          : error.contains('language')
              ? 'language'
              : 'unavailable';

  /// The phone's recogniser failed before a word: a new one of the other
  /// kind, once; then recorded speech written down in the cloud; only then
  /// an error.
  void recover(String code) {
    if (closed || cloud) return;
    if (heardWords) return finish(_words);
    _grace?.cancel();
    _grace = null;
    final again = retry;
    if (!_retried && again != null) {
      _retried = true;
      _restarting = true;
      unawaited(again());
      return;
    }
    final next = fallback;
    if (next != null) {
      fallback = null;
      _restarting = true;
      unawaited(next());
      return;
    }
    fail(code);
  }

  void endNow() {
    if (!ended.isCompleted) ended.complete();
    if (!cloud) {
      _grace ??= Timer(grace, () => finish(_words));
    }
  }

  void finish(String words, {bool fromCloud = false, RecordedAudio? audio}) {
    if (closed) return;
    emit(HearFinal(words.trim(), fromCloud: fromCloud, audio: audio));
    _close();
  }

  void fail(String code, {bool permanent = false}) {
    if (closed) return;
    emit(HearError(code, permanent: permanent));
    _close();
  }

  void cancel() => _close();

  void _close() {
    if (closed) return;
    closed = true;
    _grace?.cancel();
    _pause?.cancel();
    if (!ended.isCompleted) ended.complete();
    out.close();
  }
}
