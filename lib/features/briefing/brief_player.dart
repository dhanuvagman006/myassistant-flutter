import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../ai/model_port.dart';
import '../../ai/speech.dart';
import '../../models/brief.dart';
import '../../core/log.dart';
import '../../services/audio/pcm_player.dart';
import '../../services/brief_service.dart';
import '../../services/missed_calls_service.dart';
import '../assistant/state/assistant_engine.dart';
import '../assistant/state/assistant_state.dart';
import 'brief_now_playing.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  "PLAY MY MORNING" (2026-09-30): the day, read aloud in the assistant's
///  own voice in about a minute — meetings, reminders, missed calls,
///  promises, birthdays, bills, the weather — with captions, pause and
///  stop, ending on one helpful offer ("Would you like me to prepare you
///  for your 10:30 meeting?") that is also a button.
///
///  The words come from the server (POST /brief/script, written from the
///  brief only; see BriefService.fetchScript). The voice is the app's
///  Gemini TTS (ai/speech.dart) into the app's one player, so it sounds
///  exactly like her, and the orb moves with it.
///
///  CAPTION GROUPS, ONE REQUEST EACH. The script is cut into groups of a
///  sentence or two; each is one speech request (one natural intonation,
///  not a reset per sentence) and one caption. The next group is made
///  while this one plays. Pause stops the sound and keeps the group being
///  heard; resume says that group again from its start.
///
///  NEVER INTO AN OPEN MICROPHONE. A conversation that is running is let
///  go first (after its own words are done, when the request came by
///  voice), and anything that starts one — the orb, a question — stops
///  the brief.
/// ─────────────────────────────────────────────────────────────────────────

enum BriefPlayState { idle, loading, playing, paused, done, failed }

/// One caption group's audio: PCM16 mono chunks at [sampleRate].
class BriefClip {
  const BriefClip(this.chunks, this.sampleRate);
  final List<Uint8List> chunks;
  final int sampleRate;
}

/// Makes a caption group's audio.
abstract interface class BriefVoice {
  /// [text]'s audio, or null when it could not be made.
  Future<BriefClip?> make(String text);

  /// Drops anything being made.
  void cancel();
}

/// Where the audio plays (the app's PcmPlayer).
abstract interface class BriefAudio {
  Future<void> play(Uint8List pcm16, {required int sampleRate});
  Future<void> stop();

  /// Completes once nothing queued is still sounding.
  Future<void> drained();

  /// How long until what is queued has all been heard.
  Duration get remaining;
}

/// The assistant's own voice: Gemini TTS through ai/speech.dart. Its OWN
/// speech engine, so stopping the brief never cancels a reply.
class SpeechBriefVoice implements BriefVoice {
  SpeechBriefVoice([SpeechEngine? engine])
      : _engine = engine ?? SpeechEngine(port: ModelPorts.cloud());
  final SpeechEngine _engine;
  final _open = <SpeechStream>{};

  @override
  Future<BriefClip?> make(String text) async {
    final line = SpeechEngine.forSpeech(text).trim();
    if (line.isEmpty) return null;
    final s = _engine.open(style: 'warm, calm and unhurried');
    _open.add(s);
    final chunks = <Uint8List>[];
    var rate = 24000;
    try {
      s.add(line);
      s.close();
      await s.release(null, onChunk: (c) {
        chunks.add(c.pcm);
        rate = c.sampleRate;
      });
    } catch (e) {
      AppLog.add('brief', 'a caption could not be voiced: $e');
    } finally {
      _open.remove(s);
    }
    return chunks.isEmpty ? null : BriefClip(chunks, rate);
  }

  @override
  void cancel() {
    for (final s in List.of(_open)) {
      s.cancel();
    }
    _open.clear();
  }
}

class _PcmBriefAudio implements BriefAudio {
  const _PcmBriefAudio();
  PcmPlayer get _p => PcmPlayer.instance;
  @override
  Future<void> play(Uint8List pcm16, {required int sampleRate}) =>
      _p.play(pcm16, sampleRate: sampleRate);
  @override
  Future<void> stop() => _p.stop();
  @override
  Future<void> drained() => _p.drained();
  @override
  Duration get remaining => _p.remaining;
}

/// What the brief does to the rest of the app: fetch the words, let go of
/// a running conversation, notice one starting. Tests hand in their own.
class BriefHost {
  const BriefHost();

  Future<BriefScript?> fetch() => BriefService.instance
      .fetchScript(missed: MissedCallsService.instance.pending.value);

  /// A conversation is on (the mic may be open).
  bool get talking {
    final e = AssistantEngine.instance;
    return e.liveActive || e.inlineVoice;
  }

  /// The assistant is still answering (its lead-in: "Here's your morning").
  bool get answering {
    final e = AssistantEngine.instance;
    return PcmPlayer.instance.playing ||
        const {
          AssistantPhase.transcribing,
          AssistantPhase.thinking,
          AssistantPhase.responding,
          AssistantPhase.searching,
        }.contains(e.phase);
  }

  Future<void> leaveConversation() =>
      AssistantEngine.instance.leaveConversation(chime: false);

  /// Something started talking to the assistant: the brief gives way.
  Listenable get engine => AssistantEngine.instance;
  bool get userStarted {
    final e = AssistantEngine.instance;
    return e.liveActive ||
        const {
          AssistantPhase.listening,
          AssistantPhase.transcribing,
          AssistantPhase.thinking,
          AssistantPhase.responding,
        }.contains(e.phase);
  }
}

class BriefPlayer extends ChangeNotifier {
  BriefPlayer({BriefVoice? voice, BriefAudio? audio, BriefHost host = const BriefHost()})
      : _voiceGiven = voice,
        _audio = audio ?? const _PcmBriefAudio(),
        _host = host;

  static final BriefPlayer instance = BriefPlayer();

  final BriefVoice? _voiceGiven;
  BriefVoice? _voiceMade;
  BriefVoice get _voice => _voiceGiven ?? (_voiceMade ??= SpeechBriefVoice());
  final BriefAudio _audio;
  final BriefHost _host;

  BriefPlayState state = BriefPlayState.idle;
  BriefScript? script;

  /// The caption groups, in order.
  List<String> groups = const [];

  /// The group being heard now.
  int index = 0;

  /// Why it stopped, when it failed ("Couldn't get your day").
  String? error;

  /// Loading, playing or paused: the brief holds the speaker.
  bool get active =>
      state == BriefPlayState.loading ||
      state == BriefPlayState.playing ||
      state == BriefPlayState.paused;

  /// The now-playing strip is on screen.
  bool get showStrip => state != BriefPlayState.idle;

  /// What the strip says now.
  String get caption => switch (state) {
        BriefPlayState.done => script?.offer?.say ?? 'That was your day.',
        BriefPlayState.failed => error ?? "Couldn't play your brief.",
        _ => groups.isEmpty ? '' : groups[index.clamp(0, groups.length - 1)],
      };

  /// 0..1 through the brief.
  double get progress => groups.isEmpty
      ? 0
      : state == BriefPlayState.done
          ? 1
          : (index + 1) / groups.length;

  int _gen = 0;
  final _clips = <int, Future<BriefClip?>>{};
  final _timers = <Timer>[];
  Timer? _dismiss;
  int _played = 0;
  bool _watching = false;

  /// How long the finished strip (with its offer) stays up.
  static const doneHold = Duration(seconds: 20);

  /// A group is a sentence or two, up to about this many characters.
  static const groupChars = 170;

  /// Sentences into caption groups of up to [max] characters.
  static List<String> captionGroups(List<String> sentences, {int max = groupChars}) {
    final out = <String>[];
    var cur = '';
    for (final raw in sentences) {
      final s = raw.trim();
      if (s.isEmpty) continue;
      if (cur.isNotEmpty && cur.length + 1 + s.length > max) {
        out.add(cur);
        cur = s;
      } else {
        cur = cur.isEmpty ? s : '$cur $s';
      }
    }
    if (cur.isNotEmpty) out.add(cur);
    return out;
  }

  /// Plays the day: [given] when the words are already here, else they are
  /// fetched. [overlay] is where the now-playing strip goes (the root one).
  /// [fromVoice]: asked for in a conversation — its own short answer is
  /// let finish before the conversation is let go.
  Future<void> play({BriefScript? given, OverlayState? overlay, bool fromVoice = false}) async {
    if (state == BriefPlayState.loading) return;
    await _halt();
    final gen = ++_gen;
    if (overlay != null) BriefStripOverlay.show(overlay);
    _set(BriefPlayState.loading);
    final s = given ?? await _host.fetch();
    if (gen != _gen) return;
    if (s == null) {
      error = "Couldn't get your day. Check your connection.";
      _set(BriefPlayState.failed);
      return;
    }
    script = s;
    groups = captionGroups(s.lines);
    index = 0;
    _played = 0;
    if (groups.isEmpty) {
      error = "There's nothing to read yet.";
      _set(BriefPlayState.failed);
      return;
    }
    // NEVER INTO AN OPEN MICROPHONE: the lead-in finishes, then the
    // conversation is let go.
    if (fromVoice) {
      final until = DateTime.now().add(const Duration(seconds: 8));
      while (_host.answering && DateTime.now().isBefore(until)) {
        await Future<void>.delayed(const Duration(milliseconds: 150));
        if (gen != _gen) return;
      }
    }
    if (_host.talking) await _host.leaveConversation();
    if (gen != _gen) return;
    _watch(true);
    _set(BriefPlayState.playing);
    unawaited(_run(0, gen));
  }

  void pause() {
    if (state != BriefPlayState.playing) return;
    _gen++;
    _cancelTimers();
    unawaited(_audio.stop());
    _set(BriefPlayState.paused);
  }

  Future<void> resume() async {
    if (state != BriefPlayState.paused) return;
    final gen = ++_gen;
    _set(BriefPlayState.playing);
    await _run(index, gen);
  }

  void toggle() => state == BriefPlayState.playing ? pause() : unawaited(resume());

  /// Stops and puts the strip away.
  Future<void> stop() async {
    await _halt();
    _set(BriefPlayState.idle);
  }

  /// Puts the finished (or failed) strip away.
  void dismiss() {
    if (active) return;
    _dismiss?.cancel();
    _set(BriefPlayState.idle);
  }

  // ─────────────────────────────────────────────────────────────────────

  Future<BriefClip?> _clip(int i) {
    if (i < 0 || i >= groups.length) return Future.value(null);
    return _clips[i] ??= _voice.make(groups[i]).catchError((Object _) => null);
  }

  Future<void> _run(int from, int gen) async {
    for (var i = from; i < groups.length; i++) {
      final current = _clip(i);
      unawaited(_clip(i + 1)); // made while this one plays
      final clip = await current;
      if (gen != _gen) return;
      if (clip == null) continue; // a group that could not be voiced is skipped
      _captionAt(i, _audio.remaining, gen);
      for (final pcm in clip.chunks) {
        if (gen != _gen) return;
        await _audio.play(pcm, sampleRate: clip.sampleRate);
      }
      _played++;
    }
    if (gen != _gen) return;
    await _audio.drained();
    if (gen != _gen) return;
    _watch(false);
    if (_played == 0) {
      error = "Couldn't play your brief.";
      _set(BriefPlayState.failed);
      return;
    }
    _set(BriefPlayState.done);
    _dismiss?.cancel();
    _dismiss = Timer(doneHold, () {
      if (state == BriefPlayState.done) _set(BriefPlayState.idle);
    });
  }

  /// The caption follows the voice: group [i] shows when its audio is heard.
  void _captionAt(int i, Duration wait, int gen) {
    void show() {
      if (gen != _gen || index == i) return;
      index = i;
      notifyListeners();
    }

    if (wait <= const Duration(milliseconds: 60)) {
      show();
    } else {
      _timers.add(Timer(wait, show));
    }
  }

  Future<void> _halt() async {
    _gen++;
    _cancelTimers();
    _dismiss?.cancel();
    _watch(false);
    final was = state == BriefPlayState.playing || state == BriefPlayState.loading;
    _voice.cancel();
    _clips.clear();
    if (was) {
      try {
        await _audio.stop();
      } catch (_) {}
    }
  }

  void _cancelTimers() {
    for (final t in _timers) {
      t.cancel();
    }
    _timers.clear();
  }

  /// While it plays, a conversation starting (the orb, a question) wins.
  void _watch(bool on) {
    if (on == _watching) return;
    _watching = on;
    if (on) {
      _host.engine.addListener(_onEngine);
    } else {
      _host.engine.removeListener(_onEngine);
    }
  }

  void _onEngine() {
    if ((state == BriefPlayState.playing || state == BriefPlayState.paused) && _host.userStarted) {
      AppLog.add('brief', 'a conversation started — the brief stops');
      unawaited(stop());
    }
  }

  void _set(BriefPlayState s) {
    state = s;
    if (s == BriefPlayState.idle) {
      script = null;
      groups = const [];
      index = 0;
      error = null;
    }
    notifyListeners();
  }

  @visibleForTesting
  Future<void> debugReset() async {
    await _halt();
    _set(BriefPlayState.idle);
  }
}
