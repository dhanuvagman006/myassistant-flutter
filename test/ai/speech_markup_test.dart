import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/ai/speech_markup.dart';

void main() {
  group('a spoken reply', () {
    test('tone and expressions: heard, never shown', () {
      final r = SpeechMarkup.parse(
          '<tone: warm and deeply empathetic> <sigh> I am so sorry, Sir. <short pause> Let me fix it.');
      expect(r.tone, 'warm and deeply empathetic');
      expect(r.display, 'I am so sorry, Sir. Let me fix it.');
      expect(r.spoken, '<sigh> I am so sorry, Sir. <short pause> Let me fix it.');
    });

    test('spacing is mended only where a mark stood', () {
      final r = SpeechMarkup.parse('Sure <chuckles>, that was funny!\n<laugh>\nNext  line  as  written.');
      expect(r.display, 'Sure, that was funny!\n\nNext  line  as  written.');
      expect(r.spoken, 'Sure <chuckles>, that was funny!\n<laugh>\nNext  line  as  written.');
      expect(r.tone, isNull);
    });

    test('anything else in angle brackets is the reply itself', () {
      final r = SpeechMarkup.parse('Use <b>bold</b> and keep x < y > z. I <3 you <Chuckles>');
      expect(r.display, 'Use <b>bold</b> and keep x < y > z. I <3 you');
      expect(r.spoken, 'Use <b>bold</b> and keep x < y > z. I <3 you <chuckles>');
    });

    test('streaming: a half-written mark is held back, a finished one hidden', () {
      expect(SpeechMarkup.stripPartial('<tone: bri'), '');
      expect(SpeechMarkup.stripPartial('<tone: bright> Good news! <chuck'), 'Good news!');
      expect(SpeechMarkup.stripPartial('Good news! <chuckles> Your'), 'Good news! Your');
      expect(SpeechMarkup.stripPartial('if a < b then'), 'if a < b then',
          reason: 'a far-off "<" is text, not a mark to wait for');
    });

    test('the tone note is taken once, from wherever it is', () {
      final r = SpeechMarkup.parse('Done! <TONE: confident and efficient> Anything else?');
      expect(r.tone, 'confident and efficient');
      expect(r.display, 'Done! Anything else?');
    });
  });
}
