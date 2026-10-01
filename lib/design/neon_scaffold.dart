import 'package:flutter/material.dart';

import '../widgets/ambient_background.dart';
import 'neon_tokens.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  EVERY PAGE UNDER THE SAME SKY (2026-09-30, UI audit). Only the shell
///  and the splash drew the night sky; about 45 pushed screens painted a
///  flat `Neon.bg`, so opening anything from Home stepped out of the
///  client's neon room into a plain navy box.
///
///  A [Scaffold] for PUSHED screens: the same sky Home stands on
///  ([AmbientLight]) behind a transparent Scaffold. Swap
///  `Scaffold(backgroundColor: Neon.bg,` for `NeonScaffold(` — the common
///  parameters are the Scaffold's own.
///
///  COST. The sky never moves: it has no ticker, and it is one opaque
///  rectangle (shaders/ambient.frag, or its layered fallback) on its own
///  layer, recorded once and never again while the page above it scrolls,
///  animates or takes the keyboard — it sits outside the Scaffold, so the
///  keyboard does not even lay it out again. While a page slides in, the
///  two pages each draw theirs: the same two skies the dock's circle
///  reveal already draws. [sky] false keeps the plain ground (a camera or
///  full-bleed media page that covers it anyway).
/// ─────────────────────────────────────────────────────────────────────────
class NeonScaffold extends StatelessWidget {
  const NeonScaffold({
    super.key,
    this.appBar,
    this.body,
    this.floatingActionButton,
    this.floatingActionButtonLocation,
    this.floatingActionButtonAnimator,
    this.persistentFooterButtons,
    this.drawer,
    this.onDrawerChanged,
    this.endDrawer,
    this.onEndDrawerChanged,
    this.bottomNavigationBar,
    this.bottomSheet,
    this.resizeToAvoidBottomInset,
    this.primary = true,
    this.extendBody = false,
    this.extendBodyBehindAppBar = false,
    this.drawerScrimColor,
    this.restorationId,
    this.sky = true,
  });

  final PreferredSizeWidget? appBar;
  final Widget? body;
  final Widget? floatingActionButton;
  final FloatingActionButtonLocation? floatingActionButtonLocation;
  final FloatingActionButtonAnimator? floatingActionButtonAnimator;
  final List<Widget>? persistentFooterButtons;
  final Widget? drawer;
  final DrawerCallback? onDrawerChanged;
  final Widget? endDrawer;
  final DrawerCallback? onEndDrawerChanged;
  final Widget? bottomNavigationBar;
  final Widget? bottomSheet;
  final bool? resizeToAvoidBottomInset;
  final bool primary;
  final bool extendBody;
  final bool extendBodyBehindAppBar;
  final Color? drawerScrimColor;
  final String? restorationId;

  /// Draw the night sky behind the page (the default). False: the plain
  /// [Neon.bg] ground.
  final bool sky;

  @override
  Widget build(BuildContext context) {
    final scaffold = Scaffold(
      backgroundColor: sky ? Colors.transparent : Neon.bg,
      appBar: appBar,
      body: body,
      floatingActionButton: floatingActionButton,
      floatingActionButtonLocation: floatingActionButtonLocation,
      floatingActionButtonAnimator: floatingActionButtonAnimator,
      persistentFooterButtons: persistentFooterButtons,
      drawer: drawer,
      onDrawerChanged: onDrawerChanged,
      endDrawer: endDrawer,
      onEndDrawerChanged: onEndDrawerChanged,
      bottomNavigationBar: bottomNavigationBar,
      bottomSheet: bottomSheet,
      resizeToAvoidBottomInset: resizeToAvoidBottomInset,
      primary: primary,
      extendBody: extendBody,
      extendBodyBehindAppBar: extendBodyBehindAppBar,
      drawerScrimColor: drawerScrimColor,
      restorationId: restorationId,
    );
    if (!sky) return scaffold;
    return Stack(
      fit: StackFit.expand,
      children: [
        // Opaque, static, on its own layer (see above).
        const AmbientLight(),
        scaffold,
      ],
    );
  }
}
