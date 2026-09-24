import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

/// THE GPU PROGRAMS (2026-09-24, GPU pass).
///
/// The always-moving pictures — the voice screen's backdrop, the splash
/// orb, the ambient light behind the tabs — used to be built from Canvas
/// calls every frame: offscreen layers, blurred paths, stacks of big
/// gradients. On his phone's GPU (a Mali-G57) those were the most
/// expensive things the app drew. Each now has a fragment shader in
/// shaders/ that works out every pixel in one pass.
///
/// NEVER REQUIRED. The shader is compiled with the app (impellerc, at
/// build time) and loaded once, on first use. Until it has loaded — or
/// for good, if a phone ever cannot load it — each widget draws exactly
/// as it did before, with its Canvas painter. A failure is logged once
/// and never shown.
class GpuProgram extends ChangeNotifier {
  GpuProgram._(this.asset, {this.warmUp = false});

  /// The shader's asset key, as listed under `flutter: shaders:`.
  final String asset;

  /// Draw it once off screen as soon as it loads (see [_warm]).
  final bool warmUp;

  static final GpuProgram voiceBackdrop =
      GpuProgram._('shaders/voice_backdrop.frag', warmUp: true);
  static final GpuProgram siriOrb = GpuProgram._('shaders/siri_orb.frag');
  static final GpuProgram ambient = GpuProgram._('shaders/ambient.frag');

  /// Off: every widget draws with its Canvas painter. For tests that pin
  /// the old path, and a switch to reach for if a phone ever draws a
  /// shader wrong.
  @visibleForTesting
  static bool enabled = true;

  ui.FragmentProgram? _program;
  Future<void>? _loading;
  bool _failed = false;

  /// True once loading has failed; the Canvas painter is used for good.
  bool get failed => _failed;

  /// The loaded program, or null — still loading, failed, or switched off
  /// — in which case the caller draws the old way. Asking starts the load.
  ui.FragmentProgram? get program {
    if (!enabled) return null;
    if (_program == null) load();
    return _program;
  }

  /// Starts loading (once) and completes when it has loaded or failed.
  /// Listeners are told when the program arrives, so a picture that does
  /// not repaint by itself can switch over.
  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final p = await ui.FragmentProgram.fromAsset(asset);
      _program = p;
      if (warmUp) _warm(p);
      notifyListeners();
    } catch (e) {
      _failed = true;
      debugPrint('GpuProgram: $asset did not load ($e) — '
          'drawing with the Canvas painter instead');
    }
  }

  /// Draw the program once, one pixel, off screen. The phone's GPU driver
  /// builds a shader's pipeline the first time it is drawn with, on the
  /// thread that draws frames; for the voice backdrop that first time
  /// would otherwise be the opening of a voice session — the frame that
  /// was already the slowest in the app (67 ms, fixed earlier today).
  /// Loading happens behind Home, long before anyone taps the mic.
  static void _warm(ui.FragmentProgram p) {
    try {
      final shader = p.fragmentShader();
      // A non-zero box, so nothing in it divides by zero.
      for (var i = 0; i < 4; i++) {
        shader.setFloat(i, 1);
      }
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder).drawRect(
          const ui.Rect.fromLTWH(0, 0, 1, 1), ui.Paint()..shader = shader);
      final picture = recorder.endRecording();
      picture.toImage(1, 1).then((image) => image.dispose(),
          onError: (Object _) {}).whenComplete(() {
        picture.dispose();
        shader.dispose();
      });
    } catch (_) {
      // Best effort only: the first real frame builds it instead.
    }
  }
}
