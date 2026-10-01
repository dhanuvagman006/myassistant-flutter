// ROUTER — which engine answers a turn. Pure functions: no I/O, no clocks.
//
// Deterministic (design, 2026-09-29; Gemini Nano removed the same night on
// the owner's word — every turn is the cloud's):
//  1. the whole text is one of the user's shortcut names  -> shortcut
//  2. attachments, or a yes to a waiting question          -> cloud
//  3. a tool or personal-data word (config.routing)        -> cloud
//  4. a fresh-public-fact word, with no tool word           -> search
//  5. everything else                                       -> cloud
import 'config.dart';

enum AiRoute { cloud, search, shortcut }

class RouteRequest {
  const RouteRequest({
    required this.text,
    this.images = 0,
    this.otherAttachments = 0,
    this.serverShortcut,
    this.pendingConfirmation = false,
  });

  final String text;

  /// Photos attached to the turn.
  final int images;

  /// PDFs, voice notes, clips.
  final int otherAttachments;

  /// The shortcut /ai/context matched on the server, if any.
  final String? serverShortcut;

  /// An action is waiting for the user's yes, and this turn says yes.
  final bool pendingConfirmation;
}

class RouteDecision {
  const RouteDecision(this.route, this.reason, {this.shortcut});

  final AiRoute route;

  /// Why, for logs: 'shortcut', 'attachments', 'tool_word:remind', …
  final String reason;

  /// The shortcut to run (route == shortcut).
  final String? shortcut;

  @override
  String toString() => '${route.name} ($reason)';
}

RouteDecision chooseRoute(RouteRequest r, AiConfig config) {
  final hasAttachments = r.images > 0 || r.otherAttachments > 0;
  final shortcut = r.serverShortcut?.trim().isNotEmpty == true
      ? r.serverShortcut!.trim()
      : hasAttachments
          ? null
          : matchShortcut(r.text, config.routing.shortcutNames);
  if (shortcut != null) {
    return RouteDecision(AiRoute.shortcut, 'shortcut', shortcut: shortcut);
  }
  if (hasAttachments) return const RouteDecision(AiRoute.cloud, 'attachments');
  if (r.pendingConfirmation) {
    return const RouteDecision(AiRoute.cloud, 'pending_confirmation');
  }
  final tool = WordMatcher.of(config.routing.toolWords).firstMatch(r.text);
  if (tool != null) return RouteDecision(AiRoute.cloud, 'tool_word:$tool');
  final fresh = WordMatcher.of(config.routing.freshWords).firstMatch(r.text);
  if (fresh != null) return RouteDecision(AiRoute.search, 'fresh_word:$fresh');
  return const RouteDecision(AiRoute.cloud, 'conversation');
}

// ---------------------------------------------------------------- words

final _zeroWidth = RegExp('[​-‍﻿]');
final _nonWord = RegExp(r'[^\p{L}\p{M}\p{N}]+', unicode: true);
final _spaces = RegExp(r'\s+');
final _latin = RegExp(r'^[a-z0-9 ]+$');
// Devanagari, Bengali, Gurmukhi, Gujarati, Oriya, Tamil, Telugu, Kannada,
// Malayalam: the virama that ends a written stem.
final _finalVirama = RegExp('[्্੍્୍்్್്]\$');

/// Full-width ASCII (typed on some keyboards) as plain ASCII — the part of
/// the server's NFKC normalisation that matters for typed names.
String _foldWidth(String s) {
  if (!s.runes.any((c) => c >= 0xFF01 && c <= 0xFF5E || c == 0x3000)) return s;
  return String.fromCharCodes(s.runes.map((c) => c == 0x3000
      ? 0x20
      : c >= 0xFF01 && c <= 0xFF5E
          ? c - 0xFEE0
          : c));
}

/// Lower case, apostrophes dropped ("what's" -> "whats"), every run of
/// punctuation or space one space.
String normalizeWords(String s) => _foldWidth(s)
    .toLowerCase()
    .replaceAll(_zeroWidth, '')
    .replaceAll(RegExp("['’]"), '')
    .replaceAll(_nonWord, ' ')
    .replaceAll(_spaces, ' ')
    .trim();

/// Finds any of a list of words or phrases in a text. English words also
/// match their plain inflections (remind: reminds, reminded, reminding,
/// reminder; set: setting); words in other scripts match as word STARTS,
/// because Malayalam and Hindi add their endings to the stem
/// (വിളിക്ക് -> വിളിക്കൂ, വിളിക്കാൻ).
class WordMatcher {
  WordMatcher(Iterable<String> words) {
    final alternatives = <String>[];
    for (final w in words) {
      final k = normalizeWords(w);
      if (k.isEmpty) continue;
      alternatives.add(_latin.hasMatch(k)
          ? '${RegExp.escape(k)}${_suffixes(k)}(?= )'
          // A stem written with a final virama (അയക്ക്, भेज्) takes a
          // vowel sign in its place when inflected (അയക്കൂ): match without.
          : RegExp.escape(k.replaceFirst(_finalVirama, '')));
    }
    _re = alternatives.isEmpty ? null : RegExp(' (${alternatives.join('|')})', unicode: true);
  }

  static final _cache = Expando<WordMatcher>();

  /// One compiled matcher per list (the config's lists live for its life).
  static WordMatcher of(List<String> words) => _cache[words] ??= WordMatcher(words);

  RegExp? _re;

  static String _suffixes(String w) {
    final last = w[w.length - 1];
    final doubled = 'bdgklmnprt'.contains(last) ? '|${RegExp.escape(last)}(?:ing|ed|er|ers)' : '';
    return '(?:s|es|ed|d|ing|er|ers$doubled)?';
  }

  /// The first word or phrase found, as the text had it; null if none.
  String? firstMatch(String text) {
    final re = _re;
    if (re == null) return null;
    return re.firstMatch(' ${normalizeWords(text)} ')?.group(1);
  }

  bool hasMatch(String text) => firstMatch(text) != null;
}

// ------------------------------------------------------------ shortcuts
// A port of the server's src/shortcuts/match.js (nameKey, stripFillers,
// exactFor), so the phone and the server agree on what a name is.

/// Normalised key of a shortcut name: case, width, joiners, punctuation,
/// "my … shortcut".
String shortcutKey(String s) => _foldWidth(s)
    .toLowerCase()
    .replaceAll(_zeroWidth, '')
    .replaceAll(_nonWord, ' ')
    .replaceAll(_spaces, ' ')
    .trim()
    .replaceFirst(RegExp(r'^(?:my|the|a)\s+'), '')
    .replaceFirst(RegExp(r'\s+(?:shortcut|routine)$'), '');

const _leading = [
  'hey hari',
  'hari',
  'ok',
  'okay',
  'please',
  'turn on',
  'switch on',
  'start',
  'run',
  'do',
  'activate',
  'begin',
  'enable',
];

final _trailing = [
  'please',
  'now',
  'chalu karo',
  'shuru karo',
  'on karo',
  'kar do',
  'karo',
  'chalao',
  'चालू करो',
  'शुरू करो',
  'ऑन करो',
  'करो',
  'चलाओ',
  'ഓൺ ആക്കൂ',
  'ആക്കൂ',
  'ചെയ്യൂ',
  'ചെയ്യുക',
  'ಆನ್ ಮಾಡು',
  'ಮಾಡು',
  'ஆன் பண்ணு',
  'செய்',
  'ఆన్ చేయి',
  'చేయి',
  'on',
].map(shortcutKey).toList();

/// The words people wrap a name in, gone: "hari start office mode please".
String stripShortcutFillers(String text) {
  var k = shortcutKey(text);
  for (var changed = true; changed;) {
    changed = false;
    for (final w in _leading) {
      if (k.startsWith('$w ')) {
        k = k.substring(w.length + 1);
        changed = true;
      }
    }
    for (final w in _trailing) {
      if (w.isNotEmpty && k.endsWith(' $w')) {
        k = k.substring(0, k.length - w.length - 1);
        changed = true;
      }
    }
  }
  return shortcutKey(k);
}

/// The shortcut the WHOLE text names (exact first, then without fillers),
/// or null. "what is office mode?" never matches "office mode".
String? matchShortcut(String text, List<String> names) {
  if (names.isEmpty || text.trim().isEmpty) return null;
  final k1 = shortcutKey(text);
  final k2 = stripShortcutFillers(text);
  for (final key in [k1, k2]) {
    if (key.isEmpty) continue;
    for (final n in names) {
      if (shortcutKey(n) == key) return n;
    }
  }
  return null;
}

// --------------------------------------------------------- confirmations

const _yes = [
  'yes',
  'yeah',
  'yep',
  'yup',
  'ya',
  'ok',
  'okay',
  'sure',
  'confirm',
  'confirmed',
  'go ahead',
  'do it',
  'send it',
  'please do',
  'haan',
  'han',
  'haa',
  'ha',
  'ji',
  'theek hai',
  'thik hai',
  'sari',
  'shari',
  'seri',
  'athe',
  'aam',
  'അതെ',
  'ശരി',
  'ഓക്കേ',
  'हाँ',
  'हां',
  'जी',
  'ठीक है',
];

const _no = [
  'no',
  'nope',
  'not',
  'dont',
  'cancel',
  'stop',
  'wait',
  'nahi',
  'nahin',
  'mat',
  'venda',
  'illa',
  'വേണ്ട',
  'ഇല്ല',
  'नहीं',
  'मत',
];

/// A short yes to a question just asked ("yes", "ok go ahead", "haan",
/// "ശരി"), and no "no"/"wait"/"cancel" in it. Only such a turn may carry
/// a confirmation token back to the server.
bool isAffirmative(String text) {
  final k = normalizeWords(text);
  if (k.isEmpty || k.split(' ').length > 8) return false;
  final padded = ' $k ';
  bool has(String w) => padded.contains(' ${normalizeWords(w)} ');
  if (_no.any(has)) return false;
  return _yes.any(has);
}

/// A short "no" ("no", "cancel", "don't", "venda", "വേണ്ട", "नहीं"): it uses up
/// an approval still waiting for the owner's answer.
bool isDecline(String text) {
  final k = normalizeWords(text);
  if (k.isEmpty || k.split(' ').length > 8) return false;
  final padded = ' $k ';
  return _no.any((w) => padded.contains(' ${normalizeWords(w)} '));
}
