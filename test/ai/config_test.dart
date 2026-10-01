import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/ai/config.dart';

const _json = {
  'models': {
    'cloud': 'gemini-3.5-flash',
    'cloudFast': 'gemini-flash-lite-latest',
    'tts': 'gemini-2.5-flash-preview-tts',
    'ttsVoice': 'Puck',
    'ttsLanguage': 'ml-IN',
  },
  'nano': {'enabled': true, 'maxPromptChars': 7000}, // an old server's: ignored
  'routing': {
    'toolWords': ['remind', 'call'],
    'freshWords': ['today'],
    'shortcutNames': ['Office Mode'],
  },
  'limits': {'maxToolRounds': 4},
};

void main() {
  group('AiConfig', () {
    test('reads every field of /ai/config', () {
      final c = AiConfig.fromJson(Map<String, dynamic>.from(_json));
      expect(c.fromServer, isTrue);
      expect(c.models.cloud, 'gemini-3.5-flash');
      expect(c.models.cloudFast, 'gemini-flash-lite-latest');
      expect(c.models.tts, 'gemini-2.5-flash-preview-tts');
      expect(c.models.ttsVoice, 'Puck');
      expect(c.models.ttsLanguage, 'ml-IN');
      expect(c.routing.toolWords, ['remind', 'call']);
      expect(c.routing.freshWords, ['today']);
      expect(c.routing.shortcutNames, ['Office Mode']);
      expect(c.limits.maxToolRounds, 4);
    });

    test('the safe defaults: the design models and word lists', () {
      const d = AiConfig.defaults;
      expect(d.fromServer, isFalse);
      expect(d.limits.maxToolRounds, 6);
      expect(d.models.ttsVoice, 'Fola');
      expect(d.models.tts, 'gemini-3.8-flash-tts');
      expect(d.models.ttsStyle, 'warm, friendly and natural');
      expect(d.models.cloud, 'gemini-3-flash-preview');
      expect(d.models.cloudFallback, 'gemini-flash-lite-latest');
      expect(d.models.thinking, 'low');
      expect(d.models.ttsLanguage, 'en-IN');
      expect(d.models.cloudFast, 'gemini-flash-lite-latest');
      expect(d.routing.toolWords, containsAll(['remind', 'call', 'near me', 'my']));
      expect(d.routing.freshWords, containsAll(['today', 'who won', 'price']));
      expect(d.routing.shortcutNames, isEmpty);
    });

    test('wrong types and missing parts fall back field by field', () {
      final c = AiConfig.fromJson({
        'models': {'cloud': 42, 'tts': '  ', 'ttsVoice': 'Aoede'},
        'routing': {'toolWords': 'remind', 'freshWords': [1, '', 'now'], 'shortcutNames': null},
        'limits': 'many',
      });
      expect(c.models.cloud, const AiModels().cloud);
      expect(c.models.tts, const AiModels().tts);
      expect(c.models.ttsVoice, 'Aoede');
      expect(c.routing.toolWords, AiRouting.defaultToolWords);
      expect(c.routing.freshWords, ['now']);
      expect(c.routing.shortcutNames, isEmpty);
      expect(c.limits.maxToolRounds, 6);
      expect(AiConfig.fromJson(const {}).models.cloud, const AiModels().cloud);
    });
  });

  group('AiConfigStore', () {
    late DateTime now;
    late int fetches;
    late Map<String, dynamic>? answer;
    AiConfigStore store() => AiConfigStore(
          now: () => now,
          fetch: () async {
            fetches++;
            return answer;
          },
        );

    setUp(() {
      now = DateTime(2026, 9, 29, 10);
      fetches = 0;
      answer = Map<String, dynamic>.from(_json);
    });

    test('fetched once, then served from the cache for 30 minutes', () async {
      final s = store();
      expect((await s.get()).fromServer, isTrue);
      now = now.add(const Duration(minutes: 29));
      await s.get();
      expect(fetches, 1);
      expect(s.isFresh, isTrue);
    });

    test('an old copy is used at once and refreshed behind the turn', () async {
      final s = store();
      await s.get();
      now = now.add(const Duration(minutes: 31));
      answer = {
        ...Map<String, dynamic>.from(_json),
        'limits': {'maxToolRounds': 2},
      };
      final served = await s.get();
      expect(served.limits.maxToolRounds, 4, reason: 'the turn does not wait');
      await Future<void>.delayed(Duration.zero);
      expect(fetches, 2);
      expect(s.current.limits.maxToolRounds, 2);
    });

    test('unreachable with nothing held: the safe defaults, and no retry every turn',
        () async {
      answer = null;
      final s = store();
      final c = await s.get();
      expect(c.fromServer, isFalse);
      await s.get();
      expect(fetches, 1, reason: 'a failure waits a minute before trying again');
      now = now.add(const Duration(minutes: 2));
      answer = Map<String, dynamic>.from(_json);
      expect((await s.get()).fromServer, isTrue);
      expect(fetches, 2);
    });

    test('a failed refresh keeps the last good copy', () async {
      final s = store();
      await s.get();
      answer = null;
      final c = await s.refresh();
      expect(c.fromServer, isTrue);
      expect(c.models.ttsVoice, 'Puck');
    });

    test('a throwing fetch is a failure, not a crash', () async {
      final s = AiConfigStore(now: () => now, fetch: () => throw StateError('boom'));
      expect((await s.get()).fromServer, isFalse);
    });

    test('one request at a time; sign-in refreshes; sign-out forgets', () async {
      final s = store();
      await Future.wait([s.refresh(), s.refresh(), s.refresh()]);
      expect(fetches, 1);
      s.clear();
      expect(s.current.fromServer, isFalse);
      expect(s.fetchedAt, isNull);
      await s.refresh();
      expect(fetches, 2);
      expect(s.current.routing.shortcutNames, ['Office Mode']);
    });
  });

  group('the fast voice (live)', () {
    test("absent: the app's own defaults — on, gemini-3.8-live, Sulafat, 800 ms", () {
      final c = AiConfig.fromJson(const {'models': {}});
      expect(c.live.on, isTrue);
      expect(c.live.model, 'gemini-3.8-live');
      expect(c.live.voice, 'Sulafat');
      expect(c.live.silenceMs, 800);
      expect(c.live.prefixMs, 100);
      expect(c.live.startSensitivity, 'low');
      expect(c.live.endSensitivity, 'high');
      expect(c.live.idleCloseSec, 180);
      expect(c.live.voices, AiLive.defaultVoices);
    });

    test("the server's values win; nonsense falls back", () {
      final c = AiConfig.fromJson(const {
        'live': {
          'on': false,
          'model': 'gemini-3.1-flash-live-preview',
          'voice': 'Kore',
          'silenceMs': 700,
          'prefixMs': 20,
          'startSensitivity': 'LOW',
          'endSensitivity': 'sideways',
          'idleCloseSec': 30,
          'voices': ['Kore', 'Puck'],
        },
      });
      expect(c.live.on, isFalse);
      expect(c.live.model, 'gemini-3.1-flash-live-preview');
      expect(c.live.voice, 'Kore');
      expect(c.live.silenceMs, 700);
      expect(c.live.prefixMs, 20);
      expect(c.live.startSensitivity, 'low');
      expect(c.live.endSensitivity, 'high');
      expect(c.live.idleCloseSec, 30);
      expect(c.live.voices, ['Kore', 'Puck']);
    });

    test('a voice preview swaps only the voice', () {
      const c = AiConfig(models: AiModels(tts: 'tts-x', ttsVoice: 'Fola', ttsLanguage: 'ml-IN'));
      final p = c.withVoice('Aoede');
      expect(p.models.ttsVoice, 'Aoede');
      expect(p.models.tts, 'tts-x');
      expect(p.models.ttsLanguage, 'ml-IN');
    });
  });
}
