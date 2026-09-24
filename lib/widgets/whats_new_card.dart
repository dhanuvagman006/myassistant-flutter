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
  static const release = '0.2.97';
  static const items = <(IconData, String)>[
    (Icons.groups_rounded, 'Record a meeting (Hub → Meetings, or say "record this meeting"): get minutes, decisions and action items — share them as a PDF.'),
    (Icons.contact_mail_rounded, 'Scan a visiting card: the person is saved, one tap adds them to your contacts, another says hello on WhatsApp.'),
    (Icons.payments_rounded, 'Pay by voice: "pay Ravi 500" opens GPay or PhonePe ready to go — you approve with your UPI PIN.'),
    (Icons.event_available_rounded, 'Scan an insurance policy, licence or passport — renewal reminders 30 days and 7 days before it expires.'),
    (Icons.send_rounded, 'After a call: one tap sends a follow-up confirming what you agreed, by WhatsApp or SMS.'),
    (Icons.reply_rounded, 'Say "reply to Ramesh\'s last email — Friday works" and it replies in the same thread.'),
    (Icons.fingerprint_rounded, 'Lock the app with your fingerprint: You → Privacy & security.'),
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
