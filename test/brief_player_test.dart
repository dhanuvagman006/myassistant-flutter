import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/features/briefing/brief_now_playing.dart';
import 'package:myassistant/features/briefing/brief_player.dart';
import 'package:myassistant/models/brief.dart';

/// "Play my morning" (2026-09-30): the script's shape, the caption groups,
/// the player (voice, audio, pause, resume, stop, the offer at the end,
/// never into an open microphone) and the now-playing strip.

class FakeVoice implements BriefVoice {
  final made = <String>[];
  final gates = <String, Completer<void>>{};
  bool silent = false;
  int cancels = 0;

  @override
  Future<BriefClip?> make(String text) async {
    made.add(text);
    final g = gates[text];
    if (g != null) await g.future;
    if (silent) return null;
    return BriefClip([Uint8List.fromList(text.codeUnits.take(4).toList())], 24000);
  }

  @override
  void cancel() => cancels++;
}

class FakeAudio implements BriefAudio {
  final played = <String>[];
  int stops = 0;

  @override
  Future<void> play(Uint8List pcm16, {required int sampleRate}) async {
    played.add(String.fromCharCodes(pcm16));
  }

  @override
  Future<void> stop() async => stops++;

  @override
  Future<void> drained() async {}

  @override
  Duration get remaining => Duration.zero;
}

class FakeHost extends BriefHost {
  FakeHost({this.script});
  BriefScript? script;
  bool isTalking = false;
  bool isAnswering = false;
  bool started = false;
  int left = 0;
  final engineNotifier = ValueNotifier<int>(0);

  @override
  Future<BriefScript?> fetch() async => script;
  @override
  bool get talking => isTalking;
  @override
  bool get answering => isAnswering;
  @override
  Future<void> leaveConversation() async {
    left++;
    isTalking = false;
  }

  @override
  Listenable get engine => engineNotifier;
  @override
  bool get userStarted => started;

  void ping() => engineNotifier.value++;
}

const offer = BriefOffer(
  kind: 'meeting_prep',
  say: 'Would you like me to prepare you for your 10:30 am meeting?',
  label: 'Prepare me',
  meetingId: 'ev1',
);

BriefScript scriptOf(List<String> sentences) => BriefScript(
      part: 'morning',
      title: 'Your morning',
      script: sentences.join(' '),
      sentences: sentences,
      seconds: 40,
      offer: offer,
    );

/// Lets the player's async steps run.
Future<void> settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class FakeOfferActions extends BriefOfferActions {
  final ran = <BriefOffer>[];
  @override
  Future<void> run(BuildContext? context, BriefOffer offer) async => ran.add(offer);
}

void main() {
  group('the script from the server', () {
    test('parses, with the offer, and falls back to cutting the script', () {
      final s = BriefScript.fromJson({
        'part': 'evening',
        'title': 'Your evening',
        'greeting': 'Good evening, Sir.',
        'script': 'Good evening, Sir. Nothing more today. Anything for tomorrow?',
        'sentences': ['Good evening, Sir.', 'Nothing more today.', 'Anything for tomorrow?'],
        'seconds': 6,
        'offer': {'kind': 'talk', 'say': 'Anything for tomorrow?', 'label': 'Talk to me', 'request': ''},
        'source': 'ai',
        'empty': true,
      });
      expect(s.part, 'evening');
      expect(s.lines, hasLength(3));
      expect(s.offer!.kind, 'talk');
      expect(s.source, 'ai');
      expect(s.empty, isTrue);
      final old = BriefScript.fromJson({'script': 'One. Two! Three?'});
      expect(old.lines, ['One.', 'Two!', 'Three?']);
      expect(old.offer, isNull);
    });

    test('the meeting on the agenda carries its event id', () {
      final a = AgendaItem.fromJson({'kind': 'meeting', 'title': 'Standup', 'at': 1, 'event_id': 'evX'});
      expect(a.eventId, 'evX');
      expect(AgendaItem.fromJson({'kind': 'reminder', 'id': 3, 'title': 'x'}).eventId, isNull);
    });
  });

  test('caption groups: a sentence or two, never split mid-sentence', () {
    final g = BriefPlayer.captionGroups([
      'Good morning, Sir.',
      'You have one meeting: Design review at 10:30 am.',
      'On your list: call the bank at 11 am and pick up medicines, and the courier before lunch.',
      'Rain likely 5 pm to 7 pm.',
    ], max: 100);
    expect(g, [
      'Good morning, Sir. You have one meeting: Design review at 10:30 am.',
      'On your list: call the bank at 11 am and pick up medicines, and the courier before lunch.',
      'Rain likely 5 pm to 7 pm.',
    ]);
    expect(BriefPlayer.captionGroups(['  ', '']), isEmpty);
  });

  group('the player', () {
    late FakeVoice voice;
    late FakeAudio audio;
    late FakeHost host;
    late BriefPlayer p;
    final lines = [
      'Good morning, Sir. Here is your Wednesday.',
      'You have one meeting: Design review at 10:30 am, at Room 4. On your list: call the bank at 11 am.',
      'Amma has her birthday today, and rain is likely from 5 pm to 7 pm. Keep an umbrella handy.',
      offer.say,
    ];

    setUp(() {
      voice = FakeVoice();
      audio = FakeAudio();
      host = FakeHost(script: scriptOf(lines));
      p = BriefPlayer(voice: voice, audio: audio, host: host);
    });

    tearDown(() => p.debugReset());

    test('plays every group in order, in her voice, then offers the one thing', () async {
      final seen = <BriefPlayState>[];
      p.addListener(() => seen.add(p.state));
      await p.play();
      await settle();
      expect(seen.first, BriefPlayState.loading);
      expect(p.state, BriefPlayState.done);
      expect(voice.made, p.groups, reason: 'each caption group is one speech request');
      expect(audio.played, [for (final g in p.groups) String.fromCharCodes(g.codeUnits.take(4))]);
      expect(p.caption, offer.say, reason: 'finished, the strip shows the offer');
      expect(p.progress, 1);
      expect(p.showStrip, isTrue);
      p.dismiss();
      expect(p.state, BriefPlayState.idle);
      expect(p.showStrip, isFalse);
    });

    test('the next group is made while this one plays', () async {
      final gate = Completer<void>();
      final groups = BriefPlayer.captionGroups(lines);
      voice.gates[groups[0]] = gate;
      unawaited(p.play());
      await settle();
      expect(voice.made.take(2), groups.take(2), reason: 'the second is asked for with the first');
      expect(p.state, BriefPlayState.playing);
      gate.complete();
      await settle();
      expect(p.state, BriefPlayState.done);
    });

    test('pause stops the sound and keeps the place; resume says that group again', () async {
      final groups = BriefPlayer.captionGroups(lines);
      final gate = Completer<void>();
      voice.gates[groups[1]] = gate;
      unawaited(p.play());
      await settle();
      expect(p.index, 0);
      expect(p.caption, groups[0]);
      p.pause();
      expect(p.state, BriefPlayState.paused);
      expect(audio.stops, 1);
      gate.complete();
      await settle();
      expect(p.state, BriefPlayState.paused, reason: 'a paused brief stays paused');
      final before = audio.played.length;
      await p.resume();
      await settle();
      expect(p.state, BriefPlayState.done);
      expect(audio.played.length - before, groups.length,
          reason: 'resumed from the group being heard (the first), to the end');
    });

    test('stop puts it away at once, and drops what is being made', () async {
      final gate = Completer<void>();
      voice.gates[BriefPlayer.captionGroups(lines)[0]] = gate;
      unawaited(p.play());
      await settle();
      await p.stop();
      expect(p.state, BriefPlayState.idle);
      expect(voice.cancels, greaterThan(0));
      gate.complete();
      await settle();
      expect(audio.played, isEmpty, reason: 'nothing plays after Stop');
    });

    test('no words from the server: says so, with the way to try again', () async {
      host.script = null;
      await p.play();
      expect(p.state, BriefPlayState.failed);
      expect(p.caption, contains("Couldn't get your day"));
      host.script = scriptOf(lines);
      await p.play();
      await settle();
      expect(p.state, BriefPlayState.done);
    });

    test('no voice at all: failed, never a silent "done"', () async {
      voice.silent = true;
      await p.play();
      await settle();
      expect(p.state, BriefPlayState.failed);
      expect(p.caption, "Couldn't play your brief.");
    });

    test('asked for by voice: her lead-in finishes, then the conversation is let go', () async {
      host.isTalking = true;
      host.isAnswering = true;
      unawaited(p.play(fromVoice: true));
      await settle();
      expect(host.left, 0, reason: 'never over her own answer');
      expect(audio.played, isEmpty);
      host.isAnswering = false;
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await settle();
      expect(host.left, 1, reason: 'the mic is let go before the brief speaks');
      expect(p.state, BriefPlayState.done);
    });

    test('a conversation starting (the orb, a question) stops the brief', () async {
      final gate = Completer<void>();
      voice.gates[BriefPlayer.captionGroups(lines)[1]] = gate;
      unawaited(p.play());
      await settle();
      expect(p.state, BriefPlayState.playing);
      host.started = true;
      host.ping();
      await settle();
      expect(p.state, BriefPlayState.idle);
      gate.complete();
    });
  });

  group('the now-playing strip', () {
    Future<(BriefPlayer, FakeOfferActions, FakeVoice)> show(WidgetTester t, {double textScale = 1}) async {
      final voice = FakeVoice();
      final p = BriefPlayer(
          voice: voice, audio: FakeAudio(), host: FakeHost(script: scriptOf(['Good morning, Sir.', offer.say])));
      final actions = FakeOfferActions();
      addTearDown(p.debugReset);
      t.view.physicalSize = const Size(380, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(size: const Size(380, 800), textScaler: TextScaler.linear(textScale)),
          child: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: BriefNowPlaying(player: p, actions: actions),
            ),
          ),
        ),
      ));
      return (p, actions, voice);
    }

    testWidgets('while it plays: the words being said, Pause and Stop', (t) async {
      final (p, _, voice) = await show(t);
      final gate = Completer<void>();
      voice.gates[offer.say] = gate;
      voice.gates['Good morning, Sir. ${offer.say}'] = gate;
      await t.runAsync(() async {
        unawaited(p.play());
        await settle();
      });
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(find.text('Your morning'), findsOneWidget);
      expect(find.textContaining('Good morning, Sir.'), findsOneWidget);
      expect(find.byTooltip('Pause'), findsOneWidget);
      expect(find.byTooltip('Stop'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('Your morning, now playing')), findsOneWidget);
      await t.tap(find.byTooltip('Pause'));
      await t.pump(const Duration(milliseconds: 300));
      expect(p.state, BriefPlayState.paused);
      expect(find.byTooltip('Resume'), findsOneWidget);
      await t.tap(find.byTooltip('Stop'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(p.state, BriefPlayState.idle);
      expect(find.text('Your morning'), findsNothing);
      gate.complete();
    });

    testWidgets('finished: the offer as a lit button that does the thing', (t) async {
      final (p, actions, _) = await show(t);
      await t.runAsync(() async {
        await p.play();
        await settle();
      });
      await t.pump(const Duration(milliseconds: 400));
      expect(p.state, BriefPlayState.done);
      expect(find.text(offer.say), findsOneWidget);
      await t.tap(find.text('Prepare me'));
      await t.pump(const Duration(milliseconds: 400));
      expect(actions.ran.single.meetingId, 'ev1');
      expect(p.state, BriefPlayState.idle);
    });

    testWidgets('twice the text size: the strip still fits', (t) async {
      final (p, _, voice) = await show(t, textScale: 2);
      final gate = Completer<void>();
      voice.gates['Good morning, Sir. ${offer.say}'] = gate;
      await t.runAsync(() async {
        unawaited(p.play());
        await settle();
      });
      await t.pump(const Duration(milliseconds: 400));
      expect(t.takeException(), isNull);
      await p.stop();
      await t.pump(const Duration(milliseconds: 400));
      gate.complete();
    });
  });
}
