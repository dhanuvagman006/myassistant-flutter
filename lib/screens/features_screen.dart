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

  /// What works today, grouped the way people ask for it (2026-10-01).
  static const _groups = <(String, List<(String, String)>)>[
    ('MAKE', [
      ('Photo cards & greeting cards', "A real photo, your words, your signature — 'show me another one' until it is right"),
      ('Event posters', 'A poster for the party, the pooja, the launch — with the date and venue on it'),
      ('Pictures & short videos', "'Draw a lion in neon', 'make a video of…' — made on the spot"),
      ('Photo edits', 'Restore an old photo, clean up a portrait, try a new look on yourself (Style Studio)'),
      ('Real files', 'A PPT, a PDF report, a Word document, an Excel sheet, a letter, your resume'),
      ('Written pieces', 'A speech, a script, a plan, an email draft — on screen, ready to use'),
      ('Video notes in your voice', "Record once in You; then 'send a video note to X saying…'"),
      ('Shortcuts & standing rules', "One word that does several things; rules it always follows"),
      ('Cards & documents scanned', 'A business card becomes a contact; a scan is filed under a client or patient'),
    ]),
    ('YOUR DAY', [
      ('Reminders that call you', "'Remind me at 9' — it phones you at 9 and says it"),
      ('Alarms, timers, calendar', 'Set, change, cancel by voice; the calendar with holidays and festivals'),
      ('Daily brief', "'What's my day', a spoken morning brief, 'play my day', plan my day"),
      ('Focus & habits', "A focus timer, Today's 3, habits you keep"),
      ('Weather & going out', "'Do I need an umbrella', hour-by-hour rain, a word before you step out"),
      ('Places & directions', "'Chemist near me' on the map, directions, where am I, saved addresses"),
      ('Shopping list', "'Add this' from any conversation — tick, share, shop it from Blinkit and more"),
      ('Kitchen', 'Recipes from what you have, cook mode, pantry'),
      ('News & markets', 'Headlines as cards, a story read aloud, live stocks'),
      ('Money', 'EMIs, loans and spare money planned; currency conversion; flight fares watched'),
      ('Horoscope', 'Yours, when you ask'),
    ]),
    ('PHONE & PEOPLE', [
      ('Calls for you', "Dial anyone — or 'call Ravi and tell him I'm late': it speaks for you, retries if you ask"),
      ('A voice that fits', "Woman's or man's voice; firm for dues, warm for wishes, gentle for bad news — or 'be firm'"),
      ('Calls in six languages', 'English, Hindi, Kannada, Malayalam, Tamil, Telugu — and it follows the other person'),
      ('What came of it', "What they promised is noted for you; hear the recording in Calls; 'connect me' hands the call to you"),
      ('Wake-up calls', "'Call me at 5 and wake me up' — it keeps calling until you answer"),
      ('Calls on any app', 'WhatsApp, Telegram, Signal calls by name'),
      ('Missed calls & call notes', "'Any missed calls?'; recorded calls analysed — ask what Ravi said"),
      ('Messages', 'To another user through their assistant, WhatsApp (you tap Send), plain SMS'),
      ('Email', 'Reads, replies and sends your mail; bills by email'),
      ('People memory', "Facts, notes, dates and addresses about people — 'what's Ravi's address'"),
      ('Nearby', "Share your profession and be found; 'find me nearby lawyers' lists people on the app and real places"),
      ('Interpreter', 'Two languages across the table, live'),
      ('Phone control', 'Flashlight, volume, Bluetooth, brightness, silent, any settings page'),
      ('Apps', 'Open, install or remove any app; open a profile; show a picture of anyone or anything'),
      ('Errands', 'Order food, book a ride, book movie tickets, pay by UPI — handed to the app, you confirm'),
      ('The web', 'Search, read a page aloud, save a PDF or map from the web'),
    ]),
    ('WORK', [
      ('Meetings', 'Record one — minutes, decisions, action items, a PDF; a prep card before the next'),
      ('Arrange a meeting', 'It calls the other person and settles a time'),
      ('Clients & patients', 'Dues, payments, recalls, their files — sent when you say'),
      ('Record books', "Dictated figures and tallies — 'what's my total'"),
      ('Indian law', 'Statutes, case law, rules and procedures — quoted, never invented'),
      ('Research', 'Deep research on a topic, web search for anything live'),
      ('Notion & connected tools', 'Search, read, add and create pages; your own tool servers'),
    ]),
    ('THE ASSISTANT', [
      ('Live voice conversation', 'English, Kannada, Hindi, Tamil, Telugu, Malayalam and more — talk over it any time'),
      ('Typed chat & photos', 'Type instead, ask about a photo, the camera or a screenshot'),
      ('Memory', "'What did I just ask', 'what did you do', 'remember that'"),
      ('Yours to shape', 'Its name, voice and gender, theme colour, app lock, privacy switches'),
      ('Automatic updates', 'New versions install themselves'),
    ]),
  ];

  static const _building = <(String, String)>[
    ('Video avatar messages', 'Your assistant delivers messages as a talking avatar'),
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
          for (var g = 0; g < _groups.length; g++) ...[
            if (g > 0) const SizedBox(height: 22),
            _section(_groups[g].$1, NeonTone.success,
                Icons.check_circle_rounded, _groups[g].$2, g * 60,
                halo: g == 0 ? 0.6 : 0.4),
          ],
          const SizedBox(height: 22),
          _section('IN PROGRESS', NeonTone.warning, Icons.build_circle_rounded,
              _building, 360),
          const SizedBox(height: 22),
          _section('COMING SOON', NeonTone.discovery, Icons.schedule_rounded,
              _planned, 420),
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
