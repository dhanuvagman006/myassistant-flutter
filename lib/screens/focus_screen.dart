import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design/apple_kit.dart';
import '../design/motion.dart';
import '../design/neon_tokens.dart';
import '../design/neon_widgets.dart' show NeonScaffold, NeonSuccess;
import '../services/focus_service.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  FOCUS (2026-09-25, Momentum) — "start a 25-minute focus on the report".
///
///  A calm page: one ring in the theme colour emptying as the time runs,
///  the minutes left, what it is for, and three controls — pause, +5 min,
///  end. The session lives in FocusService, so leaving this page, locking
///  the phone or killing the app does not stop it; the notification shade
///  keeps the countdown and rings "Focus done — take 5?" at the end.
///
///  Cheap by design: the page redraws once a second, and only while it is
///  on screen and running — paused, covered or in the background, nothing
///  here asks for a frame.
/// ─────────────────────────────────────────────────────────────────────────
class FocusScreen extends StatefulWidget {
  const FocusScreen({super.key, this.minutes, this.label = '', this.autoStart = false});

  /// Minutes to start with (or to pre-select, without [autoStart]).
  final int? minutes;
  final String label;

  /// Start at once (the voice path and the Momentum screen's buttons).
  final bool autoStart;

  /// How many are open (MomentumNav does not stack a second).
  static int showing = 0;

  @override
  State<FocusScreen> createState() => _FocusScreenState();
}

class _FocusScreenState extends State<FocusScreen> with WidgetsBindingObserver {
  final _svc = FocusService.instance;
  late final TextEditingController _label = TextEditingController(text: widget.label);
  Timer? _tick;
  bool _foreground = true;
  bool _tickerOn = true;
  bool _ready = false;
  late int _pick = const [15, 25, 45, 60].contains(widget.minutes) ? widget.minutes! : 25;

  @override
  void initState() {
    super.initState();
    FocusScreen.showing++;
    WidgetsBinding.instance.addObserver(this);
    _svc.addListener(_changed);
    unawaited(_open());
  }

  Future<void> _open() async {
    await _svc.restore();
    if (widget.autoStart && !_svc.active) {
      // The ring as soon as the session exists on the phone; the
      // notification and the server log finish behind it.
      await _svc.start(widget.minutes ?? 25, label: widget.label, waitForServer: false);
    }
    if (!mounted) return;
    setState(() => _ready = true);
    _schedule();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Covered by another page: stop asking for frames.
    _tickerOn = TickerMode.valuesOf(context).enabled;
    _schedule();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) unawaited(_svc.tick());
    _schedule();
  }

  @override
  void dispose() {
    FocusScreen.showing--;
    WidgetsBinding.instance.removeObserver(this);
    _svc.removeListener(_changed);
    _tick?.cancel();
    _label.dispose();
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    _schedule();
  }

  /// The one-second redraw: only while visible, in front and running.
  void _schedule() {
    final want = mounted && _foreground && _tickerOn && _svc.running;
    if (want && _tick == null) {
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        unawaited(_svc.tick());
        if (mounted) setState(() {});
      });
    } else if (!want && _tick != null) {
      _tick!.cancel();
      _tick = null;
    }
  }

  /// Is the one-second redraw running? (Tests look.)
  @visibleForTesting
  bool get ticking => _tick != null;

  Future<void> _end() async {
    final s = _svc.session;
    if (s == null) return;
    final done = s.clock.minutesDone(FocusService.clock());
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('End this focus?', style: NeonType.cardTitle.copyWith(color: Neon.textHi)),
        content: Text(
            s.kind == FocusKind.rest
                ? 'The break ends now.'
                : done == 0
                    ? 'Less than a minute so far.'
                    : done == 1
                        ? '1 minute will be logged.'
                        : '$done minutes will be logged.',
            style: TextStyle(color: Neon.textLo, fontSize: NeonType.body)),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Keep going')),
          TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('End')),
        ],
      ),
    );
    if (ok == true) {
      HapticFeedback.mediumImpact();
      await _svc.end();
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _svc.session;
    // Under the night sky (2026-09-30): the ring is the page's light.
    return NeonScaffold(
      appBar: appleAppBar(context, s?.kind == FocusKind.rest ? 'Break' : 'Focus'),
      body: SafeArea(
        top: false,
        child: !_ready
            ? const SizedBox.shrink()
            : s == null
            ? _setup()
            : s.done
                ? _finished(s)
                : _running(s),
      ),
    );
  }

  // ── Before: how long, and what for ─────────────────────────────────────

  Widget _setup() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      children: [
        Text('How long?', style: NeonType.cardTitle.copyWith(color: Neon.textHi)),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final m in const [15, 25, 45, 60])
              // The theme's chip (2026-09-30): the picked one lit in the
              // accent's rim and glass, the rest dark.
              ChoiceChip(
                label: Text('$m min'),
                selected: _pick == m,
                onSelected: (_) => setState(() => _pick = m),
                labelStyle: NeonType.manrope(NeonType.body, FontWeight.w700)
                    .copyWith(color: Neon.textHi),
                showCheckmark: false,
                materialTapTargetSize: MaterialTapTargetSize.padded,
              ),
          ],
        ),
        const SizedBox(height: 20),
        TextField(
          controller: _label,
          maxLength: 80,
          textCapitalization: TextCapitalization.sentences,
          style: TextStyle(color: Neon.textHi, fontSize: NeonType.body),
          decoration: InputDecoration(
            labelText: 'What is it for? (optional)',
            labelStyle: TextStyle(color: Neon.textLo),
            filled: true,
            fillColor: Neon.surface,
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(Neon.rMd), borderSide: BorderSide(color: Neon.line)),
            enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(Neon.rMd), borderSide: BorderSide(color: Neon.line)),
            focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(Neon.rMd), borderSide: BorderSide(color: Neon.violet)),
          ),
        ),
        const SizedBox(height: 16),
        ApplePrimaryButton(
          label: 'Start',
          icon: Icons.play_arrow_rounded,
          onPressed: () {
            HapticFeedback.selectionClick();
            unawaited(_svc.start(_pick, label: _label.text));
          },
        ),
        const SizedBox(height: 12),
        Text('Your phone can stay locked — the countdown is in the notifications, '
            'and it tells you when time is up.',
            style: TextStyle(color: Neon.textLo, fontSize: NeonType.footnote, height: 1.35)),
      ],
    );
  }

  // ── During: the ring ──────────────────────────────────────────────────

  Widget _running(FocusSession s) {
    final now = FocusService.clock();
    final left = s.clock.remaining(now);
    final paused = s.clock.paused;
    final rest = s.kind == FocusKind.rest;
    return LayoutBuilder(builder: (context, c) {
      final ring = math.max(160.0, math.min(300.0, math.min(c.maxWidth - 64, c.maxHeight * 0.5)));
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        child: ConstrainedBox(
          // Full width too: a scroll view hands its child a loose width,
          // and a shrink-wrapped column sits at the left, not the centre.
          constraints: BoxConstraints(
              minHeight: c.maxHeight - 32, minWidth: math.max(0.0, c.maxWidth - 40)),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // THE RING IS LIT (2026-09-30): the brand gradient (the cyan
              // of the assistant on a break) with its halo behind — dimmed
              // while paused. The halo is drawn once; only the ring
              // repaints, once a second, on its own layer.
              AnimatedContainer(
                duration: Motion.reduced(context) ? Duration.zero : Motion.short,
                curve: Motion.easeMove,
                width: ring,
                height: ring,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: Neon.halo(rest ? Neon.cyan : Neon.violet,
                      strength: paused ? 0.3 : 0.9),
                ),
                child: RepaintBoundary(
                  child: CustomPaint(
                  painter: FocusRingPainter(
                    remaining: 1 - s.clock.progress(now),
                    color: rest ? Neon.cyan : Neon.violet,
                    track: Neon.line,
                    gradient: rest ? [Neon.cyan, Neon.violet] : Neon.rim,
                  ),
                  child: Center(
                    child: Padding(
                      padding: EdgeInsets.all(ring * 0.18),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(focusTimeText(left),
                                key: const ValueKey('focus-time'),
                                style: NeonType.manrope(NeonType.largeTitle, FontWeight.w700).copyWith(
                                  color: Neon.textHi,
                                  fontSize: 56,
                                  fontFeatures: const [FontFeature.tabularFigures()],
                                )),
                            Text(paused ? 'Paused' : rest ? 'Break' : 'left',
                                style: NeonType.manrope(NeonType.body, FontWeight.w600)
                                    .copyWith(color: paused ? Neon.warningInk : Neon.textLo)),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                ),
              ),
              const SizedBox(height: 16),
              if (s.label.isNotEmpty)
                Text(s.label,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: NeonType.manrope(NeonType.headline, FontWeight.w600).copyWith(color: Neon.textHi)),
              const SizedBox(height: 24),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 12,
                runSpacing: 12,
                children: [
                  _control(Icons.add_rounded, '+5 min', () {
                    HapticFeedback.selectionClick();
                    unawaited(_svc.addMinutes(5));
                  }),
                  _control(paused ? Icons.play_arrow_rounded : Icons.pause_rounded, paused ? 'Resume' : 'Pause',
                      () {
                    HapticFeedback.selectionClick();
                    unawaited(paused ? _svc.resume() : _svc.pause());
                  }, primary: true),
                  _control(Icons.stop_rounded, 'End', _end),
                ],
              ),
            ],
          ),
        ),
      );
    });
  }

  /// HIERARCHY BY LIGHT (2026-09-30): Pause/Resume is the theme's lit
  /// filled button; +5 min and End are the secondary one — a rim, no fill,
  /// no glow.
  Widget _control(IconData icon, String label, VoidCallback onTap, {bool primary = false}) {
    const pill = RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(Neon.rPill)));
    if (primary) {
      return FilledButton.icon(
        onPressed: onTap,
        style: FilledButton.styleFrom(
          minimumSize: const Size(120, 52),
          textStyle: NeonType.manrope(NeonType.rowTitle, FontWeight.w700),
          shape: pill,
        ),
        icon: Icon(icon, size: 20),
        label: Text(label),
      );
    }
    return OutlinedButton.icon(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(96, 52),
        textStyle: NeonType.manrope(NeonType.rowTitle, FontWeight.w600),
        shape: pill,
      ),
      icon: Icon(icon, size: 20),
      label: Text(label),
    );
  }

  // ── After: logged, and a break offered ────────────────────────────────

  Widget _finished(FocusSession s) {
    final rest = s.kind == FocusKind.rest;
    final title = rest
        ? 'Break over'
        : s.completed
            ? 'Focus done — take 5?'
            : 'Focus ended';
    final line = rest
        ? 'Ready for another focus?'
        : s.minutes == 0
            ? 'Every start counts.'
            : s.minutes == 1
                ? '1 minute of focus logged.'
                : '${s.minutes} minutes of focus logged.';
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 48, 20, 32),
      children: [
        // A focus logged gets the app's success moment (2026-09-30): the
        // lit disc and its tick drawing in. A break over keeps its leaf.
        if (rest)
          EnterOnce(
            scaleFrom: 0.9,
            child: Icon(Icons.spa_rounded, size: 72, color: Neon.cyan),
          )
        else
          const Center(child: NeonSuccess()),
        const SizedBox(height: 16),
        Text(title,
            textAlign: TextAlign.center,
            style: NeonType.manrope(NeonType.title3, FontWeight.w800).copyWith(color: Neon.textHi)),
        const SizedBox(height: 6),
        Text(line, textAlign: TextAlign.center, style: TextStyle(color: Neon.textLo, fontSize: NeonType.body)),
        const SizedBox(height: 28),
        if (!rest)
          ApplePrimaryButton(
            label: 'Start a 5-minute break',
            icon: Icons.free_breakfast_rounded,
            onPressed: () {
              HapticFeedback.selectionClick();
              unawaited(_svc.startBreak());
            },
          )
        else
          ApplePrimaryButton(
            label: 'Focus again',
            icon: Icons.replay_rounded,
            onPressed: () {
              HapticFeedback.selectionClick();
              unawaited(_svc.dismiss().then((_) => _svc.start(_pick, label: _label.text)));
            },
          ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: () async {
            await _svc.dismiss();
            if (mounted) Navigator.of(context).maybePop();
          },
          style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          child: Text('Done', style: NeonType.manrope(NeonType.rowTitle, FontWeight.w600)),
        ),
      ],
    );
  }
}

/// "24:59", or "1:04:59" past an hour.
String focusTimeText(Duration d) {
  final total = d.inSeconds < 0 ? 0 : d.inSeconds;
  final h = total ~/ 3600, m = (total % 3600) ~/ 60, s = total % 60;
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$ss' : '$m:$ss';
}

/// The countdown ring: a full circle of the theme colour that empties
/// clockwise from the top.
class FocusRingPainter extends CustomPainter {
  FocusRingPainter(
      {required this.remaining, required this.color, required this.track, this.gradient});

  /// 1 → 0 as the session runs.
  final double remaining;
  final Color color;
  final Color track;

  /// The arc's light from its start to its head (2026-09-30); [color]
  /// alone without it.
  final List<Color>? gradient;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.shortestSide * 0.045;
    final r = (size.shortestSide - stroke) / 2;
    final c = size.center(Offset.zero);
    canvas.drawCircle(c, r, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = track);
    final v = remaining.clamp(0.0, 1.0);
    if (v <= 0) return;
    final rect = Rect.fromCircle(center: c, radius: r);
    final g = gradient;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = color;
    if (g != null && g.length > 1) {
      // Started half a cap early, so the round tail is the first colour,
      // not the last one wrapped round.
      final cap = stroke / 2 / r;
      paint.shader = SweepGradient(
        endAngle: 2 * math.pi * v + 2 * cap,
        colors: g,
        transform: GradientRotation(-math.pi / 2 - cap),
      ).createShader(rect);
    }
    canvas.drawArc(rect, -math.pi / 2, 2 * math.pi * v, false, paint);
  }

  @override
  bool shouldRepaint(FocusRingPainter old) =>
      old.remaining != remaining ||
      old.color != color ||
      old.track != track ||
      !listEquals(old.gradient, gradient);
}
