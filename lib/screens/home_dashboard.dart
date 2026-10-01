import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../design/dock_metrics.dart';
import '../design/motion.dart';
import '../design/neon_tokens.dart';
import '../core/daily_quotes.dart';
import '../features/home/home_cards.dart';
import '../services/auth_service.dart';
import '../widgets/call_led.dart';
import 'search_screen.dart';

/// HOME TAB — what needs you now (2026-09-29).
///
/// The greeting, then one Now card, up to two smaller ones, the next three
/// things of the day and quick actions (features/home). The mic below is
/// how the user acts on any of it. The month moved to its own page.
class HomeDashboard extends StatelessWidget {
  const HomeDashboard({super.key, this.clock = DateTime.now});

  /// Test seam: the time the greeting, the date and the feed are for.
  final DateTime Function() clock;

  String get _greeting {
    final h = clock().hour;
    if (h < 12) return 'Good morning';
    if (h < 17) return 'Good afternoon';
    return 'Good evening';
  }

  @override
  Widget build(BuildContext context) {
    final now = clock();
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
        child: Builder(
      builder: (context) {
        final first = (AuthService.instance.user?.name ?? '')
            .trim()
            .split(RegExp(r'\s+'))
            .first;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // THE GREETING, LIT (2026-09-30, the client's reference): the
            // time of day as a glowing sun or moon, the name on its own
            // line in the app's light (cyan into magenta), search in a lit
            // ring beside it. Read out as one line.
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2, right: 10),
                  child: _DayIcon(hour: now.hour),
                ),
                Expanded(
                  child: Semantics(
                    header: true,
                    label: first.isEmpty ? _greeting : '$_greeting, $first',
                    child: ExcludeSemantics(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            first.isEmpty ? _greeting : '$_greeting,',
                            style: GoogleFonts.spaceGrotesk(
                              fontSize: NeonType.title2,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.5,
                              color: Neon.textHi,
                            ),
                          ),
                          if (first.isNotEmpty)
                            FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerLeft,
                              child: ShaderMask(
                                blendMode: BlendMode.srcIn,
                                shaderCallback: (r) => LinearGradient(
                                  colors: [Neon.cyan, Neon.violet, Neon.pink],
                                ).createShader(r),
                                child: Text(
                                  first,
                                  style: GoogleFonts.spaceGrotesk(
                                    fontSize: NeonType.largeTitle + 10,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: -0.8,
                                    height: 1.1,
                                    color: Colors.white,
                                    // its own glow, tinted by the gradient
                                    shadows: [
                                      Shadow(
                                          color: Colors.white.withValues(alpha: 0.55),
                                          blurRadius: 18),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                _SearchRing(
                  onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const SearchScreen())),
                ),
              ],
            ),
            const SizedBox(height: 4),
            // The date alone (owner, 2026-09-30: the weather chip beside
            // it "looks bad"). Rain or heat worth knowing about still gets
            // its own card in the feed.
            Text(
              '${wk[now.weekday - 1]}, ${now.day} ${mo[now.month - 1]}',
              style: TextStyle(color: Neon.textLo, fontSize: NeonType.body),
            ),
            // THE DAY'S LINE, right under the date (owner, 2026-09-30: "need
            // motivational quotes right below the date"). No card, no tint:
            // an accent rule down the left, brighter ink, a size up — it
            // reads as something meant, without a background of any kind.
            const SizedBox(height: 16),
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
                      style: NeonType.manrope(NeonType.rowTitle, FontWeight.w500)
                          .copyWith(color: Neon.textHi, height: 1.4, letterSpacing: 0.1),
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
          // Missed calls are cards in the feed now, ranked with the rest.
          Expanded(
            child: HomeFeedView(
              leading: header,
              clock: clock,
              // The last card clears the dock and the mic on every phone.
              padding: EdgeInsets.fromLTRB(20, 18, 20, Dock.clearance(context)),
            ),
          ),
        ],
      ),
    );
  }
}

/// The time of day, lit: a sun by day, the dusk in the evening, a moon at
/// night — each with its own glow.
class _DayIcon extends StatelessWidget {
  const _DayIcon({required this.hour});
  final int hour;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = hour >= 5 && hour < 17
        ? (Icons.wb_sunny_rounded, const Color(0xFFFFC53D))
        : hour >= 17 && hour < 20
            ? (Icons.wb_twilight_rounded, const Color(0xFFFF9A4D))
            : (Icons.nightlight_round, const Color(0xFFC9B8FF));
    return DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: Neon.halo(color, strength: 0.9),
      ),
      child: Icon(icon, size: 30, color: color),
    );
  }
}

/// Search in a lit ring: the app's rim around a round glass button.
class _SearchRing extends StatelessWidget {
  const _SearchRing({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          // A hairline of the app's light, no halo (premium pass).
          colors: [for (final c in Neon.rim) c.withValues(alpha: 0.45)],
        ),
        boxShadow: Neon.lift,
      ),
      child: Padding(
        padding: const EdgeInsets.all(1),
        child: Material(
          color: Neon.surface,
          shape: const CircleBorder(),
          child: IconButton(
            tooltip: 'Search',
            onPressed: onTap,
            icon: Icon(Icons.search_rounded, color: Neon.textHi, size: 24),
          ),
        ),
      ),
    );
  }
}
