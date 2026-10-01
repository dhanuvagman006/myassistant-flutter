import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import 'studio_palettes.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  READABLE OVER ANY PICTURE (2026-09-30). A picture from a model can be
///  white where the title stands, or a crowd of detail behind the venue.
///  So the poster's backdrop (picture, veil, rims — everything under the
///  words) is drawn small, and under each line of words the contrast is
///  measured against the LEAST legible pixels there (the brightest and
///  the darkest, whichever is worse). Where it falls short of 4.5:1, or
///  the picture is busy, a scrim — a blurred, tinted glass panel — goes
///  behind the words, just dark (or light) enough to reach it.
/// ─────────────────────────────────────────────────────────────────────────

/// What the backdrop looks like under one block of words.
class RegionTone {
  const RegionTone({required this.bright, required this.dark, required this.mean, required this.spread});

  /// The pixel at the 95th percentile of luminance, and the 5th.
  final Color bright;
  final Color dark;

  /// Mean and standard deviation of relative luminance (0–1).
  final double mean;
  final double spread;
}

final _linear = Float64List.fromList([
  for (var i = 0; i < 256; i++)
    (i / 255) <= 0.04045 ? (i / 255) / 12.92 : math.pow(((i / 255) + 0.055) / 1.055, 2.4).toDouble(),
]);

/// The backdrop, sampled small.
class LuminanceGrid {
  LuminanceGrid(this.width, this.height, this.rgba, this.scale);

  final int width;
  final int height;
  final Uint8List rgba;

  /// Grid pixels per poster pixel.
  final double scale;

  /// Draws [paint] (a poster-sized backdrop) at most [maxEdge] pixels on
  /// its long side and reads it back.
  static Future<LuminanceGrid> capture(Size size, void Function(Canvas c) paint,
      {int maxEdge = 180}) async {
    final k = maxEdge / math.max(size.width, size.height);
    final w = math.max(1, (size.width * k).round()), h = math.max(1, (size.height * k).round());
    final rec = ui.PictureRecorder();
    final c = Canvas(rec, Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()));
    c.scale(k);
    paint(c);
    final pic = rec.endRecording();
    final img = await pic.toImage(w, h);
    pic.dispose();
    final data = await img.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
    img.dispose();
    return LuminanceGrid(w, h, data!.buffer.asUint8List(), k);
  }

  RegionTone tone(Rect r) {
    final x0 = (r.left * scale).floor().clamp(0, width - 1);
    final x1 = (r.right * scale).ceil().clamp(x0 + 1, width);
    final y0 = (r.top * scale).floor().clamp(0, height - 1);
    final y1 = (r.bottom * scale).ceil().clamp(y0 + 1, height);
    final lums = <double>[];
    final at = <int>[];
    var sum = 0.0;
    for (var y = y0; y < y1; y++) {
      for (var x = x0; x < x1; x++) {
        final i = (y * width + x) * 4;
        final l = 0.2126 * _linear[rgba[i]] + 0.7152 * _linear[rgba[i + 1]] + 0.0722 * _linear[rgba[i + 2]];
        lums.add(l);
        at.add(i);
        sum += l;
      }
    }
    final n = lums.length;
    final mean = sum / n;
    var v = 0.0;
    for (final l in lums) {
      v += (l - mean) * (l - mean);
    }
    final order = List<int>.generate(n, (i) => i)..sort((a, b) => lums[a].compareTo(lums[b]));
    Color px(int k) {
      final i = at[order[k]];
      return Color.fromARGB(255, rgba[i], rgba[i + 1], rgba[i + 2]);
    }

    return RegionTone(
      bright: px(((n - 1) * 0.95).round()),
      dark: px(((n - 1) * 0.05).round()),
      mean: mean,
      spread: math.sqrt(v / n),
    );
  }
}

/// The scrim one block needs.
class ScrimPlan {
  const ScrimPlan({required this.before, required this.after, required this.alpha, required this.blur});

  /// Contrast of the words against the backdrop alone, and with the scrim.
  final double before;
  final double after;

  /// The panel's opacity (0: no panel).
  final double alpha;

  /// Blur the picture under the panel (a busy picture).
  final bool blur;

  bool get needed => alpha > 0;
}

/// Contrast the words in [ink] reach over [t] with a panel of [panel] at
/// [alpha] on top: against its brightest AND its darkest pixels, whichever
/// is worse — a mid-tone ink (gold foil) can fail either way.
double contrastOver(Color ink, RegionTone t, Color panel, double alpha) {
  Color under(Color c) => alpha <= 0 ? c : Color.alphaBlend(panel.withValues(alpha: alpha), c);
  return math.min(contrastRatio(ink, under(t.bright)), contrastRatio(ink, under(t.dark)));
}

/// Busy: the picture's detail under the words varies this much.
const studioBusySpread = 0.2;

/// The least panel that brings [ink] to [target] over [t] (with a little
/// to spare), or none when the backdrop already reads.
ScrimPlan planScrim(Color ink, RegionTone t, Color panel, {double target = 4.5}) {
  final before = contrastOver(ink, t, panel, 0);
  final busy = t.spread > studioBusySpread;
  if (before >= target && !busy) {
    return ScrimPlan(before: before, after: before, alpha: 0, blur: false);
  }
  var lo = 0.0, hi = 0.96;
  if (contrastOver(ink, t, panel, hi) < target + 0.25) {
    lo = hi;
  } else {
    for (var i = 0; i < 18; i++) {
      final mid = (lo + hi) / 2;
      if (contrastOver(ink, t, panel, mid) >= target + 0.25) {
        hi = mid;
      } else {
        lo = mid;
      }
    }
    lo = hi;
  }
  final alpha = math.max(lo, busy ? 0.42 : 0.28);
  return ScrimPlan(before: before, after: contrastOver(ink, t, panel, alpha), alpha: alpha, blur: true);
}
