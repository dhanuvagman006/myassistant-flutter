// SPEECH MARKUP — how a spoken reply should sound.
//
// When the phone will speak a reply it asks the server for its delivery
// guide (/ai/context `expressive`), and the conversation model may then
// open the reply with a tone note, `<tone: warm and deeply empathetic>`,
// and put vocal expressions from Gemini TTS's set between words
// (`<sigh>`, `<chuckles>`, `<short pause>`…). The speech model acts on
// both; the user never sees them. [SpokenReply.display] is what is shown
// and remembered, [SpokenReply.spoken] what is voiced.
library;

class SpokenReply {
  const SpokenReply({required this.display, required this.spoken, this.tone});

  /// The reply without any delivery marks.
  final String display;

  /// The reply with its vocal expressions, without the tone note.
  final String spoken;

  /// How it should sound ("bright and sunny"), when the model said.
  final String? tone;
}

abstract final class SpeechMarkup {
  /// Every expression Gemini TTS performs, so a stray one is never shown
  /// (the server offers the model only the ones that suit an assistant).
  static const expressions = {
    'argh', 'breath', 'heavy breath', 'exhales', 'cackle', 'cheer', 'chuckle',
    'chuckles', 'cough', 'cry', 'gasp', 'giggle', 'groan', 'growl', 'grunt',
    'grr', 'hiss', 'laugh', 'laughter', 'moan', 'pant', 'pff', 'phew',
    'scream', 'shout', 'shriek', 'sigh', 'sighs', 'sneeze', 'snicker', 'snort',
    'sob', 'throat-clearing', 'tsk', 'whimper', 'whispers', 'whispering',
    'yawn', 'short pause', 'long pause',
  };

  static final _tag = RegExp(r'<\s*([a-zA-Z][a-zA-Z \-]{0,30}?)\s*>');
  static final _tone = RegExp(r'<\s*tone\s*:\s*([^<>\n]{1,80}?)\s*>', caseSensitive: false);

  // Where a mark was cut or kept, so spacing is mended there and only there.
  static const _cut = '\u0000';
  static final _cuts = RegExp('[ \\t]*$_cut(?:[ \\t]*$_cut)*[ \\t]*');

  static String _name(String inner) => inner.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  static bool isExpression(String inner) => expressions.contains(_name(inner));

  /// [raw] split into what is shown, what is said and the tone.
  static SpokenReply parse(String raw) {
    String? tone;
    final noTone = raw.replaceAllMapped(_tone, (m) {
      tone ??= m[1]!.trim();
      return _cut;
    });
    return SpokenReply(
      display: _mend(_expressions(noTone, keep: false)),
      spoken: _mend(_expressions(noTone, keep: true)),
      tone: tone == null || tone!.isEmpty ? null : tone,
    );
  }

  /// [text] as shown: tone notes and expressions removed.
  static String strip(String text) => _mend(_expressions(text.replaceAll(_tone, _cut), keep: false));

  /// A reply still streaming, safe to show: [strip], less a trailing "<…"
  /// that may yet become a mark.
  static String stripPartial(String text) {
    final open = text.lastIndexOf('<');
    if (open >= 0 && !text.contains('>', open) && _mayBecomeMark(text.substring(open + 1))) {
      text = text.substring(0, open);
    }
    return strip(text);
  }

  /// Whether what follows an unclosed "<" can still turn into a mark.
  static bool _mayBecomeMark(String rest) {
    final r = rest.trimLeft().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    if (r.length > 90 || rest.contains('\n')) return false;
    if (RegExp(r'^t(o(n(e ?(:.*)?)?)?)?$').hasMatch(r)) return true;
    return expressions.any((e) => e.startsWith(r));
  }

  static String _expressions(String text, {required bool keep}) =>
      text.replaceAllMapped(_tag, (m) {
        if (!isExpression(m[1]!)) return m[0]!;
        return keep ? '$_cut<${_name(m[1]!)}>$_cut' : _cut;
      });

  /// One space where a mark stood between words; none at a line's edge or
  /// before punctuation. Text the model wrote elsewhere is left as it is.
  static String _mend(String s) => s.replaceAllMapped(_cuts, (m) {
        final before = m.start == 0 ? '\n' : s[m.start - 1];
        final after = m.end >= s.length ? '\n' : s[m.end];
        if (before == '\n' || after == '\n' || ',.!?;:'.contains(after)) return '';
        return ' ';
      }).trim();
}
