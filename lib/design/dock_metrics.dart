import 'package:flutter/widgets.dart';

/// THE DOCK'S FOOTPRINT, IN ONE PLACE.
///
/// Every tab scrolls under the same thing: a 66 dp bar (plus the system
/// navigation inset under it) with the 76 dp mic docked on its top edge,
/// so the mic rises 38 dp above the bar. Lists used to end with a
/// hard-coded 120 dp of padding, which was 2 dp short on the owner's
/// phone and ~32 dp short on phones with 3-button navigation: the last
/// card ended under the mic. Everything that has to clear the dock asks
/// here instead of guessing.
abstract final class Dock {
  /// BottomAppBar.height in HomeShell.
  static const double barHeight = 66;

  /// How far the centre-docked mic rises above the bar (half of 76 dp).
  static const double orbRise = 38;

  /// Bottom padding that keeps content clear of the bar AND the mic.
  ///
  /// Inside HomeShell's body (extendBody) MediaQuery padding.bottom is
  /// already the bar plus the system inset; outside the shell it is just
  /// the inset, so the same call stays sensible on a pushed screen.
  static double clearance(BuildContext context, {double gap = 18}) =>
      MediaQuery.paddingOf(context).bottom + orbRise + gap;
}
