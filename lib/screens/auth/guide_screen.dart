import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../design/neon_tokens.dart';
import '../../design/motion.dart';
import '../../design/neon_widgets.dart';
import '../../widgets/glow_cta.dart';
import '../../services/assistant_identity.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  FIRST-RUN GUIDE — four swipeable cards, shown once after the welcome
///  moment. Teaches the one habit that matters (talk to it) and where
///  things live. Skippable at every step; never blocks anything.
/// ─────────────────────────────────────────────────────────────────────────
class GuideScreen extends StatefulWidget {
  const GuideScreen({super.key, required this.onDone});

  final VoidCallback onDone;

  @override
  State<GuideScreen> createState() => _GuideScreenState();
}

class _GuideScreenState extends State<GuideScreen> {
  final _page = PageController();
  int _index = 0;

  List<({IconData icon, String title, String body})> get _pages {
    final a = AssistantIdentity.name;
    return [
      (
        icon: Icons.graphic_eq_rounded,
        title: 'Talk, don\'t tap',
        body: 'Tap the orb at the bottom of the home screen and just speak. '
            '$a listens, answers out loud, and keeps the conversation going.',
      ),
      (
        icon: Icons.task_alt_rounded,
        title: '$a actually gets things done',
        body: 'Place calls, deliver messages, set reminders, plan your money, '
            'create images and speeches — say it, and it happens.',
      ),
      (
        icon: Icons.space_dashboard_rounded,
        title: 'Your day, at a glance',
        body: 'Home shows your agenda, promises, messages and headlines. '
            'The Hub holds finance, markets, clients and more.',
      ),
      (
        icon: Icons.tune_rounded,
        title: 'Make it yours',
        body: 'Pick a voice under the You tab, add your own '
            'rules — or just say "your name is Nova now" and $a renames '
            'itself.',
      ),
    ];
  }

  void _next() {
    HapticFeedback.selectionClick();
    if (_index >= _pages.length - 1) {
      widget.onDone();
    } else {
      _page.nextPage(
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
    }
  }

  @override
  void dispose() {
    _page.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pages = _pages;
    final last = _index == pages.length - 1;

    // Under Home's sky, each page's icon in the lit brand tile and the
    // one action lit (2026-09-30).
    final reduced = Motion.reduced(context);
    return NeonScaffold(
      body: SafeArea(
        child: Column(
          children: [
            // Skip is always one tap away — a guide must never feel like a
            // gate.
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(top: 4, right: 8),
                child: TextButton(
                  onPressed: widget.onDone,
                  child: Text('Skip', style: TextStyle(color: Neon.textLo)),
                ),
              ),
            ),
            Expanded(
              child: PageView.builder(
                controller: _page,
                itemCount: pages.length,
                onPageChanged: (i) => setState(() => _index = i),
                itemBuilder: (_, i) {
                  final p = pages[i];
                  return Center(
                    // Scrolls when short on room instead of overflowing.
                    child: SingleChildScrollView(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 420),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 32),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              BrandMark(size: 64, icon: p.icon),
                              const SizedBox(height: 26),
                              Text(
                                p.title,
                                style: GoogleFonts.spaceGrotesk(
                                  fontSize: 26,
                                  fontWeight: FontWeight.w700,
                                  color: Neon.textHi,
                                  letterSpacing: -0.5,
                                  height: 1.15,
                                ),
                              ),
                              const SizedBox(height: 12),
                              Text(
                                p.body,
                                style: TextStyle(
                                  color: Neon.textLo,
                                  fontSize: 16,
                                  height: 1.55,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Row(
                  children: [
                    // Progress dots — the current one stretches.
                    for (var i = 0; i < pages.length; i++) ...[
                      AnimatedContainer(
                        // Motion tokens (2026-09-30; a raw 220 ms).
                        duration: reduced ? Duration.zero : Motion.short,
                        curve: Motion.easeMove,
                        width: i == _index ? 22 : 7,
                        height: 7,
                        decoration: BoxDecoration(
                          color: i == _index
                              ? Neon.violet
                              : Neon.violet.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(4),
                          boxShadow: i == _index
                              ? Neon.halo(Neon.violet, strength: 0.6)
                              : null,
                        ),
                      ),
                      const SizedBox(width: 6),
                    ],
                    const Spacer(),
                    // The theme's lit button with the brand's halo under it
                    // (a bare TextStyle here drew the phone's own font).
                    DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(14),
                        boxShadow: Neon.halo(Neon.violet),
                      ),
                      child: FilledButton(
                        onPressed: _next,
                        style: FilledButton.styleFrom(
                          textStyle: NeonType.manrope(
                              NeonType.rowTitle, FontWeight.w600),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 28, vertical: 14),
                        ),
                        child: Text(last ? 'Get started' : 'Next'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
