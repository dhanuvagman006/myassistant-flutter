import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design/motion.dart';
import '../design/neon_tokens.dart';
import '../models/momentum.dart';
import '../services/app_feedback.dart';
import '../services/momentum_service.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  MOMENTUM PIECES — shared by the Home card and the Momentum screen
///  (2026-09-25). Everything here is still at rest: the ring moves only
///  when its number changes, a tick only when tapped, and the celebration
///  burst runs its 1.2 s and stops. An idle Home asks for no frames.
/// ─────────────────────────────────────────────────────────────────────────

/// "x/3" in a thin ring that fills as the day's wins are ticked.
class MomentumRing extends StatelessWidget {
  const MomentumRing({super.key, required this.done, required this.total, this.size = 44});
  final int done;
  final int total;
  final double size;

  @override
  Widget build(BuildContext context) {
    final target = total == 0 ? 0.0 : (done / total).clamp(0.0, 1.0);
    return Semantics(
      label: '$done of $total done',
      child: SizedBox(
        width: size,
        height: size,
        child: TweenAnimationBuilder<double>(
          tween: Tween(end: target),
          duration: Motion.reduced(context) ? Duration.zero : Motion.short,
          curve: Motion.easeMove,
          builder: (context, v, child) => CustomPaint(
            painter: _RingPainter(v, Neon.violet, Neon.line),
            child: child,
          ),
          child: Center(
            child: Text('$done/$total',
                style: NeonType.manrope(NeonType.caption, FontWeight.w700).copyWith(color: Neon.textHi)),
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.value, this.color, this.track);
  final double value;
  final Color color;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 4.0;
    final r = (math.min(size.width, size.height) - stroke) / 2;
    final c = size.center(Offset.zero);
    canvas.drawCircle(c, r, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = track);
    if (value <= 0) return;
    canvas.drawArc(
      Rect.fromCircle(center: c, radius: r),
      -math.pi / 2,
      2 * math.pi * value,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.value != value || old.color != color || old.track != track;
}

/// The round tick box of a Today's-3 row.
class MomentumTick extends StatelessWidget {
  const MomentumTick({super.key, required this.done, this.size = 24});
  final bool done;
  final double size;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: Motion.reduced(context) ? Duration.zero : Motion.micro,
      curve: Motion.easeMove,
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: done ? Neon.violet : Colors.transparent,
        border: Border.all(color: done ? Neon.violet : Neon.textDim, width: 2),
      ),
      child: done ? Icon(Icons.check_rounded, size: size * 0.66, color: Neon.onAccent) : null,
    );
  }
}

/// One Today's-3 row: tap to tick, long-press for edit / tomorrow / remove.
class MomentumPriorityRow extends StatelessWidget {
  const MomentumPriorityRow({super.key, required this.priority});
  final MomentumPriority priority;

  @override
  Widget build(BuildContext context) {
    final p = priority;
    final saved = p.id > 0;
    return Semantics(
      button: true,
      checked: p.done,
      label: p.title,
      hint: 'Double tap to ${p.done ? 'untick' : 'tick off'}. Long press for more.',
      excludeSemantics: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(Neon.rSm),
        onTap: !saved ? null : () => _toggle(context, p),
        onLongPress: !saved ? null : () => showPriorityActions(context, p),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                MomentumTick(done: p.done),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    p.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: p.done ? Neon.textLo : Neon.textHi,
                      fontSize: NeonType.body,
                      height: 1.25,
                      decoration: p.done ? TextDecoration.lineThrough : null,
                      decorationColor: Neon.textLo,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static Future<void> _toggle(BuildContext context, MomentumPriority p) async {
    HapticFeedback.lightImpact();
    final ok = await MomentumService.instance.togglePriority(p.id);
    if (!ok && context.mounted) _sayWhy(context);
  }
}

/// A habit as a chip: tap to tick it for today.
class MomentumHabitChip extends StatelessWidget {
  const MomentumHabitChip({super.key, required this.habit});
  final MomentumHabit habit;

  @override
  Widget build(BuildContext context) {
    final h = habit;
    final done = h.doneToday;
    return Semantics(
      button: true,
      checked: done,
      label: '${h.title}${h.streak > 1 ? ', ${h.streak} days running' : ''}',
      excludeSemantics: true,
      child: PressScale(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: h.id <= 0
              ? null
              : () async {
                  HapticFeedback.selectionClick();
                  final ok = await MomentumService.instance.toggleHabit(h.id);
                  if (!ok && context.mounted) _sayWhy(context);
                },
          child: SizedBox(
            height: 48,
            child: Center(
              child: AnimatedContainer(
                duration: Motion.reduced(context) ? Duration.zero : Motion.micro,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                decoration: BoxDecoration(
                  color: done ? Neon.violet.withValues(alpha: 0.16) : Neon.surface,
                  borderRadius: BorderRadius.circular(Neon.rPill),
                  border: Border.all(color: done ? Neon.violet : Neon.line),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (h.emoji.isNotEmpty) ...[
                      Text(h.emoji, style: const TextStyle(fontSize: NeonType.footnote)),
                      const SizedBox(width: 6),
                    ],
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 150),
                      child: Text(h.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: NeonType.manrope(NeonType.footnote, FontWeight.w600).copyWith(color: Neon.textHi)),
                    ),
                    if (done) ...[
                      const SizedBox(width: 6),
                      Icon(Icons.check_circle_rounded, size: 16, color: Neon.violet),
                    ] else if (h.streak > 1) ...[
                      const SizedBox(width: 6),
                      Text('${h.streak}',
                          style: NeonType.manrope(NeonType.caption, FontWeight.w700).copyWith(color: Neon.textLo)),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Says why a change did not go through (the service keeps the reason).
void _sayWhy(BuildContext context) {
  final why = MomentumService.instance.lastError;
  if (why != null) AppFeedback.show(why, context: context, tone: FeedbackTone.error);
}

/// Long-press on a priority: edit, move to tomorrow, remove.
Future<void> showPriorityActions(BuildContext context, MomentumPriority p) async {
  HapticFeedback.selectionClick();
  final choice = await showAppSheet<String>(
    context: context,
    backgroundColor: Neon.surface,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(p.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: NeonType.manrope(NeonType.body, FontWeight.w600).copyWith(color: Neon.textHi)),
          ),
          for (final (key, icon, label) in [
            ('edit', Icons.edit_rounded, 'Edit'),
            if (!p.done) ('tomorrow', Icons.east_rounded, 'Move to tomorrow'),
            ('remove', Icons.delete_outline_rounded, 'Remove'),
          ])
            ListTile(
              minTileHeight: 52,
              leading: Icon(icon, color: key == 'remove' ? Neon.errorInk : Neon.textHi),
              title: Text(label,
                  style: NeonType.manrope(NeonType.rowTitle, FontWeight.w600)
                      .copyWith(color: key == 'remove' ? Neon.errorInk : Neon.textHi)),
              onTap: () => Navigator.of(ctx).pop(key),
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
  if (!context.mounted || choice == null) return;
  final svc = MomentumService.instance;
  switch (choice) {
    case 'edit':
      final t = await askForText(context, title: 'Edit', initial: p.title, action: 'Save');
      if (t != null && t != p.title && !await svc.renamePriority(p.id, t) && context.mounted) _sayWhy(context);
    case 'tomorrow':
      if (await svc.movePriorityToTomorrow(p.id)) {
        if (context.mounted) AppFeedback.show('Moved to tomorrow.', context: context, tone: FeedbackTone.success);
      } else if (context.mounted) {
        _sayWhy(context);
      }
    case 'remove':
      if (!await svc.deletePriority(p.id) && context.mounted) _sayWhy(context);
  }
}

/// Adds one of today's wins (asks for its words first).
Future<void> addPriority(BuildContext context) async {
  final t = await askForText(context,
      title: 'A win for today', hint: 'e.g. Finish the report', action: 'Add');
  if (t == null || !context.mounted) return;
  if (!await MomentumService.instance.addPriority(t) && context.mounted) _sayWhy(context);
}

/// A one-line text sheet. Null when cancelled or left empty.
Future<String?> askForText(BuildContext context,
    {required String title, String initial = '', String hint = '', String action = 'Save'}) {
  final ctrl = TextEditingController(text: initial);
  return showAppSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Neon.surface,
    builder: (ctx) {
      void submit() {
        final v = ctrl.text.replaceAll(RegExp(r'\s+'), ' ').trim();
        Navigator.of(ctx).pop(v.isEmpty ? null : v);
      }

      return Padding(
        padding: EdgeInsets.fromLTRB(20, 20, 20, 16 + MediaQuery.viewInsetsOf(ctx).bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: NeonType.cardTitle.copyWith(color: Neon.textHi)),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              autofocus: true,
              maxLength: 80,
              textCapitalization: TextCapitalization.sentences,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => submit(),
              style: TextStyle(color: Neon.textHi, fontSize: NeonType.body),
              decoration: InputDecoration(
                hintText: hint,
                hintStyle: TextStyle(color: Neon.textDim),
                filled: true,
                fillColor: Neon.surfaceHigh,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(Neon.rMd),
                  borderSide: BorderSide(color: Neon.line),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(Neon.rMd),
                  borderSide: BorderSide(color: Neon.line),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(Neon.rMd),
                  borderSide: BorderSide(color: Neon.violet),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: Text('Cancel', style: TextStyle(color: Neon.textLo)),
                ),
                const SizedBox(width: 6),
                FilledButton(
                  onPressed: submit,
                  style: FilledButton.styleFrom(
                    backgroundColor: Neon.violet,
                    foregroundColor: Neon.onAccent,
                    minimumSize: const Size(88, 48),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Neon.rPill)),
                  ),
                  child: Text(action),
                ),
              ],
            ),
          ],
        ),
      );
    },
  ).whenComplete(ctrl.dispose);
}

/// ─────────────────────────────────────────────────────────────────────────
///  THE CELEBRATION — a soft glow and a ring of sparks from [origin], once:
///  1.2 s, then gone (the controller rests; nothing ticks afterwards).
///  Painted, no confetti library. With "Remove animations" on there is no
///  burst at all, only the haptic and the line.
/// ─────────────────────────────────────────────────────────────────────────
class MomentumBurst extends StatelessWidget {
  const MomentumBurst({super.key, required this.progress, required this.origin});

  /// 0 → 1 over the burst.
  final Animation<double> progress;

  /// Where it starts, as a fraction of the box (0.5, 0.5 = centre).
  final Alignment origin;

  static const duration = Duration(milliseconds: 1200);

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: RepaintBoundary(
        child: CustomPaint(
          painter: _BurstPainter(progress, origin, Neon.violet, Neon.pink),
          size: Size.infinite,
        ),
      ),
    );
  }
}

class _BurstPainter extends CustomPainter {
  _BurstPainter(this.t, this.origin, this.a, this.b) : super(repaint: t);
  final Animation<double> t;
  final Alignment origin;
  final Color a;
  final Color b;

  static const _sparks = 14;

  @override
  void paint(Canvas canvas, Size size) {
    final v = t.value;
    if (v <= 0 || v >= 1) return;
    final c = origin.alongSize(size);
    final reach = size.shortestSide * 0.9;
    // The glow: a soft disc that swells and fades.
    final glowR = reach * Curves.easeOutCubic.transform(v);
    final glowA = (1 - v) * 0.35;
    canvas.drawCircle(
      c,
      glowR,
      Paint()
        ..shader = RadialGradient(colors: [
          a.withValues(alpha: glowA),
          b.withValues(alpha: glowA * 0.4),
          b.withValues(alpha: 0),
        ]).createShader(Rect.fromCircle(center: c, radius: math.max(glowR, 1))),
    );
    // The sparks: fly out, slow down, fade.
    final travel = Curves.easeOutCubic.transform(v);
    final fade = 1 - Curves.easeInQuad.transform(v);
    for (var i = 0; i < _sparks; i++) {
      final angle = (i / _sparks) * 2 * math.pi + (i.isEven ? 0.12 : -0.08);
      final dist = reach * (0.45 + 0.25 * ((i * 37) % 10) / 10) * travel;
      final p = c + Offset(math.cos(angle), math.sin(angle)) * dist;
      canvas.drawCircle(p, 2.5 + (i % 3), Paint()..color = (i.isEven ? a : b).withValues(alpha: fade));
    }
  }

  @override
  bool shouldRepaint(_BurstPainter old) => false; // repaints with its animation
}

/// Plays [MomentumService.celebration] on the view it wraps — only when
/// that view is on screen, each celebration once — with a haptic and the
/// short line [builder] shows for four seconds.
class MomentumCelebrationHost extends StatefulWidget {
  const MomentumCelebrationHost({
    super.key,
    this.origin = Alignment.topRight,
    required this.builder,
  });

  final Alignment origin;

  /// Builds the view, given the celebration line to show (null = none now).
  final Widget Function(BuildContext context, String? line) builder;

  @override
  State<MomentumCelebrationHost> createState() => _MomentumCelebrationHostState();
}

class _MomentumCelebrationHostState extends State<MomentumCelebrationHost>
    with SingleTickerProviderStateMixin {
  late final AnimationController _burst =
      AnimationController(vsync: this, duration: MomentumBurst.duration);
  final _svc = MomentumService.instance;
  int _played = 0;
  String? _line;
  bool _bursting = false;

  @override
  void initState() {
    super.initState();
    // Anything already announced belongs to whoever was on screen then.
    _played = _svc.celebration.value?.seq ?? 0;
    _svc.celebration.addListener(_onCelebration);
    _burst.addStatusListener((s) {
      if (s == AnimationStatus.completed && mounted) {
        setState(() => _bursting = false);
        _burst.value = 0;
      }
    });
  }

  @override
  void dispose() {
    _svc.celebration.removeListener(_onCelebration);
    _burst.dispose();
    super.dispose();
  }

  bool get _onScreen {
    if (!mounted || !TickerMode.valuesOf(context).enabled) return false;
    return ModalRoute.of(context)?.isCurrent ?? true;
  }

  void _onCelebration() {
    final c = _svc.celebration.value;
    if (c == null || c.seq <= _played || !_onScreen) return;
    _played = c.seq;
    HapticFeedback.heavyImpact();
    final still = Motion.reduced(context);
    setState(() {
      _line = c.line;
      _bursting = !still;
    });
    if (!still) _burst.forward(from: 0);
    Future<void>.delayed(const Duration(seconds: 4), () {
      if (mounted && _line == c.line) setState(() => _line = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        widget.builder(context, _line),
        if (_bursting)
          Positioned.fill(child: MomentumBurst(progress: _burst, origin: widget.origin)),
      ],
    );
  }
}
