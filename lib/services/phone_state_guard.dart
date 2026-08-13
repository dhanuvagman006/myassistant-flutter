import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:phone_state/phone_state.dart';

/// INCOMING-CALL GUARD — the moment the phone rings (or a call connects),
/// Hari must go silent INSTANTLY: no talking over the ringtone, no mic
/// capture stealing audio focus from the call.
///
/// Usage (AssistantEngine.start):
///   PhoneStateGuard.instance.start(
///     onCallActive: () { /* stop TTS + capture NOW */ },
///     onCallEnded:  () { /* resume wake word */ },
///   );
///
/// Android needs the runtime READ_PHONE_STATE permission (also added to
/// the manifest). If the user denies it, the guard degrades silently —
/// everything else keeps working, Hari just can't auto-mute on calls.
/// iOS uses the CallKit observer via the plugin; no permission needed.
class PhoneStateGuard {
  PhoneStateGuard._();
  static final PhoneStateGuard instance = PhoneStateGuard._();

  StreamSubscription<PhoneState>? _sub;
  bool _inCall = false;

  /// True while the phone is ringing or a call is in progress. The
  /// controller checks this before starting to speak or record, so a
  /// reply that finishes streaming mid-call never plays over it.
  bool get inCall => _inCall;

  VoidCallback? _onCallActive;
  VoidCallback? _onCallEnded;

  Future<void> start({
    required VoidCallback onCallActive,
    required VoidCallback onCallEnded,
  }) async {
    _onCallActive = onCallActive;
    _onCallEnded = onCallEnded;
    if (_sub != null) return; // already watching

    // Ask once; denial is fine (guard just stays inactive on Android).
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        final status = await Permission.phone.status;
        if (!status.isGranted) {
          final r = await Permission.phone.request();
          if (!r.isGranted) return;
        }
      }
    } catch (_) {
      return;
    }

    try {
      _sub = PhoneState.stream.listen(_onEvent, onError: (_) {});
    } catch (_) {
      // Plugin unavailable on this platform — no guard, no crash.
    }
  }

  void _onEvent(PhoneState event) {
    switch (event.status) {
      // CALL_INCOMING fires the instant the phone starts ringing;
      // CALL_STARTED when a call (in OR out) actually connects. Both
      // must silence Hari immediately.
      case PhoneStateStatus.CALL_INCOMING:
      case PhoneStateStatus.CALL_STARTED:
        if (!_inCall) {
          _inCall = true;
          _onCallActive?.call();
        }
      case PhoneStateStatus.CALL_ENDED:
      case PhoneStateStatus.NOTHING:
        if (_inCall) {
          _inCall = false;
          _onCallEnded?.call();
        }
    }
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    _inCall = false;
  }
}
