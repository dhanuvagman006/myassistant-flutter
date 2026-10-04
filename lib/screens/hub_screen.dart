import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

import '../design/apple_kit.dart';
import '../design/dock_metrics.dart';
import '../design/neon_tokens.dart';
import 'clients_screen.dart';
import 'connected_apps_screen.dart';
import 'calendar_screen.dart';
import 'calls_screen.dart';
import 'documents_screen.dart';
import 'finance_screen.dart';
import 'phone/call_notes_screen.dart';
import 'reminders_screen.dart';
import 'shortcuts_screen.dart';
import 'news_screen.dart';
import 'nearby_screen.dart';
import 'email_setup_screen.dart';
import 'features_screen.dart';
import 'stocks_screen.dart';
import 'studio/studio_screen.dart';
import '../features/shopping/shopping_list_screen.dart';
import '../design/motion.dart';

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
            // The month, moved off Home (2026-09-29): Home shows what is
            // next; everything with a date lives here.
            _Row(
              'Calendar',
              'Everything with a date — reminders, promises, bills, birthdays',
              Icons.calendar_month_rounded,
              Neon.accentA,
              (c) => const CalendarScreen(),
            ),
            // "Office mode" (build 120): made by voice, run from here.
            _Row(
              'Shortcuts',
              'One word does several things — say its name',
              Icons.bolt_rounded,
              Neon.accentA,
              (c) => const ShortcutsScreen(),
            ),
            _Row(
              'Reminders',
              'Everything you asked me to remember — add, tick off, remove',
              Icons.notifications_active_rounded,
              Neon.accentA,
              (c) => const RemindersScreen(),
            ),
            // One list for anything to buy (build 124): groceries, a dress,
            // a charger — "add this to my shopping list" in any conversation.
            _Row(
              'Shopping list',
              'Anything to buy — say “add this to my shopping list”',
              Icons.shopping_basket_rounded,
              Neon.accentE,
              (c) => const ShoppingListScreen(),
              trailing: const ShoppingCountBadge(),
            ),
            // Chats took Nearby's dock tab (owner, 2026-10-04).
            _Row(
              'Nearby',
              'People around you and what they do',
              Icons.near_me_rounded,
              Neon.accentB,
              (c) => const NearbyScreen(),
            ),
          ]),
          // News as cards, by topic (2026-09-25).
          _group(context, 'Stay informed', [
            _Row(
              'News',
              "Today's stories as cards — swipe through, tap to read",
              Icons.newspaper_rounded,
              Neon.accentC,
              (c) => const NewsScreen(),
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
          _group(context, 'Connections', [
            _Row(
              'Connected apps',
              'Link your notes app, mail and more — in one place',
              Icons.hub_rounded,
              Neon.accentA,
              (c) => const ConnectedAppsScreen(),
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

  // THE ROW DIPS NOW (2026-09-30): the same 0.985 dip and light tick as
  // every AppleRow — a full-width row moves its edges three times as far
  // as a card, so the dip is a third of a card's. (2026-09-24 had no dip:
  // the old 0.97 pulled the row 8 dp in from its card's edges.)
  Widget _rowTile(BuildContext context, _Row r) {
    return PressScale(
      scale: 0.985,
      child: InkWell(
        onTap: () {
          HapticFeedback.selectionClick();
          Navigator.of(context).push(MaterialPageRoute(builder: r.builder));
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 11, 12, 11),
          child: Row(
            children: [
              // The shared lit tile (2026-09-30): the brand-built gradient
              // plus the glass sheen every other tile in the app now has.
              IconTile(r.icon, r.color, size: 36),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // The same words become the page's title: they fly into
                    // its bar as it pushes in (motion.dart, titleHeroTag).
                    Hero(
                      tag: titleHeroTag(r.title),
                      flightShuttleBuilder: titleFlight,
                      child: Text(
                        r.title,
                        style: NeonType.row.copyWith(color: Neon.textHi),
                      ),
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
              if (r.trailing != null) ...[
                const SizedBox(width: 8),
                r.trailing!
              ],
              Icon(Icons.chevron_right_rounded, color: Neon.textDim, size: 20),
            ],
          ),
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

  /// A live count beside the chevron (the shopping list's things to buy).
  final Widget? trailing;
  const _Row(this.title, this.subtitle, this.icon, this.color, this.builder,
      {this.trailing});
}
