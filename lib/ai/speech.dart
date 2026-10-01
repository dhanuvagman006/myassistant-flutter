// SPEECH OUT — Gemini TTS through Firebase AI Logic (firebase_ai: a TTS
// model, responseModalities audio + SpeechConfig voice/language): every
// spoken reply is voiced here; model, voice and language come from
// /ai/config.
//
// The reply is cut into sentences and the FIRST one is synthesised on its
// own, so playback starts while the rest is made (two at a time, handed
// out in order). Each sentence comes back as PCM16 mono (raw, or in a WAV
// as 3.8 Flash TTS answers), which the app's existing player plays through
// an [AudioSink]. [cancel] is the barge-in: nothing more is handed out.
//
// Every sentence is asked for in the reply's tone ("Say in a bright and
// sunny voice: ...", which the model follows and does not read out) and
// keeps its vocal expressions (<sigh>, <chuckles>...; see speech_markup).
import 'dart:async';
import 'dart:typed_data';

import 'package:firebase_ai/firebase_ai.dart';

import '../core/log.dart';
import 'config.dart';
import 'model_port.dart';
import 'speech_markup.dart';

/// Where spoken audio goes: the app's PCM player (wired by the engine).
abstract interface class AudioSink {
  /// Queue [pcm16] (mono, [sampleRate] Hz) after whatever is queued.
  Future<void> play(Uint8List pcm16, {required int sampleRate});

  /// Stop at once and drop everything queued (barge-in).
  Future<void> stop();
}

/// One synthesised sentence.
class SpeechChunk {
  const SpeechChunk({
    required this.index,
    required this.text,
    required this.pcm,
    this.sampleRate = 24000,
  });

  /// Position in the reply (0 = first sentence).
  final int index;
  final String text;
  final Uint8List pcm;
  final int sampleRate;
}

class SpeechEngine {
  SpeechEngine({
    required this.port,
    AiConfig Function()? config,
    this.timeout = const Duration(seconds: 15),
    this.parallel = 2,
  }) : _config = config ?? (() => AiConfigStore.instance.current);

  final ModelPort port;
  final AiConfig Function() _config;

  /// The most one sentence may take to synthesise.
  final Duration timeout;

  /// Sentences synthesised at once after the first.
  final int parallel;

  var _generation = 0;

  // ------------------------------------------------------------ text

  static final _url = RegExp(r'https?://\S+');
  static final _mdLink = RegExp(r'\[([^\]]+)\]\([^)]*\)');
  static final _marks = RegExp(r'[*_`#>|~]+');
  static final _bullet = RegExp(r'^\s*(?:[-•]|\d+[.)])\s+', multiLine: true);

  static final _markTag = RegExp(r'<\s*([a-zA-Z][a-zA-Z \-]{0,30}?)\s*>');

  /// The reply as it should be SAID: no markdown, no URLs; its vocal
  /// expressions kept for the speech model.
  static String forSpeech(String text) {
    final kept = <String>[];
    final guarded = text.replaceAllMapped(_markTag, (m) {
      if (!SpeechMarkup.isExpression(m[1]!) || kept.length > 0x1000) return m[0]!;
      kept.add('<${m[1]!.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ')}>');
      return String.fromCharCode(0xE000 + kept.length - 1);
    });
    return guarded
        .replaceAllMapped(_mdLink, (m) => m[1]!)
        .replaceAll(_url, '')
        .replaceAll(_bullet, '')
        .replaceAll(_marks, '')
        .replaceAll(RegExp(r'[ \t]+'), ' ')
        .trim()
        .replaceAllMapped(RegExp('[\uE000-\uF000]'), (m) {
      final i = m[0]!.codeUnitAt(0) - 0xE000;
      return i < kept.length ? kept[i] : '';
    });
  }

  /// What the speech model is asked to say.
  ///
  /// THE WORDS ALONE (2026-09-30). Gemini 3.8 TTS treats its input as a
  /// verbatim transcript, and a "Say in a warm voice:" lead-in was spoken
  /// aloud — measured through our own Firebase endpoint: "Say in a calm
  /// voice. Done, your reminder is set…" (6.8 s of audio for a 4.4 s line).
  /// The tone now comes from the reply's own wording and its vocal
  /// expressions (<sigh>, <short pause>…), which 3.8 performs. The 2.5
  /// preview models still get the lead-in: without it they could answer a
  /// bare sentence as text.
  static String prompt(String sentence, String style, {String model = ''}) {
    if (!model.contains('2.5')) return sentence;
    final s = style.trim();
    return s.isEmpty ? 'Say: $sentence' : 'Say in a $s voice: $sentence';
  }

  /// The language to ask the speech model for: the configured one for text
  /// in Latin script; none for Malayalam, Hindi, Tamil and other scripts,
  /// where the model detects the language itself (Firebase advises not to
  /// set one when a request mixes languages).
  static String? languageFor(String text, String configured) =>
      RegExp('[\u0900-\u0DFF]').hasMatch(text) ? null : configured;

  static final _end = RegExp('[.!?।॥]+["\'”’)\\]]*\\s+');
  static final _lastWord = RegExp(r'([\p{L}.]+)$', unicode: true);
  static final _initial = RegExp(r'^\p{Lu}$', unicode: true);
  static const _abbreviations = {
    'mr', 'mrs', 'ms', 'dr', 'st', 'sr', 'jr', 'vs', 'etc', 'eg', 'ie', 'no',
    'prof', 'rs', 'approx', 'dept', 'govt', 'ltd', 'inc',
  };

  static List<String> _splitLine(String line) {
    final out = <String>[];
    var start = 0;
    for (final m in _end.allMatches(line)) {
      if (line[m.start] == '.') {
        final word = _lastWord.firstMatch(line.substring(start, m.start))?.group(1) ?? '';
        final bare = word.replaceAll('.', '').toLowerCase();
        if (_abbreviations.contains(bare) || _initial.hasMatch(word)) continue;
      }
      final s = line.substring(start, m.end).trim();
      if (s.isNotEmpty) out.add(s);
      start = m.end;
    }
    final rest = line.substring(start).trim();
    if (rest.isNotEmpty) out.add(rest);
    return out;
  }

  /// At most this many characters in one speech request after the first.
  static const maxPiece = 600;

  /// What is sent to the speech model, in order: the first sentence alone,
  /// so its audio can start at once, then the rest together.
  ///
  /// ONE VOICE, NOT ONE PER SENTENCE (2026-09-30). Each sentence used to be
  /// its own request, and the voice started its intonation afresh every
  /// time — the "reading aloud" sound the client called robotic. Google's
  /// guidance for voice agents is one request per turn; the first sentence
  /// stays apart only so the reply does not wait for all of it. (It also
  /// spends the speech quota half as fast.)
  static List<String> pieces(String text) {
    final all = sentences(text);
    if (all.length <= 1) return all;
    final out = [all.first];
    var rest = '';
    for (final x in all.skip(1)) {
      if (rest.isNotEmpty && rest.length + 1 + x.length > maxPiece) {
        out.add(rest);
        rest = x;
      } else {
        rest = rest.isEmpty ? x : '$rest $x';
      }
    }
    if (rest.isNotEmpty) out.add(rest);
    return out;
  }

  /// The reply's sentences, in order. A new line always ends one; "Dr.",
  /// "Rs. 500", "3.5" and initials do not. Pieces shorter than [minChars]
  /// join their neighbour, so a reply is not dozens of tiny requests.
  /// Pieces shorter than this join a neighbour.
  static const minChars = 24;

  static List<String> sentences(String text, {int minChars = SpeechEngine.minChars}) {
    final pieces = <String>[
      for (final line in text.split(RegExp(r'\n+')))
        if (line.trim().isNotEmpty) ..._splitLine(line.trim()),
    ];
    final merged = <String>[];
    for (final p in pieces) {
      if (merged.isNotEmpty && merged.last.length < minChars) {
        merged[merged.length - 1] = '${merged.last} $p';
      } else {
        merged.add(p);
      }
    }
    if (merged.length > 1 && merged.last.length < minChars) {
      final last = merged.removeLast();
      merged[merged.length - 1] = '${merged.last} $last';
    }
    return merged;
  }

  /// Sample rate from "audio/L16;codec=pcm;rate=24000" (24 kHz if absent).
  static int sampleRateOf(String mimeType) =>
      int.tryParse(RegExp(r'rate=(\d+)').firstMatch(mimeType)?.group(1) ?? '') ?? 24000;

  /// The PCM16 inside a WAV file and its sample rate; null when [bytes] is
  /// not one. A data chunk sized 0 or past the end runs to the end (a WAV
  /// written as it streams).
  static (Uint8List, int)? fromWav(Uint8List bytes) {
    String id(int at) => String.fromCharCodes(bytes.sublist(at, at + 4));
    if (bytes.length < 12 || id(0) != 'RIFF' || id(8) != 'WAVE') return null;
    final data = ByteData.sublistView(bytes);
    var rate = 24000;
    var at = 12;
    while (at + 8 <= bytes.length) {
      final size = data.getUint32(at + 4, Endian.little);
      final body = at + 8;
      final name = id(at);
      if (name == 'fmt ' && body + 8 <= bytes.length) {
        rate = data.getUint32(body + 4, Endian.little);
      } else if (name == 'data') {
        final end = size == 0 || body + size > bytes.length ? bytes.length : body + size;
        return (Uint8List.sublistView(bytes, body, end), rate);
      }
      at = body + size + (size.isOdd ? 1 : 0);
    }
    return null;
  }

  /// One response's audio parts as PCM16 and their rate.
  static (Uint8List, int) pcmOf(List<InlineDataPart> audio) {
    final out = BytesBuilder(copy: false);
    int? rate;
    for (final p in audio) {
      final wav = fromWav(p.bytes);
      out.add(wav?.$1 ?? p.bytes);
      rate ??= wav?.$2 ?? sampleRateOf(p.mimeType);
    }
    return (out.takeBytes(), rate ?? 24000);
  }

  // ------------------------------------------------------------ audio

  /// Replies being spoken now (so a barge-in stops every one of them).
  final _open = <SpeechStream>{};

  /// A reply to speak as it is written: see [SpeechStream]. [style] is its
  /// tone ("bright and sunny"); without one, the configured default.
  SpeechStream open({String? style}) {
    final given = (style ?? '').trim();
    final s = SpeechStream._(this, given.isNotEmpty ? given : _config().models.ttsStyle, _generation);
    _open.add(s);
    s._done.future.whenComplete(() => _open.remove(s));
    return s;
  }

  /// Gets the speech model's connection and tokens ready.
  Future<void> warmUp() => port.warmUp();

  /// Each sentence's audio, in order, as it streams in; a sentence that
  /// cannot be made is skipped.
  Stream<SpeechChunk> synthesizeChunks(String text, {String? style}) {
    final s = open(style: style);
    for (final p in pieces(forSpeech(text))) {
      s.add(p);
    }
    s.close();
    final out = StreamController<SpeechChunk>();
    out
      ..onListen = () {
        s.release(null, onChunk: out.add).whenComplete(out.close);
      }
      ..onCancel = s.cancel;
    return out.stream;
  }

  /// [synthesizeChunks], as the PCM bytes alone.
  Stream<Uint8List> synthesize(String text, {String? style}) =>
      synthesizeChunks(text, style: style).map((c) => c.pcm);

  /// Synthesise and play through [sink]. Returns how many pieces of audio
  /// were handed to it.
  Future<int> speak(
    String text,
    AudioSink sink, {
    String? style,
    void Function(SpeechChunk chunk)? onChunk,
  }) {
    final s = open(style: style);
    for (final p in pieces(forSpeech(text))) {
      s.add(p);
    }
    s.close();
    return s.release(sink, onChunk: onChunk);
  }

  /// Barge-in: nothing more is synthesised or handed out; [sink] (when
  /// given) stops at once.
  Future<void> cancel({AudioSink? sink}) async {
    _generation++;
    for (final s in List.of(_open)) {
      s.cancel();
    }
    if (sink != null) {
      try {
        await sink.stop();
      } catch (_) {}
    }
  }
}

/// One sentence of a [SpeechStream].
class _Part {
  _Part(this.index, this.text);
  final int index;
  final String text;
  final chunks = <Uint8List>[];
  int rate = 24000;
  int handed = 0;
  bool finished = false;
}

/// A reply spoken while it is still being written (brain.dart).
///
/// Sentences are [add]ed as the model finishes them and synthesised at once,
/// streamed, [SpeechEngine.parallel] at a time, so the audio is ready before
/// it is needed. Nothing plays until [release] (the brain calls it once the
/// server has checked the reply); then every piece of audio goes to the
/// sink as soon as it exists and the sentences before it have been handed
/// over, with no gap between them. [cancel] drops everything.
class SpeechStream {
  SpeechStream._(this._engine, this.style, this._generation);

  final SpeechEngine _engine;

  /// The reply's tone. Only the 2.5 speech models are told it (in words);
  /// see [SpeechEngine.prompt].
  final String style;
  final int _generation;

  final _parts = <_Part>[];
  final _subs = <StreamSubscription<GenerateContentResponse>>{};
  final _done = Completer<int>();
  var _next = 0;
  var _started = 0;
  var _running = 0;
  var _handed = 0;
  var _closed = false;
  var _released = false;
  var _cancelled = false;
  AudioSink? _sink;
  void Function(SpeechChunk chunk)? _onChunk;
  Future<void> _queue = Future<void>.value();

  bool get _dead => _cancelled || _generation != _engine._generation;

  /// How many sentences it holds.
  int get length => _parts.length;

  /// A finished sentence; its audio is asked for at once.
  void add(String sentence) {
    final text = sentence.trim();
    if (_closed || _dead || text.isEmpty) return;
    _parts.add(_Part(_parts.length, text));
    _startMore();
  }

  /// No more sentences.
  void close() {
    _closed = true;
    _pump();
  }

  /// Plays what is ready and everything after it, in order, into [sink]
  /// (none: [onChunk] only). Completes with how many pieces of audio were
  /// handed over, once the last is.
  Future<int> release(AudioSink? sink, {void Function(SpeechChunk chunk)? onChunk}) {
    _sink = sink;
    _onChunk = onChunk;
    _released = true;
    _pump();
    return _done.future;
  }

  /// Drops everything: nothing more is asked for or played.
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final s in List.of(_subs)) {
      s.cancel().ignore();
    }
    _subs.clear();
    if (!_done.isCompleted) _done.complete(_handed);
  }

  void _startMore() {
    while (!_dead && _running < _engine.parallel && _started < _parts.length) {
      final p = _parts[_started++];
      _running++;
      _synth(p).whenComplete(() {
        _running--;
        p.finished = true;
        _startMore();
        _pump();
      });
    }
  }

  /// [p]'s audio, streamed; once more when the first try brought none.
  Future<void> _synth(_Part p) async {
    for (var attempt = 0; attempt < 2 && !_dead && p.chunks.isEmpty; attempt++) {
      await _stream(p);
    }
  }

  Future<void> _stream(_Part p) {
    final cfg = _engine._config();
    final done = Completer<void>();
    StreamSubscription<GenerateContentResponse>? sub;
    Timer? firstAudio;
    Timer? whole;
    void finish() {
      firstAudio?.cancel();
      whole?.cancel();
      final s = sub;
      if (s != null) _subs.remove(s);
      if (!done.isCompleted) done.complete();
    }

    void stop() {
      sub?.cancel().ignore();
      finish();
    }

    // No sound within the limit: the sentence is asked for again, then
    // skipped. A stream that stalls midway ends where it stalled.
    // Why a sentence went unspoken reaches the log (tester run 2026-10-01:
    // "error tts" with no cause behind it).
    firstAudio = Timer(_engine.timeout, () {
      AppLog.add('tts', 'sentence ${p.index}: no audio in ${_engine.timeout.inSeconds}s');
      stop();
    });
    whole = Timer(_engine.timeout * 3, () {
      AppLog.add('tts', 'sentence ${p.index}: stalled midway');
      stop();
    });
    sub = _engine.port
        .stream(ModelRequest(
          model: cfg.models.tts,
          contents: [
            Content.text(SpeechEngine.prompt(p.text, style, model: cfg.models.tts)),
          ],
          generationConfig: GenerationConfig(
            responseModalities: [ResponseModalities.audio],
            speechConfig: SpeechConfig(
              voiceName: cfg.models.ttsVoice,
              languageCode: SpeechEngine.languageFor(p.text, cfg.models.ttsLanguage),
            ),
          ),
        ))
        .listen(
      (resp) {
        if (_dead) return stop();
        final audio = [
          for (final part in resp.inlineDataParts)
            if (part.mimeType.toLowerCase().startsWith('audio/')) part,
        ];
        if (audio.isEmpty) return;
        final (pcm, rate) = SpeechEngine.pcmOf(audio);
        if (pcm.isEmpty) return;
        firstAudio?.cancel();
        p.rate = rate;
        p.chunks.add(pcm);
        _pump();
      },
      onError: (Object e) {
        AppLog.add('tts', 'sentence ${p.index} failed: ${e.runtimeType} ${e.toString().replaceAll(RegExp(r'\s+'), ' ').substring(0, e.toString().length.clamp(0, 140))}');
        finish();
      },
      onDone: finish,
      cancelOnError: true,
    );
    _subs.add(sub);
    return done.future;
  }

  void _pump() {
    if (_dead) {
      if (!_done.isCompleted) _done.complete(_handed);
      return;
    }
    if (!_released) return;
    while (_next < _parts.length) {
      final p = _parts[_next];
      while (p.handed < p.chunks.length) {
        final pcm = p.chunks[p.handed++];
        _handed++;
        _onChunk?.call(SpeechChunk(index: p.index, text: p.text, pcm: pcm, sampleRate: p.rate));
        final sink = _sink;
        if (sink != null) {
          final rate = p.rate;
          _queue = _queue.then((_) async {
            if (!_dead) await sink.play(pcm, sampleRate: rate);
          }).catchError((Object _) {});
        }
      }
      if (!p.finished) return; // more of this sentence is on its way
      _next++;
    }
    if (_closed && _running == 0 && !_done.isCompleted) {
      _queue.whenComplete(() {
        if (!_done.isCompleted) _done.complete(_handed);
      });
    }
  }
}
