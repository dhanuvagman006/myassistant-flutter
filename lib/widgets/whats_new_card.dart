import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../design/motion.dart';
import '../design/neon_tokens.dart';
import '../services/api_service.dart';

/// WHAT'S NEW — a card at the top of Home, once per release.
///
/// Improvements nobody is told about are improvements nobody notices. Not
/// a dialog (launch stays calm): a dismissible card in the feed, gone for
/// good once closed, back only when there is a new list.
class WhatsNewCard extends StatefulWidget {
  const WhatsNewCard({super.key});

  /// Bump with every release that has something worth telling.
  /// The release this card describes: the one the server published last
  /// (its changelog is what the user just installed). A baked-in list
  /// used to describe 0.2.99 forever (2026-10-01).
  static String get release => ApiService.config.latestVersionName;

  static const _icons = [
    Icons.auto_awesome_rounded,
    Icons.record_voice_over_rounded,
    Icons.photo_camera_rounded,
    Icons.calendar_month_rounded,
  ];

  static List<(IconData, String)> get items => [
        for (final (i, line) in ApiService.config.changelog.indexed)
          (_icons[i % _icons.length], line),
      ];

  static String _key() => 'whats_new_seen_$release';

  @override
  State<WhatsNewCard> createState() => _WhatsNewCardState();
}

class _WhatsNewCardState extends State<WhatsNewCard> {
  bool _show = false;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      // Nothing to say (no changelog yet) is no card at all.
      if (mounted && WhatsNewCard.items.isNotEmpty && p.getBool(WhatsNewCard._key()) != true) {
        setState(() => _show = true);
      }
    }).catchError((_) {});
  }

  Future<void> _dismiss() async {
    HapticFeedback.selectionClick();
    setState(() => _show = false);
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(WhatsNewCard._key(), true);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    // Fades in as its room opens, and the room closes on the standard
    // curve in 180 ms once it is dismissed (2026-09-24: it was uncovered
    // like a curtain, and left a blank gap that closed slowly).
    return AnimatedSize(
      duration: const Duration(milliseconds: 180),
      curve: Motion.easeMove,
      child: !_show
          ? const SizedBox(width: double.infinity)
          : EnterOnce(
              duration: Motion.micro,
              delay: const Duration(milliseconds: 60),
              child: Container(
              margin: const EdgeInsets.only(bottom: 18),
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
              decoration: BoxDecoration(
                color: Neon.surfaceHigh,
                borderRadius: BorderRadius.circular(Neon.rLg),
                border: Border.all(color: Neon.violet.withValues(alpha: 0.45)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(Icons.auto_awesome_rounded, color: Neon.violet, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text("What's new",
                          style: TextStyle(
                              color: Neon.textHi, fontSize: 16, fontWeight: FontWeight.w700)),
                    ),
                    IconButton(
                      tooltip: 'Dismiss',
                      onPressed: _dismiss,
                      icon: Icon(Icons.close_rounded, color: Neon.textLo, size: 20),
                    ),
                  ]),
                  for (final (icon, text) in WhatsNewCard.items)
                    Padding(
                      padding: const EdgeInsets.only(top: 8, right: 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(icon, size: 17, color: Neon.cyan),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(text,
                                style: TextStyle(color: Neon.textLo, fontSize: 14, height: 1.4)),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            ),
    );
  }
}
