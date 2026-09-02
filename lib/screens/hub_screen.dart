import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../design/neon_tokens.dart';
import 'clients_screen.dart';
import 'diagnostics_screen.dart';
import 'finance_screen.dart';
import 'stocks_screen.dart';

/// HUB TAB — every feature as a front door.
///
/// Finance, markets, clients and tools used to hide behind small buttons
/// under the orb; here each one gets a real card with room to explain
/// itself — the "super-app" surface investors can actually see.
class HubScreen extends StatelessWidget {
  const HubScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final entries = [
      _Entry(
        'Finance',
        'EMIs, incomes & payoff plans',
        Icons.account_balance_wallet_rounded,
        Neon.violet,
        (c) => const FinanceScreen(),
      ),
      _Entry(
        'Markets',
        'Live stocks & AI analysis',
        Icons.trending_up_rounded,
        Neon.cyan,
        (c) => const StocksScreen(),
      ),
      _Entry(
        'Clients',
        'Case files & documents',
        Icons.folder_shared_rounded,
        Neon.pink,
        (c) => const ClientsScreen(),
      ),
      _Entry(
        'Connection',
        'Server & diagnostics',
        Icons.settings_ethernet_rounded,
        Neon.lime,
        (c) => const DiagnosticsScreen(),
      ),
    ];

    return SafeArea(
      bottom: false,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 120),
        children: [
          Text(
            'Hub',
            style: GoogleFonts.spaceGrotesk(
              fontSize: 27,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.5,
              color: Neon.textHi,
            ),
          ),
          const SizedBox(height: 4),
          Text('Everything your assistant can run for you.',
              style: TextStyle(color: Neon.textLo, fontSize: 13.5)),
          const SizedBox(height: 18),
          GridView.count(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: 2,
            mainAxisSpacing: 14,
            crossAxisSpacing: 14,
            childAspectRatio: 1.12,
            children: [for (final e in entries) _card(context, e)],
          ),
        ],
      ),
    );
  }

  Widget _card(BuildContext context, _Entry e) {
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () => Navigator.of(context)
          .push(MaterialPageRoute(builder: e.builder)),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Neon.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Neon.line),
          boxShadow: Neon.cardShadow,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: e.color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(e.icon, color: e.color, size: 23),
            ),
            const Spacer(),
            Text(e.title,
                style: TextStyle(
                    color: Neon.textHi,
                    fontSize: 15.5,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 3),
            Text(e.subtitle,
                maxLines: 2,
                style: TextStyle(
                    color: Neon.textLo, fontSize: 12, height: 1.3)),
          ],
        ),
      ),
    );
  }
}

class _Entry {
  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;
  final Widget Function(BuildContext) builder;
  const _Entry(this.title, this.subtitle, this.icon, this.color, this.builder);
}
