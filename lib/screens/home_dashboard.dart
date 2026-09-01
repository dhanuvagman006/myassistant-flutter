import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../design/neon_tokens.dart';
import '../features/assistant/widgets/today_panel.dart';
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
            child: AnimatedBuilder(
              animation: BriefService.instance,
              builder: (context, _) {
                final b = BriefService.instance.brief;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _greeting,
                      style: GoogleFonts.spaceGrotesk(
                        fontSize: 27,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.5,
                        color: Neon.textHi,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Text(
                          '${wk[now.weekday - 1]}, ${now.day} ${mo[now.month - 1]}',
                          style: const TextStyle(
                              color: Neon.textLo, fontSize: 13.5),
                        ),
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
                              style: const TextStyle(
                                  color: Neon.cyan,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                );
              },
            ),
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
