import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/ai/config.dart';
import 'package:myassistant/ai/router.dart';

AiConfig _config({
  List<String>? toolWords,
  List<String>? freshWords,
  List<String> shortcuts = const [],
}) =>
    AiConfig(
      routing: AiRouting(
        toolWords: toolWords ??
            const [
              'remind', 'call', 'message', 'send', 'email', 'book', 'order', 'open',
              'play', 'set', 'alarm', 'timer', 'schedule', 'calendar', 'meeting', 'note',
              'remember', 'forget', 'pay', 'navigate', 'directions', 'weather', 'news',
              'near me', 'my',
              // Hindi / Malayalam, transliterated and in their own scripts.
              'bhejo', 'yaad dilao', 'vilikku', 'ayakku', 'भेजो', 'याद', 'വിളിക്ക്', 'അയക്ക്',
            ],
        freshWords: freshWords ??
            const ['today', 'latest', 'now', 'current', 'score', 'price', 'who won', 'news of'],
        shortcutNames: shortcuts,
      ),
    );

RouteDecision _route(
  String text, {
  AiConfig? config,
  int images = 0,
  int other = 0,
  String? serverShortcut,
  bool pending = false,
}) =>
    chooseRoute(
      RouteRequest(
        text: text,
        images: images,
        otherAttachments: other,
        serverShortcut: serverShortcut,
        pendingConfirmation: pending,
      ),
      config ?? _config(),
    );

void main() {
  group('1. shortcuts', () {
    final c = _config(shortcuts: ['Office Mode', 'Good Night', 'ഓഫീസ് മോഡ്']);

    test('the whole text naming a shortcut runs it', () {
      final d = _route('office mode', config: c);
      expect(d.route, AiRoute.shortcut);
      expect(d.shortcut, 'Office Mode');
      expect(_route('Good night!', config: c).shortcut, 'Good Night');
    });

    test('the words people wrap a name in are ignored, as the server does', () {
      for (final t in [
        'start office mode please',
        'Hari, turn on office mode',
        'my office mode shortcut',
        'office mode chalu karo',
        'ok run the office mode now',
      ]) {
        expect(_route(t, config: c).shortcut, 'Office Mode', reason: t);
      }
      expect(_route('ഓഫീസ് മോഡ് ഓൺ ആക്കൂ', config: c).shortcut, 'ഓഫീസ് മോഡ്');
      expect(_route('ＯＦＦＩＣＥ ＭＯＤＥ', config: c).shortcut, 'Office Mode',
          reason: 'full-width letters');
    });

    test('a name inside a question or a command never runs it', () {
      for (final t in ['what is office mode?', 'delete office mode', 'office mode is great']) {
        expect(_route(t, config: c).route, isNot(AiRoute.shortcut), reason: t);
      }
    });

    test("the server's match wins, even with no local names", () {
      final d = _route('whatever', serverShortcut: 'Gym Time');
      expect([d.route, d.shortcut], [AiRoute.shortcut, 'Gym Time']);
      expect(_route('office mode', config: c, images: 1).route, isNot(AiRoute.shortcut),
          reason: 'a local match needs a turn without attachments');
    });

    test('shortcutKey and stripShortcutFillers mirror match.js', () {
      expect(shortcutKey('  My   Office-Mode  Shortcut '), 'office mode');
      expect(shortcutKey('the Good Night routine'), 'good night');
      expect(shortcutKey('ജോലി‍മോഡ്'), shortcutKey('ജോലിമോഡ്'));
      expect(stripShortcutFillers('hey hari please start office mode now please'), 'office mode');
      expect(stripShortcutFillers('office mode on karo'), 'office mode');
      expect(matchShortcut('', ['x']), isNull);
      expect(matchShortcut('office', const []), isNull);
    });
  });

  group('2. attachments', () {
    test('a photo, a PDF, audio or video goes to the cloud', () {
      expect(_route('summarise this', other: 1).reason, 'attachments');
      expect(_route('what are these', images: 2).route, AiRoute.cloud);
      expect(_route('hi', images: 1, other: 1).route, AiRoute.cloud);
      expect(_route('what is this', images: 1).reason, 'attachments');
    });
  });

  group('3. tool and personal-data words', () {
    test('English, with inflections', () {
      for (final (text, word) in [
        ('Remind me to drink water', 'remind'),
        ('any reminders tomorrow?', 'reminders'),
        ('I was reminded twice', 'reminded'),
        ('call amma', 'call'),
        ('calling dad now', 'calling'),
        ('set an alarm for 6', 'set'),
        ('keep setting it', 'setting'),
        ("what's the weather", 'weather'),
        ('restaurants near me', 'near me'),
        ("what's on my calendar", 'my'),
        ('PLAY some music', 'play'),
        ('book a cab', 'book'),
      ]) {
        final d = _route(text);
        expect(d.route, AiRoute.cloud, reason: text);
        expect(d.reason, 'tool_word:$word', reason: text);
      }
    });

    test('Hindi and Malayalam, transliterated or in their scripts', () {
      for (final text in [
        'amma ko message bhejo',
        'kal subah yaad dilao',
        'ammaye vilikku',
        'ഇത് അമ്മയ്ക്ക് അയക്കൂ',
        'അമ്മയെ വിളിക്കൂ',
        'मम्मी को भेजो',
        'मुझे याद दिलाना',
      ]) {
        expect(_route(text).route, AiRoute.cloud, reason: text);
      }
    });

    test('whole words only: no tool word hiding inside another word', () {
      for (final text in ['tell me a joke', 'what is photosynthesis', 'explain the setup of chess']) {
        expect(_route(text).reason, 'conversation', reason: text);
      }
      // "set" + "up" is not "setup"; "caller"/"called" are inflections.
      expect(_route('who called').route, AiRoute.cloud);
    });

    test('a tool word beats a fresh word', () {
      expect(_route('remind me about the latest score').route, AiRoute.cloud);
      expect(_route('latest news').reason, 'tool_word:news');
    });

    test('an empty list matches nothing', () {
      final c = _config(toolWords: const [], freshWords: const []);
      // AiRouting keeps the lists it was given (fromJson falls back).
      expect(_route('remind me', config: c).reason, 'conversation');
    });
  });

  group('4. fresh public facts', () {
    test('go to Google-Search-grounded cloud', () {
      for (final (text, word) in [
        ('who won the match yesterday', 'who won'),
        ('gold price', 'price'),
        ("what's the score", 'score'),
        ('latest on the election', 'latest'),
        ('what happened today', 'today'),
        ('current prime minister of Japan', 'current'),
      ]) {
        final d = _route(text);
        expect(d.route, AiRoute.search, reason: text);
        expect(d.reason, 'fresh_word:$word', reason: text);
      }
    });
  });

  group('5. everything else', () {
    test('the cloud, which answers every turn now', () {
      final d = _route('tell me a joke');
      expect([d.route, d.reason], [AiRoute.cloud, 'conversation']);
      expect(_route('ഒരു തമാശ പറയൂ').route, AiRoute.cloud, reason: 'any language');
    });

    test('a yes to a pending action goes to the cloud (the model retries it)', () {
      expect(_route('yes', pending: true).reason, 'pending_confirmation');
      expect(_route('yes').reason, 'conversation');
    });

    test('the safe defaults route the same way', () {
      final d = chooseRoute(const RouteRequest(text: 'tell me a joke'), AiConfig.defaults);
      expect([d.route, d.reason], [AiRoute.cloud, 'conversation']);
      expect(
          chooseRoute(const RouteRequest(text: 'latest cricket score'), AiConfig.defaults).route,
          AiRoute.search);
      expect(chooseRoute(const RouteRequest(text: 'remind me at 5'), AiConfig.defaults).route,
          AiRoute.cloud);
    });
  });

  group('confirmations', () {
    test('a short yes, in any of the languages', () {
      for (final t in ['yes', 'Yes please', 'ok go ahead', 'sure, do it', 'haan', 'haan ji',
          'theek hai', 'ശരി', 'അതെ', 'हाँ', 'ठीक है', 'send it']) {
        expect(isAffirmative(t), isTrue, reason: t);
      }
    });

    test('a no uses a pending approval up', () {
      for (final no in ['no', 'No, cancel it', "don't", 'venda', 'വേണ്ട', 'नहीं', 'wait']) {
        expect(isDecline(no), isTrue, reason: no);
      }
      for (final other in ['yes', 'ok go ahead', 'what time is it', '']) {
        expect(isDecline(other), isFalse, reason: other);
      }
    });

    test('a no, a wait, or a long sentence is not a yes', () {
      for (final t in ['no', 'ok wait', "don't", 'yes but cancel it', 'nahi', 'വേണ്ട', 'नहीं',
          '', 'ok so tell me about the history of the roman empire please', 'maybe']) {
        expect(isAffirmative(t), isFalse, reason: t);
      }
    });
  });

  test('normalizeWords: case, apostrophes, punctuation, width', () {
    expect(normalizeWords("What's  the WEATHER?!"), 'whats the weather');
    expect(normalizeWords('Ｈｉ'), 'hi');
    expect(WordMatcher(const ['near me']).firstMatch('Cafes near me?'), 'near me');
    expect(WordMatcher(const []).hasMatch('anything'), isFalse);
    expect(WordMatcher(const ["what's on"]).hasMatch('Whats on today'), isTrue);
  });
}
