import 'package:flutter/material.dart';

import '../features/assistant/state/assistant_engine.dart';
import '../features/assistant/widgets/action_cards.dart';

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
  }

  @override
  void dispose() {
    _engine.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final child = _card();
    // Nothing to show is the common case: stay out of the way entirely so
    // the dock and the tab underneath keep every pixel and every tap.
    if (child == null) return const SizedBox.shrink();

    final bottom = MediaQuery.of(context).padding.bottom + 84; // above the dock
    return Positioned(
      left: 0,
      right: 0,
      bottom: bottom,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            child: child,
          ),
        ),
      ),
    );
  }

  /// Only ever ONE card. When a turn produces several things the most
  /// urgent wins — a decision the user has to make outranks a result they
  /// only need to read.
  Widget? _card() {
    final e = _engine;

    if (e.pendingConfirmation != null) {
      return ConfirmationCard(
        key: const ValueKey('confirm'),
        pending: e.pendingConfirmation!,
        onDecision: (approved) => e.confirm(approved),
      );
    }

    if (e.callStatus != null) {
      return CallStatusCard(
        key: const ValueKey('callstatus'),
        status: e.callStatus!,
      );
    }

    if (e.presentedText != null) {
      final h = MediaQuery.of(context).size.height;
      return ConstrainedBox(
        key: const ValueKey('script'),
        constraints: BoxConstraints(maxHeight: h * 0.55),
        child: ScriptCard(
          title: e.presentedTitle ?? 'For you',
          content: e.presentedText!,
          onClose: e.dismissPresentedText,
        ),
      );
    }

    if (e.searchResults.isNotEmpty) {
      final results = e.searchResults.take(3).toList(growable: false);
      return Column(
        key: const ValueKey('search'),
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final r in results)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: SearchResultCard(result: r),
            ),
        ],
      );
    }

    // A document that the gallery could not show (no host to pop over).
    if (e.generatedImage != null) {
      final h = MediaQuery.of(context).size.height;
      return ConstrainedBox(
        key: ValueKey('image-${e.generatedImage!.id}'),
        constraints: BoxConstraints(maxHeight: h * 0.46),
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
