import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../design/neon_tokens.dart';
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
        body:
            'Tap the orb at the bottom of the home screen and just speak. '
            '$a listens, answers out loud, and keeps the conversation going.',
      ),
      (
        icon: Icons.task_alt_rounded,
        title: '$a actually gets things done',
        body:
            'Place calls, deliver messages, set reminders, plan your money, '
            'create images and speeches — say it, and it happens.',
      ),
      (
        icon: Icons.space_dashboard_rounded,
        title: 'Your day, at a glance',
        body:
            'Home shows your agenda, promises, messages and headlines. '
            'The Hub holds finance, markets, clients and more.',
      ),
      (
        icon: Icons.tune_rounded,
        title: 'Make it yours',
        body:
            'Rename $a, pick a voice and a face, or add your own rules — '
            'any time, under the You tab.',
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

    return Scaffold(
      backgroundColor: Neon.bg,
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
                  child: const Text('Skip',
                      style: TextStyle(color: Neon.textLo)),
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
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 420),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 32),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              width: 64,
                              height: 64,
                              decoration: BoxDecoration(
                                color: Neon.textHi,
                                borderRadius: BorderRadius.circular(18),
                              ),
                              child: Icon(p.icon,
                                  color: Colors.white, size: 30),
                            ),
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
                              style: const TextStyle(
                                color: Neon.textLo,
                                fontSize: 15.5,
                                height: 1.55,
                              ),
                            ),
                          ],
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
                        duration: const Duration(milliseconds: 220),
                        curve: Curves.easeOutCubic,
                        width: i == _index ? 22 : 7,
                        height: 7,
                        decoration: BoxDecoration(
                          color: i == _index
                              ? Neon.textHi
                              : Neon.textHi.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                      const SizedBox(width: 6),
                    ],
                    const Spacer(),
                    FilledButton(
                      onPressed: _next,
                      style: FilledButton.styleFrom(
                        backgroundColor: Neon.textHi,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 28, vertical: 14),
                      ),
                      child: Text(last ? 'Get started' : 'Next'),
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
