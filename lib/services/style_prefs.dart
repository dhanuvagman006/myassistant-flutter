import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A4 — Assistant style settings + A3 — app menu language.
///
/// Singleton loaded ONCE at startup; every later read is a plain field
/// access (no async, no disk) so chat/voice hot paths pay zero cost.
/// Writes persist in the background and notify listeners so the UI and
/// the TTS engine react instantly.
class StylePrefs extends ChangeNotifier {
  StylePrefs._();
  static final StylePrefs instance = StylePrefs._();

  static const tones = ['friendly', 'professional', 'cheerful', 'calm'];
  static const lengths = ['short', 'balanced', 'detailed'];

  /// UI language for app menus (A3). 'en' | 'hi' | 'ml'.
  static const uiLanguages = ['en', 'hi', 'ml'];

  String tone = 'friendly';
  String answerLength = 'balanced';
  String uiLanguage = 'en';

  /// Speed of the on-device fallback voice (0.52 tuned). The assistant now
  /// speaks through Gemini TTS, which takes no rate: kept for the setting.
  double speechRate = 0.52;

  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    final p = await SharedPreferences.getInstance();
    tone = _pick(p.getString('style_tone'), tones, tone);
    answerLength = _pick(p.getString('style_length'), lengths, answerLength);
    uiLanguage = _pick(p.getString('ui_language'), uiLanguages, uiLanguage);
    speechRate = (p.getDouble('style_speech_rate') ?? speechRate).clamp(0.3, 0.9);
    _loaded = true;
    notifyListeners();
  }

  static String _pick(String? v, List<String> allowed, String fallback) =>
      (v != null && allowed.contains(v)) ? v : fallback;

  Future<void> setTone(String v) => _save('style_tone', tone = v);
  Future<void> setAnswerLength(String v) => _save('style_length', answerLength = v);
  Future<void> setUiLanguage(String v) => _save('ui_language', uiLanguage = v);

  Future<void> setSpeechRate(double v) async {
    speechRate = v.clamp(0.3, 0.9);
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setDouble('style_speech_rate', speechRate);
  }

  Future<void> _save(String key, String value) async {
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setString(key, value);
  }
}
