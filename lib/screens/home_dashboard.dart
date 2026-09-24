import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../design/dock_metrics.dart';
import '../design/motion.dart';
import '../design/neon_tokens.dart';
import '../features/assistant/widgets/today_panel.dart';
import '../core/daily_quotes.dart';
import '../services/auth_service.dart';
import '../services/streak_service.dart';
import '../services/brief_service.dart';
import '../widgets/call_led.dart';
import '../widgets/missed_calls_card.dart';
import 'search_screen.dart';

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
    // THE HEADER SCROLLS WITH THE FEED (2026-09-24, home2.png). Pinned, it
    // took ~250 dp of the screen, and the feed scrolled up under the quote
    // with no gap or ground — the suggestion chips looked like they slid
    // beneath its text. Now greeting, date and quote are simply the top of
    // the list; only the call light stays put.
    final header = Reveal(
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
            // warm spot of color instead of a wall of gray. Search
            // sits beside it: find anything, from the first screen.
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: RichText(
                    text: TextSpan(
                      style: GoogleFonts.spaceGrotesk(
                        fontSize: NeonType.title2,
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
                ),
                IconButton(
                  tooltip: 'Search',
                  onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const SearchScreen())),
                  icon: Icon(Icons.search_rounded, color: Neon.textHi, size: 26),
                ),
              ],
            ),
            const SizedBox(height: 4),
            // A Wrap, not a Row: with a larger system font (common
            // on the phones this app is for) date + streak +
            // weather did not fit one line and overflowed.
            Wrap(
              spacing: 10,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  '${wk[now.weekday - 1]}, ${now.day} ${mo[now.month - 1]}',
                  style: TextStyle(
                      color: Neon.textLo, fontSize: NeonType.body),
                ),
                // COMING BACK IS THE HABIT. A quiet streak count
                // beside the date — visible enough to notice, far
                // from a game badge.
                if (StreakService.instance.count > 1) ...[
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
                        // Plain ink at night: the violet words sat on the
                        // brightest pool of the dark ambient at 3.4:1.
                        Text(
                          '${StreakService.instance.count} days',
                          style: NeonType.manrope(
                                  NeonType.caption, FontWeight.w700)
                              .copyWith(
                                  color: Neon.isDark
                                      ? Neon.textHi
                                      : Neon.violet),
                        ),
                      ],
                    ),
                  ),
                ],
                if (b.weatherLine != null) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 3),
                    decoration: BoxDecoration(
                      color: Neon.cyan.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    // cyanInk: plain cyan words on this chip were 2.48:1.
                    child: Text(
                      b.weatherLine!,
                      style: NeonType.manrope(
                              NeonType.caption, FontWeight.w600)
                          .copyWith(color: Neon.cyanInk),
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
                  // Medium, for real (it drew as regular): a step above
                  // the feed, a step below the bold section titles.
                  Expanded(
                    child: Text(
                      DailyQuotes.today(),
                      style: NeonType.manrope(
                              NeonType.rowTitle, FontWeight.w500)
                          .copyWith(
                        color: Neon.textHi,
                        height: 1.4,
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
    ));
    return SafeArea(
      bottom: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Shows only while the assistant is actually on a call.
          const CallLed(),
          // Calls missed since the owner last looked, with Call back
          // (owner, 2026-09-24). Nothing at all when there are none.
          const MissedCallsCard(),
          Expanded(
            child: TodayBriefBody(
              leading: header,
              // The last card clears the dock and the mic on every phone.
              padding: EdgeInsets.fromLTRB(20, 18, 20, Dock.clearance(context)),
            ),
          ),
        ],
      ),
    );
  }
}
