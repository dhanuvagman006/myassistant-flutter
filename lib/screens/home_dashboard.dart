import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../design/motion.dart';
import '../design/neon_tokens.dart';
import '../features/assistant/widgets/today_panel.dart';
import '../core/daily_quotes.dart';
import '../services/auth_service.dart';
import '../services/streak_service.dart';
import '../services/brief_service.dart';

/// HOME TAB — the day at a glance, out in the open.
///
/// What used to hide behind the Today pill is the resting state now:
/// greeting, weather, messages, agenda, promises, circle — a feed the
/// user reads without asking. The mic below is how they act on it.
class HomeDashboard extends StatelessWidget {
  const HomeDashboard({super.key});

  String get _greeting {
    final h = DateTime.now().hour;
    if (h < 12) return 'Good morning';
    if (h < 17) return 'Good afternoon';
    return 'Good evening';
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    const wk = [
      'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday',
      'Sunday'
    ];
    const mo = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    return SafeArea(
      bottom: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
            child: Reveal(
                child: AnimatedBuilder(
              animation: BriefService.instance,
              builder: (context, _) {
                final b = BriefService.instance.brief;
                final first = (AuthService.instance.user?.name ?? '')
                    .trim()
                    .split(RegExp(r'\s+'))
                    .first;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Personal, with the name carrying the accent — one
                    // warm spot of color instead of a wall of gray.
                    RichText(
                      text: TextSpan(
                        style: GoogleFonts.spaceGrotesk(
                          fontSize: 27,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.5,
                          color: Neon.textHi,
                        ),
                        children: [
                          TextSpan(text: _greeting),
                          if (first.isNotEmpty) ...[
                            const TextSpan(text: ', '),
                            TextSpan(
                                text: first,
                                style: TextStyle(color: Neon.violet)),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Text(
                          '${wk[now.weekday - 1]}, ${now.day} ${mo[now.month - 1]}',
                          style: TextStyle(
                              color: Neon.textLo, fontSize: 13.5),
                        ),
                        // COMING BACK IS THE HABIT. A quiet streak count
                        // beside the date — visible enough to notice, far
                        // from a game badge.
                        if (StreakService.instance.count > 1) ...[
                          const SizedBox(width: 10),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 3),
                            decoration: BoxDecoration(
                              color: Neon.violet.withValues(alpha: 0.13),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.local_fire_department_rounded,
                                    size: 13, color: Neon.violet),
                                const SizedBox(width: 4),
                                Text(
                                  '${StreakService.instance.count} days',
                                  style: TextStyle(
                                      color: Neon.violet,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700),
                                ),
                              ],
                            ),
                          ),
                        ],
                        if (b.weatherLine != null) ...[
                          const SizedBox(width: 10),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 3),
                            decoration: BoxDecoration(
                              color: Neon.cyan.withValues(alpha: 0.10),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              b.weatherLine!,
                              style: TextStyle(
                                  color: Neon.cyan,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600),
                            ),
                          ),
                        ],
                      ],
                    ),
                    // THE DAY'S LINE, as plain text under the date — no
                    // card, no tint, nothing to tap (his call, 2026-09-19:
                    // the three action tiles came out and this took their
                    // place). It reads as part of the header, which is
                    // what makes it feel considered rather than bolted on.
                    const SizedBox(height: 16),
                    // HIGHLIGHTED, BUT STILL JUST TEXT. A card was
                    // rejected, and a plain grey line was too easy to
                    // skip past — so it gets the editorial treatment
                    // instead: an accent rule down the left, brighter
                    // ink, a size up. It reads as something meant,
                    // without a background of any kind.
                    IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Container(
                            width: 3,
                            decoration: BoxDecoration(
                              gradient: Neon.gBrand,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              DailyQuotes.today(),
                              style: TextStyle(
                                color: Neon.textHi,
                                fontSize: 16.5,
                                height: 1.4,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.1,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            )),
          ),
          const Expanded(
            child: TodayBriefBody(
              padding: EdgeInsets.fromLTRB(20, 14, 20, 120),
            ),
          ),
        ],
      ),
    );
  }
}
