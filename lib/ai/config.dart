// AI CONFIG — GET /ai/config, what the brain needs to choose and call
// models: model names, voice and tone, the routing vocabularies and the
// tool-round limit.
//
// Cached. A copy younger than 30 minutes is used as it is; an older one is
// still used while a fresh one is fetched in the background; the store is
// refreshed on every sign-in (identity.dart) and emptied on sign-out. When
// the server cannot be reached and nothing was ever fetched, the SAFE
// DEFAULTS apply.
import 'dart:async';

import '../services/api_service.dart';

List<String> _strings(Object? v) => v is List
    ? [
        for (final e in v)
          if (e is String && e.trim().isNotEmpty) e.trim()
      ]
    : const [];

String _str(Object? v, String fallback) => v is String && v.trim().isNotEmpty ? v.trim() : fallback;

int _int(Object? v, int fallback) => v is num && v.isFinite && v > 0 ? v.toInt() : fallback;

class AiModels {
  const AiModels({
    this.cloud = 'gemini-3-flash-preview',
    this.cloudFast = 'gemini-flash-lite-latest',
    this.cloudFallback = 'gemini-flash-lite-latest',
    this.thinking = 'low',
    this.tts = 'gemini-3.8-flash-tts',
    this.ttsVoice = 'Fola',
    this.ttsStyle = 'warm, friendly and natural',
    this.ttsLanguage = 'en-IN',
  });

  final String cloud;
  final String cloudFast;

  /// Answers when [cloud] fails or has not started in time.
  final String cloudFallback;

  /// How hard [cloud] thinks first: minimal, low, medium or high.
  final String thinking;
  final String tts;
  final String ttsVoice;

  /// The delivery a spoken reply gets when its model gave no tone.
  final String ttsStyle;

  /// BCP-47, from the user's preferred language ("en-IN", "ml-IN", "hi-IN").
  final String ttsLanguage;

  /// The same models with another voice (a voice preview).
  AiModels copyWith({String? ttsVoice}) => AiModels(
        cloud: cloud,
        cloudFast: cloudFast,
        cloudFallback: cloudFallback,
        thinking: thinking,
        tts: tts,
        ttsVoice: ttsVoice ?? this.ttsVoice,
        ttsStyle: ttsStyle,
        ttsLanguage: ttsLanguage,
      );

  factory AiModels.fromJson(Object? j) {
    const d = AiModels();
    if (j is! Map) return d;
    return AiModels(
      cloud: _str(j['cloud'], d.cloud),
      cloudFast: _str(j['cloudFast'], d.cloudFast),
      cloudFallback: _str(j['cloudFallback'], d.cloudFallback),
      thinking: _str(j['thinking'], d.thinking),
      tts: _str(j['tts'], d.tts),
      ttsVoice: _str(j['ttsVoice'], d.ttsVoice),
      ttsStyle: _str(j['ttsStyle'], d.ttsStyle),
      ttsLanguage: _str(j['ttsLanguage'], d.ttsLanguage),
    );
  }
}

class AiRouting {
  const AiRouting({
    this.toolWords = defaultToolWords,
    this.freshWords = defaultFreshWords,
    this.shortcutNames = const [],
  });

  /// Tool or personal-data words: a turn with one goes to the cloud (tools).
  final List<String> toolWords;

  /// Fresh-public-fact words: with no tool word, the turn is a grounded
  /// Google Search answer.
  final List<String> freshWords;

  /// This user's shortcut names: said whole, they run with no model.
  final List<String> shortcutNames;

  /// Used until the server's list arrives (the design's own lists), so a
  /// phone that never reached /ai/config still routes sensibly.
  static const defaultToolWords = [
    'remind',
    'reminder',
    'call',
    'message',
    'send',
    'email',
    'mail',
    'book',
    'order',
    'open',
    'play',
    'set',
    'alarm',
    'timer',
    'schedule',
    'calendar',
    'meeting',
    'note',
    'remember',
    'forget',
    'pay',
    'navigate',
    'directions',
    'weather',
    'news',
    'near me',
    'my',
  ];
  static const defaultFreshWords = [
    'today',
    'latest',
    'now',
    'current',
    'score',
    'price',
    'who won',
    'news of',
  ];

  factory AiRouting.fromJson(Object? j) {
    if (j is! Map) return const AiRouting();
    final tool = _strings(j['toolWords']);
    final fresh = _strings(j['freshWords']);
    return AiRouting(
      toolWords: tool.isEmpty ? defaultToolWords : tool,
      freshWords: fresh.isEmpty ? defaultFreshWords : fresh,
      shortcutNames: _strings(j['shortcutNames']),
    );
  }
}

class AiLimits {
  const AiLimits({this.maxToolRounds = 6});

  final int maxToolRounds;

  factory AiLimits.fromJson(Object? j) =>
      AiLimits(maxToolRounds: j is Map ? _int(j['maxToolRounds'], 6) : 6);
}

/// THE FAST VOICE (2026-09-30): Gemini Live through Firebase AI Logic —
/// GET /ai/config `live`. Measured from the PC that day: end of speech to
/// her first audio 0.62 s on gemini-3.8-live (500 ms silence, high end
/// sensitivity) against 5-8 s for the recogniser -> model -> TTS cascade,
/// which stays as the fallback and the typed path. Every field has the
/// app's own default, so a server that does not send `live` yet still
/// gets the fast voice.
class AiLive {
  const AiLive({
    this.on = true,
    this.model = 'gemini-3.8-live',
    this.voice = 'Sulafat',
    this.silenceMs = 800,
    this.prefixMs = 100,
    this.startSensitivity = 'low',
    this.endSensitivity = 'high',
    this.idleCloseSec = 180,
    this.affectiveDialog = false,
    this.voices = defaultVoices,
  });

  /// Off: every voice turn is the cascade's.
  final bool on;
  final String model;

  /// Her Live voice (one of the prebuilt voices; Fola is the cascade's).
  final String voice;

  /// Silence that ends the owner's turn (Live's own detector).
  final int silenceMs;

  /// Audio kept before the detected start of speech.
  final int prefixMs;

  /// 'high' | 'low'.
  final String startSensitivity;
  final String endSensitivity;

  /// A session nobody uses is closed after this long. Three minutes: a
  /// session warmed as the app came to the front (prewarmVoice) is still
  /// there when the orb is tapped after a look around the app.
  final int idleCloseSec;

  /// Her tone follows the feeling in their voice and in her words (Live's
  /// affective dialog; the client, 2026-09-30: "more emotion"). OFF: the
  /// Firebase AI Logic Live endpoint closed the session "before setup"
  /// with it on (measured on the owner's phone, 2026-09-30); the feeling
  /// comes from the instruction instead. The server can turn it on when
  /// the endpoint takes it.
  final bool affectiveDialog;

  /// The voices the picker offers for Live.
  final List<String> voices;

  static const defaultVoices = [
    'Sulafat',
    'Callirrhoe',
    'Achernar',
    'Aoede',
    'Vindemiatrix',
    'Kore',
    'Charon',
    'Achird',
  ];

  static String _sensitivity(Object? v, String fallback) {
    final s = v is String ? v.trim().toLowerCase() : '';
    return s == 'high' || s == 'low' ? s : fallback;
  }

  factory AiLive.fromJson(Object? j) {
    const d = AiLive();
    if (j is! Map) return d;
    final voices = _strings(j['voices']);
    return AiLive(
      on: j['on'] is bool ? j['on'] as bool : d.on,
      model: _str(j['model'], d.model),
      voice: _str(j['voice'], d.voice),
      silenceMs: _int(j['silenceMs'], d.silenceMs),
      prefixMs: _int(j['prefixMs'], d.prefixMs),
      startSensitivity: _sensitivity(j['startSensitivity'], d.startSensitivity),
      endSensitivity: _sensitivity(j['endSensitivity'], d.endSensitivity),
      idleCloseSec: _int(j['idleCloseSec'], d.idleCloseSec),
      affectiveDialog:
          j['affectiveDialog'] is bool ? j['affectiveDialog'] as bool : d.affectiveDialog,
      voices: voices.isEmpty ? defaultVoices : voices,
    );
  }
}

class AiConfig {
  const AiConfig({
    this.models = const AiModels(),
    this.routing = const AiRouting(),
    this.limits = const AiLimits(),
    this.live = const AiLive(),
    this.fromServer = false,
  });

  final AiModels models;
  final AiRouting routing;
  final AiLimits limits;

  /// The fast voice (Gemini Live).
  final AiLive live;

  /// False for the safe defaults (the server was never reached).
  final bool fromServer;

  static const AiConfig defaults = AiConfig();

  /// The same config with another voice for the cascade (a voice preview).
  AiConfig withVoice(String voice) => AiConfig(
        models: models.copyWith(ttsVoice: voice),
        routing: routing,
        limits: limits,
        live: live,
        fromServer: fromServer,
      );

  factory AiConfig.fromJson(Map<String, dynamic> j) => AiConfig(
        models: AiModels.fromJson(j['models']),
        routing: AiRouting.fromJson(j['routing']),
        limits: AiLimits.fromJson(j['limits']),
        live: AiLive.fromJson(j['live']),
        fromServer: true,
      );
}

/// The cached /ai/config. One per app ([instance]); tests make their own.
class AiConfigStore {
  AiConfigStore({
    Future<Map<String, dynamic>?> Function()? fetch,
    DateTime Function()? now,
    this.maxAge = const Duration(minutes: 30),
    this.retryAfter = const Duration(minutes: 1),
  })  : _fetch = fetch ?? _defaultFetch,
        _now = now ?? DateTime.now;

  static final AiConfigStore instance = AiConfigStore();

  static Future<Map<String, dynamic>?> _defaultFetch() =>
      ApiService.getJson('/ai/config', timeout: const Duration(seconds: 5));

  final Future<Map<String, dynamic>?> Function() _fetch;
  final DateTime Function() _now;

  /// How long a fetched copy is used as it is.
  final Duration maxAge;

  /// After a failed fetch, how long before trying again (so an offline
  /// phone does not wait on the network every turn).
  final Duration retryAfter;

  AiConfig? _config;
  DateTime? _fetchedAt;
  DateTime? _failedAt;
  Future<AiConfig>? _inFlight;

  /// The best config right now: the last one fetched, else the defaults.
  AiConfig get current => _config ?? AiConfig.defaults;

  DateTime? get fetchedAt => _fetchedAt;

  bool get isFresh => _fetchedAt != null && _now().difference(_fetchedAt!) < maxAge;

  bool get _mayRetry => _failedAt == null || _now().difference(_failedAt!) >= retryAfter;

  /// For a turn: never waits when any copy is held (a stale one is
  /// refreshed in the background); waits for the first fetch otherwise.
  Future<AiConfig> get() async {
    if (isFresh) return current;
    if (_config != null) {
      if (_mayRetry) unawaited(refresh());
      return current;
    }
    if (!_mayRetry) return current;
    return refresh();
  }

  /// Fetch now (sign-in, or a stale copy). One request at a time; a failure
  /// keeps whatever was held.
  Future<AiConfig> refresh() {
    final running = _inFlight;
    if (running != null) return running;
    final next = _load();
    _inFlight = next;
    next.whenComplete(() {
      if (identical(_inFlight, next)) _inFlight = null;
    });
    return next;
  }

  Future<AiConfig> _load() async {
    try {
      final j = await _fetch();
      if (j != null) {
        _config = AiConfig.fromJson(j);
        _fetchedAt = _now();
        _failedAt = null;
      } else {
        _failedAt = _now();
      }
    } catch (_) {
      _failedAt = _now();
    }
    return current;
  }

  /// Sign-out: the next account must not inherit this one's shortcuts.
  void clear() {
    _config = null;
    _fetchedAt = null;
    _failedAt = null;
  }
}
