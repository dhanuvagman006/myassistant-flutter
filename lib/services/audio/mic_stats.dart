/// WHAT THE MICROPHONE ACTUALLY DID.
///
/// The Samsung S24 Ultra report (2026-09-20) took a day to diagnose
/// because the numbers that explained it — how loud this handset's
/// speech really is, where the room's noise floor sat, what bar we were
/// holding it to — existed only inside a running session and were never
/// reported anywhere. The barge-in watch (mic_stream.dart) updates these as it listens; the next
/// capability report carries them, so a remote complaint arrives with
/// evidence attached.
///
/// Deliberately levels and counters only: never audio, never words.
class MicStats {
  MicStats._();

  static double peak = 0;
  static double floor = 0;
  static double threshold = 0;
  static int frames = 0;
  static int speechFrames = 0;
  static int gatedFrames = 0; // attenuated as noise — high means trouble

  /// Build 113: times the owner talked over her, and how much of her voice
  /// this phone lets back into the microphone (barge_in.dart). A phone
  /// where she keeps getting cut off shows it here.
  static int bargeIns = 0;
  static double echoCoupling = 0;

  static void note({
    required double level,
    required double noiseFloor,
    required double speechThreshold,
    required bool loud,
    required bool gated,
  }) {
    frames++;
    if (level > peak) peak = level;
    floor = noiseFloor;
    threshold = speechThreshold;
    if (loud) speechFrames++;
    if (gated) gatedFrames++;
  }

  static void reset() {
    peak = 0;
    floor = 0;
    threshold = 0;
    frames = 0;
    speechFrames = 0;
    gatedFrames = 0;
    bargeIns = 0;
    echoCoupling = 0;
  }

  /// Rounded for a log line, empty before the first session so a fresh
  /// install does not report a screenful of zeroes.
  static Map<String, dynamic> snapshot() {
    if (frames == 0) return const {};
    double r(double v) => (v * 1000).round() / 1000;
    return {
      'micPeak': r(peak),
      'micFloor': r(floor),
      'micThreshold': r(threshold),
      'micFrames': frames,
      'micSpeechPct': ((speechFrames / frames) * 100).round(),
      'micGatedPct': ((gatedFrames / frames) * 100).round(),
      'micBargeIns': bargeIns,
      'micEchoCoupling': r(echoCoupling),
    };
  }
}
