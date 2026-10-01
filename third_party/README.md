# third_party

## firebase_ai (4.0.0, patched)

A copy of `firebase_ai` 4.0.0 from pub.dev (Apache 2.0, `firebase_ai/LICENSE`),
used through `dependency_overrides` in `pubspec.yaml`. Four changes, each
marked `PATCHED`, three in `lib/src/live_session.dart` and one export:

1. `_listenToWebSocket` skips a Live message whose kind the SDK does not
   know (none of its top-level keys is one it parses; a known kind that
   fails to parse is still an error) (gemini-3.8-live sends `voiceActivity`, `usageMetadata` and empty
   keep-alives, about 30 a turn). Upstream turned each one into a stream
   error. That error ENDS `receive()`, and whatever was queued behind it in
   the same socket read was dropped: a tool call (the model then waits
   forever for its answer), a turn complete, or her audio. The app's Live
   voice then sat on "Listening" (client's S24 Ultra, 2026-09-30).
2. `onFrame`: a callback for every frame the server sends, understood or
   not. `lib/ai/live_voice.dart` uses it to tell a live session from a dead
   one.
3. `lib/firebase_ai.dart` also exports `LiveWebSocketClosedException`, so
   the app can tell a closed socket from a bad message by type rather than
   by its wording.
4. The Live socket pings every 30 s (`pingInterval`). A socket that stops
   answering (a Wi-Fi to mobile hand-off, a dead NAT) is closed within a
   minute, so the app reconnects instead of streaming audio into nothing.
   The server answers pings: measured from the PC on 2026-09-30, 55 s at a
   10 s interval, none missed. 30 s rather than 10 s because dart:io needs
   the pong before the next ping, and on a slow network the pong queues
   behind her audio.

`pubspec.yaml`'s `resolution: workspace` line is commented out (it only
applies inside the FlutterFire monorepo).

To upgrade: check whether the new release still ends `receive()` on an
unknown message. If it does not, drop the override. If it does, copy the new
release here and re-apply all four changes.
