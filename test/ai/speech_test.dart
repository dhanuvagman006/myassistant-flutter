import 'dart:async';
import 'dart:typed_data';

import 'package:firebase_ai/firebase_ai.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/ai/config.dart';
import 'package:myassistant/ai/model_port.dart';
import 'package:myassistant/ai/speech.dart';

import 'fakes.dart';

const _config = AiConfig(
  models: AiModels(tts: 'tts-model', ttsVoice: 'Puck', ttsLanguage: 'ml-IN'),
);

String _prompt(ModelRequest r) => (r.contents.single.parts.single as TextPart).text;

/// The sentence asked for, without its delivery line.
String _said(ModelRequest r) => _prompt(r).replaceFirst(RegExp(r'^Say(?: in a .*? voice)?: '), '');

/// A WAV file of [pcm] at [rate] Hz, the way 3.8 Flash TTS answers.
Uint8List _wav(List<int> pcm, {int rate = 24000}) {
  final b = BytesBuilder()
    ..add('RIFF'.codeUnits)
    ..add(_u32(36 + pcm.length))
    ..add('WAVEfmt '.codeUnits)
    ..add(_u32(16))
    ..add([1, 0, 1, 0])
    ..add(_u32(rate))
    ..add(_u32(rate * 2))
    ..add([2, 0, 16, 0])
    ..add('data'.codeUnits)
    ..add(_u32(pcm.length))
    ..add(pcm);
  return b.toBytes();
}

List<int> _u32(int v) => [v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff];

void main() {
  group('sentences', () {
    test('ends at . ! ? and the danda, not inside numbers or after abbreviations', () {
      expect(
        SpeechEngine.sentences(
            'Dr. Rao will see you at 3.30 today. Bring Rs. 500 in cash! Is that fine? '
            'रिपोर्ट तैयार है। ठीक है, हम चलते हैं।',
            minChars: 1),
        [
          'Dr. Rao will see you at 3.30 today.',
          'Bring Rs. 500 in cash!',
          'Is that fine?',
          'रिपोर्ट तैयार है।',
          'ठीक है, हम चलते हैं।',
        ],
      );
    });

    test('initials and new lines', () {
      expect(SpeechEngine.sentences('J. K. Rowling wrote it.\nShe lives in Scotland', minChars: 1),
          ['J. K. Rowling wrote it.', 'She lives in Scotland']);
    });

    test('short pieces join a neighbour so a reply is not many tiny requests', () {
      expect(
        SpeechEngine.sentences('Sure! Here it is. The meeting is at five in the evening. Ok.'),
        ['Sure! Here it is. The meeting is at five in the evening. Ok.'],
      );
      expect(SpeechEngine.sentences(''), isEmpty);
      expect(SpeechEngine.sentences('Hi.'), ['Hi.']);
    });

    test('forSpeech drops markdown, bullets and links', () {
      expect(
        SpeechEngine.forSpeech('**Top picks**\n- [Café Coffee](https://x.example/a) is *nice*\n'
            '1. See https://y.example for more'),
        'Top picks\nCafé Coffee is nice\nSee for more',
      );
    });

    test('forSpeech keeps vocal expressions for the speech model, nothing else in brackets', () {
      expect(SpeechEngine.forSpeech('**Sorry** <Sigh> that is hard. <short  pause> Try *again*.'),
          'Sorry <sigh> that is hard. <short pause> Try again.');
      expect(SpeechEngine.forSpeech('a <b> c > d'), 'a <b c d', reason: 'not an expression: cleaned as before');
    });

    test('3.8 gets the words alone (a lead-in was spoken aloud); 2.5 keeps it', () {
      expect(SpeechEngine.prompt('Hello there.', 'bright and sunny'), 'Hello there.');
      expect(SpeechEngine.prompt('Hello there.', 'bright and sunny', model: 'gemini-3.8-flash-tts'),
          'Hello there.');
      expect(SpeechEngine.prompt('Hello there.', 'bright and sunny', model: 'gemini-2.5-flash-preview-tts'),
          'Say in a bright and sunny voice: Hello there.');
      expect(SpeechEngine.prompt('Hello there.', ' ', model: 'gemini-2.5-flash-preview-tts'),
          'Say: Hello there.');
    });

    test('the first sentence alone, the rest as one request', () {
      expect(SpeechEngine.pieces('One. Two is here now. Three is here too.'),
          ['One. Two is here now. Three is here too.'],
          reason: 'short sentences still join (minChars): one request');
      expect(SpeechEngine.pieces('The first sentence is here. The second one follows it. And a third.'),
          ['The first sentence is here.', 'The second one follows it. And a third.']);
      expect(SpeechEngine.pieces('Just the one sentence here.'), ['Just the one sentence here.']);
      final long = List.generate(40, (i) => 'Sentence number $i is right here.').join(' ');
      final parts = SpeechEngine.pieces(long);
      expect(parts.skip(1).every((x) => x.length <= SpeechEngine.maxPiece), isTrue);
      expect(parts.join(' '), long, reason: 'nothing lost or reordered');
    });

    test('Malayalam or Hindi text: the model picks the language itself', () {
      expect(SpeechEngine.languageFor('Your reminder is set.', 'en-IN'), 'en-IN');
      expect(SpeechEngine.languageFor('ശരി, ഞാൻ ഓർമ്മിപ്പിക്കാം.', 'en-IN'), isNull);
      expect(SpeechEngine.languageFor('ठीक है, मैं याद दिला दूँगी।', 'en-IN'), isNull);
    });

    test('WAV answers are unwrapped to PCM at their own rate', () {
      final (pcm, rate) = SpeechEngine.fromWav(_wav([1, 2, 3, 4], rate: 16000))!;
      expect(pcm, [1, 2, 3, 4]);
      expect(rate, 16000);
      expect(SpeechEngine.fromWav(Uint8List.fromList([1, 2, 3])), isNull);
      // Written as it streamed: a data size of 0 runs to the end.
      final streamed = _wav([5, 6]);
      streamed.setRange(40, 44, [0, 0, 0, 0]);
      expect(SpeechEngine.fromWav(streamed)!.$1, [5, 6]);
    });

    test('sample rate from the MIME type', () {
      expect(SpeechEngine.sampleRateOf('audio/L16;codec=pcm;rate=24000'), 24000);
      expect(SpeechEngine.sampleRateOf('audio/L16;rate=16000'), 16000);
      expect(SpeechEngine.sampleRateOf('audio/wav'), 24000);
    });
  });

  group('synthesis', () {

    test('expressions stay in the words; a WAV answer plays as its PCM', () async {
      final model = FakeModel([audioResponse(_wav([1, 2, 3, 4], rate: 24000), mime: 'audio/wav')]);
      final e = SpeechEngine(port: model, config: () => _config);
      final chunks = await e.synthesizeChunks('<sigh> I am so sorry about that.', style: 'warm').toList();
      expect(_prompt(model.requests.single), '<sigh> I am so sorry about that.');
      expect(chunks.single.pcm, [1, 2, 3, 4], reason: 'no header played as sound');
      expect(chunks.single.sampleRate, 24000);
    });

    test('the TTS request: model, voice, language, audio out', () async {
      final model = FakeModel([audioResponse([1, 2])]);
      final e = SpeechEngine(port: model, config: () => _config);
      final chunks = await e.synthesizeChunks('Hello, how are you today?').toList();
      expect(chunks.single.pcm, [1, 2]);
      expect(chunks.single.sampleRate, 24000);
      final r = model.requests.single;
      expect(r.model, 'tts-model');
      expect(_prompt(r), 'Hello, how are you today?',
          reason: 'the words alone: 3.8 speaks any lead-in aloud');
      final g = r.generationConfig!.toJson();
      expect(g['responseModalities'], ['AUDIO']);
      expect(g['speechConfig'], {
        'voice_config': {
          'prebuilt_voice_config': {'voice_name': 'Puck'},
        },
        'language_code': 'ml-IN',
      });
    });

    test('two sentences at a time, streamed; audio handed over in order, as it comes', () async {
      final streams = <String, StreamController<GenerateContentResponse>>{};
      final asked = <String>[];
      final model = FakeModel([
        for (var i = 0; i < 3; i++)
          (ModelRequest r) {
            final s = _said(r);
            asked.add(s);
            return (streams[s] = StreamController<GenerateContentResponse>()).stream;
          },
      ]);
      final e = SpeechEngine(port: model, config: () => _config);
      final got = <String>[];
      final done = Completer<void>();
      // Three pieces straight into a stream (a reply joins its sentences
      // after the first — pieces() — so this drives the stream itself).
      final st = e.open();
      for (final x in [
        'The first sentence is here.',
        'The second one follows it.',
        'And here is the third sentence.',
      ]) {
        st.add(x);
      }
      st.close();
      st
          .release(null, onChunk: (c) => got.add('${c.index}:${c.pcm.join(',')}'))
          .whenComplete(done.complete);
      await Future<void>.delayed(Duration.zero);
      expect(asked, ['The first sentence is here.', 'The second one follows it.']);

      // The second speaks first: it waits for the first.
      streams['The second one follows it.']!.add(audioResponse([2]));
      await Future<void>.delayed(Duration.zero);
      expect(got, isEmpty);
      streams['The first sentence is here.']!.add(audioResponse([1]));
      await Future<void>.delayed(Duration.zero);
      expect(got, ['0:1'], reason: 'audio goes out as it streams in');
      streams['The first sentence is here.']!.add(audioResponse([1, 1]));
      await streams['The first sentence is here.']!.close();
      await Future<void>.delayed(Duration.zero);
      expect(asked.length, 3, reason: 'the third is asked for once the first is done');
      expect(got, ['0:1', '0:1,1', '1:2']);
      await streams['The second one follows it.']!.close();
      streams['And here is the third sentence.']!.add(audioResponse([3]));
      await streams['And here is the third sentence.']!.close();
      await done.future;
      expect(got, ['0:1', '0:1,1', '1:2', '2:3']);
    });

    test('a refused sentence is retried once, then skipped', () async {
      var firstTries = 0;
      Object answer(ModelRequest r) {
        if (_said(r).startsWith('This first')) {
          return firstTries++ == 0 ? Exception('Model tried to generate text') : audioResponse([9]);
        }
        return Exception('never');
      }

      final model = FakeModel([answer, answer, answer, answer]);
      final e = SpeechEngine(port: model, config: () => _config);
      final chunks = await e
          .synthesizeChunks('This first sentence works fine. This second sentence never works.')
          .toList();
      expect(chunks.map((c) => c.text), ['This first sentence works fine.']);
      expect(model.requests.length, 4, reason: 'each sentence asked twice at most');
    });

    test('no sound within the limit: asked once more, then skipped', () async {
      final model = FakeModel([
        (ModelRequest _) => Completer<GenerateContentResponse>().future, // never
        audioResponse([2]),
        (ModelRequest _) => Completer<GenerateContentResponse>().future, // never again
      ]);
      final e = SpeechEngine(
          port: model, config: () => _config, timeout: const Duration(milliseconds: 30));
      final chunks = await e
          .synthesizeChunks('The first sentence is very slow. The second sentence is quick.')
          .toList();
      expect(chunks.map((c) => c.index), [1]);
      expect(model.requests.length, 3);
    });

    test('released only when the brain says so, and a cancel drops it all', () async {
      final model = FakeModel([audioResponse([1]), audioResponse([2])]);
      final e = SpeechEngine(port: model, config: () => _config);
      final s = e.open(style: 'calm')..add('The first sentence is here.');
      await Future<void>.delayed(Duration.zero);
      expect(model.requests.length, 1, reason: 'asked for at once, while the reply is written');
      s
        ..add('The second one follows it.')
        ..close();
      await Future<void>.delayed(Duration.zero);
      final sink = RecordingSink();
      expect(await s.release(sink), 2);
      expect(sink.played, [Uint8List.fromList([1]), Uint8List.fromList([2])]);

      final dropped = e.open()..add('Never heard at all.');
      dropped.cancel();
      expect(await dropped.release(sink), 0);
    });

    test('synthesize() is the PCM alone', () async {
      final model = FakeModel([audioResponse([7, 7])]);
      final pcm = await SpeechEngine(port: model, config: () => _config)
          .synthesize('Just one sentence here.')
          .toList();
      expect(pcm, [Uint8List.fromList([7, 7])]);
    });
  });

  group('speak and barge-in', () {
    test('speak plays every sentence through the sink, in order', () async {
      final model = FakeModel([audioResponse([1]), audioResponse([2])]);
      final sink = RecordingSink();
      final seen = <int>[];
      final n = await SpeechEngine(port: model, config: () => _config).speak(
          'The first sentence is here. The second one follows it.', sink,
          onChunk: (c) => seen.add(c.index));
      expect(n, 2);
      expect(sink.played, [
        Uint8List.fromList([1]),
        Uint8List.fromList([2]),
      ]);
      expect(sink.rates, [24000, 24000]);
      expect(seen, [0, 1]);
    });

    test('cancel stops handing out audio and stops the sink', () async {
      final second = Completer<GenerateContentResponse>();
      final model = FakeModel([
        audioResponse([1]),
        (ModelRequest _) => second.future,
      ]);
      final e = SpeechEngine(port: model, config: () => _config);
      final sink = RecordingSink();
      final speaking = e.speak('The first sentence is here. The second one follows it.', sink);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await e.cancel(sink: sink);
      second.complete(audioResponse([2]));
      expect(await speaking, 1);
      expect(sink.played.length, 1);
      expect(sink.stops, 1);
    });
  });
}
