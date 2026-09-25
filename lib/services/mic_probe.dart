import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../core/log.dart';
import 'live_service.dart';
import 'task_voice.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  MIC TEST — the plan's P1 probe, run from the Diagnostics screen.
///
///  Owner, 2026-09-25: "start talk while it works". Before the voice
///  session is allowed to stay open while a task runs in another app, this
///  measures, on his own phone, whether the microphone keeps hearing real
///  sound while the app is off screen. It only runs when he taps
///  "Start mic test"; nothing else in the app changes.
///
///  How: TaskVoiceService takes the microphone foreground slot (Android's
///  rule for a microphone off screen), then LiveService.probeMic restarts
///  the session's own recorder with the task settings and hands every
///  frame to [MicProbeCounts]. The frames are counted and dropped. Nothing
///  is recorded, stored, or sent to the server or Gemini; the result is a
///  handful of counts on the screen and one line in the app's own log.
///
///  Why these counts (plan section 4): a microphone Android has silenced
///  gives EXACT zeros, while a working one in a quiet room still gives
///  small non-zero noise. So "frames with any non-zero sample" and "frames
///  with RMS above 8" tell the two apart, which the session's speech
///  detector (VAD-loud, counted too) cannot: it only fires on speech.
/// ─────────────────────────────────────────────────────────────────────────

/// One frame's numbers. PCM16 little-endian mono.
class FrameMeasure {
  const FrameMeasure(this.samples, this.nonZero, this.rms);

  final int samples;

  /// Any sample other than exact zero.
  final bool nonZero;

  /// Root mean square in int16 steps ("LSB"): 0 for digital silence, a few
  /// for a quiet room, hundreds to thousands for speech.
  final double rms;

  static FrameMeasure of(List<int> pcm) {
    var sum = 0.0;
    var n = 0;
    var nonZero = false;
    for (var i = 0; i + 1 < pcm.length; i += 2) {
      var s = (pcm[i] & 0xFF) | ((pcm[i + 1] & 0xFF) << 8);
      if (s >= 0x8000) s -= 0x10000;
      if (s != 0) nonZero = true;
      sum += (s * s).toDouble();
      n++;
    }
    return FrameMeasure(n, nonZero, n == 0 ? 0 : math.sqrt(sum / n));
  }
}

/// The session's speech detector, level part: the same level measure and
/// the same adaptive bar (LiveService.levelOf / speechThresholdFor), the
/// same peak decay, and the room learned from every frame that is not loud.
class ProbeVad {
  double noiseFloor = 0.01;
  double peakLevel = 0.0;

  bool loud(List<int> pcm) {
    final l = LiveService.levelOf(pcm);
    if (l == null) return false;
    if (l > peakLevel) {
      peakLevel = l;
    } else {
      peakLevel *= 0.9995;
    }
    final loud = l >
        LiveService.speechThresholdFor(
            noiseFloor: noiseFloor, peakLevel: peakLevel);
    if (!loud) noiseFloor = noiseFloor * 0.95 + l * 0.05;
    return loud;
  }
}

/// The counts of one mic test. Everything except [onScreenFrames] counts
/// only frames that arrived while the app was NOT on screen.
class MicProbeCounts {
  /// ε in the plan: RMS above this is "the microphone hears something".
  static const double epsilon = 8;

  /// The plan's A1 test is a 20-second stay in another app.
  static const int judgeAfterMs = 20000;

  int frames = 0;
  int awayMs = 0;
  int nonZeroFrames = 0;
  int aboveEpsilonFrames = 0;
  double peakRms = 0;
  int loudFrames = 0;
  int onScreenFrames = 0;
  int silencedEvents = 0;
  int? modeAtStart;
  int? modeAtEnd;

  /// Why it ended: a TaskVoiceStop wire string or one of MicProbe's codes.
  String? stopCode;

  final ProbeVad _vad = ProbeVad();

  /// One frame. The detector learns the room from every frame, on screen
  /// or not, as the session's does.
  void add(List<int> pcm, {required bool away}) {
    final m = FrameMeasure.of(pcm);
    if (m.samples == 0) return;
    final loud = _vad.loud(pcm);
    if (!away) {
      onScreenFrames++;
      return;
    }
    frames++;
    awayMs += pcm.length ~/ 32; // PCM16 mono 16 kHz: 32 bytes a millisecond
    if (m.nonZero) nonZeroFrames++;
    if (m.rms > epsilon) aboveEpsilonFrames++;
    if (m.rms > peakRms) peakRms = m.rms;
    if (loud) loudFrames++;
  }

  double pct(int n) => frames == 0 ? 0 : n * 100 / frames;

  /// The plan's A1 pass line: at least 95% of the frames away non-zero AND
  /// at least 50% above [epsilon]. Null until [judgeAfterMs] of them.
  bool? get a1Pass => awayMs < judgeAfterMs
      ? null
      : pct(nonZeroFrames) >= 95 && pct(aboveEpsilonFrames) >= 50;

  String get _a1 => switch (a1Pass) {
        true => 'PASS',
        false => 'FAIL',
        null => 'not judged (under ${judgeAfterMs ~/ 1000} s away)',
      };

  String _s(int ms) => '${(ms / 1000).toStringAsFixed(1)} s';
  String _p(int n) => '${pct(n).round()}%';

  /// One line for AppLog. Counts only, never audio.
  String logLine() => 'mic test ended (${stopCode ?? '?'}): '
      'away ${_s(awayMs)}, $frames frames; '
      'non-zero $nonZeroFrames (${_p(nonZeroFrames)}); '
      'rms>${epsilon.round()} $aboveEpsilonFrames (${_p(aboveEpsilonFrames)}); '
      'peak rms ${peakRms.round()}; vad-loud $loudFrames; '
      'silenced $silencedEvents; '
      'audio mode ${TaskVoice.modeName(modeAtStart)}->${TaskVoice.modeName(modeAtEnd)}; '
      'on-screen frames $onScreenFrames; A1 $_a1';

  /// The same, one fact a line, in plain words for the screen.
  List<String> reportLines() => [
        'Time away from the app: ${_s(awayMs)} ($frames frames)',
        'Frames with any sound at all: $nonZeroFrames (${_p(nonZeroFrames)})',
        'Frames above the quiet-room level (RMS > ${epsilon.round()}): '
            '$aboveEpsilonFrames (${_p(aboveEpsilonFrames)})',
        'Loudest moment (RMS): ${peakRms.round()}',
        'Frames loud enough to count as speech: $loudFrames',
        'Times another app took the mic: $silencedEvents',
        'Audio mode: ${TaskVoice.modeName(modeAtStart)} at start, '
            '${TaskVoice.modeName(modeAtEnd)} at the end',
        'Frames while this app was on screen (not counted above): '
            '$onScreenFrames',
        'A1 check: $_a1',
      ];
}

enum MicProbePhase { idle, starting, running, done, failed }

/// Runs one mic test at a time. [instance] is the one the screen uses.
class MicProbe extends ChangeNotifier with WidgetsBindingObserver {
  MicProbe({TaskVoicePort? voice, LiveService? live})
      : _voice = voice ?? const TaskVoice(),
        _live = live ?? LiveService.instance;

  static final MicProbe instance = MicProbe();

  /// Why a test ended, beyond the service's own reasons (TaskVoiceStop).
  static const endedReturned = 'returned';
  static const endedButton = 'button';

  static String wordsFor(String? code) => switch (code) {
        endedReturned => 'you came back to the app',
        endedButton => 'Stop was tapped on this screen',
        LiveService.probeEndedBySession => 'a voice conversation started',
        LiveService.probeEndedByError => 'the microphone failed',
        LiveService.probeEndedByDone => 'the microphone stopped by itself',
        null => '',
        _ => TaskVoiceStop.fromWire(code).words,
      };

  final TaskVoicePort _voice;
  final LiveService _live;

  MicProbePhase phase = MicProbePhase.idle;
  MicProbeCounts counts = MicProbeCounts();

  /// Why the last start failed, in plain words.
  String? problem;

  bool _away = false;
  bool _wasAway = false;
  bool _observing = false;
  StreamSubscription<TaskVoiceEvent>? _events;

  bool get busy =>
      phase == MicProbePhase.starting || phase == MicProbePhase.running;

  Future<void> start() async {
    if (busy) return;
    counts = MicProbeCounts();
    problem = null;
    _away = false;
    _wasAway = false;
    if (_live.active) {
      return _fail('Close the voice conversation first. '
          'The mic test cannot run while it is open.');
    }
    phase = MicProbePhase.starting;
    notifyListeners();
    if (!await _live.probePermission()) {
      return _fail('The microphone permission is needed.');
    }
    // Before start(): a stop that follows promotion at once (a call already
    // on) must not be missed.
    _events = _voice.events().listen(_onEvent);
    final r = await _voice.start();
    if (!r.ok) {
      await _cancelEvents();
      return _fail('Android did not start the mic test (${r.error}).');
    }
    if (phase != MicProbePhase.starting) return; // stopped meanwhile
    counts.modeAtStart = r.audioMode;
    _observe(true);
    final ok = await _live.probeMic(_onFrame, onEnded: (why) => _finish(why));
    if (phase != MicProbePhase.starting) {
      if (ok) await _live.stopProbe();
      return;
    }
    if (!ok) {
      _observe(false);
      await _cancelEvents();
      await _voice.stop();
      return _fail('The microphone would not start.');
    }
    phase = MicProbePhase.running;
    AppLog.add('micprobe',
        'mic test started; audio mode ${TaskVoice.modeName(r.audioMode)}');
    notifyListeners();
  }

  /// Stop on the screen.
  Future<void> stop() => _finish(endedButton);

  void _onFrame(Uint8List frame) {
    if (!busy) return;
    counts.add(frame, away: _away);
    notifyListeners();
  }

  void _onEvent(TaskVoiceEvent e) {
    if (e.silenced) {
      counts.silencedEvents++;
      notifyListeners();
      return;
    }
    final r = e.reason;
    if (r == null) return;
    unawaited(_finish(r.wire, modeEnd: e.modeEnd));
  }

  Future<void> _finish(String code, {int? modeEnd}) async {
    if (!busy) return;
    phase = MicProbePhase.done;
    counts.stopCode = code;
    if (modeEnd != null) counts.modeAtEnd = modeEnd;
    _observe(false);
    notifyListeners();
    await _live.stopProbe();
    // Nothing to do when the service already stopped itself; otherwise it
    // stops now. Either way the answer carries the audio mode.
    final mode = await _voice.stop();
    counts.modeAtEnd ??= mode;
    await _cancelEvents();
    AppLog.add('micprobe', counts.logLine());
    notifyListeners();
  }

  void _fail(String why) {
    phase = MicProbePhase.failed;
    problem = why;
    AppLog.add('micprobe', 'mic test did not start: $why');
    notifyListeners();
  }

  Future<void> _cancelEvents() async {
    final s = _events;
    _events = null;
    await s?.cancel();
  }

  void _observe(bool on) {
    if (on == _observing) return;
    _observing = on;
    if (on) {
      WidgetsBinding.instance.addObserver(this);
    } else {
      WidgetsBinding.instance.removeObserver(this);
    }
  }

  /// Away = hidden or paused (the app is not on screen). Coming back ends
  /// the test, so the counts are exactly the time away.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _away = true;
        _wasAway = true;
      case AppLifecycleState.resumed:
        _away = false;
        if (_wasAway && busy) unawaited(_finish(endedReturned));
      case AppLifecycleState.inactive:
        // The notification shade or the app switcher over the app: not a
        // trip away, and nothing to change.
        break;
    }
  }
}
