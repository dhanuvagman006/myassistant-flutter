import 'package:audioplayers/audioplayers.dart';

import '../core/log.dart';

/// THE SOUND THAT MEANS "GO AHEAD".
///
/// Connecting takes a moment, and until now nothing marked the end of it:
/// the orb changed colour, which you only notice if you are looking at
/// the screen. People spoke into the gap and their first words were lost.
/// One short two-note chime the instant the socket is live — the same
/// convention every voice assistant uses — and you can start talking
/// without watching the phone.
///
/// Once per session, only on the transition into listening. Never at the
/// end of a turn: a sound after every reply would be exhausting.
class ListeningChime {
  ListeningChime._();

  static final AudioPlayer _player = AudioPlayer(playerId: 'listening_chime');
  static bool _warmed = false;

  /// Preload so the first play is not delayed by a disk read — the whole
  /// point is that it lands exactly when listening starts.
  static Future<void> warm() async {
    if (_warmed) return;
    _warmed = true;
    try {
      await _player.setReleaseMode(ReleaseMode.stop);
      await _player.setSource(AssetSource('sounds/listening.wav'));
    } catch (e) {
      AppLog.add('chime', 'warm failed: $e');
    }
  }

  /// Plays it. Failures are swallowed: a missing sound must never stop a
  /// conversation from starting.
  static Future<void> play() async {
    try {
      await _player.stop();
      await _player.play(
        AssetSource('sounds/listening.wav'),
        volume: 0.55,
        // The chime belongs with the assistant's voice, not the ringer,
        // so it follows media volume and ducks around a call.
        mode: PlayerMode.lowLatency,
      );
    } catch (e) {
      AppLog.add('chime', 'play failed: $e');
    }
  }
}
