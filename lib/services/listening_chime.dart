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
///
/// TWO SOUNDS, ONE PAIR (his ask, 2026-09-20): a rising fifth to open and
/// the same two notes falling to close, so starting and stopping are told
/// apart without looking. The closing one is quieter and shorter — an
/// ending should be felt, not announced.
class ListeningChime {
  ListeningChime._();

  static final AudioPlayer _player = AudioPlayer(playerId: 'listening_chime');
  static bool _warmed = false;

  static const _startSound = 'sounds/listen_start.wav';
  static const _stopSound = 'sounds/listen_stop.wav';

  /// Preload so the first play is not delayed by a disk read — the whole
  /// point is that it lands exactly when listening starts.
  static Future<void> warm() async {
    if (_warmed) return;
    _warmed = true;
    try {
      await _player.setReleaseMode(ReleaseMode.stop);
      await _player.setSource(AssetSource(_startSound));
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
        AssetSource(_startSound),
        volume: 0.55,
        // The chime belongs with the assistant's voice, not the ringer,
        // so it follows media volume and ducks around a call.
        mode: PlayerMode.lowLatency,
      );
    } catch (e) {
      AppLog.add('chime', 'play failed: $e');
    }
  }

  /// The closing half of the pair — played when the conversation ends,
  /// so the user knows the microphone is shut without looking. Quieter
  /// than the opening: nobody needs an ending announced.
  static Future<void> playStop() async {
    try {
      await _player.stop();
      await _player.play(
        AssetSource(_stopSound),
        volume: 0.42,
        mode: PlayerMode.lowLatency,
      );
    } catch (e) {
      AppLog.add('chime', 'stop sound failed: $e');
    }
  }
}
