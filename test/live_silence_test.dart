import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/features/assistant/state/assistant_engine.dart';
import 'package:myassistant/features/assistant/state/assistant_state.dart';
import 'package:myassistant/services/live_service.dart';
import 'package:myassistant/services/location_service.dart';

/// Silence is trimmed, and a quiet minute ends the session (owner,
/// 2026-09-24: "when user don't respond for 1 min (silence) auto close it;
/// don't send silent packets to my agent, trim it"). Driven with synthetic
/// PCM through the real per-frame path, with a fake clock.

/// One 128 ms mic frame of PCM16 @16 kHz: a 220 Hz tone at [amp].
Uint8List tone(int amp, {double hz = 220}) {
  const samples = 2048;
  final b = ByteData(samples * 2);
  for (var i = 0; i < samples; i++) {
    b.setInt16(
        i * 2, (amp * math.sin(2 * math.pi * hz * i / 16000)).round(),
        Endian.little);
  }
  return b.buffer.asUint8List();
}

final quiet = tone(20);
final speech = tone(8000);

class Rig {
  final svc = LiveService.instance;
  final sent = <Object>[];
  DateTime t = DateTime(2026, 9, 24, 10);
  int closes = 0;

  void begin() {
    svc.debugBeginSession(sink: sent.add, clock: () => t);
    svc.onQuietTimeout = () => closes++;
  }

  void feed(Uint8List frame, [int n = 1]) {
    for (var i = 0; i < n; i++) {
      svc.debugMicChunk(frame);
      t = t.add(const Duration(milliseconds: 128));
    }
  }

  void server(Map<String, dynamic> m) => svc.debugServerFrame(jsonEncode(m));

  List<String> get markers => [
        for (final f in sent)
          if (f is String) jsonDecode(f)['type'] as String,
      ];

  List<Uint8List> get audio => sent.whereType<Uint8List>().toList();

  /// A spoken sentence: onset, speech, then the hangover that ends it.
  void utterance({int frames = 6}) {
    feed(speech, frames);
    feed(quiet, 8); // 1024 ms of quiet > the 1000 ms hangover
  }
}

int peakOf(Uint8List b) {
  final d = ByteData.sublistView(b);
  var m = 0;
  for (var i = 0; i + 1 < b.length; i += 2) {
    m = math.max(m, d.getInt16(i, Endian.little).abs());
  }
  return m;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The recorder registers itself with its plugin when LiveService is
  // built; no microphone is used here, so the plugin just says yes.
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
          const MethodChannel('com.llfbandit.record/messages'),
          (call) async => null);
  late Rig r;

  setUp(() {
    r = Rig()..begin();
  });
  tearDown(() => r.svc.debugEndSession());

  test('speech burst, then the tail, then ONE pause marker, then nothing',
      () {
    r.feed(quiet, 3);
    r.utterance();
    expect(r.markers, ['activity_start', 'activity_end']);
    r.server({'type': 'turn_complete'}); // the model's turn is over
    r.sent.clear();

    r.feed(quiet, 20);
    // 1.2 s of the quiet goes up (Google must HEAR the pause) — as a
    // whisper — then the uplink stops with exactly one marker.
    final marker = r.sent.indexWhere((f) => f is String);
    expect(marker, 10, reason: '10 frames x 128 ms = 1280 ms of tail');
    for (final f in r.sent.take(marker)) {
      expect(peakOf(f as Uint8List), lessThan(50), reason: 'whispered');
    }
    expect(r.markers, ['audio_pause']);
    expect(r.sent.length, marker + 1, reason: 'no frames while silent');
    expect(r.svc.uplinkPaused, isTrue);

    r.feed(quiet, 200); // 25 s of an empty room
    expect(r.sent.length, marker + 1);
    expect(r.svc.uplinkPauses, 1);
  });

  test('onset resumes the uplink with the pre-roll at full volume', () {
    r.utterance();
    r.server({'type': 'turn_complete'});
    r.feed(quiet, 15);
    expect(r.svc.uplinkPaused, isTrue);
    r.sent.clear();

    final a = tone(8000, hz: 300);
    final b = tone(7000, hz: 400);
    r.feed(a); // loud, but not yet speech: held, not sent
    expect(r.sent, isEmpty);
    r.feed(b); // 256 ms loud: onset
    expect(r.svc.uplinkPaused, isFalse);
    expect(r.markers, ['activity_start']);
    final audio = r.audio;
    // The lead-in, oldest first, exactly as recorded (not whispered).
    expect(audio.length, greaterThanOrEqualTo(2));
    expect(audio[audio.length - 2], a);
    expect(audio.last, b);
    expect(r.sent.last, isA<String>(),
        reason: 'the replay goes up before activity_start');

    // Speech streams live from here on, and the next pause needs a new
    // tail after the next utterance.
    r.feed(speech, 3);
    r.feed(quiet, 8);
    expect(r.markers, ['activity_start', 'activity_end']);
    r.server({'type': 'turn_complete'});
    r.sent.clear();
    r.feed(quiet, 11);
    expect(r.markers, ['audio_pause']);
  });

  test('never pauses while the model has the turn', () async {
    r.utterance();
    r.sent.clear();
    // Thinking: no reply yet, well inside the grace after activity_end.
    r.feed(quiet, 40); // 5.1 s
    expect(r.markers, isEmpty);
    expect(r.audio.length, 40);

    // A tool is running: the uplink stays up for as long as it does.
    r.server({'type': 'tool_started', 'tool': 'web_search'});
    r.feed(quiet, 100); // 12.8 s
    expect(r.markers, isEmpty);
    r.server({'type': 'tool_completed', 'tool': 'web_search'});

    // Her reply plays: nothing goes up at all, and no marker.
    r.svc.playing = true;
    final before = r.sent.length;
    r.feed(quiet, 30);
    expect(r.sent.length, before);
    r.server({'type': 'turn_complete'});
    r.svc.playing = false;
    // The loudspeaker's own tail (250 ms of wall-clock time) stays shut out.
    await Future<void>.delayed(const Duration(milliseconds: 300));

    // Her turn is over and the tail was already heard: it pauses now.
    r.feed(quiet, 4);
    expect(r.markers, ['audio_pause']);
  });

  test("the loudspeaker's tail never goes up as the owner talking",
      () async {
    r.svc.playing = true;
    r.feed(speech, 3); // her own voice in the microphone
    r.svc.playing = false;
    r.sent.clear();
    r.feed(speech); // the last of her word, still sounding
    expect(r.sent, isEmpty, reason: 'shut for the speaker tail');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    r.feed(quiet);
    expect(r.audio, hasLength(1), reason: 'open again once it has drained');
  });

  test("the speaker-tail line the server's CI checks is still there", () {
    // The backend's fulfillment test ("barge-in is GONE") reads this file
    // and looks for this exact line; a harmless rewrite of it turned the
    // server's whole test run red.
    final src = File('lib/services/live_service.dart').readAsStringSync();
    expect(src, contains('_micOpenAt = DateTime.now().add(_speakerTail)'));
    expect(src, contains('if (playing || remoteSpeaking || typingMute) {'));
  });

  test('modelTurn: her turn, until turn_complete', () {
    expect(r.svc.modelTurn, isFalse);
    r.utterance();
    expect(r.svc.modelTurn, isTrue, reason: 'an answer is expected');
    r.server({'type': 'turn_complete'});
    expect(r.svc.modelTurn, isFalse);
    r.svc.playing = true;
    expect(r.svc.modelTurn, isTrue);
  });

  // A rebuild (location allowed mid-session) waits for these too, so the
  // owner is never cut off mid-sentence.
  test('ownerTalking: from onset until the hangover ends it', () {
    expect(r.svc.ownerTalking, isFalse);
    r.feed(speech, 3);
    expect(r.svc.ownerTalking, isTrue);
    expect(r.svc.modelTurn, isFalse, reason: 'his turn, not hers');
    // A breath is not the end of what he is saying (2026-09-26).
    r.feed(quiet, 5);
    expect(r.svc.ownerTalking, isTrue, reason: '640 ms of quiet is a pause, not the end');
    r.feed(quiet, 3);
    expect(r.svc.ownerTalking, isFalse);
  });

  test('ownerTalking: the speaker gate holding an utterance', () async {
    r.svc.speakerGateEnabled = true;
    r.svc.speakerScorer = (pcm) async => 0.9;
    r.feed(speech, 2);
    expect(r.svc.ownerTalking, isTrue, reason: 'held, not yet scored');
    r.feed(quiet, 8);
    await Future<void>.delayed(Duration.zero);
    expect(r.svc.ownerTalking, isFalse);
  });

  test('era changes when a session stops', () async {
    final before = r.svc.era;
    r.svc.debugEndSession();
    await r.svc.stop(); // nothing open: only the era moves
    expect(r.svc.era, isNot(before));
  });

  test('a typed request keeps the uplink up until the answer comes', () {
    r.feed(quiet, 12);
    expect(r.markers, ['audio_pause']);
    r.sent.clear();
    r.svc.sendText('what is on my calendar');
    r.feed(quiet, 20);
    // Still paused (nothing to send), and never a second marker.
    expect(r.markers, ['text']);
    expect(r.audio, isEmpty);
  });

  test('translator mode never pauses', () {
    r.svc.translatorBypass = true;
    r.utterance();
    r.server({'type': 'turn_complete'});
    r.sent.clear();
    r.feed(quiet, 60);
    expect(r.markers, isEmpty);
    expect(r.audio.length, 60);
  });

  test('switching to translator mode resumes a paused uplink', () {
    r.feed(quiet, 12);
    expect(r.svc.uplinkPaused, isTrue);
    r.svc.translatorBypass = true;
    r.sent.clear();
    r.feed(quiet, 3);
    expect(r.svc.uplinkPaused, isFalse);
    expect(r.audio.length, 3);
  });

  test('speaker gate: no pause during the hold; accept resumes with it',
      () async {
    r.svc.speakerGateEnabled = true;
    r.svc.speakerScorer = (pcm) async => 0.9; // the enrolled voice
    r.feed(quiet, 12); // quiet streams live at full volume, then pauses
    expect(r.markers, ['audio_pause']);
    expect(peakOf(r.audio.first), greaterThan(10), reason: 'not whispered');
    r.sent.clear();

    r.feed(speech, 8); // held while the voiceprint decides
    expect(r.markers, isEmpty);
    expect(r.audio, isEmpty);
    await Future<void>.delayed(Duration.zero); // the score lands
    expect(r.markers, ['activity_start']);
    expect(r.svc.uplinkPaused, isFalse);
    // The two quiet frames the pause kept back lead in, then the speech.
    final up = r.audio.single;
    expect(up.length, 2 * quiet.length + 8 * speech.length,
        reason: 'the whole held utterance goes up at once');
    expect(up.sublist(0, quiet.length), quiet, reason: 'at full volume');
    expect(up.sublist(2 * quiet.length),
        [for (var i = 0; i < 8; i++) ...speech]);

    r.feed(speech, 2); // accepted: live
    r.feed(quiet, 8);
    expect(r.markers, ['activity_start', 'activity_end']);
    r.server({'type': 'turn_complete'});
    r.sent.clear();
    r.feed(quiet, 11);
    expect(r.markers, ['audio_pause']);
  });

  test('speaker gate: the soft start of a word survives the pause',
      () async {
    r.svc.speakerGateEnabled = true;
    var scored = -1;
    r.svc.speakerScorer = (pcm) async {
      scored = pcm.length;
      return 0.9;
    };
    // An earlier sentence, so the microphone's own loudness is known (a
    // cold detector counts any first sound as loud).
    r.feed(speech, 8);
    await Future<void>.delayed(Duration.zero);
    r.feed(quiet, 8);
    r.server({'type': 'turn_complete'});
    r.feed(quiet, 30);
    expect(r.svc.uplinkPaused, isTrue);
    r.sent.clear();

    final soft = tone(400, hz: 3000); // an "s": under the speech bar
    r.feed(soft);
    expect(r.sent, isEmpty, reason: 'paused: nothing goes up yet');
    r.feed(speech, 8);
    await Future<void>.delayed(Duration.zero);
    expect(r.markers, ['activity_start']);
    expect(scored, 8 * speech.length,
        reason: 'the voiceprint scores the voice, never the quiet');
    final up = r.audio.single;
    // ~450 ms of lead-in (the last three quiet frames and the "s"), then
    // the held speech.
    expect(up.length, 4 * quiet.length + 8 * speech.length);
    expect(up.sublist(3 * quiet.length, 4 * quiet.length), soft,
        reason: 'the onset reaches the model whole, at full volume');
  });

  test('speaker gate: quiet that already went up live is not replayed',
      () async {
    r.svc.speakerGateEnabled = true;
    r.svc.speakerScorer = (pcm) async => 0.9;
    r.feed(quiet, 5); // inside the tail: streamed live, not paused
    expect(r.svc.uplinkPaused, isFalse);
    r.sent.clear();
    r.feed(speech, 8);
    await Future<void>.delayed(Duration.zero);
    expect(r.audio.single.length, 8 * speech.length,
        reason: 'no quiet frame goes up twice');
  });

  test('speaker gate: someone else is dropped, and the room pauses again',
      () async {
    r.svc.speakerGateEnabled = true;
    r.svc.speakerScorer = (pcm) async => 0.05; // not the owner
    r.feed(quiet, 12);
    r.sent.clear();
    r.feed(speech, 10);
    await Future<void>.delayed(Duration.zero);
    r.feed(quiet, 4);
    expect(r.markers, isEmpty, reason: 'rejected: nothing reaches the model');
    expect(r.audio, isEmpty);
  });

  group('a minute of quiet', () {
    test('closes the session once, after 60 s', () {
      r.feed(quiet, 469); // 59.9 s
      expect(r.closes, 0);
      r.feed(quiet);
      expect(r.closes, 1);
      r.feed(quiet, 100);
      expect(r.closes, 1, reason: 'once');
    });

    test('the assistant speaking never triggers it', () {
      r.svc.playing = true;
      r.feed(quiet, 1000); // two minutes of her talking
      expect(r.closes, 0);
      r.svc.playing = false;
      r.feed(quiet, 468);
      expect(r.closes, 0, reason: 'the minute starts when she stops');
      r.feed(quiet, 2);
      expect(r.closes, 1);
    });

    test('an avatar speaking, or a tool running, is not quiet either', () {
      r.svc.remoteSpeaking = true;
      r.feed(quiet, 600);
      r.svc.remoteSpeaking = false;
      r.server({'type': 'tool_started', 'tool': 'find_places_nearby'});
      r.feed(quiet, 600);
      expect(r.closes, 0);
      r.server({'type': 'tool_completed', 'tool': 'find_places_nearby'});
      r.feed(quiet, 468);
      expect(r.closes, 0);
      r.feed(quiet, 2);
      expect(r.closes, 1);
    });

    test('the owner speaking starts the minute over', () {
      r.feed(quiet, 400); // 51 s
      r.utterance();
      r.feed(quiet, 440); // 56 s after the sentence
      expect(r.closes, 0);
      r.feed(quiet, 30);
      expect(r.closes, 1);
    });

    test('a call the assistant placed keeps the session open', () {
      final t0 = DateTime(2026, 9, 24, 10);
      bool running(String? status, Duration ago) =>
          AssistantEngine.callStillRunning(
              status == null
                  ? null
                  : CallStatusInfo(status: status, contactName: 'the clinic'),
              t0,
              t0.add(ago));
      // The server reports only changes: a long "speaking with them" is
      // minutes without a frame, and its outcome comes back through the
      // session — closing it would lose what the business said.
      for (final s in ['dialing', 'ringing', 'in_progress', 'summarizing']) {
        expect(running(s, const Duration(minutes: 2)), isTrue, reason: s);
      }
      for (final s in [
        'completed',
        'failed',
        'no_answer',
        'ended',
        'timeout',
        'cancelled',
      ]) {
        expect(running(s, Duration.zero), isFalse, reason: s);
      }
      expect(running(null, Duration.zero), isFalse);
      expect(running('in_progress', const Duration(minutes: 5)), isFalse,
          reason: "past the server's own 180 s limit it is over");
    });

    test('the engine can decline (a card waiting on a tap)', () {
      r.svc.onQuietTimeout = () {
        r.closes++;
        r.svc.noteActivity(); // not now — try again in a minute
      };
      r.feed(quiet, 470);
      expect(r.closes, 1);
      r.feed(quiet, 468);
      expect(r.closes, 1);
      r.feed(quiet, 1);
      expect(r.closes, 2);
    });
  });

  // Location (owner, 2026-09-24): "my assistant should be aware of user
  // location when he makes any requests".
  group('where the owner is', () {
    final t0 = DateTime(2026, 9, 24, 10);

    test('a move of more than 300 m, or 5 minutes, is worth sending', () {
      expect(
          LiveService.shouldSendLocation(
              lastLat: null, lastLng: null, lastAt: null,
              lat: 12.87, lng: 74.84, now: t0),
          isTrue,
          reason: 'the first fix');
      expect(
          LiveService.shouldSendLocation(
              lastLat: 12.87, lastLng: 74.84, lastAt: t0,
              lat: 12.871, lng: 74.84, // ~111 m
              now: t0.add(const Duration(minutes: 1))),
          isFalse);
      expect(
          LiveService.shouldSendLocation(
              lastLat: 12.87, lastLng: 74.84, lastAt: t0,
              lat: 12.874, lng: 74.84, // ~445 m
              now: t0.add(const Duration(minutes: 1))),
          isTrue);
      expect(
          LiveService.shouldSendLocation(
              lastLat: 12.87, lastLng: 74.84, lastAt: t0,
              lat: 12.87, lng: 74.84,
              now: t0.add(const Duration(minutes: 5))),
          isTrue,
          reason: 'every 5 minutes');
      expect(LiveService.distanceMeters(12.87, 74.84, 12.871, 74.84),
          closeTo(111, 2));
    });

    test('the live session is told with one small message', () {
      expect(r.svc.maybeSendLocation(12.87041, 74.84312, 18.4), isTrue);
      expect(jsonDecode(r.sent.last as String), {
        'type': 'location',
        'lat': 12.8704,
        'lng': 74.8431,
        'acc': 18,
      });
      r.sent.clear();
      r.t = r.t.add(const Duration(minutes: 2));
      expect(r.svc.maybeSendLocation(12.8710, 74.8431, 20), isFalse,
          reason: '~70 m in two minutes: not worth a message');
      expect(r.sent, isEmpty);
      r.t = r.t.add(const Duration(minutes: 3));
      expect(r.svc.maybeSendLocation(12.8710, 74.8431, 20), isTrue);
    });

    test('which requests need the owner\'s position', () {
      for (final yes in [
        'restaurants near me',
        'any petrol pump nearby?',
        'nearest hospital',
        'where am I',
        'book a cab to the airport',
        'how far is the station',
        'directions to Kadri park',
      ]) {
        expect(LocationService.needsHere(yes), isTrue, reason: yes);
      }
      for (final no in [
        'weather in Delhi',
        'call Ravi',
        'what is the time',
        'remind me at 5',
      ]) {
        expect(LocationService.needsHere(no), isFalse, reason: no);
      }
    });

    test('only tools the server offers with location off trigger the ask',
        () {
      // find_places_nearby, get_current_location and start_navigation are
      // hidden from the model while location is denied: they could never
      // start while there was anything to ask.
      expect(LocationService.locationTools, {'book_ride'});
    });
  });
}
