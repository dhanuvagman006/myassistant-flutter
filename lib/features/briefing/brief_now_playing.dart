import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../design/dock_metrics.dart';
import '../../design/motion.dart';
import '../../design/neon_tokens.dart';
import '../../design/neon_widgets.dart';
import '../../models/brief.dart';
import '../../services/auth_service.dart';
import '../../services/avatar_message_service.dart';
import '../assistant/state/assistant_engine.dart';
import '../meeting_prep/meeting_prep_sheet.dart';
import 'brief_player.dart';

/// What the finished brief's offer button does. The real ones by default;
/// tests hand in their own.
class BriefOfferActions {
  const BriefOfferActions();

  Future<void> run(BuildContext? context, BriefOffer offer) async {
    switch (offer.kind) {
      case 'meeting_prep':
        final ctx = context ?? AvatarMessageService.navigatorKey.currentContext;
        if (ctx != null && ctx.mounted) {
          await showMeetingPrep(ctx, meetingId: offer.meetingId);
        }
      case 'ask':
        if (offer.request.trim().isNotEmpty) {
          await AssistantEngine.instance.askAssistant(offer.request);
        }
      default:
        await AssistantEngine.instance
            .beginInlineConversation(name: AuthService.instance.user?.name);
    }
  }
}

/// ─────────────────────────────────────────────────────────────────────────
///  THE NOW-PLAYING STRIP (2026-09-30): a lit mini-player floating over
///  the dock while the day is read — what is being said (the captions),
///  how far along, pause and stop. Finished, it turns into the one offer
///  the brief ended with ("Prepare me") for twenty seconds.
///
///  It lives in the root overlay ([BriefStripOverlay]), so a brief asked
///  for by voice on any screen has its controls on that screen.
/// ─────────────────────────────────────────────────────────────────────────
class BriefNowPlaying extends StatelessWidget {
  const BriefNowPlaying({
    super.key,
    this.player,
    this.actions = const BriefOfferActions(),
  });

  /// [BriefPlayer.instance] unless a test hands one in.
  final BriefPlayer? player;
  final BriefOfferActions actions;

  @override
  Widget build(BuildContext context) {
    final p = player ?? BriefPlayer.instance;
    return ListenableBuilder(
      listenable: p,
      builder: (context, _) {
        final child = p.showStrip
            ? _Strip(key: const ValueKey('brief-strip'), p: p, actions: actions)
            : const SizedBox.shrink(key: ValueKey('brief-none'));
        if (Motion.reduced(context)) return child;
        return AnimatedSwitcher(
          duration: Motion.short,
          switchInCurve: Motion.easeMove,
          switchOutCurve: Curves.easeIn,
          transitionBuilder: (c, a) => FadeTransition(
            opacity: a,
            child: SlideTransition(
              position: Tween(begin: const Offset(0, 0.25), end: Offset.zero).animate(a),
              child: c,
            ),
          ),
          child: child,
        );
      },
    );
  }
}

class _Strip extends StatelessWidget {
  const _Strip({super.key, required this.p, required this.actions});
  final BriefPlayer p;
  final BriefOfferActions actions;

  @override
  Widget build(BuildContext context) {
    final title = p.script?.title ?? 'Your day';
    final s = p.state;
    final loading = s == BriefPlayState.loading;
    final done = s == BriefPlayState.done;
    final failed = s == BriefPlayState.failed;
    final tone = failed ? NeonTone.danger : done ? NeonTone.success : NeonTone.brand;
    final offer = p.script?.offer;
    final label = switch (s) {
      BriefPlayState.loading => 'Getting your day ready',
      BriefPlayState.playing => '$title, now playing',
      BriefPlayState.paused => '$title, paused',
      BriefPlayState.done => '$title, finished',
      BriefPlayState.failed => 'Your brief',
      BriefPlayState.idle => '',
    };
    return Semantics(
      container: true,
      label: label,
      child: GlowCard(
        tone: tone,
        halo: 1,
        radius: Neon.rMd,
        padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                ExcludeSemantics(
                  child: loading
                      ? const SizedBox(width: 40, height: 40, child: Center(child: NeonLoader.inline(size: 22)))
                      : _Bars(on: s == BriefPlayState.playing, tone: tone),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ExcludeSemantics(
                        child: Text(
                          loading ? 'Getting your day ready…' : title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: NeonType.manrope(NeonType.footnote, FontWeight.w700)
                              .copyWith(color: Neon.textLo),
                        ),
                      ),
                      if (!loading) ...[
                        const SizedBox(height: 2),
                        Text(
                          p.caption,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: NeonType.manrope(NeonType.body, FontWeight.w600)
                              .copyWith(color: Neon.textHi, height: 1.35),
                        ),
                      ],
                    ],
                  ),
                ),
                if (s == BriefPlayState.playing || s == BriefPlayState.paused)
                  IconButton(
                    tooltip: s == BriefPlayState.playing ? 'Pause' : 'Resume',
                    constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                    onPressed: p.toggle,
                    icon: Icon(
                      s == BriefPlayState.playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      color: Neon.textHi,
                      size: 28,
                    ),
                  ),
                IconButton(
                  tooltip: done || failed ? 'Close' : 'Stop',
                  constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                  onPressed: () => done || failed ? p.dismiss() : unawaited(p.stop()),
                  icon: Icon(done || failed ? Icons.close_rounded : Icons.stop_rounded,
                      color: Neon.textLo, size: 24),
                ),
              ],
            ),
            if (s == BriefPlayState.playing || s == BriefPlayState.paused) ...[
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ExcludeSemantics(child: _Progress(value: p.progress, tone: tone)),
              ),
            ],
            if (done && offer != null && offer.label.isNotEmpty) ...[
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerLeft,
                child: NeonPill(
                  label: offer.label,
                  icon: switch (offer.kind) {
                    'meeting_prep' => Icons.groups_rounded,
                    'talk' => Icons.mic_rounded,
                    _ => Icons.graphic_eq_rounded,
                  },
                  tone: NeonTone.success,
                  onPressed: () {
                    p.dismiss();
                    unawaited(actions.run(context, offer));
                  },
                ),
              ),
            ],
            if (failed) ...[
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerLeft,
                child: NeonPill(
                  label: 'Try again',
                  icon: Icons.refresh_rounded,
                  tone: NeonTone.danger,
                  onPressed: () => unawaited(p.play()),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A thin lit bar: how far through the day.
class _Progress extends StatelessWidget {
  const _Progress({required this.value, required this.tone});
  final double value;
  final NeonTone tone;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: SizedBox(
        height: 3,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: Neon.line),
            FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: value.clamp(0.0, 1.0),
              child: DecoratedBox(
                decoration: BoxDecoration(gradient: LinearGradient(colors: tone.rim)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Four lit bars that move with the voice; still when paused, or when
/// Remove animations is on.
class _Bars extends StatefulWidget {
  const _Bars({required this.on, required this.tone});
  final bool on;
  final NeonTone tone;

  @override
  State<_Bars> createState() => _BarsState();
}

class _BarsState extends State<_Bars> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1200));

  void _sync() {
    final move = widget.on && !Motion.reduced(context);
    if (move && !_c.isAnimating) {
      _c.repeat();
    } else if (!move && _c.isAnimating) {
      _c.stop();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(_Bars old) {
    super.didUpdateWidget(old);
    _sync();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rim = widget.tone.rim;
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        gradient: Neon.tile(rim.first),
        borderRadius: BorderRadius.circular(13),
        boxShadow: Neon.halo(rim.first, strength: 0.7),
      ),
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: _c,
          builder: (_, __) => Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < 4; i++)
                Container(
                  width: 3.5,
                  margin: const EdgeInsets.symmetric(horizontal: 1.5),
                  height: 6 +
                      (widget.on
                          ? 12 * (0.5 + 0.5 * math.sin((_c.value * 2 * math.pi) + i * 1.3)).abs()
                          : 4.0 + i % 2 * 4),
                  decoration: BoxDecoration(
                    color: Neon.onTile(rim.first),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Puts the strip in the root overlay, over the dock, once; it takes itself
/// out when the brief is put away.
abstract final class BriefStripOverlay {
  static OverlayEntry? _entry;

  static void show(OverlayState overlay) {
    if (_entry != null) return;
    final p = BriefPlayer.instance;
    late final VoidCallback onChange;
    final entry = OverlayEntry(
      builder: (ctx) => Positioned(
        left: 12,
        right: 12,
        // Over the dock's bar and the mic on it (the root overlay's inset
        // is only the system's).
        bottom: MediaQuery.paddingOf(ctx).bottom + Dock.barHeight + Dock.orbRise + 10,
        child: const Material(type: MaterialType.transparency, child: BriefNowPlaying()),
      ),
    );
    onChange = () {
      if (p.state == BriefPlayState.idle) {
        p.removeListener(onChange);
        if (_entry == entry) _entry = null;
        entry.remove();
      }
    };
    p.addListener(onChange);
    _entry = entry;
    overlay.insert(entry);
  }
}
