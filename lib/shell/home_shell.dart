import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design/neon_tokens.dart';
import '../features/assistant/assistant_screen.dart';
import '../features/assistant/state/assistant_engine.dart';
import '../screens/assistant_settings_screen.dart';
import '../screens/home_dashboard.dart';
import '../screens/hub_screen.dart';
import '../screens/updates_screen.dart';
import '../services/assistant_identity.dart';
import '../services/brief_service.dart';
import '../services/location_service.dart';
import '../services/usage_service.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  HOME SHELL — the app's new backbone (Daylight redesign, Sept 2026).
///
///  Three tabs (Home · Hub · You) with the mic docked centre-stage: the
///  dashboard is the resting state, and the voice conversation is a
///  full-screen moment you summon — not a wall you live behind.
///  All boot work that used to live in AssistantScreen happens here,
///  because this is now the first screen after sign-in.
/// ─────────────────────────────────────────────────────────────────────────
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  /// Survives the full-tree rebuild a theme flip causes, so toggling dark
  /// mode in the You tab doesn't dump the user back on Home.
  static int lastTab = 0;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = HomeShell.lastTab;

  @override
  void initState() {
    super.initState();
    final engine = AssistantEngine.instance;
    engine.start();
    // The assistant's user-chosen name — every visible mention reads this.
    AssistantIdentity.load();
    BriefService.instance.start();
    // Deliberately NO message announcing here: launching the app must be
    // SILENT. Unread messages sit in the Home feed and are spoken when
    // the user starts a conversation or taps the message notification.
    // Silent no-ops until their permissions are granted.
    UsageService.instance.syncIfPermitted();
    LocationService.instance.refresh();
  }

  void _openConversation() {
    HapticFeedback.mediumImpact();
    Navigator.of(context).push(
      PageRouteBuilder(
        fullscreenDialog: true,
        transitionDuration: const Duration(milliseconds: 280),
        pageBuilder: (_, __, ___) => const AssistantScreen(),
        transitionsBuilder: (_, anim, __, child) => SlideTransition(
          position: Tween(begin: const Offset(0, 0.06), end: Offset.zero)
              .animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
          child: FadeTransition(opacity: anim, child: child),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Neon.bg,
      extendBody: true,
      body: IndexedStack(
        index: _tab,
        children: const [
          HomeDashboard(),
          HubScreen(),
          UpdatesScreen(),
          AssistantSettingsScreen(),
        ],
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      floatingActionButton: GestureDetector(
        onTap: _openConversation,
        child: Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Neon.textHi,
            boxShadow: [
              BoxShadow(
                color: Neon.textHi.withValues(alpha: 0.28),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Icon(Icons.mic_rounded, color: Neon.onInk, size: 30),
        ),
      ),
      bottomNavigationBar: BottomAppBar(
        color: Neon.surface,
        elevation: 0,
        height: 66,
        shape: const CircularNotchedRectangle(),
        notchMargin: 8,
        padding: EdgeInsets.zero,
        child: Row(
          children: [
            // Two items each side of the notch keeps the row symmetric.
            _navItem(0, Icons.space_dashboard_outlined,
                Icons.space_dashboard_rounded, 'Home'),
            _navItem(
                1, Icons.grid_view_outlined, Icons.grid_view_rounded, 'Hub'),
            const SizedBox(width: 72), // notch space for the mic
            _navItem(2, Icons.newspaper_outlined, Icons.newspaper_rounded,
                'Updates'),
            _navItem(3, Icons.person_outline_rounded, Icons.person_rounded,
                'You'),
          ],
        ),
      ),
    );
  }

  Widget _navItem(int i, IconData icon, IconData active, String label) {
    final selected = _tab == i;
    return Expanded(
      child: InkWell(
        onTap: () {
          HapticFeedback.selectionClick();
          HomeShell.lastTab = i;
          setState(() => _tab = i);
        },
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(selected ? active : icon,
                size: 23, color: selected ? Neon.textHi : Neon.textDim),
            const SizedBox(height: 3),
            Text(label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected ? Neon.textHi : Neon.textDim,
                )),
          ],
        ),
      ),
    );
  }
}
