import 'package:flutter/material.dart';

import '../design/apple_kit.dart';
import '../design/motion.dart';
import '../design/neon_tokens.dart';
import '../design/neon_widgets.dart';

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
    (
      'Meetings & reminders',
      'From calls and documents, straight onto your calendar'
    ),
    (
      'Document understanding',
      'Share a timetable, sheet or deck — it reads them all'
    ),
    (
      'Documents you can send',
      'Ask for a PDF, a slide deck, a document or a spreadsheet — it writes the real file'
    ),
    (
      'Split the bill',
      "Photo of the bill, 'split this four ways'"
    ),
    ('Us', 'Anniversary countdown on the calendar'),
    ('Email', 'Reads and sends your mail when you ask'),
    ('Daily brief', 'Agenda, promises, weather and news in one glance'),
    (
      'Assistant phone calls',
      'The assistant calls people for you — wake-up calls, messages, questions'
    ),
    ('Shortcuts', 'Say one word and I do several things'),
    ('Legal lookup', 'Indian case-law search built in'),
    ('Automatic updates', 'New versions install themselves'),
  ];

  static const _building = <(String, String)>[
    (
      'Video avatar messages',
      'Your assistant delivers messages as a talking avatar'
    ),
  ];

  static const _planned = <(String, String)>[
    ('Hands-free wake word', 'Just say the name — no tap needed'),
    ('More phones', 'The same assistant on other kinds of phone'),
    ('App store release', 'Install and update from the app store'),
  ];

  @override
  Widget build(BuildContext context) {
    return NeonScaffold(
      appBar: appleAppBar(context, 'Features'),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
            20, 8, 20, 32 + MediaQuery.paddingOf(context).bottom),
        children: [
          // Each tier in its meaning's light (2026-09-30, NeonTone): live
          // is done-and-well green and the brightest; in progress amber;
          // coming soon the purple of something to discover.
          _section('LIVE NOW', NeonTone.success, Icons.check_circle_rounded,
              _live, 0,
              halo: 0.6),
          const SizedBox(height: 22),
          _section('IN PROGRESS', NeonTone.warning, Icons.build_circle_rounded,
              _building, 120),
          const SizedBox(height: 22),
          _section('COMING SOON', NeonTone.discovery, Icons.schedule_rounded,
              _planned, 220),
        ],
      ),
    );
  }

  Widget _section(String title, NeonTone tone, IconData icon,
      List<(String, String)> items, int delayMs,
      {double halo = 0.3}) {
    final tint = tone.ink;
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
          GlowCard(
            tone: tone,
            halo: halo,
            rimWidth: 1.6,
            child: Column(
              children: [
                for (var i = 0; i < items.length; i++) ...[
                  if (i > 0)
                    Divider(height: 1, thickness: 0.5, color: Neon.line),
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
                              color: tone.rim.first,
                              shape: BoxShape.circle,
                              boxShadow:
                                  Neon.halo(tone.rim.first, strength: 0.4)),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(items[i].$1,
                                  style: TextStyle(
                                      color: Neon.textHi,
                                      fontSize: 15,
                                      fontWeight: FontWeight.w700)),
                              const SizedBox(height: 2),
                              Text(items[i].$2,
                                  style: TextStyle(
                                      color: Neon.textLo,
                                      fontSize: 13,
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
