import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../design/neon_tokens.dart';
import 'clients_screen.dart';
import 'diagnostics_screen.dart';
import 'documents_screen.dart';
import 'finance_screen.dart';
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
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 120),
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 20),
            child: Text(
              'Hub',
              style: GoogleFonts.spaceGrotesk(
                fontSize: 32,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.6,
                color: Neon.textHi,
              ),
            ),
          ),
          _group(context, 'Practice', [
            _Row(
              'Clients & patients',
              'Case files, notes and their documents',
              Icons.folder_shared_rounded,
              const Color(0xFF007AFF),
              (c) => const ClientsScreen(),
            ),
            _Row(
              'My documents',
              'Your own scans, IDs and files',
              Icons.description_rounded,
              const Color(0xFF34C759),
              (c) => const DocumentsScreen(),
            ),
          ]),
          _group(context, 'Looks', [
            _Row(
              'Style Studio',
              'Try on outfits and hairstyles on your own photo',
              Icons.auto_awesome_rounded,
              const Color(0xFFAF52DE),
              (c) => const StudioScreen(),
            ),
          ]),
          _group(context, 'Money', [
            _Row(
              'Finance',
              'EMIs, incomes and payoff plans',
              Icons.account_balance_wallet_rounded,
              const Color(0xFFAF52DE),
              (c) => const FinanceScreen(),
            ),
            _Row(
              'Markets',
              'Live stocks and analysis',
              Icons.trending_up_rounded,
              const Color(0xFFFF9500),
              (c) => const StocksScreen(),
            ),
          ]),
          _group(context, 'System', [
            _Row(
              'Connection',
              'Server and diagnostics',
              Icons.settings_ethernet_rounded,
              const Color(0xFF8E8E93),
              (c) => const DiagnosticsScreen(),
            ),
          ]),
        ],
      ),
    );
  }

  Widget _group(BuildContext context, String title, List<_Row> rows) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 16, bottom: 7),
            child: Text(
              title.toUpperCase(),
              style: TextStyle(
                color: Neon.textDim,
                fontSize: 13,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.4,
              ),
            ),
          ),
          Material(
            color: Neon.surface,
            borderRadius: BorderRadius.circular(14),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (var i = 0; i < rows.length; i++) ...[
                  if (i > 0)
                    Padding(
                      // Hairline inset to align with the text, iOS-style.
                      padding: const EdgeInsets.only(left: 60),
                      child: Divider(height: 1, thickness: 0.5, color: Neon.line),
                    ),
                  _rowTile(context, rows[i]),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _rowTile(BuildContext context, _Row r) {
    return InkWell(
      onTap: () =>
          Navigator.of(context).push(MaterialPageRoute(builder: r.builder)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 11, 12, 11),
        child: Row(
          children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: r.color,
                borderRadius: BorderRadius.circular(7),
              ),
              child: Icon(r.icon, color: Colors.white, size: 18),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    r.title,
                    style: TextStyle(
                      color: Neon.textHi,
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                      letterSpacing: -0.2,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    r.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: Neon.textLo, fontSize: 12.5),
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
