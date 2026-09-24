import 'package:flutter/material.dart';

import '../design/apple_kit.dart';
import '../design/dock_metrics.dart';
import '../design/neon_tokens.dart';
import 'clients_screen.dart';
import 'calls_screen.dart';
import 'documents_screen.dart';
import 'finance_screen.dart';
import 'phone/call_notes_screen.dart';
import 'reminders_screen.dart';
import 'meetings/meetings_screen.dart';
import 'email_setup_screen.dart';
import 'features_screen.dart';
import 'stocks_screen.dart';
import 'studio/studio_screen.dart';

/// HUB TAB — every feature as a front door.
///
/// Apple-style grouped lists (the iOS Settings pattern): plain ground,
/// white rounded groups, one row per destination with a small solid-color
/// icon tile, hairline separators and a chevron. No decoration that
/// doesn't inform — the calm look is the design.
class HubScreen extends StatelessWidget {
  const HubScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: ListView(
        // The last row clears the dock and the mic on every phone (a fixed
        // 120 left it under the mic with 3-button navigation).
        padding: EdgeInsets.fromLTRB(16, 18, 16, Dock.clearance(context)),
        children: [
          // The same large title every tab uses.
          const LargeTitle('Hub'),
          _group(context, 'Your day', [
            _Row(
              'Reminders',
              'Everything you asked me to remember — add, tick off, remove',
              Icons.notifications_active_rounded,
              Neon.accentA,
              (c) => const RemindersScreen(),
            ),
            _Row(
              'Meetings',
              'Record a meeting — get minutes, decisions and action items',
              Icons.groups_rounded,
              Neon.accentB,
              (c) => const MeetingsScreen(),
            ),
          ]),
          _group(context, 'Phone', [
            _Row(
              'Calls',
              'Calls I made for you — and what they said back',
              Icons.phone_in_talk_rounded,
              Neon.accentD,
              (c) => const CallsScreen(),
            ),
            _Row(
              'Call notes',
              'AI notes, reminders and answers from your recorded calls',
              Icons.call_rounded,
              Neon.accentE,
              (c) => const CallNotesScreen(),
            ),
            _Row(
              'Email',
              'Link your mailbox — then ask me to read or send mail',
              Icons.alternate_email_rounded,
              Neon.accentA,
              (c) => const EmailSetupScreen(),
            ),
          ]),
          _group(context, 'Practice', [
            _Row(
              'Clients & patients',
              'Case files, notes and their documents',
              Icons.folder_shared_rounded,
              Neon.accentF,
              (c) => const ClientsScreen(),
            ),
            _Row(
              'My documents',
              'Your own scans, IDs and files',
              Icons.description_rounded,
              Neon.accentC,
              (c) => const DocumentsScreen(),
            ),
          ]),
          _group(context, 'Looks', [
            _Row(
              'Style Studio',
              'Try on outfits and hairstyles on your own photo',
              Icons.auto_awesome_rounded,
              Neon.accentB,
              (c) => const StudioScreen(),
            ),
          ]),
          _group(context, 'Money', [
            _Row(
              'Finance',
              'EMIs, incomes and payoff plans',
              Icons.account_balance_wallet_rounded,
              Neon.accentB,
              (c) => const FinanceScreen(),
            ),
            _Row(
              'Markets',
              'Live stocks and analysis',
              Icons.trending_up_rounded,
              Neon.accentD,
              (c) => const StocksScreen(),
            ),
          ]),
          _group(context, 'App', [
            _Row(
              'Features',
              "What's live, what's being built, what's next",
              Icons.grid_view_rounded,
              Neon.accentC,
              (c) => const FeaturesScreen(),
            ),
          ]),
        ],
      ),
    );
  }

  // THE SAME LABEL AND CARD AS THE YOU TAB (2026-09-24). Hub drew its own
  // section label (accent, 11.5 sp, heavy, wide tracking) beside You's
  // grey one on the neighbouring tab, and its groups had no edge on the
  // ground. GroupLabel and GroupedCard are the shared pieces: one label
  // style, a hairline edge, and the separators inset past the icon tile.
  Widget _group(BuildContext context, String title, List<_Row> rows) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GroupLabel(title),
          GroupedCard(
            dividerInset: 60,
            children: [for (final r in rows) _rowTile(context, r)],
          ),
        ],
      ),
    );
  }

  // No press dip (2026-09-24): a full-width row inside its grouped card
  // pulled 8 dp in from the card's edges under the finger. The ripple is
  // the acknowledgement.
  Widget _rowTile(BuildContext context, _Row r) {
    return InkWell(
      onTap: () =>
          Navigator.of(context).push(MaterialPageRoute(builder: r.builder)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 11, 12, 11),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                // One family, not a bag of app-store colours: every tile
                // is built from the brand accents by the same rule.
                gradient: Neon.tile(r.color),
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(r.icon, color: Neon.onTile(r.color), size: 19),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    r.title,
                    style: NeonType.row.copyWith(color: Neon.textHi),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    r.subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: Neon.textLo,
                        fontSize: NeonType.footnote,
                        height: 1.3),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: Neon.textDim, size: 20),
          ],
        ),
      ),
    );
  }
}

class _Row {
  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;
  final Widget Function(BuildContext) builder;
  const _Row(this.title, this.subtitle, this.icon, this.color, this.builder);
}
