import 'dart:async';

import 'package:livekit_client/livekit_client.dart' as lk;

import 'api_service.dart';
import '../core/log.dart';

/// The photorealistic avatar layer for live mode.
///
/// The assistant's brain is unchanged: voice still goes up the /live/ws
/// socket to Gemini. What changes is where the REPLY comes out. The
/// backend streams Gemini's audio to HeyGen, which renders
/// a lip-synced human against it, and this service subscribes to what it
/// publishes — video AND audio together, so the mouth cannot drift from
/// the words. While an avatar is live the app does not play the PCM that
/// would otherwise arrive on the socket; that is the same voice, and
/// playing both would double it.
///
/// Every failure here is non-fatal by design. If the room never comes up,
/// or the avatar never renders, live mode carries on as audio-only rather than
/// taking the conversation down with it.
class AvatarService {
  AvatarService._();
  static final AvatarService instance = AvatarService._();

  lk.Room? _room;
  String? _roomName;
  lk.EventsListener<lk.RoomEvent>? _events;

  /// The avatar's video track once it is actually rendering, else null.
  lk.VideoTrack? get videoTrack => _videoTrack;
  lk.VideoTrack? _videoTrack;

  /// Room name to hand the live socket, so the backend knows which room
  /// this conversation's audio belongs in. Null when there is no avatar.
  String? get roomName => _roomName;

  bool get isLive => _videoTrack != null;

  /// True while the avatar's audio track is actually producing sound.
  ///
  /// This is the ONLY honest "she is talking" signal in avatar mode. The
  /// backend knows when Gemini finished GENERATING, but the avatar service
  /// buffers and lags that by a noticeable margin, so a turn_complete-based
  /// guess unmutes the mic while she is still mid-sentence. LiveKit derives
  /// this from the real audio energy, so it stays true until she actually
  /// stops.
  bool get isSpeaking => _isSpeaking;
  bool _isSpeaking = false;

  /// Fires on every speaking transition. The mic gate hangs off this: while
  /// she is audible her voice is coming out of the phone's speaker and back
  /// into the mic, and anything uploaded then is heard by the model as the
  /// user interrupting — so she cuts herself off mid-word.
  void Function(bool speaking)? onSpeakingChanged;

  /// Fires when the avatar appears or disappears, so the UI can swap
  /// between the video and the fallback orb.
  void Function()? onChanged;

  /// True when the backend has the avatar provider configured AND it is
  /// renderable right now. Used to decide whether to even try.
  static Future<bool> isAvailable() async {
    try {
      final r = await ApiService.getJson('/live/avatar');
      return r != null && r['available'] == true;
    } catch (_) {
      return false;
    }
  }

  /// Reserve an avatar and join its room. Returns the room name on
  /// success, or null if the avatar could not be started — in which case
  /// the caller should proceed audio-only.
  Future<String?> start() async {
    await stop();
    try {
      final s = await ApiService.sendJson('/live/avatar/session', method: 'POST');
      if (s == null) return null;
      final url = s['url'] as String?;
      final token = s['token'] as String?;
      if (url == null || token == null) return null;

      final room = lk.Room(
        // adaptiveStream/dynacast off: they exist to save bandwidth by
        // dropping to a lower spatial layer, and this is one small 360p
        // track that is always full-screen. There is nothing to save and
        // every reason not to let it degrade further.
        roomOptions: const lk.RoomOptions(adaptiveStream: false, dynacast: false),
      );
      _room = room;
      _roomName = s['room'] as String?;

      // Listen BEFORE connecting: the avatar may already be publishing by the
      // time we finish the handshake, and a missed event would leave the
      // screen on the fallback orb for the whole call.
      _events = room.createListener()
        ..on<lk.TrackSubscribedEvent>((e) {
          if (e.track is lk.VideoTrack) {
            _videoTrack = e.track as lk.VideoTrack;
            // Providers publish WITH SIMULCAST, and the default
            // subscription lands on a lower spatial layer — measured at
            // 360x360, which is a third of the pixels for no benefit on a
            // stream that is always full-screen. Ask for the top layer
            // explicitly rather than trusting the default.
            e.publication.setVideoQuality(lk.VideoQuality.HIGH).catchError((_) {});
            final d = e.publication.dimensions;
            AppLog.add(
              'avatar',
              'video track live ${d == null ? "?" : "${d.width}x${d.height}"}',
            );
            onChanged?.call();
          }
        })
        ..on<lk.TrackUnsubscribedEvent>((e) {
          if (identical(e.track, _videoTrack)) {
            _videoTrack = null;
            AppLog.add('avatar', 'video track gone');
            onChanged?.call();
          }
        })
        ..on<lk.RoomDisconnectedEvent>((_) {
          _videoTrack = null;
          _setSpeaking(false);
          AppLog.add('avatar', 'room disconnected');
          onChanged?.call();
        })
        ..on<lk.ActiveSpeakersChangedEvent>((e) {
          // Only REMOTE speakers count. The app publishes nothing to this
          // room, but guarding anyway keeps a future change from making the
          // user's own voice mute their microphone.
          _setSpeaking(e.speakers.any((p) => p is lk.RemoteParticipant));
        });

      await room.connect(url, token);
      AppLog.add('avatar', 'joined ${_roomName ?? "room"}');
      return _roomName;
    } catch (e) {
      AppLog.add('avatar', 'start failed: $e');
      await stop();
      return null;
    }
  }

  /// Leave and tell the backend to tear the room down. The DELETE matters
  /// for more than tidiness: the session is what the provider bills for,
  /// so a skipped teardown is a meter left running.
  void _setSpeaking(bool v) {
    if (_isSpeaking == v) return;
    _isSpeaking = v;
    try { onSpeakingChanged?.call(v); } catch (_) {}
  }

  Future<void> stop() async {
    final room = _roomName;
    _videoTrack = null;
    // Release the mic gate on the way out, or a teardown mid-sentence would
    // leave the microphone muted for the rest of the session.
    _setSpeaking(false);
    try { await _events?.dispose(); } catch (_) {}
    _events = null;
    try { await _room?.disconnect(); } catch (_) {}
    try { await _room?.dispose(); } catch (_) {}
    _room = null;
    _roomName = null;
    if (room != null) {
      try {
        await ApiService.sendJson('/live/avatar/session/$room', method: 'DELETE');
      } catch (_) {
        // The backend also tears down when the live socket closes, and
        // again on its own idle timer, so a failed DELETE is not a leak.
      }
    }
  }
}
