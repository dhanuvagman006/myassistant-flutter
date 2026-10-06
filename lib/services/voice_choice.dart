import 'dart:async';

import '../ai/live_voice.dart';
import '../features/assistant/state/assistant_engine.dart';
import 'api_service.dart';
import 'auth_service.dart';
import 'greeting_voice.dart';

/// THE ASSISTANT'S VOICE, CHOSEN (2026-10-06). One way to save it, for the
/// Settings row and for "open voice settings" said in a conversation: on
/// this phone (LiveVoicePrefs, what the next live session asks for) and on
/// the server (the profile, what it falls back to). The next session is in
/// the new voice: LiveVoice drops a warmed session in the old one.
class VoiceChoice {
  VoiceChoice._();

  /// Saves [voice]. Null when it is saved; otherwise the sentence to show
  /// (the server explains a refusal, e.g. a voice that does not fit the
  /// assistant's name), and the previous voice is kept.
  static Future<String?> save(String voice) async {
    final previous = LiveVoicePrefs.chosenVoice ?? '';
    await LiveVoicePrefs.setVoice(voice);
    // A cached greeting is in the old voice.
    unawaited(GreetingVoice.instance.clear());
    final r = await ApiService.sendJson('/profile/assistant', method: 'PUT', body: {'voice': voice});
    if (r == null || r['rejected'] == true) {
      await LiveVoicePrefs.setVoice(previous);
      unawaited(GreetingVoice.instance.prewarm(openingLine()));
      return (r?['message'] ?? "Couldn't save the voice.").toString();
    }
    // The recorded opening in the NEW voice, fetched now: the next tap is
    // greeted in it at once (owner, 2026-10-06: "update instantly").
    unawaited(GreetingVoice.instance.prewarm(openingLine()));
    // The waiting session is in the OLD voice: it is replaced now, not at
    // the next tap, so that tap is heard at once (2026-10-06, measured: a
    // tap right after a switch waited ~3 s for the new session).
    AssistantEngine.instance.prewarmVoice();
    return null;
  }

  /// "Hello Madam." when the profile says female, "Hello Sir." otherwise —
  /// the same line the server gives GPT-Live (ai/gptLive.js).
  static String openingLine() =>
      (AuthService.instance.user?.gender ?? '').trim().toLowerCase() == 'female'
          ? 'Hello Madam.'
          : 'Hello Sir.';
}
