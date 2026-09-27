import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../design/dock_metrics.dart';
import '../design/motion.dart';
import '../design/neon_tokens.dart';
import '../features/assistant/state/assistant_engine.dart';
import '../features/assistant/widgets/action_cards.dart';
import '../services/app_feedback.dart';
import 'inline_voice.dart' show InlineCaptionOverlay, voiceSessionOnScreen;

/// ─────────────────────────────────────────────────────────────────────────
///  THE CARDS A TURN PRODUCES, ON HOME.
///
///  These used to live only inside the full conversation screen, which is
///  why Home had to throw that screen over itself the moment a turn needed
///  a tap — and why an image the assistant said was "on your screen" was
///  on a screen nobody was looking at.
///
///  They sit above the dock now, over whatever tab is open, so a
///  confirmation, a call in progress or a written piece appears exactly
///  where the user already is. The conversation keeps running underneath
///  and the mic stays hot.
///
///  Generated images and recalled documents are deliberately NOT here:
///  they open the full-screen gallery instead. One thing, one presentation.
/// ─────────────────────────────────────────────────────────────────────────
class AssistantResultOverlay extends StatefulWidget {
  const AssistantResultOverlay({super.key});

  @override
  State<AssistantResultOverlay> createState() => _AssistantResultOverlayState();
}

class _AssistantResultOverlayState extends State<AssistantResultOverlay> {
  final _engine = AssistantEngine.instance;

  @override
  void initState() {
    super.initState();
    _engine.addListener(_onChange);
    AppFeedback.changes.addListener(_onChange);
    InlineCaptionOverlay.typeBarReach.addListener(_onChange);
  }

  @override
  void dispose() {
    _engine.removeListener(_onChange);
    AppFeedback.changes.removeListener(_onChange);
    InlineCaptionOverlay.typeBarReach.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    // Nothing to show is the common case: stay out of the way entirely so
    // the dock and the tab underneath keep every pixel and every tap.
    final m = MediaQuery.of(context);
    // WHERE THE CARD SITS. It used to add the dock twice (padding.bottom,
    // then a SafeArea on top of it), so it floated a whole dock-height too
    // high and a tall card ran off the top of a small phone. Now: just
    // above the mic — or, during a voice session, just above the session's
    // text box, so the two never overlap. A toast showing: above the toast.
    final reach = InlineCaptionOverlay.typeBarReach.value;
    final base = voiceSessionOnScreen(_engine)
        ? (reach > 0 ? reach + 10 : Dock.clearance(context, gap: 12) + 80)
        : Dock.clearance(context, gap: 14);
    final bottom = AppFeedback.clearOfToast(base);
    // Clear of the status bar and the activity pill under it — and of the
    // keyboard, which this screen area ends at when it is up (the body's
    // own MediaQuery no longer reports it, so ask the window).
    final view = View.of(context);
    final kb = view.viewInsets.bottom / view.devicePixelRatio;
    final room = math.max(
        0.0, m.size.height - kb - bottom - m.viewPadding.top - 64);
    final child = _card(room);
    if (child == null) return const SizedBox.shrink();
    return AnimatedPositioned(
      duration: Motion.short,
      curve: Motion.easeMove,
      left: 0,
      right: 0,
      bottom: bottom,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: room),
          // CARDS COME OUT OF THE MIC (2026-09-24). The switcher below was
          // created together with the first card, and a switcher never
          // animates its first child — so every confirmation, script,
          // sources and image card appeared at full size in one frame. The
          // first card now fades in as it grows from 96% about its bottom
          // edge (just above the mic, which it never crosses); leaving
          // stays instant. A card replacing another fades and grows in on
          // the same curve, anchored at the bottom, so a taller or shorter
          // card no longer jumps its top edge (it was a linear cross-fade
          // centred on both).
          child: EnterOnce(
            duration: const Duration(milliseconds: 240),
            scaleFrom: 0.96,
            alignment: Alignment.bottomCenter,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 240),
              reverseDuration: Motion.out,
              switchInCurve: Motion.easeEnter,
              switchOutCurve: Motion.easeFadeOut,
              transitionBuilder: (child, a) => FadeTransition(
                opacity: a,
                child: ScaleTransition(
                  scale: Tween<double>(begin: 0.96, end: 1.0).animate(a),
                  alignment: Alignment.bottomCenter,
                  filterQuality: FilterQuality.medium,
                  child: child,
                ),
              ),
              layoutBuilder: (current, previous) => Stack(
                alignment: Alignment.bottomCenter,
                children: [...previous, if (current != null) current],
              ),
              child: child,
            ),
          ),
        ),
      ),
    );
  }

  /// Only ever ONE card. When a turn produces several things the most
  /// urgent wins — a decision the user has to make outranks a result they
  /// only need to read.
  Widget? _card(double room) {
    final e = _engine;

    if (e.pendingConfirmation != null) {
      return ConfirmationCard(
        key: const ValueKey('confirm'),
        pending: e.pendingConfirmation!,
        onDecision: (approved) => e.confirm(approved),
      );
    }

    // An event read off a picked screenshot: a one-tap choice, so it sits
    // with the decisions, above anything only to be read.
    if (e.seenEvent != null) {
      return EventOfferCard(
        key: const ValueKey('seen-event'),
        event: e.seenEvent!,
        onRemind: e.remindSeenEvent,
        onCalendar: e.calendarSeenEvent,
        onClose: e.dismissSeenEvent,
      );
    }

    // A CALL IN PROGRESS IS NOT A CARD ANY MORE (his call, 2026-09-20:
    // "don't display that current call on the orb itself"). It covered
    // whatever screen the user was on for the length of the conversation,
    // to say something they did not need to watch. CallLed on Home shows
    // it as a status light instead, and the Calls screen holds the reply.

    if (e.presentedText != null) {
      final h = MediaQuery.of(context).size.height;
      return ConstrainedBox(
        key: const ValueKey('script'),
        constraints: BoxConstraints(maxHeight: math.min(h * 0.55, room)),
        child: ScriptCard(
          title: e.presentedTitle ?? 'For you',
          content: e.presentedText!,
          onClose: e.dismissPresentedText,
        ),
      );
    }

    // WEB RESULTS: a labelled stack with its own ✕, capped in height and
    // scrollable — three bare cards with no way to close them used to sit
    // over the orb and the captions until the next question.
    if (e.searchResults.isNotEmpty) {
      final results = e.searchResults.take(3).toList(growable: false);
      final h = MediaQuery.of(context).size.height;
      return ConstrainedBox(
        key: const ValueKey('search'),
        constraints: BoxConstraints(maxHeight: math.min(h * 0.45, room)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const SizedBox(width: 6),
                Icon(Icons.public_rounded, size: 15, color: Neon.textLo),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Sources',
                    style: TextStyle(
                        color: Neon.textLo,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.3),
                  ),
                ),
                IconButton(
                  tooltip: 'Close sources',
                  constraints:
                      const BoxConstraints(minWidth: 48, minHeight: 48),
                  padding: EdgeInsets.zero,
                  onPressed: e.dismissSearchResults,
                  icon: Icon(Icons.close_rounded,
                      size: 18, color: Neon.textHi),
                  style: IconButton.styleFrom(
                    backgroundColor: Neon.surfaceHigh,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final r in results)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: SearchResultCard(result: r),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }

    // A document that the gallery could not show (no host to pop over).
    if (e.generatedImage != null) {
      final h = MediaQuery.of(context).size.height;
      return ConstrainedBox(
        key: ValueKey('image-${e.generatedImage!.id}'),
        constraints: BoxConstraints(maxHeight: math.min(h * 0.46, room)),
        child: GeneratedImageCard(
          document: e.generatedImage!,
          prompt: '',
          onClose: e.dismissGeneratedImage,
        ),
      );
    }

    return null;
  }
}
