import 'dart:collection';
import 'dart:math' as math;

/// IS THE OWNER REALLY TALKING OVER HER? (build 113, 2026-09-26)
///
/// The owner: "interrupt should be there… a strong valid one interrupt…
/// how we talk with a human". Barge-in went off on 2026-09-20 because on a
/// Samsung S24 the echo canceller let her own voice back into the
/// microphone, Google heard it as the user, and she cut herself off
/// mid-sentence. Every bar tried then was a fixed multiple of the room's
/// noise, which is a guess at how much of her voice leaks back, and on that
/// handset every guess was wrong.
///
/// This check MEASURES the leak instead of guessing it. While she speaks,
/// each microphone frame is set against how loud SHE was at that moment
/// ([EchoReference]). On this phone, at this volume, her voice comes back
/// at about [coupling] times her own level (above the room's own noise).
/// That figure is learnt from her own turns, near the top of what was seen
/// lately, so a phone that leaks a lot raises its own bar. The owner is
/// talking over her only when the microphone is:
///   - well above what the room plus her voice could put there
///     ([echoMargin]),
///   - clearly louder than ordinary speech detection needs
///     ([speechMargin]),
///   - and stays that way for [holdMs]: a word, not a cough, a clink or the
///     tail of her own syllable. One quiet frame between syllables is
///     forgiven.
/// Until it has heard [warmupMs] of her voice, it does not know this phone's
/// leak and nothing counts. Missing an early interruption costs a second.
/// Interrupting herself costs the conversation.
class BargeInDetector {
  BargeInDetector({
    this.echoMargin = 2.5,
    this.speechMargin = 1.6,
    this.holdMs = 380,
    this.warmupMs = 800,
    this.minEcho = 0.03,
    this.historyFrames = 48,
    this.percentile = 0.9,
  });

  /// How far above her predicted echo the microphone must be (x2.5, 8 dB).
  final double echoMargin;

  /// How far above the session's ordinary speech bar.
  final double speechMargin;

  /// How long the owner must keep talking before it counts.
  final int holdMs;

  /// How much of her voice must be heard before this phone's leak is known.
  final int warmupMs;

  /// Her level (plain RMS) below which she is between words: the leak is
  /// only learnt while she is clearly audible, or the room's noise divided
  /// by almost nothing would pass for an enormous leak.
  final double minEcho;

  /// How many of her frames the leak is learnt over (about 6 s).
  final int historyFrames;

  /// Where in the recent ratios the leak is read: near the top, so a loud
  /// syllable does not catch the bar low, but not the very top, so one
  /// odd frame (a "hmm" from the owner) does not lock everyone out.
  final double percentile;

  final _ratios = ListQueue<double>();
  int _heardMs = 0;
  int _runMs = 0;
  bool _forgiven = false;

  /// Barge-ins confirmed since the app started (for the diagnostics report).
  int confirmed = 0;

  /// How much of her voice comes back into the microphone, per unit of her
  /// level. 0 before anything is learnt.
  double get coupling {
    if (_ratios.isEmpty) return 0;
    final s = _ratios.toList()..sort();
    final i = ((s.length - 1) * percentile).round();
    return s[i];
  }

  /// True once this phone's leak has been measured.
  bool get warm => _heardMs >= warmupMs;

  /// A fresh session on the same phone keeps what was learnt about the
  /// leak (it belongs to the handset, not the conversation) and only drops
  /// a half-heard interruption.
  void resetRun() {
    _runMs = 0;
    _forgiven = false;
  }

  /// Forgets the phone as well (tests; a changed audio route).
  void forget() {
    _ratios.clear();
    _heardMs = 0;
    resetRun();
  }

  /// One microphone frame heard while she is speaking.
  ///
  /// [mic] is the frame's level on the session's scale; [echo] her loudest
  /// level over the moments the frame could hold ([EchoReference]);
  /// [floor] the room's noise on the mic's scale; [speechBar] the session's
  /// ordinary speech threshold; [ms] the frame's length. True once, at the
  /// moment an interruption is confirmed.
  bool feed({
    required double mic,
    required double echo,
    required double floor,
    required double speechBar,
    required int ms,
  }) {
    final c = coupling;
    final bar = math.max(
      speechBar * speechMargin,
      floor + c * echo * echoMargin,
    );
    if (warm && mic > bar) {
      _runMs += ms;
      _forgiven = false;
      if (_runMs >= holdMs) {
        resetRun();
        confirmed++;
        return true;
      }
      return false;
    }
    if (_runMs > 0) {
      // Mid-word for all we know: one dip is forgiven, and nothing from an
      // interruption in progress is learnt as her echo.
      if (!_forgiven) {
        _forgiven = true;
        return false;
      }
      resetRun();
      return false;
    }
    // Her voice alone: learn how much of it comes back.
    if (echo >= minEcho) {
      _ratios.add(math.max(0.0, mic - floor) / echo);
      while (_ratios.length > historyFrames) {
        _ratios.removeFirst();
      }
      _heardMs += ms;
    }
    return false;
  }
}
