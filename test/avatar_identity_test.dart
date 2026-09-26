// SEND MESSAGES AS YOU (2026-09-26) — the sender's identity video and the
// recipient's AI video note.
//
// The profile the server reports, the video upload (streamed, with
// progress, a 403 kept distinct, given up only when it stops moving),
// where a note's media may be fetched from with our token, the screen's
// states (never an endless spinner again), the recorder (its refusals, the
// words under the camera, the pace, the review), when a note is allowed to
// open, and the label a recipient sees.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:myassistant/design/neon_tokens.dart';
import 'package:myassistant/features/assistant/state/assistant_engine.dart';
import 'package:myassistant/screens/avatar_identity_screen.dart';
import 'package:myassistant/screens/identity_record_screen.dart';
import 'package:myassistant/services/api_service.dart';
import 'package:myassistant/services/app_feedback.dart';
import 'package:myassistant/services/avatar_message_service.dart';
import 'package:myassistant/services/recording_guard.dart';
import 'package:myassistant/widgets/avatar_message_popup.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

const _video = {
  'id': 'v_12',
  'duration_ms': 31250,
  'bytes': 18400000,
  'created_at': 1790000100000,
  'script_version': 1,
};

final _messenger =
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
const _perms = MethodChannel('flutter.baseflow.com/permissions/methods');

/// How many times the camera and microphone were asked for.
int _asked = 0;

void _permissions(int status) {
  _asked = 0;
  _messenger.setMockMethodCallHandler(_perms, (c) async {
    if (c.method == 'requestPermissions') {
      _asked++;
      return {for (final p in c.arguments as List) p: status};
    }
    return status;
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The real Manrope: the large-text checks measure what the phone draws.
  setUpAll(() async {
    GoogleFonts.config.allowRuntimeFetching = false;
    for (final w in NeonType.weights) {
      GoogleFonts.manrope(fontWeight: w);
    }
    await GoogleFonts.pendingFonts();
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    IdentityRecordScreen.resetPace();
  });
  tearDown(() {
    AppFeedback.resetForTest();
    RecordingGuard.resetForTest();
    _messenger.setMockMethodCallHandler(_perms, null);
  });

  group('the profile', () {
    test('reads every field the server sends', () {
      final p = AvatarProfile.fromJson({
        'consented': true,
        'consented_at': 1790000000000,
        'enabled': true,
        'has_video': true,
        'video': _video,
        'has_face': false,
        'has_voice': true,
        'script_version': 1,
      });
      expect(p.consented, isTrue);
      expect(p.consentedAt, 1790000000000);
      expect(p.enabled, isTrue);
      expect(p.hasVideo, isTrue);
      expect(p.video!.id, 'v_12');
      expect(p.video!.durationMs, 31250);
      expect(p.video!.length, const Duration(milliseconds: 31250));
      expect(p.video!.bytes, 18400000);
      expect(p.video!.createdAt, 1790000100000);
      expect(p.video!.scriptVersion, 1);
      expect(p.hasFace, isFalse);
      expect(p.hasVoice, isTrue);
      expect(p.scriptVersion, 1);
    });

    test('a user with nothing stored reads as all off', () {
      final p = AvatarProfile.fromJson({
        'consented': false,
        'consented_at': null,
        'enabled': false,
        'has_video': false,
        'video': null,
      });
      expect(p.consented, isFalse);
      expect(p.consentedAt, isNull);
      expect(p.enabled, isFalse);
      expect(p.hasVideo, isFalse);
      expect(p.video, isNull);
      expect(AvatarProfile.fromJson(const {}).hasVideo, isFalse);
    });

    test('numbers as text and numeric ids are read the same', () {
      final p = AvatarProfile.fromJson({
        'consented': 1,
        'video': {'id': 42, 'duration_ms': '30000', 'created_at': 1.79e12},
      });
      expect(p.consented, isTrue);
      expect(p.hasVideo, isTrue, reason: 'a video object means there is one');
      expect(p.video!.id, '42');
      expect(p.video!.durationMs, 30000);
      expect(p.video!.createdAt, 1790000000000);
    });
  });

  group('the upload result', () {
    test('200: saved, with the video', () {
      final r = IdentityUploadResult.fromResponse(
          200, jsonEncode({'ok': true, 'video': _video}));
      expect(r.ok, isTrue);
      expect(r.video!.id, 'v_12');
      expect(r.consentRequired, isFalse);
    });

    test('403 consent_required is its own case', () {
      final r = IdentityUploadResult.fromResponse(
          403, jsonEncode({'error': 'consent_required'}));
      expect(r.ok, isFalse);
      expect(r.consentRequired, isTrue);
      expect(r.message, contains('Consent'));
    });

    test('too large, too short, offline, and a server fault each say so', () {
      expect(IdentityUploadResult.fromResponse(413, 'Payload Too Large').tooLarge,
          isTrue);
      final short = IdentityUploadResult.fromResponse(
          400, jsonEncode({'error': 'The video must be 15 to 90 seconds.'}));
      expect(short.message, contains('15 to 90 seconds'));
      const offline = IdentityUploadResult(status: 0);
      expect(offline.message, contains('kept'));
      expect(offline.message, contains('Try again'));
      final fault = IdentityUploadResult.fromResponse(500, '<html>oops</html>');
      expect(fault.ok, isFalse);
      expect(fault.message, contains('500'));
    });
  });

  group('uploading the video', () {
    late File take;
    setUp(() {
      final dir = Directory.systemTemp.createTempSync('identity_upload');
      addTearDown(() => dir.deleteSync(recursive: true));
      take = File('${dir.path}/take.mp4')
        ..writeAsBytesSync(List.filled(300000, 7));
    });

    test('a streamed multipart POST with its fields, reporting progress',
        () async {
      late http.Request seen;
      final client = MockClient((req) async {
        seen = req;
        return http.Response(jsonEncode({'ok': true, 'video': _video}), 200);
      });
      final sent = <int>[];
      var total = 0;
      final r = await AvatarMessageService.uploadVideo(
        take,
        durationMs: 30500,
        scriptVersion: 1,
        client: client,
        onProgress: (s, t) {
          sent.add(s);
          total = t;
        },
      );
      expect(r.ok, isTrue);
      expect(r.video!.id, 'v_12');
      expect(seen.method, 'POST');
      expect(seen.url.path, '/avatar-profile/video');
      expect(seen.headers['content-type'], startsWith('multipart/form-data'));
      final body = latin1.decode(seen.bodyBytes);
      expect(body, contains('name="duration_ms"\r\n\r\n30500'));
      expect(body, contains('name="script_version"\r\n\r\n1'));
      expect(body, contains('name="file"; filename="identity.mp4"'));
      expect(body, contains('content-type: video/mp4'));
      expect(total, greaterThan(300000));
      expect(sent.last, total, reason: 'every byte counted');
      expect(sent.length, greaterThan(1), reason: 'streamed in pieces');
      expect(take.existsSync(), isTrue);
    });

    test('a 403 comes back as consent required', () async {
      final r = await AvatarMessageService.uploadVideo(
        take,
        durationMs: 30000,
        scriptVersion: 1,
        client: MockClient((_) async =>
            http.Response(jsonEncode({'error': 'consent_required'}), 403)),
      );
      expect(r.consentRequired, isTrue);
    });

    test('no connection: status 0, and the take is still on the phone',
        () async {
      final r = await AvatarMessageService.uploadVideo(
        take,
        durationMs: 30000,
        scriptVersion: 1,
        client: MockClient((_) async => throw const SocketException('offline')),
      );
      expect(r.status, 0);
      expect(r.ok, isFalse);
      expect(take.existsSync(), isTrue);
    });

    test('given up when nothing moves; a slow line that moves goes on',
        () async {
      // Nothing is taken from the body, and no answer comes.
      final stuck = await AvatarMessageService.uploadVideo(
        take,
        durationMs: 30000,
        scriptVersion: 1,
        idleLimit: const Duration(milliseconds: 80),
        client: MockClient.streaming(
            (_, __) => Completer<http.StreamedResponse>().future),
      );
      expect(stuck.status, 0);

      // Slow — longer in all than the idle limit — but never still.
      final watch = Stopwatch()..start();
      final slow = await AvatarMessageService.uploadVideo(
        take,
        durationMs: 30000,
        scriptVersion: 1,
        idleLimit: const Duration(milliseconds: 150),
        client: MockClient.streaming((_, body) async {
          await for (final _ in body) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
          return http.StreamedResponse(
              Stream.value(utf8.encode(jsonEncode({'ok': true, 'video': _video}))),
              200);
        }),
      );
      expect(watch.elapsedMilliseconds, greaterThan(150));
      expect(slow.ok, isTrue);
    });
  });

  test("a note's media is fetched with our token only from our own server",
      () {
    const base = 'https://api.hariassistant.tech';
    Uri? at(String? u) => AvatarMessageService.mediaUri(u, base: base);
    expect(at('/messages/5/media').toString(), '$base/messages/5/media');
    expect(at('$base/docs/9/file').toString(), '$base/docs/9/file');
    expect(at('https://elsewhere.example/clip.mp4'), isNull);
    expect(at('http://api.hariassistant.tech/clip.mp4'), isNull,
        reason: 'no downgrade to plain http');
    expect(at(''), isNull);
    expect(at(null), isNull);
  });

  test('signing out sweeps notes and left-behind takes, nothing else',
      () async {
    final dir = Directory.systemTemp.createTempSync('sweep');
    addTearDown(() => dir.deleteSync(recursive: true));
    Set<String> names() =>
        dir.listSync().map((e) => e.uri.pathSegments.last).toSet();
    for (final n in [
      'avatarmsg_7.mp4',
      'avatarmsg_8.wav',
      'REC123.mp4',
      'meeting_1.m4a',
      'RECIPE.txt',
      'photo.jpg',
    ]) {
      File('${dir.path}/$n').writeAsStringSync('x');
    }
    // The recorder, opening: old takes only.
    await AvatarMessageService.sweepTemporary(dir: dir, takesOnly: true);
    expect(names(), {
      'avatarmsg_7.mp4',
      'avatarmsg_8.wav',
      'meeting_1.m4a',
      'RECIPE.txt',
      'photo.jpg'
    });
    // ...and never one newer than the moment it opened.
    File('${dir.path}/REC9.mp4').writeAsStringSync('x');
    await AvatarMessageService.sweepTemporary(
        dir: dir,
        takesOnly: true,
        before: DateTime.now().subtract(const Duration(hours: 1)));
    expect(names(), contains('REC9.mp4'));
    // Signing out: other people's notes as well.
    await AvatarMessageService.sweepTemporary(dir: dir);
    expect(names(), {'meeting_1.m4a', 'RECIPE.txt', 'photo.jpg'});
  });

  group('the recipient', () {
    test("the label's prefix is not repeated under the title", () {
      expect(videoNoteWords('AI video note from Ravi: meet me at twelve'),
          'meet me at twelve');
      expect(videoNoteWords('See you at twelve'), 'See you at twelve');
    });

    testWidgets('a video note says it was made by AI, and from whom',
        (t) async {
      await t.pumpWidget(MaterialApp(
        home: Builder(
          builder: (c) => TextButton(
            onPressed: () => showAvatarMessagePopup(
              c,
              senderName: 'Ravi',
              text: 'AI video note from Ravi: meet me at twelve',
              // The clip could not be fetched: the words still carry the label.
              kind: 'text',
              videoNote: true,
            ),
            child: const Text('open'),
          ),
        ),
      ));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      expect(find.text('AI video note from Ravi'), findsOneWidget);
      expect(find.text('meet me at twelve'), findsOneWidget);
      expect(find.byIcon(Icons.videocam_off_rounded), findsOneWidget);
    });
  });

  group('when a video note may open', () {
    final svc = AvatarMessageService.instance;
    late bool Function() mustWait;
    late Duration poll, cap;
    late Future<List<Map<String, dynamic>>?> Function() fetchUnread;
    late Future<void> Function(Object?) markRead;
    late Future<File?> Function(Map<String, dynamic>) download;
    late Future<void> Function(String, String) notify;
    late List<Object?> marked;
    late List<String> notes;
    late int fetches;

    Map<String, dynamic> note(int id, String from) => {
          'id': id,
          'from': from,
          'message': 'AI video note from $from: meet me at twelve',
          'media': 'video',
          'media_url': '/docs/$id/file',
        };

    setUp(() {
      mustWait = svc.mustWait;
      poll = svc.freePoll;
      cap = svc.freeCap;
      fetchUnread = svc.fetchUnread;
      markRead = svc.markRead;
      download = svc.download;
      notify = svc.notify;
      marked = [];
      notes = [];
      fetches = 0;
      ApiService.sessionToken = 'test';
      svc
        ..freePoll = const Duration(milliseconds: 100)
        ..markRead = ((id) async => marked.add(id))
        ..download = ((_) async {
          fetches++;
          return null;
        })
        ..notify = ((title, _) async => notes.add(title));
    });
    tearDown(() {
      svc
        ..mustWait = mustWait
        ..freePoll = poll
        ..freeCap = cap
        ..fetchUnread = fetchUnread
        ..markRead = markRead
        ..download = download
        ..notify = notify;
      ApiService.sessionToken = null;
    });

    Future<void> app(WidgetTester t) => t.pumpWidget(MaterialApp(
        navigatorKey: AvatarMessageService.navigatorKey,
        home: const Scaffold()));

    Future<void> close(WidgetTester t) async {
      await t.tap(find.byTooltip('Close'));
      await t.pumpAndSettle();
    }

    testWidgets(
        'it waits while the speaker and mic are busy, then opens at once and '
        'gets its clip itself — with Try again when it does not come',
        (t) async {
      await app(t);
      var busy = true;
      final clip = Completer<File?>();
      svc
        ..mustWait = (() => busy)
        ..fetchUnread = (() async => [note(7, 'Ravi')])
        ..download = ((_) {
          fetches++;
          return fetches == 1 ? clip.future : Future.value(null);
        });
      final done = svc.showPending();
      await t.pump(const Duration(seconds: 3));
      expect(find.text('AI video note from Ravi'), findsNothing);
      expect(marked, isEmpty, reason: 'still unread while it waits');
      busy = false;
      await t.pump(const Duration(milliseconds: 150));
      await t.pump();
      // Up at once, saying what it is doing — not a minute of nothing.
      expect(find.text('AI video note from Ravi'), findsOneWidget);
      expect(find.text('Getting the video…'), findsOneWidget);
      expect(marked, [7]);
      expect(fetches, 1);
      clip.complete(null); // the line dropped
      await t.pump();
      await t.pump();
      expect(find.text('Getting the video…'), findsNothing);
      expect(find.textContaining("The video didn't load"), findsOneWidget);
      expect(find.textContaining('saved in your documents'), findsOneWidget);
      await t.tap(find.text('Try again'));
      await t.pump();
      await t.pump();
      expect(fetches, 2);
      await close(t);
      expect(await done, isTrue);
    });

    testWidgets('a recording, a voice session or the app lock holds it',
        (t) async {
      // The real check, not a stand-in: nothing is busy in a test...
      expect(svc.mustWait(), isFalse);
      // ...until a recorder holds the room.
      RecordingGuard.hold(#meeting);
      expect(svc.mustWait(), isTrue);
      RecordingGuard.hold(#identity);
      RecordingGuard.release(#meeting);
      expect(svc.mustWait(), isTrue,
          reason: 'one recorder letting go frees nothing for the other');
      RecordingGuard.release(#identity);
      expect(svc.mustWait(), isFalse);
    });

    testWidgets('a note that comes while another is open is shown after it',
        (t) async {
      await app(t);
      var round = 0;
      svc
        ..mustWait = (() => false)
        ..fetchUnread = (() async {
          round++;
          return round == 1
              ? [note(1, 'Ravi')]
              : round == 2
                  ? [note(2, 'Meera')]
                  : const [];
        });
      final first = svc.showPending();
      await t.pump();
      await t.pump();
      expect(find.text('AI video note from Ravi'), findsOneWidget);
      // The second push: taken, not dropped.
      expect(await svc.showPending(), isTrue);
      await close(t);
      expect(find.text('AI video note from Meera'), findsOneWidget);
      await close(t);
      expect(await first, isTrue);
      expect(marked, [1, 2]);
      expect(round, 2);
    });

    testWidgets('after ten minutes busy it leaves a notification instead',
        (t) async {
      await app(t);
      svc
        ..mustWait = (() => true)
        ..freePoll = const Duration(seconds: 1)
        ..freeCap = const Duration(minutes: 10)
        ..fetchUnread = (() async => [note(7, 'Ravi')]);
      final done = svc.showPending();
      for (var i = 0; i < 11; i++) {
        await t.pump(const Duration(minutes: 1));
      }
      expect(await done, isTrue);
      expect(notes, ['Ravi sent you a video note']);
      expect(marked, isEmpty, reason: 'unread: the tap shows it');
      expect(find.byType(Dialog), findsNothing);
    });

    testWidgets('"show the other later" leaves the way back in the tray',
        (t) async {
      await app(t);
      svc
        ..mustWait = (() => false)
        ..fetchUnread = (() async => [note(1, 'Ravi'), note(2, 'Meera')]);
      final done = svc.showPending();
      await t.pump();
      await t.pump();
      await t.tap(find.text('Show the other 1 later'));
      await t.pumpAndSettle();
      expect(await done, isTrue);
      expect(marked, [1]);
      expect(notes, ['A video note is waiting']);
    });
  });

  group('the screen', () {
    Future<void> settle(WidgetTester t) async {
      for (var i = 0; i < 4; i++) {
        await t.pump(const Duration(milliseconds: 200));
      }
    }

    final at = DateTime(2026, 9, 26, 10).millisecondsSinceEpoch;
    AvatarProfile recorded() => AvatarProfile(
          consented: true,
          consentedAt: at,
          enabled: true,
          hasVideo: true,
          video: IdentityVideo(id: 'v_12', durationMs: 31250, createdAt: at),
        );

    testWidgets('a failed load shows the error and Try again, not a spinner',
        (t) async {
      var calls = 0;
      await t.pumpWidget(MaterialApp(
          home: AvatarIdentityScreen(loader: () async {
        calls++;
        return null;
      })));
      await settle(t);
      expect(find.textContaining("Couldn't load your video settings"),
          findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await t.tap(find.text('Try again'));
      await settle(t);
      expect(calls, 2);
    });

    testWidgets('before consent: what the video is for, and nothing else asked',
        (t) async {
      await t.pumpWidget(MaterialApp(
          home: AvatarIdentityScreen(
              loader: () async => const AvatarProfile())));
      await settle(t);
      expect(find.textContaining('reading a script'), findsOneWidget);
      // Said plainly: where it is kept, and that a person makes each note.
      expect(find.textContaining('saved on our servers'), findsOneWidget);
      expect(find.textContaining('made from it by our team'), findsOneWidget);
      expect(find.textContaining('only to make the video notes you ask for'),
          findsOneWidget);
      expect(find.textContaining('marked as made by AI'), findsWidgets);
      expect(find.textContaining('Delete it any time'), findsOneWidget);
      expect(find.text('I agree'), findsOneWidget);
      expect(find.text('Delete everything'), findsOneWidget);
      // The photo and voice-sample capture are gone: the video carries both.
      expect(find.text('Gallery'), findsNothing);
      expect(find.text('Record sample'), findsNothing);
      expect(find.text('Record your video'), findsNothing,
          reason: 'consent comes first');
    });

    testWidgets('consented, no video yet: Record, and the switch waits for it',
        (t) async {
      await t.pumpWidget(MaterialApp(
          home: AvatarIdentityScreen(
              loader: () async => const AvatarProfile(consented: true))));
      await settle(t);
      expect(find.text('No video yet'), findsOneWidget);
      expect(find.text('Record your video'), findsOneWidget);
      expect(t.widget<Switch>(find.byType(Switch)).onChanged, isNull);
    });

    testWidgets('with a video: when, how long, Record again, and the switch',
        (t) async {
      await t.pumpWidget(
          MaterialApp(home: AvatarIdentityScreen(loader: () async => recorded())));
      await settle(t);
      expect(find.text('Recorded'), findsOneWidget);
      expect(find.text('26 Sep 2026 · 0:31'), findsOneWidget);
      expect(find.text('Record again'), findsOneWidget);
      expect(find.text('Consent given'), findsOneWidget);
      expect(find.text('Withdraw consent'), findsOneWidget);
      // The name the assistant says when it is off, and no promise of a
      // text fallback that does not exist.
      expect(find.text('Send as you'), findsOneWidget);
      expect(find.textContaining('When off, none are made.'), findsOneWidget);
      expect(find.textContaining('as text'), findsNothing);
      final s = t.widget<Switch>(find.byType(Switch));
      expect(s.value, isTrue);
      expect(s.onChanged, isNotNull);
    });

    testWidgets('the largest text on a small phone cuts no row title',
        (t) async {
      t.view.devicePixelRatio = 2.0;
      t.view.physicalSize = const Size(720, 1400);
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        home: MediaQuery.withClampedTextScaling(
          minScaleFactor: 2.0,
          maxScaleFactor: 2.0,
          child: AvatarIdentityScreen(loader: () async => recorded()),
        ),
      ));
      await settle(t);
      for (final title in [
        'Recorded',
        'Record again',
        'Send as you',
        'Consent given',
        'Withdraw consent',
      ]) {
        await t.scrollUntilVisible(find.text(title), 100,
            scrollable: find.byType(Scrollable).first);
        final p = t.renderObject<RenderParagraph>(find.text(title));
        expect(p.didExceedMaxLines, isFalse, reason: title);
      }
    });

    test("a refusal to turn it on names what is really missing", () {
      // The server's two refusals (PUT /avatar-profile/prefs, 409).
      expect(enableRefusal('Agree to video notes first.'),
          'Give your consent first.');
      expect(enableRefusal('Record your 30-second video first.'),
          'Record your video first.');
      expect(enableRefusal('consent_required'), 'Give your consent first.');
      expect(enableRefusal(null), "Couldn't change that — try again.");
    });

    testWidgets('the saved video stops before the recorder opens', (t) async {
      final player = _FakePlayer();
      final before = VideoPlayerPlatform.instance;
      VideoPlayerPlatform.instance = player;
      addTearDown(() => VideoPlayerPlatform.instance = before);
      final dir = Directory.systemTemp.createTempSync('thumb');
      addTearDown(() => dir.deleteSync(recursive: true));
      final copy = File('${dir.path}/v_12.mp4')..writeAsBytesSync(const [0]);
      _permissions(0); // the recorder opens on its permission view
      await t.pumpWidget(MaterialApp(
          home: AvatarIdentityScreen(
              loader: () async => recorded(),
              localCopyOf: (_) async => copy)));
      await settle(t);
      await t.tap(find.byType(VideoPlayer));
      await t.pump();
      expect(player.log.last, 'play');
      await t.tap(find.text('Record again'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(find.byType(IdentityRecordScreen), findsOneWidget);
      expect(player.log.lastIndexOf('pause'),
          greaterThan(player.log.lastIndexOf('play')),
          reason: 'its sound would be in the new take');
    });
  });

  group('the recorder', () {
    const camera = MethodChannel('plugins.flutter.io/camera');
    tearDown(() => _messenger.setMockMethodCallHandler(camera, null));

    Future<void> open(WidgetTester t) async {
      await t.pumpWidget(const MaterialApp(home: IdentityRecordScreen()));
      for (var i = 0; i < 4; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
    }

    testWidgets('permission refused: says why, and asks again', (t) async {
      _permissions(0); // denied
      await open(t);
      expect(find.text('Camera and microphone needed'), findsOneWidget);
      expect(find.text('Allow'), findsOneWidget);
    });

    testWidgets(
        'a refusal is not asked again as the prompt closes; back from '
        'Settings, it is', (t) async {
      _permissions(0);
      await open(t);
      expect(_asked, 1);
      // The prompt closing: the app was only INACTIVE.
      final b = t.binding;
      b.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      b.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      for (var i = 0; i < 4; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
      expect(_asked, 1, reason: '"Don\'t allow" must not bring it straight back');
      expect(find.text('Allow'), findsOneWidget);
      // A real trip away (to Settings) and back.
      b.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      b.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      b.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await t.pump();
      b.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      b.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      b.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      for (var i = 0; i < 4; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
      expect(_asked, 2);
      // And the Allow button asks once.
      await t.tap(find.text('Allow'));
      for (var i = 0; i < 4; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
      expect(_asked, 3);
    });

    testWidgets('permission refused for good: the way to Settings', (t) async {
      _permissions(4); // permanently denied
      await open(t);
      expect(find.text('Camera and microphone are off'), findsOneWidget);
      expect(find.text('Open settings'), findsOneWidget);
    });

    testWidgets('no front camera: never falls back to the back one',
        (t) async {
      _permissions(1);
      _messenger.setMockMethodCallHandler(camera, (c) async {
        if (c.method == 'availableCameras') {
          return [
            {'name': '0', 'lensFacing': 'back', 'sensorOrientation': 90},
          ];
        }
        return null;
      });
      await open(t);
      expect(find.text('No front camera'), findsOneWidget);
    });

    testWidgets('while it is open, a video note waits', (t) async {
      _permissions(0);
      await open(t);
      expect(RecordingGuard.busy, isTrue);
      await t.pumpWidget(const SizedBox());
      expect(RecordingGuard.busy, isFalse);
    });

    group('with a camera', () {
      late _FakeCamera cam;
      late List<bool> screenOn;
      const device = MethodChannel('hari/device');
      setUp(() {
        cam = _FakeCamera();
        final before = CameraPlatform.instance;
        CameraPlatform.instance = cam;
        addTearDown(() => CameraPlatform.instance = before);
        screenOn = [];
        _messenger.setMockMethodCallHandler(device, (c) async {
          if (c.method == 'keepScreenOn') {
            screenOn.add((c.arguments as Map)['on'] as bool);
          }
          return true;
        });
        addTearDown(() => _messenger.setMockMethodCallHandler(device, null));
      });

      final button = find.byKey(const ValueKey('record-button'));
      final lines = identityScript.split('\n');

      Future<void> countIn(WidgetTester t) async {
        await t.tap(button);
        await t.pump();
        expect(find.text('3'), findsOneWidget);
        await t.pump(const Duration(seconds: 1));
        expect(find.text('2'), findsOneWidget);
        await t.pump(const Duration(seconds: 1));
        expect(find.text('1'), findsOneWidget);
        await t.pump(const Duration(seconds: 1));
        await t.pump(); // recording starts; the clock's first frame
      }

      Future<void> stop(WidgetTester t) async {
        await t.tap(button);
        await t.pump();
        await t.pump();
        await t.pump();
      }

      testWidgets(
          'front camera, 720p with sound at a sane bitrate; a take under '
          '20 s is refused and says why; at a minute it stops by itself',
          (t) async {
        _permissions(1);
        await open(t);
        expect(cam.settings!.resolutionPreset, ResolutionPreset.high);
        expect(cam.settings!.enableAudio, isTrue);
        expect(cam.settings!.videoBitrate, IdentityRecordRules.videoBitrate);
        expect(cam.settings!.audioBitrate, IdentityRecordRules.audioBitrate);
        expect(cam.created!.lensDirection, CameraLensDirection.front);
        expect(find.text("I'm recording this"), findsOneWidget);

        await countIn(t);
        expect(cam.started, 1);
        expect(screenOn, [true], reason: 'the screen stays on while recording');
        await t.pump(const Duration(seconds: 10));
        expect(find.text('0:10'), findsOneWidget);
        await stop(t);
        expect(cam.stopped, 1);
        expect(screenOn.last, isFalse);
        expect(find.text(IdentityRecordRules.tooShort), findsOneWidget);
        expect(find.text('Watch it back'), findsNothing);

        await countIn(t);
        expect(cam.started, 2);
        await t.pump(const Duration(seconds: 59));
        expect(cam.stopped, 1, reason: 'still recording at 0:59');
        await t.pump(const Duration(seconds: 1));
        await t.pump();
        await t.pump();
        expect(cam.stopped, 2, reason: 'stopped by itself at 1:00');
        expect(find.text('Watch it back'), findsOneWidget);
        expect(find.text('1:00'), findsOneWidget);
        expect(find.text('Save'), findsOneWidget);

        await t.tap(find.text('Retake'));
        await t.pump();
        await t.pump();
        expect(find.text('Watch it back'), findsNothing);
        expect(cam.resumed, 1);
      });

      testWidgets(
          'the words are read just under the camera; the 3-2-1 sits over '
          'the face, clear of them', (t) async {
        t.view.devicePixelRatio = 2.75;
        t.view.physicalSize = const Size(393 * 2.75, 851 * 2.75);
        addTearDown(t.view.reset);
        _permissions(1);
        await open(t);
        final reading = t.getCenter(find.text(lines.first)).dy;
        expect(reading / 851, lessThan(0.22),
            reason: 'halfway down, the eyes looked down in every note');
        await t.tap(button);
        await t.pump();
        final digit = t.getRect(find.text('3'));
        expect(digit.center.dy / 851, inInclusiveRange(0.35, 0.65));
        for (final l in lines.take(4)) {
          expect(t.getRect(find.text(l)).overlaps(digit), isFalse, reason: l);
        }
        await t.tap(button); // cancel
        await t.pump();
      });

      testWidgets('every stage fits a small phone at the largest text, with '
          'every instruction whole', (t) async {
        t.view.devicePixelRatio = 2.0;
        t.view.physicalSize = const Size(720, 1280);
        addTearDown(t.view.reset);
        _permissions(1);
        await t.pumpWidget(MaterialApp(
          home: MediaQuery.withClampedTextScaling(
            minScaleFactor: 2.0,
            maxScaleFactor: 2.0,
            child: const IdentityRecordScreen(),
          ),
        ));
        for (var i = 0; i < 4; i++) {
          await t.pump(const Duration(milliseconds: 100));
        }
        expect(button, findsOneWidget, reason: 'ready');
        void whole(Finder f) {
          final p = t.renderObject<RenderParagraph>(f);
          expect(p.maxLines, isNull);
          expect(p.didExceedMaxLines, isFalse);
        }

        whole(find.textContaining('Hold the phone at eye level'));
        await countIn(t);
        await t.pump(const Duration(seconds: 12));
        await stop(t);
        whole(find.text(IdentityRecordRules.tooShort));
        await countIn(t);
        await t.pump(const Duration(seconds: 36));
        expect(find.text('Finished? Tap to stop.'), findsOneWidget);
        await stop(t);
        expect(find.text('Watch it back'), findsOneWidget);
        // Overflow would have failed the test by now.
      });

      testWidgets('a slower pace for a slower reader, kept for the next take',
          (t) async {
        _permissions(1);
        await open(t);
        await t.tap(find.byKey(const ValueKey('pace-slower')));
        await t.pump();
        await countIn(t);
        await t.pump(const Duration(seconds: 36));
        // At the normal pace the script is over by now; at the slower one
        // it is still going.
        expect(find.text('Read along at an easy pace.'), findsOneWidget);
        await t.pump(const Duration(seconds: 7));
        expect(find.text('Finished? Tap to stop.'), findsOneWidget);
        await stop(t);
        await t.tap(find.text('Retake'));
        await t.pump();
        await t.pump();
        final chip = t.widget<Semantics>(find
            .ancestor(
                of: find.byKey(const ValueKey('pace-slower')),
                matching: find.byType(Semantics))
            .first);
        expect(chip.properties.selected, isTrue);
      });

      testWidgets('leaving the app mid-take throws the take away', (t) async {
        _permissions(1);
        await open(t);
        await countIn(t);
        await t.pump(const Duration(seconds: 12));
        final b = t.binding;
        b.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        b.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        await t.pump();
        await t.pump();
        expect(cam.stopped, 1);
        expect(cam.disposed, 1, reason: 'the camera is given up in the background');
        b.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        b.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        for (var i = 0; i < 4; i++) {
          await t.pump(const Duration(milliseconds: 100));
        }
        expect(find.textContaining('nothing was kept'), findsOneWidget);
        expect(find.text('Watch it back'), findsNothing);
        expect(cam.createdCount, 2, reason: 'the camera opens again on return');
      });

      testWidgets('a camera given up late is waited for before a new one opens',
          (t) async {
        final gate = Completer<void>();
        cam.holdDispose = gate.future;
        _permissions(1);
        await open(t);
        await countIn(t);
        await t.pump(const Duration(seconds: 5));
        final b = t.binding;
        b.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        b.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        await t.pump();
        b.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        b.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        for (var i = 0; i < 4; i++) {
          await t.pump(const Duration(milliseconds: 100));
        }
        expect(cam.createdCount, 1, reason: 'the old one is still going');
        gate.complete();
        for (var i = 0; i < 4; i++) {
          await t.pump(const Duration(milliseconds: 100));
        }
        expect(cam.createdCount, 2);
        expect(cam.log.indexOf('disposed'), lessThan(cam.log.lastIndexOf('create')));
      });

      testWidgets(
          'review: the take plays with the screen on; a tap pauses and plays '
          'it; back from the background it plays again', (t) async {
        final player = _FakePlayer();
        final before = VideoPlayerPlatform.instance;
        VideoPlayerPlatform.instance = player;
        addTearDown(() => VideoPlayerPlatform.instance = before);
        _permissions(1);
        await open(t);
        await countIn(t);
        await t.pump(const Duration(seconds: 25));
        await stop(t);
        await t.pump();
        expect(find.text('Watch it back'), findsOneWidget);
        expect(player.log.last, 'play');
        expect(screenOn.last, isTrue, reason: 'on while it plays');

        final middle = t.getCenter(find.byType(Scaffold));
        await t.tapAt(middle);
        await t.pump();
        expect(player.log.last, 'pause');
        expect(screenOn.last, isFalse);
        await t.tapAt(middle);
        await t.pump();
        expect(player.log.last, 'play');

        final b = t.binding;
        b.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        b.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        b.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await t.pump();
        expect(player.log.last, 'pause');
        b.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        b.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        b.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await t.pump();
        expect(player.log.last, 'play',
            reason: 'it came back to a frozen frame');
        expect(screenOn.last, isTrue);
      });
    });

    testWidgets('a camera that will not start: Try again, and no gallery',
        (t) async {
      _permissions(1);
      _messenger.setMockMethodCallHandler(camera, (c) async {
        throw PlatformException(code: 'CameraAccess', message: 'in use');
      });
      await open(t);
      expect(find.text("Couldn't start the camera"), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
      expect(find.textContaining('Gallery'), findsNothing);
      expect(find.byIcon(Icons.photo_library_rounded), findsNothing);
    });
  });

  testWidgets('the server can open "Send messages as you" by voice',
      (t) async {
    expect(AssistantEngine.instance.canOpenAppScreen('avatar_identity'),
        isTrue);
    expect(AssistantEngine.instance.canOpenAppScreen('no_such_screen'),
        isFalse);
  });
}

/// A front camera that records instantly. The "file" it hands back is
/// only a path; deletes of it are noted.
class _FakeCamera extends CameraPlatform {
  final _ready = StreamController<CameraInitializedEvent>.broadcast();
  final _errors = StreamController<CameraErrorEvent>.broadcast();
  MediaSettings? settings;
  CameraDescription? created;
  int createdCount = 0, started = 0, stopped = 0, resumed = 0, disposed = 0;
  final log = <String>[];

  /// A release that takes its time, as the real one can.
  Future<void>? holdDispose;
  late final String _dir =
      Directory.systemTemp.createTempSync('fake_camera').path;

  @override
  Future<List<CameraDescription>> availableCameras() async => const [
        CameraDescription(
            name: '0',
            lensDirection: CameraLensDirection.back,
            sensorOrientation: 90),
        CameraDescription(
            name: '1',
            lensDirection: CameraLensDirection.front,
            sensorOrientation: 270),
      ];

  @override
  Future<int> createCameraWithSettings(
      CameraDescription description, MediaSettings mediaSettings) async {
    created = description;
    settings = mediaSettings;
    log.add('create');
    return ++createdCount;
  }

  @override
  Stream<CameraInitializedEvent> onCameraInitialized(int cameraId) =>
      _ready.stream;

  // Never closes: the controller waits on .first of it.
  @override
  Stream<CameraErrorEvent> onCameraError(int cameraId) => _errors.stream;

  @override
  Stream<DeviceOrientationChangedEvent> onDeviceOrientationChanged() =>
      const Stream.empty();

  @override
  Future<void> initializeCamera(int cameraId,
      {ImageFormatGroup imageFormatGroup = ImageFormatGroup.unknown}) async {
    scheduleMicrotask(() => _ready.add(CameraInitializedEvent(cameraId, 1280,
        720, ExposureMode.auto, false, FocusMode.auto, false)));
  }

  @override
  Future<void> lockCaptureOrientation(
      int cameraId, DeviceOrientation orientation) async {}

  @override
  Future<void> prepareForVideoRecording() async {}

  @override
  Future<void> startVideoCapturing(VideoCaptureOptions options) async =>
      started++;

  @override
  Future<XFile> stopVideoRecording(int cameraId) async {
    stopped++;
    final path = '$_dir/take_$stopped.mp4';
    File(path).writeAsBytesSync(const [0, 0, 0, 24]);
    return XFile(path);
  }

  @override
  Future<void> pausePreview(int cameraId) async {}

  @override
  Future<void> resumePreview(int cameraId) async => resumed++;

  @override
  Widget buildPreview(int cameraId) => const ColoredBox(color: Colors.teal);

  @override
  Future<void> dispose(int cameraId) async {
    log.add('dispose');
    final hold = holdDispose;
    if (hold != null) await hold;
    disposed++;
    log.add('disposed');
  }
}

/// A video player that plays nothing and notes what it was told.
class _FakePlayer extends VideoPlayerPlatform {
  final log = <String>[];
  final _events = <int, StreamController<VideoEvent>>{};
  int _next = 0;

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final id = _next++;
    final events = StreamController<VideoEvent>();
    _events[id] = events;
    log.add('create');
    scheduleMicrotask(() => events.add(VideoEvent(
        eventType: VideoEventType.initialized,
        duration: const Duration(seconds: 30),
        size: const Size(720, 1280))));
    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => _events[playerId]!.stream;

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> play(int playerId) async => log.add('play');

  @override
  Future<void> pause(int playerId) async => log.add('pause');

  @override
  Future<void> setVolume(int playerId, double volume) async {}

  @override
  Future<void> seekTo(int playerId, Duration position) async {}

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;

  @override
  Widget buildViewWithOptions(VideoViewOptions options) =>
      const ColoredBox(color: Colors.indigo);

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}

  @override
  Future<void> setPreventsDisplaySleepDuringVideoPlayback(
      int playerId, bool preventsDisplaySleepDuringVideoPlayback) async {}

  @override
  Future<void> dispose(int playerId) async => log.add('dispose');
}
