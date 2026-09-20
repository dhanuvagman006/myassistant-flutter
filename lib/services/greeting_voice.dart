import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import '../core/log.dart';
import 'api_service.dart';

/// THE GREETING IN THE ASSISTANT'S OWN VOICE.
///
/// "Hi sir" used to come out of the phone's built-in text-to-speech —
/// instant, but a different and noticeably worse voice than the one that
/// answers a second later. His call, 2026-09-20: "the voice quality is a
/// bit low, I want the agent's own voice… let the API say it, or record
/// the same voice instead of playing some low quality audio."
///
/// So it is SYNTHESISED ONCE by the same /tts endpoint the assistant
/// speaks through — which already honours the voice chosen in Settings —
/// cached on disk, and played straight from the file on every later tap.
/// One network call in the app's lifetime; instant and identical after
/// that.
///
/// IT NEVER FALLS BACK TO THE DEVICE VOICE. A greeting that sounds wrong
/// is what he asked to remove, so an uncached greeting is simply silent
/// (the listening chime still marks the moment) and warms itself for
/// next time.
class GreetingVoice {
  GreetingVoice._();
  static final GreetingVoice instance = GreetingVoice._();

  final AudioPlayer _player = AudioPlayer(playerId: 'greeting_voice');

  Future<File> _fileFor(String text) async {
    final dir = await getApplicationSupportDirectory();
    final key = sha1.convert(utf8.encode(text)).toString().substring(0, 16);
    return File('${dir.path}/greet_$key.wav');
  }

  /// Fetch and cache, if it is not already there. Safe to call often.
  Future<void> prewarm(String text) async {
    if (text.trim().isEmpty) return;
    try {
      final f = await _fileFor(text);
      // A truncated or empty file is worse than none — re-fetch it.
      if (await f.exists() && await f.length() > 2000) return;
      final path = await ApiService.synthesizeSpeech(text);
      if (path == null) return;
      final src = File(path);
      if (!await src.exists() || await src.length() < 2000) return;
      await src.copy(f.path);
      try {
        await src.delete();
      } catch (_) {/* temp file, best effort */}
      AppLog.add('greeting', 'cached "$text"');
    } catch (e) {
      AppLog.add('greeting', 'prewarm failed: $e');
    }
  }

  /// Plays the cached greeting. Returns false when nothing was cached —
  /// the caller stays silent rather than using another voice.
  Future<bool> play(String text) async {
    if (text.trim().isEmpty) return false;
    try {
      final f = await _fileFor(text);
      if (!await f.exists() || await f.length() < 2000) {
        prewarm(text); // ready for the next tap
        return false;
      }
      await _player.stop();
      await _player.play(
        DeviceFileSource(f.path),
        volume: 1.0,
        // Belongs with the assistant's voice, not the ringer.
        mode: PlayerMode.lowLatency,
      );
      return true;
    } catch (e) {
      AppLog.add('greeting', 'play failed: $e');
      return false;
    }
  }

  /// Drop every cached greeting — called when the user picks a different
  /// voice, so the next tap is greeted in the voice they just chose
  /// rather than the one they replaced.
  Future<void> clear() async {
    try {
      final dir = await getApplicationSupportDirectory();
      for (final e in dir.listSync()) {
        if (e is File && e.path.contains('/greet_') && e.path.endsWith('.wav')) {
          try {
            await e.delete();
          } catch (_) {/* best effort */}
        }
      }
      AppLog.add('greeting', 'cache cleared');
    } catch (_) {/* nothing cached is a fine outcome */}
  }
}
