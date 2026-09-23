import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../design/neon_tokens.dart';

/// WHAT'S NEW — a card at the top of Home, once per release.
///
/// Improvements nobody is told about are improvements nobody notices. Not
/// a dialog (launch stays calm): a dismissible card in the feed, gone for
/// good once closed, back only when there is a new list.
class WhatsNewCard extends StatefulWidget {
  const WhatsNewCard({super.key});

  /// Bump with every release that has something worth telling.
  static const release = '0.2.95';
  static const items = <(IconData, String)>[
    (Icons.graphic_eq_rounded, 'A new listening orb that ripples with your voice, so you can see it hearing you.'),
    (Icons.phone_in_talk_rounded, 'Call notes, clearer: calls grouped by day, a summary for each, and an honest status when one is still being analysed.'),
    (Icons.search_rounded, 'Search everything — documents, clients, reminders and chats — from the button on Home.'),
    (Icons.notifications_active_rounded, 'All your reminders in one place: Hub → Reminders. Add, tick off, or see which ones will call you.'),
    (Icons.undo_rounded, 'Swiped something by mistake? Every swipe and tick can now be undone.'),
    (Icons.manage_accounts_rounded, 'Sign out, export or delete your account from the You tab.'),
    (Icons.wifi_off_rounded, 'Clear messages when you are offline or something goes wrong — with a way to try again.'),
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
      if (mounted && p.getBool(WhatsNewCard._key()) != true) setState(() => _show = true);
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
    return AnimatedSize(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
      child: !_show
          ? const SizedBox(width: double.infinity)
          : Container(
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
                                style: TextStyle(color: Neon.textLo, fontSize: 13.5, height: 1.4)),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}
