import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

import 'neon_tokens.dart';
import 'motion.dart';

export 'neon_scaffold.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  Reusable UI atoms for the Neon design system. Every screen builds from
///  these instead of ad-hoc containers, so the look stays consistent.
///
///  THE STATES (2026-09-30): waiting is [NeonLoader] (inline in a row or a
///  button, [NeonLoader.page] for a whole page), nothing-yet is
///  [NeonEmptyState], could-not is [NeonErrorState], and done is
///  [NeonSuccess]. One of each, on every screen.
/// ─────────────────────────────────────────────────────────────────────────

/// Empty state — the icon in a lit tile, a title, a hint and at most one
/// action.
///
/// THE ACTION IS A PILL (2026-09-30): give [actionLabel] and [onAction]
/// and the next step is a [NeonPill] in the state's [tone]; [action] still
/// takes any widget (a primary button, for an error's "Try again").
class NeonEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;

  /// The hint under the title: what to do, in a sentence.
  final String? body;
  final Widget? action;

  /// The action as a lit pill (used when [action] is null).
  final String? actionLabel;
  final IconData? actionIcon;
  final VoidCallback? onAction;

  /// The light of the tile and the pill: brand for "nothing here yet",
  /// danger for a failure ([NeonErrorState]).
  final NeonTone tone;

  const NeonEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.body,
    this.action,
    this.actionLabel,
    this.actionIcon,
    this.onAction,
    this.tone = NeonTone.brand,
  });

  @override
  Widget build(BuildContext context) {
    final rim = tone.rim;
    final next = action ??
        (actionLabel != null && onAction != null
            ? NeonPill(
                label: actionLabel!,
                icon: actionIcon,
                tone: tone,
                onPressed: onAction,
              )
            : null);
    return Center(
      // Scrolls when space is short (keyboard up, large text) instead of
      // spilling past its edge — found by test/layout_sweep_test.dart.
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(Neon.s7),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // A LIT TILE (2026-09-30, the client's neon reference): the
              // tone's rim round glass tinted by it, with the rim's own
              // soft light — the icon is the one lit thing on an empty page.
              ExcludeSemantics(
                child: Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(26),
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: rim,
                    ),
                    boxShadow: Neon.halo(rim.first, strength: 0.7),
                  ),
                  padding: const EdgeInsets.all(2),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(24),
                      color: tone.fill,
                    ),
                    child: Icon(icon, size: 34, color: tone.ink),
                  ),
                ),
              ),
              const SizedBox(height: Neon.s5),
              // Bold for real: copyWith(w700) on the theme style kept its
              // medium font file (see NeonType).
              Text(title,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium?.merge(
                      NeonType.manrope(NeonType.headline, FontWeight.w700)
                          .copyWith(color: Neon.textHi))),
              if (body != null) ...[
                const SizedBox(height: Neon.s2),
                // Narrow enough that the lines balance: at full width the
                // copy left one-word widows ("…when it / ends.").
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 320),
                  child: Text(body!,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Neon.textLo, height: 1.4)),
                ),
              ],
              if (next != null) ...[
                const SizedBox(height: Neon.s5),
                next,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// THE ONE ERROR STATE (2026-09-29, UI pass). Seven screens had seven
/// treatments — "Something broke the circuit" over a bolt, a cloud with a
/// text link, grey words with no way to retry, orange words in a card.
/// Now every screen that could not load says the same three things, in
/// plain words: what happened ([message], the title: "Couldn't load your
/// clients"), what to do ([hint]), and one primary "Try again" — the
/// accent-filled button every other primary action uses. Lit in the
/// danger tone (2026-09-30).
class NeonErrorState extends StatelessWidget {
  /// What could not happen, as a title: "Couldn't load your clients".
  final String message;

  /// The next step, in a sentence. Defaults to the connection advice,
  /// which is what almost every load failure needs.
  final String? hint;
  final VoidCallback? onRetry;
  final IconData icon;

  const NeonErrorState({
    super.key,
    required this.message,
    this.hint,
    this.onRetry,
    this.icon = Icons.cloud_off_rounded,
  });

  static const defaultHint = 'Check your connection, then try again.';

  @override
  Widget build(BuildContext context) {
    return NeonEmptyState(
      icon: icon,
      title: message,
      body: hint ?? defaultHint,
      tone: NeonTone.danger,
      action: onRetry == null
          ? null
          : FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Try again'),
              // Spelled out rather than left to the theme, so it is the
              // same button inside any theme (and in tests without one).
              style: FilledButton.styleFrom(
                backgroundColor: Neon.accentFill,
                foregroundColor: Neon.onAccent,
                elevation: Neon.isDark ? 8 : 0,
                shadowColor: Neon.violet,
                minimumSize: const Size(48, 48),
                padding:
                    const EdgeInsets.symmetric(horizontal: 22, vertical: 13),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                textStyle: NeonType.manrope(NeonType.rowTitle, FontWeight.w600),
              ),
            ),
    );
  }
}

/// THE LOADER (2026-09-30): the app's own spinner — a ring of the orb's
/// light turning. Use it wherever something is on its way:
///  * `NeonLoader()` — 42 dp, the default, as before;
///  * `NeonLoader.inline()` — 18 dp, in a row, a pill or a button;
///  * `NeonLoader.page(label: …)` — centred on the page, with an optional
///    line under it ("Loading your clients…").
/// The ring is drawn once and turned as a layer: a turning spinner never
/// repaints the page around it. It holds still with "Remove animations"
/// on (it still says wait), and a screen reader hears [semanticLabel].
class NeonLoader extends StatelessWidget {
  final double size;

  /// A line under a page loader ([NeonLoader.page]).
  final String? label;
  final bool _page;

  /// What a screen reader hears.
  final String semanticLabel;

  const NeonLoader({super.key, this.size = 42, this.semanticLabel = 'Loading'})
      : label = null,
        _page = false;

  /// Small, for inside a row, a pill or a button.
  const NeonLoader.inline(
      {super.key, this.size = 18, this.semanticLabel = 'Loading'})
      : label = null,
        _page = false;

  /// Centred on the page, with an optional [label] under it.
  const NeonLoader.page(
      {super.key, this.label, this.size = 42, this.semanticLabel = 'Loading'})
      : _page = true;

  @override
  Widget build(BuildContext context) {
    final ring = Semantics(
      label: semanticLabel,
      child: _Ring(size: size),
    );
    if (!_page) return ring;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ring,
          if (label != null) ...[
            const SizedBox(height: Neon.s3),
            Text(label!,
                textAlign: TextAlign.center,
                style: NeonType.manrope(NeonType.footnote, FontWeight.w500)
                    .copyWith(color: Neon.textLo)),
          ],
        ],
      ),
    );
  }
}

class _Ring extends StatefulWidget {
  const _Ring({required this.size});
  final double size;

  @override
  State<_Ring> createState() => _RingState();
}

class _RingState extends State<_Ring> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1100));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // "Remove animations" on: the ring holds still (it still says wait).
    if (Motion.reduced(context)) {
      _c.stop();
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    return SizedBox.square(
      dimension: s,
      child: RotationTransition(
        turns: _c,
        // Drawn once; only the layer turns.
        child: RepaintBoundary(
          child: CustomPaint(
            painter: _RingPainter(
              colors: [Neon.violet, Neon.cyan, Neon.pink, Neon.violet],
              track: Neon.line,
              stroke: math.max(2.0, s * 0.085),
            ),
          ),
        ),
      ),
    );
  }
}

/// A thin track and, over it, a sweep of the orb's colours that fades in
/// from its tail to a bright round head.
class _RingPainter extends CustomPainter {
  _RingPainter(
      {required this.colors, required this.track, required this.stroke});
  final List<Color> colors;
  final Color track;
  final double stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final r = (math.min(size.width, size.height) - stroke) / 2;
    final c = size.center(Offset.zero);
    final rect = Rect.fromCircle(center: c, radius: r);
    canvas.drawCircle(
        c,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..color = track);
    canvas.drawArc(
      rect,
      -math.pi / 2,
      math.pi * 1.5,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..shader = SweepGradient(
          startAngle: 0,
          endAngle: math.pi * 1.5,
          colors: [colors.first.withValues(alpha: 0), ...colors.skip(1)],
          transform: const GradientRotation(-math.pi / 2),
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.stroke != stroke ||
      old.track != track ||
      !_same(old.colors, colors);

  static bool _same(List<Color> a, List<Color> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// DONE (2026-09-30): a brief success mark for a confirmation — "Saved",
/// "Sent", "Connected". A green-lit disc grows in (no bounce), its tick
/// draws itself, and its light swells once and settles; about 0.7 s, then
/// it asks for no frames at all. With "Remove animations" on it is simply
/// there. A screen reader hears [label] (or "Done") as it appears.
class NeonSuccess extends StatefulWidget {
  const NeonSuccess({super.key, this.size = 72, this.label});

  final double size;

  /// Words under the mark ("Saved"), also what a screen reader hears.
  final String? label;

  /// How long it takes to settle.
  static const Duration duration = Duration(milliseconds: 700);

  @override
  State<NeonSuccess> createState() => _NeonSuccessState();
}

class _NeonSuccessState extends State<NeonSuccess>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: NeonSuccess.duration);
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (Motion.reduced(context)) {
      _c.value = 1;
    } else {
      _c.forward();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  // The disc grows over the first half, the tick draws from a quarter in,
  // and the light swells to its peak halfway and settles to a soft glow.
  static const Curve _grow = Interval(0, 0.5, curve: Motion.easeEnter);
  static const Curve _draw = Interval(0.25, 0.8, curve: Motion.easeMove);

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    final rim = NeonTone.success.rim;
    final mark = AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final t = _c.value;
        final grow = _grow.transform(t);
        final swell = t < 0.5 ? t / 0.5 : 1 - (t - 0.5) / 0.5 * 0.55;
        return Opacity(
          opacity: grow.clamp(0.0, 1.0),
          child: Transform.scale(
            scale: 0.72 + 0.28 * grow,
            child: Container(
              width: s,
              height: s,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: rim,
                ),
                boxShadow:
                    Neon.halo(rim.first, strength: 0.35 + 0.85 * swell),
              ),
              padding: const EdgeInsets.all(2.4),
              child: DecoratedBox(
                decoration: BoxDecoration(
                    shape: BoxShape.circle, color: NeonTone.success.fill),
                child: CustomPaint(
                  painter: _TickPainter(
                    progress: _draw.transform(t),
                    color: NeonTone.success.ink,
                    stroke: math.max(2.5, s * 0.07),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
    return Semantics(
      liveRegion: true,
      label: widget.label ?? 'Done',
      excludeSemantics: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          mark,
          if (widget.label != null) ...[
            const SizedBox(height: Neon.s3),
            Text(widget.label!,
                textAlign: TextAlign.center,
                style: NeonType.manrope(NeonType.headline, FontWeight.w700)
                    .copyWith(color: Neon.textHi)),
          ],
        ],
      ),
    );
  }
}

/// The tick, drawn from its short arm to the tip of its long one.
class _TickPainter extends CustomPainter {
  _TickPainter(
      {required this.progress, required this.color, required this.stroke});
  final double progress;
  final Color color;
  final double stroke;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;
    final w = size.width, h = size.height;
    final path = Path()
      ..moveTo(w * 0.28, h * 0.52)
      ..lineTo(w * 0.44, h * 0.67)
      ..lineTo(w * 0.73, h * 0.36);
    final metric = path.computeMetrics().first;
    canvas.drawPath(
      metric.extractPath(0, metric.length * progress.clamp(0.0, 1.0)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_TickPainter old) =>
      old.progress != progress || old.color != color || old.stroke != stroke;
}

/// Ambient background — deep space with two soft radial neon washes.
/// Wrap any Scaffold body with this for the signature backdrop.
class NeonBackdrop extends StatelessWidget {
  final Widget child;
  const NeonBackdrop({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(color: Neon.bg),
      child: Stack(
        children: [
          Positioned(
            top: -120,
            left: -80,
            child: _wash(Neon.violet, 340),
          ),
          Positioned(
            bottom: -140,
            right: -100,
            child: _wash(Neon.cyan, 380),
          ),
          child,
        ],
      ),
    );
  }

  Widget _wash(Color c, double size) => IgnorePointer(
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(colors: [
              c.withValues(alpha: 0.07),
              c.withValues(alpha: 0.0),
            ]),
          ),
        ),
      );
}

/// ─────────────────────────────────────────────────────────────────────────
///  A LIT CARD (2026-09-30, the client's neon reference): a thin gradient
///  rim in its [tone]'s two colours, the card's ground tinted by it (glass
///  lit from the edge), and — for what matters most — the rim's own halo.
///  One primitive for every card that carries meaning, so the same kind of
///  thing looks the same on every screen ([NeonTone]).
///
///  TAPPABLE AND FLYING (2026-09-30): give it [onTap] (and/or
///  [onLongPress]) and it dips under the finger, ticks and reads as a
///  button ([Tappable]); give it [heroTag] ([cardHeroTag] of the item's id)
///  and it grows into the page it opens ([cardFlight]) — the page marks its
///  top with a Hero of the same tag.
/// ─────────────────────────────────────────────────────────────────────────
class GlowCard extends StatelessWidget {
  const GlowCard({
    super.key,
    required this.child,
    this.tone = NeonTone.brand,
    this.padding = EdgeInsets.zero,
    this.radius = Neon.rLg,
    this.rimWidth = 2.4,
    this.halo = 0.8,
    this.minHeight = 0,
    this.onTap,
    this.onLongPress,
    this.heroTag,
    this.semanticLabel,
  });

  final Widget child;
  final NeonTone tone;
  final EdgeInsets padding;
  final double radius;
  final double rimWidth;

  /// 0: no halo; 0.35: the soft glow every lit card has; 0.8 (default):
  /// a lit card; 1: the full glow (the Now card).
  final double halo;
  final double minHeight;

  /// Opens or does something: the card becomes a [Tappable].
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// The card flies into the page it opens ([cardHeroTag]). Unique on the
  /// screen. No flight with "Remove animations" on.
  final Object? heroTag;

  /// What a screen reader calls the card when it is tappable, if its own
  /// words do not say.
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final rim = tone.rim;
    Widget card = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: rim,
        ),
        borderRadius: BorderRadius.circular(radius),
        boxShadow: halo > 0 ? Neon.halo(rim.first, strength: halo) : null,
      ),
      child: Padding(
        padding: EdgeInsets.all(rimWidth),
        child: Container(
          constraints: BoxConstraints(minHeight: minHeight),
          padding: padding,
          decoration: BoxDecoration(
            color: tone.fill,
            borderRadius: BorderRadius.circular(radius - rimWidth),
          ),
          child: child,
        ),
      ),
    );
    final tag = heroTag;
    if (tag != null && !Motion.reduced(context)) {
      card = Hero(
        tag: tag,
        flightShuttleBuilder:
            radius == Neon.rLg ? cardFlight : cardFlightFor(cardRadius: radius),
        child: card,
      );
    }
    return Tappable(
      onTap: onTap,
      onLongPress: onLongPress,
      semanticLabel: semanticLabel,
      child: card,
    );
  }
}

/// ─────────────────────────────────────────────────────────────────────────
///  A NEON PILL: an outlined, lit button or chip — the rim of its [tone],
///  the label in the tone's ink, a faint halo. 48 dp to the finger however
///  small it looks. Card actions ("Remind me", "Open") and Home's quick
///  actions are these. It dips under the finger and ticks (2026-09-30):
///  it was the one button in the app that did not answer a touch.
/// ─────────────────────────────────────────────────────────────────────────
class NeonPill extends StatelessWidget {
  const NeonPill({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.tone = NeonTone.brand,
    this.busy = false,
    this.inkOverride,
    this.quiet = false,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final NeonTone tone;
  final bool busy;

  /// OPT-IN, THE GLASS LOOK (Home, 2026-09-30): a 1 px rim of the tone at
  /// low alpha on a faint wash of it, no halo — a secondary action that
  /// sits on a glass card without shouting. Off: the lit pill, unchanged.
  final bool quiet;

  /// The label's colour, when the tone's ink is not wanted (a chip's words
  /// stay in the text colour).
  final Color? inkOverride;

  @override
  Widget build(BuildContext context) {
    final rim = tone.rim;
    final ink = inkOverride ?? tone.ink;
    final press = onPressed;
    final enabled = press != null && !busy;
    Widget pill = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: enabled
          ? () {
              HapticFeedback.selectionClick();
              press();
            }
          : null,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
        child: Center(
          widthFactor: 1,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                  colors: quiet
                      ? [for (final c in rim) c.withValues(alpha: 0.38)]
                      : rim),
              borderRadius: BorderRadius.circular(Neon.rPill),
              boxShadow: quiet ? null : Neon.halo(rim.first, strength: 0.8),
            ),
            child: Padding(
              padding: EdgeInsets.all(quiet ? 1 : 1.8),
              child: Container(
                padding: EdgeInsets.symmetric(
                    horizontal: quiet ? 14 : 13, vertical: quiet ? 8 : 7),
                decoration: BoxDecoration(
                  color: quiet
                      ? Color.alphaBlend(
                          rim.first.withValues(alpha: 0.10), Neon.surface)
                      : tone.fill,
                  borderRadius: BorderRadius.circular(Neon.rPill),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (busy)
                      SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: ink),
                      )
                    else if (icon != null)
                      Icon(icon, size: 16, color: ink),
                    if (busy || icon != null) const SizedBox(width: 6),
                    Text(
                      label,
                      style: NeonType.manrope(NeonType.footnote, FontWeight.w700)
                          .copyWith(color: ink),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    // A small target: a deeper dip than a card's reads the same.
    if (enabled) pill = PressScale(scale: 0.95, child: pill);
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      // The tap is the pill's own, since its children's are excluded:
      // TalkBack's double tap reaches it.
      onTap: enabled ? press : null,
      excludeSemantics: true,
      child: pill,
    );
  }
}
