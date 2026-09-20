import 'package:flutter/material.dart';

import '../design/motion.dart';
import '../design/neon_tokens.dart';

/// FEATURES — an honest, three-tier map of the product: what works
/// today, what is being built right now, and what is planned. Static by
/// design: it changes exactly when the app changes, so it ships with
/// each release. Update the lists below whenever a feature moves tiers
/// (his spec, 2026-09-18: "fully implemented / currently working on /
/// yet to work on").
class FeaturesScreen extends StatelessWidget {
  const FeaturesScreen({super.key});

  static const _live = <(String, String)>[
    ('Voice assistant', 'Natural live conversation in your language'),
    ('Call notes', 'Recorded calls analysed — ask about any call, any fact'),
    ('Meetings & reminders', 'From calls and documents, straight onto your calendar'),
    ('Document understanding', 'Share a timetable or paper — reminders set themselves'),
    ('Email', 'Reads and sends your mail when you ask'),
    ('Daily brief', 'Agenda, promises, weather and news in one glance'),
    ('Phone control', 'Open apps, call contacts, set timers — by voice'),
    ('Legal lookup', 'Indian case-law search built in'),
    ('Automatic updates', 'New versions install themselves'),
  ];

  static const _building = <(String, String)>[
    ('Assistant phone calls', 'The assistant calls people for you — wake-up calls, messages, questions'),
    ('Video avatar messages', 'Your assistant delivers messages as a talking avatar'),
  ];

  static const _planned = <(String, String)>[
    ('Hands-free wake word', 'Just say the name — no tap needed'),
    ('iPhone version', 'The same assistant on iOS'),
    ('Play Store release', 'Install and update from Google Play'),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Neon.bg,
      appBar: AppBar(backgroundColor: Neon.bg, title: const Text('Features')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          _section('LIVE NOW', Neon.lime, Icons.check_circle_rounded, _live, 0),
          const SizedBox(height: 22),
          _section('IN PROGRESS', const Color(0xFFFFB020),
              Icons.build_circle_rounded, _building, 120),
          const SizedBox(height: 22),
          _section('COMING SOON', Neon.violet, Icons.schedule_rounded,
              _planned, 220),
        ],
      ),
    );
  }

  Widget _section(String title, Color tint, IconData icon,
      List<(String, String)> items, int delayMs) {
    return Reveal(
      delayMs: delayMs,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: tint),
              const SizedBox(width: 8),
              Text(title,
                  style: TextStyle(
                      color: tint,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.1)),
            ],
          ),
          const SizedBox(height: 10),
          Container(
            decoration: BoxDecoration(
              color: Neon.surface,
              borderRadius: BorderRadius.circular(Neon.rLg),
              border: Border.all(color: Neon.line),
            ),
            child: Column(
              children: [
                for (var i = 0; i < items.length; i++) ...[
                  if (i > 0)
                    Divider(height: 1, thickness: 1, color: Neon.line),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          margin: const EdgeInsets.only(top: 6),
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                              color: tint, shape: BoxShape.circle),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(items[i].$1,
                                  style: TextStyle(
                                      color: Neon.textHi,
                                      fontSize: 14.5,
                                      fontWeight: FontWeight.w700)),
                              const SizedBox(height: 2),
                              Text(items[i].$2,
                                  style: TextStyle(
                                      color: Neon.textLo,
                                      fontSize: 12.5,
                                      height: 1.35)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
