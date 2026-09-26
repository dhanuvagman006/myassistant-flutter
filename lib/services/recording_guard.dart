import 'package:flutter/foundation.dart';

/// SOMETHING IS BEING RECORDED (2026-09-26).
///
/// The identity recorder and the meeting recorder END the voice session
/// before they take the camera and microphone, so "no voice session" does
/// not mean "free to play a clip out loud". A video note that opened then
/// covered the recorder, and its sound went into the recording — into the
/// meeting, or into the very video the user's voice is made from. Each
/// recorder holds this while it needs the room quiet; the video-note popup
/// waits until nobody holds it.
abstract final class RecordingGuard {
  static final Set<Object> _holders = {};

  /// True while any recorder holds it.
  static final ValueNotifier<bool> active = ValueNotifier(false);

  static bool get busy => active.value;

  /// [owner] needs the speaker quiet until it calls [release]. Holding
  /// twice is one hold.
  static void hold(Object owner) {
    _holders.add(owner);
    active.value = true;
  }

  /// One recorder letting go never frees another's hold.
  static void release(Object owner) {
    _holders.remove(owner);
    active.value = _holders.isNotEmpty;
  }

  @visibleForTesting
  static void resetForTest() {
    _holders.clear();
    active.value = false;
  }
}
